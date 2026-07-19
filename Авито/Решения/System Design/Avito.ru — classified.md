---
aliases:
  - Avito classified system design
  - Проектирование Avito.ru
  - Classified backend
tags:
  - тип/разбор
  - область/проектирование-систем
  - компания/авито
  - тема/classified
статус: проверено
---

# Avito.ru — classified

## TL;DR

Canonical listing хранится в transactional database, фотографии — в object storage за CDN, полнотекстовый search index — восстановимая eventual-consistent projection. Создание объявления проходит state machine `draft → media_ready → active`; commit `active` и outbox event атомарны. Indexer применяет только монотонно более новую `listing_version`, поэтому retry и out-of-order delivery безопасны.

SERP читает search index и допускает согласованную бизнесом задержку. Карточка и список собственных объявлений читают canonical/projection stores с более строгой свежестью. В выбранном расширении жизненного цикла удаление, блокировка и изменение прав не ждут обычного search refresh: deny overlay или final revalidation не даёт показать запрещённое объявление. Это проектное допущение, а не требование исходника. На старте 100 RPS решение можно держать простым; границы command, media и search сохраняются, чтобы масштабироваться к 20k RPS без преждевременной сетевой декомпозиции.

## Контекст и ментальная модель

Backend классифайда должен:

- выполнять полнотекстовый поиск и возвращать SERP;
- показывать карточку объявления;
- показывать объявления владельца;
- принимать новое объявление, которое позже появляется в поиске;
- хранить несколько фотографий.

По условию система растёт со 100 до 20k RPS, reads относятся к writes как 100:1, а задержка индексации допустима. Главное следствие: source of truth и read-optimized search view не надо насильно объединять. [[50 Проектирование систем/Проектирование поиска и автодополнения|Search]] отвечает «какие candidates подходят», database — «каково актуальное состояние и вправе ли пользователь его видеть».

## Требования

### Функциональные

Из условия:

- создать объявление с текстом для полнотекстового поиска и несколькими фотографиями;
- опубликовать его с допустимой задержкой появления в поиске;
- получить SERP полнотекстового поиска, карточку объявления и список объявлений владельца.

Для полного жизненного цикла дальше приняты проектные допущения, которых нет в исходнике:

- draft/publish state machine, stable `listing_id` и отдельный indexing status;
- filters, sorting и cursor pagination в поиске;
- update, unpublish и delete с защитой от воскрешения старым search event;
- moderation/block state и безопасный media lifecycle.

### Нефункциональные и SLO

Точные SLO в условии отсутствуют. Для интервью фиксируем проектные цели:

- card/owner list: 99,95% availability, p99 до 400 мс server-side;
- bounded SERP: 99,9%, p95 до 250 мс, p99 до 600 мс;
- publish durability: ответ `active` только после canonical commit;
- 99% active listings появляются в search не позже 60 секунд;
- для принятого выше delete/block lifecycle цель — исчезновение из выдачи не позже 10 секунд через deny overlay;
- search может быть eventual, но version одного listing не откатывается назад.

Эти числа — design targets для обсуждения, а не статистика Avito. Их меняют после business SLA и load test.

### Вне scope

- Frontend, рекомендации, рекламный auction и ML ranking.
- Платежи, доставка и messenger.
- Реализация search engine, object store или image codec.
- Юридическая модель moderation; проектируется только technical state flow.

## Оценка нагрузки и ёмкости

Из условия: 100 RPS на старте, до 20k RPS, отношение writes к reads `1:100`.

При `T` total RPS:

```text
write_rps = T / 101
read_rps  = 100T / 101
```

На целевом пике 20k это примерно `198 writes/s` и `19 802 reads/s`. На старте — около `1 write/s` и `99 reads/s`. Это peak split, не среднесуточный traffic: умножать 20k на сутки как постоянную нагрузку без diurnal profile нельзя.

Доли SERP/card/owner-list неизвестны. Пусть `q` — доля search reads; тогда search peak `≈19 802q QPS`. Capacity engine определяют query mix, filters, result window и p99; одного documents count недостаточно.

Для media в условии нет числа photos и среднего size. Если create rate равен `C`, среднее число photos `P`, а средний compressed object `S` bytes, ingress равен `C × P × S`, logical storage/day — `C × 86 400 × P × S`. Эти параметры надо получить из аналитики; подстановка случайных «5 фото по 1 MB» не становится фактом.

Аналогично search capacity: при `D` active documents и среднем index footprint `I`, primary index имеет порядок `D × I`; replicas, segment overhead и blue-green reindex умножают объём. Во время reindex старая и новая generation сосуществуют, поэтому capacity резервируют заранее.

## API и модель данных

### API

```http
POST /v1/listings
Idempotency-Key: create-7
{"title":"...","description":"...","category_id":42,"price":1000}

POST /v1/listings/{listing_id}/media:begin-upload
POST /v1/listings/{listing_id}:publish
If-Match: "listing-version-3"

GET /v1/listings/{listing_id}
GET /v1/me/listings?status=active&cursor=...&limit=50
GET /v1/search?q=велосипед&category_id=42&cursor=...&limit=50
```

Create/publish используют [[20 Бэкенд/Ключи идемпотентности и дедупликация запросов|idempotency keys]]. Update защищён optimistic version/ETag: два редактора не перетирают друг друга молча. Search cursor включает hash query/filter/access scope, index generation, point-in-time handle и stable sort tuple; offset не подходит для глубоких страниц.

### Модель данных

```text
listing(
  listing_id, owner_id, category_id,
  title, description, price, location,
  status, moderation_status, version,
  created_at, updated_at, published_at
)

listing_media(
  listing_id, media_id, object_key, checksum,
  position, status, width, height, version
)

owner_listing(
  owner_id, status, updated_at, listing_id, listing_version
)

outbox(
  event_id, listing_id, listing_version, event_type, payload, published_at
)

search_document(
  listing_id, listing_version, analyzed_text,
  category, price, geo, moderation/visibility fields
)

deny_overlay(listing_id, deny_version, reason, expires_or_tombstone)
```

`listing` — source of truth. `owner_listing` может сначала быть SQL index/view, а при росте стать отдельной projection. Search document денормализован: query не делает distributed joins. Event содержит source version; consumer применяет update только если `incoming_version > stored_version`. Delete — versioned tombstone, иначе поздний create/update воскресит документ.

State machine не позволяет `active`, пока обязательные fields и media готовы. Photo bytes и metadata проходят staged lifecycle из [[50 Проектирование систем/Проектирование файлового хранилища|проектирования файлового хранилища]].

## Архитектура и критические потоки

```text
Client -> API/Auth -> Listing Command/Query -> primary DB + replicas
                                     \-> transactional outbox
Client -> Media API -> signed upload -> object storage -> scan/derivatives -> CDN
Outbox -> event log -> Search Indexer -> search generations
                 \-> Owner-list projector
                 \-> deny-overlay projector
Client -> Search API -> query limits/cache -> search index -> optional final validation
```

### Создание и публикация

1. `POST /listings` дедуплицируется и создаёт `draft`.
2. Media API выдаёт scoped upload URLs. Finalize проверяет checksum/size/type; scanner и derivative worker создают immutable versions.
3. `publish` в одной DB transaction проверяет owner, expected version, completeness и moderation policy, переводит listing в `active`, увеличивает version и пишет outbox.
4. Ответ подтверждает canonical publication, но честно возвращает `search_status: pending`.
5. Indexer читает event, строит document и делает idempotent versioned upsert. После refresh listing появляется в SERP.

Crash между DB commit и publish event закрывается [[40 Распределённые системы/Transactional outbox и Change Data Capture|outbox]]. Crash indexer после записи, но до acknowledgment приводит к повтору, который безопасен по version.

### SERP

Search API нормализует query, ограничивает clauses/result window, применяет category/price/location filters и ranking. Первый page открывает короткоживущий point-in-time snapshot конкретной index generation; cursor продолжает тот же snapshot. Это делает страницы стабильнее, но deny overlay проверяется заново: безопасность важнее неизменности уже увиденной выдачи.

Search result содержит компактную карточку из index. Переход на listing card читает canonical/cache по `listing_id` и не показывает `blocked/deleted`, даже если stale document ещё присутствует в index. Для owner read-your-write путь идёт через canonical store, не через немедленный refresh всех search shards.

### Изменение и удаление

Update увеличивает `listing_version`; search event можно применять в любом delivery order, но не в обратном version order. При block/delete transaction сначала записывает canonical deny version и outbox. Быстрый deny overlay распространяется отдельным high-priority channel; обычное физическое удаление из index догоняет позже.

## Масштабирование и надёжность

- Начальный DB: один primary multi-AZ плюс read replicas, правильные indexes по `listing_id` и `(owner_id, status, updated_at, listing_id)`. Шардирование вводится после measured limits.
- При росте listings shard key по stable `listing_id` равномерно распределяет writes/card reads. Owner list требует отдельной projection по `owner_id`; крупного seller при необходимости suffix-shard-ят.
- Search shards распределяют documents; replicas обслуживают QPS. Category/region routing применяется только после анализа skew, иначе популярная категория становится hot shard.
- Object bytes передаются напрямую storage/CDN, API не становится bandwidth proxy.
- Caches: immutable photo URLs; listing cache keyed `(id, version)`; negative cache короткий. Search result cache полезен только для повторяющихся query/filter и не заменяет engine capacity.
- Backpressure: indexing queue отделена от request path; live updates приоритетнее bulk reindex. Queue lag не может расти бесконечно — load shedding затрагивает previews/analytics, а не delete overlay.
- Index восстанавливается из source snapshot + ordered/versioned changes. Он не является единственной копией объявления.

Consistency deliberately различается: publish/card/owner mutation — strong в home DB; search — eventual; delete authorization — monotonic deny. Такой контракт честнее общего обещания «данные консистентны».

## Failure modes

| Отказ | Обнаружение | Реакция |
| --- | --- | --- |
| Client повторил create после timeout | тот же idempotency key/fingerprint | вернуть прежний `listing_id`, конфликт при другом payload |
| DB commit есть, event не отправлен | oldest unpublished outbox age | publisher дочитывает запись после restart |
| Events пришли не по порядку | stored vs incoming `listing_version` | игнорировать старую version, tombstone не откатывать |
| Search cluster частично недоступен | shard failures, p99/error rate | bounded partial result только если product разрешает; иначе retry budget и error |
| Index lag выше freshness SLO | source-to-search version lag | autoscale indexer, приоритет live events, остановить reindex |
| Photo загружено, metadata не committed | orphan inventory | lifecycle/reconciliation удаляет staging после safety window |
| DB доступна, search недоступен | synthetic search и health | create/card/owner paths продолжают работать; SERP деградирует отдельно |
| Delete ещё в stale SERP | deny-overlay miss/age | final validation скрывает listing; alert на overlay SLO |
| Hot seller/category | per-key/shard saturation | split owner projection; rebalance search routing после load model |

## Безопасность

- Owner mutation проверяет object-level authorization; listing ID не является credential.
- Photos: scoped signed upload, size/pixel/decompression limits, MIME sniffing, malware scan, stripping sensitive EXIF, immutable public derivative вместо original.
- Full-text query проходит limits по длине, operators, regex/wildcard и timeout; «query string» нельзя слепо превращать в административный DSL.
- Draft/blocked/PII fields не попадают в public search document. Logs исключают description, contacts, signed URLs и raw query при privacy policy.
- Rate limits разделяют anonymous search, authenticated writes и media bytes. Bot/scraping protection не должна делать карточку недоступной обычному пользователю.
- Deletion/retention включают DB rows, search tombstones, caches, objects, backups и derived images; каждый контур имеет owner и reconciliation.

## Observability и SLO

- API RED metrics по route: RPS, error, p50/p95/p99, saturation.
- End-to-end `published_at → searchable_at` и `denied_at → no-longer-visible`; broker lag сам по себе недостаточен.
- Search: query latency по category/filter/complexity, rejected expensive queries, shard failures, cache hit, result count.
- Indexer: events/s, retry/DLQ, stale-version drops, refresh/merge pressure, generation size.
- DB: connection pool, lock time, replica lag, slow owner/card queries, hottest keys.
- Media: upload/finalize failures, orphan bytes, scan age, derivative backlog, CDN hit/egress.
- Synthetic flow создаёт listing, публикует, ждёт SERP, читает card, удаляет и проверяет deny.

Alerts строятся по user-visible SLO и burn rate, как требует [[50 Проектирование систем/SLO в System Design|SLO-разбор]], а не по одному CPU threshold.

## Эволюция решения и миграции

1. **100 RPS:** modular monolith, PostgreSQL, object storage/CDN, небольшой search cluster, transactional outbox.
2. **Рост reads:** read replicas/cache, отдельные Search API и indexer; load tests формируют shard count.
3. **Тысячи RPS:** owner projection, independent scaling command/search/media, partitioned event log.
4. **20k RPS:** DB sharding только после измеренного bottleneck; search generations, automated rebalancing, multi-AZ/DR drills.

Analyzer/mapping меняют blue-green: построить новую generation из snapshot, догнать changes, shadow-query/сравнить, атомарно переключить alias, оставить старую для rollback. Dual write application прямо в два индекса не заменяет replayable source log.

## Trade-offs и альтернативы

- PostgreSQL full-text уменьшает число систем на старте. Отдельный Lucene-based index выигрывает при сложном ranking/facets и independent QPS, но добавляет freshness/reindex operations.
- Синхронно индексировать внутри publish кажется проще для read-your-write, однако связывает availability DB и search и не даёт общей transaction. Асинхронный outbox честно показывает `pending` и восстанавливается.
- Final validation каждой SERP row даёт свежесть, но превращает search в N+1 dependency. Deny overlay закрывает security-sensitive changes, а остальная staleness остаётся допустимой.
- Shard DB по owner удобно для «мои объявления», но hot seller и card-by-id требуют routing. Hash `listing_id` плюс owner projection разделяет эти access paths ценой второй копии.
- Mutable photo URL упрощает frontend, но ломает cache invalidation. Immutable versioned URL плюс metadata pointer делает rollout и purge предсказуемыми.

## Типичные ошибки

- Делать search index source of truth: rebuild или stale document начинает определять business state.
- Обещать мгновенную выдачу, хотя условие разрешает lag, и синхронно связывать publish с search cluster.
- Не version-ить events: поздний update воскрешает удалённое объявление.
- Хранить photo bytes в application DB/API path: WAL, replicas и bandwidth начинают конкурировать с metadata.
- Использовать offset для глубокой SERP: latency и duplicates растут при refresh.
- Делать один shard per category без оценки skew: популярная категория перегревает node.
- Называть 20k RPS средним суточным traffic: peak, average и endpoint mix смешиваются.

## Когда применять

Архитектура подходит read-heavy classified, где listing creation transactional, media велико, а full-text search может отставать. Если каталог мал и query просты, PostgreSQL FTS способен быть разумным первым этапом. На интервью сильный ответ показывает state machine публикации, versioned outbox, границу source/index и путь удаления. Перечисления «PostgreSQL + Kafka + Elasticsearch» недостаточно.

## Источники

- Исходное условие Avito: `90 Вложения/Авито/Авитою. Систем дизайн.txt`, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://datatracker.ietf.org/doc/html/rfc9110) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [Apache Lucene 10.3.1 core documentation](https://lucene.apache.org/core/10_3_1/core/index.html) — Apache Lucene, версия 10.3.1, проверено 2026-07-18; пример search engine core, не обязательный vendor.
- [Amazon S3 data consistency model](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel) — Amazon Web Services, проверено 2026-07-18; пример object storage, не обязательный выбор продукта.
- [PostgreSQL 18 transaction isolation](https://www.postgresql.org/docs/18/transaction-iso.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
