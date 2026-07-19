---
aliases:
  - Read-heavy content service design
  - Проектирование сервиса контента с преобладанием чтения
tags:
  - область/проектирование-систем
  - тип/разбор
  - тема/read-heavy
статус: проверено
---

# Проектирование read-heavy content service

## TL;DR

Система хранит каноническую metadata в транзакционной БД, крупные immutable payload и media — в object storage, а публичные представления раздаёт через CDN. Write path сначала фиксирует управляемое состояние `draft → publishing → published`, затем асинхронно строит производные данные: search document, cache invalidation и preview. Read path почти всегда заканчивается на CDN или distributed cache; origin остаётся источником истины, а не самым быстрым слоем.

Главный компромисс — свежесть против доступности и цены. Для опубликованного immutable content допустимы долгие TTL и stale serving. Permission revoke или удаление требует authoritative deny либо короткоживущего version-bound grant на каждый новый private read. Versioned URL и адресный purge ускоряют переход, но сами не отзывают уже известный старый URL: без отдельной deny-границы быстрый CDN превращается в канал утечки.

## Контекст и ментальная модель

Проектируем сервис статей и media. Автор создаёт и редактирует материал, читатели открывают его по `content_id` или slug. Reads примерно на три порядка чаще writes. Контент после публикации меняется редко, поэтому горячий путь надо отделить от authoring path.

Ментальная модель: control plane управляет metadata, версиями и доступом; data plane раздаёт уже опубликованные bytes. Такой разрез не заставляет API-сервер проксировать каждый мегабайт и позволяет независимо масштабировать публикацию и чтение.

## Требования

### Functional requirements

- Создать draft, загрузить media, обновить и опубликовать версию.
- Получить опубликованную версию по стабильному ID; slug служит вторичным lookup.
- Поддержать public, unlisted и private content.
- Удалить или скрыть материал, не переиспользуя его immutable version URL.
- Вернуть список материалов автора через cursor pagination.

### Non-functional requirements

- Reads продолжаются при кратком отказе origin, если в edge cache есть безопасная версия.
- Подтверждённая публикация не указывает на отсутствующий object.
- Один idempotency key не создаёт две логические публикации.
- Нельзя отдать private representation через shared cache.
- Система выдерживает резкий hot-key spike после внешней ссылки.

### SLO: availability, latency, durability, consistency

Interview targets:

| Путь | SLO |
| --- | --- |
| Public read | 99,95% успешных запросов за 30 дней; p95 ≤ 150 ms и p99 ≤ 400 ms от ближайшего edge при cache hit |
| Origin read | 99,9%; p99 ≤ 500 ms без учёта передачи крупного media |
| Publish | 99,9%; p99 ≤ 1 s до durable состояния `published` |
| Durability | после успешного publish metadata и object не теряются при отказе одной зоны; region-loss RPO ≤ 5 min, RTO ≤ 30 min |
| Consistency | author получает read-your-writes; новый public reader видит версию не позднее 60 s; revoke private access запрещает новые read/download starts ≤ 10 s |

Разные окна свежести намеренны. Публикацию можно немного задержать, а revoke нельзя прятать за минутным TTL. Базовый SLO относится к новой авторизации и началу нового HTTP request: уже переданные bytes не отозвать, а stream, начатый до revoke, object storage обычно не прерывает. Если product требует оборвать активную передачу, нужен online authorization proxy/edge, который контролирует stream; обычного signed URL недостаточно.

### Вне scope

- Совместное редактирование документа в реальном времени.
- Персонализированное ранжирование ленты.
- Транскодирование видео и DRM.
- Полнотекстовый поиск: индекс получает события, но его внутреннее устройство раскрыто в [[30 Данные/Search index|заметке о search index]].

## Traffic и storage estimates

Все числа ниже — interview assumptions, не benchmark продукта.

- 50 млн DAU, по 20 открытий в день: `50M × 20 = 1B reads/day`.
- Средний read rate: `1B / 86 400 ≈ 11 574 RPS`; peak factor 10 даёт `≈ 116k RPS`.
- 1 млн новых версий в день: `1M / 86 400 ≈ 11,6 writes/s`; peak factor 10 — `≈ 116 writes/s`.
- Средняя metadata 4 KiB: `1M × 4 KiB ≈ 3,8 GiB/day`, около `1,4 TiB/year` без индексов и реплик.
- В среднем 1 MiB media на новую версию: `≈ 0,95 TiB/day`, около `348 TiB/year` logical storage.
- Если 80% public reads закрывает CDN, origin peak снижается с `116k` до `≈ 23k RPS`. Это capacity assumption; его надо подтвердить hit-ratio по реальному workload.

Крупнейшая статья и самый популярный object важнее среднего. Отдельно измеряем размер p99, распределение popularity и долю private reads, которые нельзя положить в общий cache.

## API contract

```http
POST /v1/contents
Idempotency-Key: 9d3...

{"visibility":"public","title":"..."}
```

Ответ `201` содержит `content_id`, `version_id`, upload URLs и `state=draft`. Повтор с тем же ключом и тем же payload возвращает тот же результат; другой payload получает conflict согласно [[20 Бэкенд/Ключи идемпотентности и дедупликация запросов|контракту idempotency key]].

```http
POST /v1/contents/{content_id}/versions/{version_id}:publish
If-Match: "draft-revision-7"

GET /v1/contents/{content_id}
GET /v1/authors/{author_id}/contents?cursor=...
DELETE /v1/contents/{content_id}
```

`GET` возвращает immutable `version_id`, metadata, `ETag` и подписанные URL для непубличных objects. Cursor включает `(published_at, content_id)`, чтобы вставки не сдвигали страницы; подробнее этот выбор разобран в [[20 Бэкенд/Пагинация offset, cursor и continuation token|заметке о пагинации]].

## Data model

```text
content(content_id, owner_id, visibility, current_version_id, state,
        slug, created_at, updated_at, row_version)

content_version(content_id, version_id, title, body_object_key,
                manifest_hash, created_at, published_at, status)

asset(asset_id, content_id, version_id, object_key, size, checksum,
      media_type, scan_status)

outbox(event_id, aggregate_id, type, payload, created_at, published_at)
```

`current_version_id` меняется одной транзакцией вместе с `published` и outbox event. Object key содержит случайный `version_id`, поэтому новый upload не перезаписывает опубликованные bytes. Slug не primary key: rename не должен менять identity.

## High-level architecture

```text
client -> CDN -> read API -> distributed cache -> metadata DB
            \-------------------------------> object storage

author -> write API -> metadata DB + outbox
          |             |
          |             +-> event stream -> indexer / invalidator / preview worker
          +-> signed multipart upload ------> object storage
```

CDN кэширует только public versioned URLs. Read API проверяет visibility и возвращает manifest. Write API владеет state machine; workers не могут самостоятельно сделать draft опубликованным.

## Read path и write path

### Write path

1. Author создаёт draft. API фиксирует metadata и выдаёт ограниченные по времени upload URLs.
2. Client загружает assets напрямую в object storage и передаёт checksum.
3. Finalize проверяет наличие, размер и checksum; malware scan переводит asset из `pending` в `clean`.
4. Publish в одной DB-транзакции проверяет ownership и revision, обновляет `current_version_id` и пишет outbox event.
5. Event workers инвалидируют mutable lookup `/contents/{id}`, строят search projection и прогревают CDN только для public content.

### Read path

1. Public versioned URL проверяется на edge. Hit завершает запрос без origin.
2. На miss read API ищет manifest в cache, затем в metadata DB.
3. Для public object возвращается CDN URL; для private — signed URL, связанный с конкретной версией и authorization decision. Decision живёт не больше 10 s, а `expires_at` URL не позже `decision_checked_at + 10 s`: повторная выдача из старого cache не продлевает доступ.
4. Conditional request с `ETag` даёт `304`, а range request — `206`, если клиент продолжает загрузку.

### Сквозная трассировка

Author публикует `content=C7`, `version=V3`. Object `assets/C7/V3/body` уже записан и checksum совпал. Транзакция ставит `current_version_id=V3` и outbox event `E91`, после commit API отвечает `published`. Worker повторно получает `E91` после timeout, но дедуплицирует его по `event_id`; purge выполняется дважды безопасно. Первый reader делает origin miss, получает manifest V3 и наполняет CDN. Следующие readers читают V3 с edge. Ни один из них не увидит metadata V3 до существования object.

## Выбор storage

Metadata и state transitions требуют constraints, conditional update и локальной транзакции, поэтому стартовая точка — SQL. Выбор между SQL и key-value зависит от формы доступа и границ корректности; эти признаки разобраны в [[30 Данные/SQL или key-value|заметке о выборе storage]].

Body и media лежат в [[30 Данные/Object и blob storage|object storage]]: доступ идёт по key, objects велики и почти immutable. Search index и CDN — производные слои; потеря одного из них не должна уничтожать source of truth.

## Partitioning и replication

- До предела одной SQL-инсталляции применяем read replicas и индексы `(owner_id, published_at, content_id)`.
- Затем metadata shard key — hash `content_id`; lookup по slug идёт через отдельный directory или globally unique slug table.
- Object key начинается с hash/version ID, чтобы не концентрировать writes на одном префиксе реализации.
- Metadata синхронно реплицируется между зонами. Cross-region replica асинхронна и определяет заявленный RPO.
- CDN и cache не входят в durability boundary. Их можно перестроить.

Shard по `owner_id` удобен для author listing, но celebrity author создаёт hot shard. Hash по `content_id` ровнее; список автора тогда хранится отдельной projection.

## Caching

Используем три разных policy:

- Immutable version URL: `Cache-Control: public, max-age=31536000, immutable`.
- Mutable current-version lookup: короткий TTL, `ETag` и purge после publish.
- Private content: `private, no-store` для shared intermediaries; signed URL не превращает response автоматически в безопасный shared object. Каждый новый request после URL expiry снова проходит authorization.

Request coalescing на miss и stale-while-revalidate защищают origin от stampede. Но stale serving отключается для permission lookup и tombstone. Семантика validators и shared caches опирается на [[20 Бэкенд/HTTP-методы, статус-коды, заголовки и семантика кэширования|HTTP caching contract]].

## Async processing

Search indexing, preview generation, analytics и CDN purge идут после DB commit через [[40 Распределённые системы/Transactional outbox и Change Data Capture|transactional outbox]]. Delivery остаётся at-least-once, поэтому consumers используют `event_id` и version compare. Очередь ограничивает concurrency и применяет [[40 Распределённые системы/Backpressure и queue buildup|backpressure]], иначе массовый reindex вытеснит свежие публикации.

## Failure handling

| Failure | Сигнал | Реакция | Остаточный эффект |
| --- | --- | --- | --- |
| Metadata DB primary недоступна | write errors, replica health | остановить publish, продолжить безопасные cached reads, выполнить controlled failover | authoring временно недоступен |
| Object upload оборвался | incomplete session age, missing parts | resumable multipart; lifecycle удаляет abandoned parts | draft остаётся `uploading` |
| Outbox consumer отстал | event lag, oldest-event age | добавить workers, приоритизировать invalidation, throttling reindex | search/preview устаревают, source остаётся корректным |
| CDN purge потерян | old-version hit после publish | versioned URLs, короткий TTL mutable key, periodic reconciliation | ограниченное окно stale content |
| Hot key перегрузил origin | cache miss rate, per-key QPS | coalescing, shield cache, stale public response, rate limit expensive variants | первая miss может быть медленной |
| Region потерян | synthetic journey и regional health | route public reads к replica/CDN; promote metadata только по runbook и fencing | writes ждут promotion; потеря в пределах RPO |
| Ошибочное удаление | delete audit, tombstone count | soft delete, version retention, restore + purge correction | восстановление зависит от retention |
| Private grant отозван | deny-after-revoke probe, auth-cache age | push invalidation; URL expiry ограничен исходным 10-секундным decision window | начатый до revoke stream может завершиться; новые starts блокируются ≤ 10 s |

## Security

- Authorization проверяет owner и visibility на metadata path; object store не принимает произвольный public write.
- Upload URL ограничен key, методом, размером, content type и сроком; finalize повторно сверяет metadata.
- Private response нельзя кэшировать общим ключом без user/entitlement dimension. Authorization cache entry хранит `checked_at`/`valid_until ≤ checked_at + 10 s`; новый signed URL не сдвигает `valid_until`.
- Malware scan и content-type sniffing происходят до публикации пользовательских файлов.
- Object keys не считаются секретом. Доступ задают policy и короткоживущая подпись.
- Audit log хранит publish, visibility change, delete и administrative restore без чувствительного body.

## Observability

SLI разделяются по edge hit и origin path: общий p99 скроет медленный miss. Нужны `cdn_hit_ratio`, origin RPS, cache fill latency, DB saturation, object errors, outbox lag, publish-state age, purge latency и доля unsafe stale responses. Для private path отдельно измеряем authorization decision age и время от revoke commit до отказа нового download start; незавершённые streams считаются отдельной метрикой. Trace context проходит от API до outbox event через correlation fields по W3C Trace Context.

Synthetic checks выполняют public read, private denial, upload-finalize-publish и delete. Alert строится по burn rate SLO, а не по одному CPU threshold.

## Capacity planning

При peak `116k reads/s` и 80% CDN hit origin видит `≈23k/s`. С 30% headroom проектируем `23k / 0,7 ≈ 33k RPS` origin capacity. Если одна измеренная replica выдерживает 2k RPS при нужном p99, нужно минимум `ceil(33/2)=17` replicas; 2k — целевой результат load test, не свойство runtime.

Object growth `≈348 TiB/year` задаёт lifecycle, replication budget и restore test. DB capacity считают отдельно по metadata, индексам и WAL; media bytes туда не попадают.

## Cost trade-offs

Главные статьи — object storage, CDN egress, cross-region replication и cache memory. Высокий edge hit одновременно снижает latency и origin cost. Полная multi-region active-active запись для редких authoring writes дорога и усложняет conflict handling; single home writer плюс read replicas обычно лучше, пока business SLO не требует продолжать публикацию при потере региона.

Preview каждого размера заранее уменьшает CPU на read, но увеличивает storage. On-demand transform дешевле для cold content и опаснее для hot-key spike; практичный вариант генерирует несколько популярных размеров при publish, редкие — лениво с дедупликацией.

## Migration и rollout plan

1. Начать с SQL + object storage, API-сервисов и versioned URLs; CDN включить в shadow metrics.
2. Разрешить CDN для малого процента public content, сравнивая checksum/headers с origin.
3. Ввести outbox и dual-publish события, пока старый synchronous indexer остаётся источником поведения.
4. Переключить search/preview/invalidation consumers по одному; reconciliation сравнивает expected и actual versions.
5. При шардировании выполнить online backfill, dual read с наблюдением расхождений и затем сменить write authority по процедуре [[30 Данные/Dual read и dual write migrations|dual read/write migration]].
6. Multi-region добавить после измеренного SLO gap: replica, restore drill, read traffic, controlled promotion, затем failback.

Каждый этап обратим до смены authority. Rollback приложения не должен откатывать уже опубликованный object или schema несовместимо.

## Bottlenecks

- Hot content key и одновременный cache expiry.
- Metadata index по slug/author, если pagination или cardinality выбраны плохо.
- Egress и preview CPU, а не средний write QPS.
- Outbox lag после bulk import.
- Purge API provider и control-plane limits CDN.
- Cross-region object replication lag, который расходится с metadata RPO.

## Trade-offs и альтернативы

| Решение | Выигрыш | Цена | Когда менять |
| --- | --- | --- | --- |
| Fanout через CDN | низкая read latency и egress с origin | invalidation и privacy risk | public immutable content преобладает |
| SQL metadata | транзакция publish и constraints | write scaling требует sharding | инварианты важнее экстремального write QPS |
| Immutable versions | простое caching и rollback | больше storage, нужен GC | почти всегда для published content |
| Single-region writer | простой порядок версий | writes останавливаются при region failover | переходить к multi-writer лишь при подтверждённом SLO |
| Synchronous indexing | мгновенный search | publish зависит от index | оставить async, если search freshness допускает lag |

## Типичные ошибки

- **Неверное предположение:** object upload и metadata update можно считать одной транзакцией. **Симптом:** published row указывает на отсутствующий object. **Причина:** разные durability boundaries. **Исправление:** state machine, finalize-check и reconciliation.
- **Неверное предположение:** signed URL безопасно кэшировать как public. **Симптом:** пользователь получает чужой private object. **Причина:** cache key не включает entitlement. **Исправление:** private/no-store либо CDN token validation с точной policy.
- **Неверное предположение:** purge гарантирует мгновенную глобальную инвалидацию. **Симптом:** часть edge отдаёт старую версию. **Причина:** distributed control plane и retries. **Исправление:** versioned URL, bounded TTL и tombstone policy.

## Когда применять

Дизайн подходит для статей, карточек каталога, профилей, изображений и другого контента, где опубликованная версия редко меняется, reads доминируют, а media можно адресовать immutable key. Для collaborative editor, low-latency trading state или per-request персонализированного document лучше выбрать другой центр архитектуры.

## Источники

- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RFC 9111: HTTP Caching](https://www.rfc-editor.org/rfc/rfc9111) — IETF, RFC 9111, июнь 2022, проверено 2026-07-18.
- [What is Amazon S3? — data consistency model](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel) — Amazon Web Services, актуальная редакция Amazon S3 User Guide, проверено 2026-07-18.
- [Uploading and copying objects using multipart upload](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html) — Amazon Web Services, актуальная редакция Amazon S3 User Guide, проверено 2026-07-18.
- [Use signed URLs](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-signed-urls.html) — Amazon Web Services, актуальная редакция Amazon CloudFront Developer Guide; expiration проверяется при начале HTTP request, проверено 2026-07-18.
- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering, издание 2016 года, проверено 2026-07-18.
- [Trace Context](https://www.w3.org/TR/trace-context/) — W3C Recommendation, редакция 23 ноября 2021, проверено 2026-07-18.
