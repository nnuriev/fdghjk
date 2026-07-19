---
aliases:
  - Avito Messenger Backend system design
  - Проектирование Messenger Avito
tags:
  - тип/разбор
  - область/проектирование-систем
  - компания/авито
  - тема/chat
статус: проверено
---

# Messenger BE

## TL;DR

Messenger разделяется на durable message plane и connection plane. API принимает сообщение с `client_message_id`, проверяет участие в чате, назначает порядок внутри `conversation_id` и отвечает только после durable commit. Outbox публикует событие; fanout строит per-user/device inbox, WebSocket gateways доставляют online, push обслуживает offline. Потеря connection не теряет историю и не создаёт повтор при retry.

Сообщения шардируются по `conversation_id`, а список чатов — отдельная проекция по `user_id`. Один индекс не может одновременно оптимально поддерживать ordered history и «все чаты популярного продавца». Для таких продавцов user projection дополнительно suffix-shard-ится. Источник требует доставку realtime не позже трёх секунд; это SLI от durable acceptance до появления события у подключённого получателя, а не гарантия прочтения или push на выключенном телефоне.

## Контекст и ментальная модель

Исходное условие: спроектировать backend P2P-чата покупателя и продавца, создаваемого из объявления. Нужны отправка, приём/чтение и список чатов; realtime — до трёх секунд. Push и изображения — дополнительные функции. Frontend/mobile protocol вне детальной проработки.

Базовая архитектура переиспользует инварианты [[50 Проектирование систем/Проектирование чата|общего проектирования чата]], но учитывает Avito-специфику: чат связан с `listing_id`, участников всегда двое, а продавец способен иметь тысячи чатов. Каноническая история и online delivery — разные проекции одного принятого сообщения.

## Требования

### Функциональные

- Создать или вернуть существующий чат для `(listing_id, buyer_id, seller_id)` по кнопке «Написать».
- Отправить text message; повтор после неизвестного результата не создаёт второе логическое сообщение.
- Получить ordered history и новые сообщения online; продолжить после reconnect.
- Показать список чатов пользователя, последние сообщения и unread count.
- Зафиксировать delivered/read cursor.
- Дополнительно: push offline-устройствам и изображения через отдельный upload flow.

### Нефункциональные и SLO

Из условия: online delivery должна укладываться в 3 секунды. Остальные числа ниже — проектные цели интервью, а не данные Avito:

- send acceptance: availability 99,95%, p99 не более 700 мс в пределах server-side path;
- online delivery: 99% событий не позже 3 секунд после durable commit при активном connection;
- history/list: availability 99,95%, p99 не более 500 мс для bounded page;
- acknowledged message переживает отказ одной availability zone;
- порядок задаётся внутри чата; глобальный порядок между чатами не нужен;
- unread, list preview, presence и push могут быть eventual, но их lag измеряется.

### Вне scope

- Group chats, звонки, federation и frontend UX.
- End-to-end encryption protocol и server-side full-text search.
- Алгоритмы модерации содержимого и ранжирование spam.
- Гарантия push: внешний provider и выключенное устройство не входят в 3-second SLO.

## Оценка нагрузки и ёмкости

Вводные из задания:

- 30 млн MAU, 3 млн DAU;
- 100 млн активных объявлений;
- пользователь пишет в среднем в три чата и «10 сообщений в день»;
- средний чат содержит 10 сообщений и активен семь дней;
- в среднем 10 чатов на объявление;
- сообщение в среднем 50 символов, максимум «10 КБ»; исходник не уточняет, означает ли это 10 000 или 10 240 bytes;
- у популярных продавцов возможны тысячи чатов.

Фраза про три чата и 10 сообщений неоднозначна: это могут быть 10 сообщений суммарно либо 10 в каждый чат. Поэтому capacity считается диапазоном:

- lower estimate: `3M × 10 = 30M messages/day`, в среднем `≈347/s`;
- upper estimate: `3M × 3 × 10 = 90M/day`, в среднем `≈1 042/s`;
- peak factor 10 — наше допущение: `≈3,5–10,4k messages/s`.

50 символов нельзя считать 50 bytes: UTF-8 и envelope меняют размер. Для planning примем 512 bytes на text message вместе с IDs, timestamps и indexing metadata. Это даёт `≈15,4–46,1 GB/day` logical, или `≈5,6–16,8 TB/year` без реплик, attachments и storage overhead. Retention в условии не задан; до его согласования годовой расчёт — только ориентир.

Число simultaneous connections из DAU не выводится. Обозначим его `C`; если load test подтверждает `G` connections на gateway replica, replicas нужны как минимум `ceil(C/G)` плюс headroom. Подставлять красивое число без теста event loop, TLS memory и heartbeat traffic нельзя — это нарушает методику [[50 Проектирование систем/Оценка нагрузки и ёмкости|оценки нагрузки]].

## API и модель данных

### API

```http
PUT /v1/listings/{listing_id}/conversations/{buyer_id}
Idempotency-Key: create-42

PUT /v1/conversations/{conversation_id}/messages/{client_message_id}
{"type":"text","text":"Здравствуйте"}

GET /v1/conversations/{conversation_id}/messages?before_seq=1842&limit=50
GET /v1/me/conversations?cursor=...&limit=50

PUT /v1/conversations/{conversation_id}/read-cursor
{"read_through_seq":1842}
```

`PUT` с client-generated identity выражает retry contract. Сервер проверяет payload fingerprint: тот же key с другим body возвращает conflict. Cursor списка подписывает `(user_id, last_activity_at, conversation_id, projection_version)`; правила cursor pagination раскрыты в [[20 Бэкенд/Пагинация offset, cursor и continuation token|заметке о пагинации]].

WebSocket protocol имеет version, event type, durable `inbox_seq` и acknowledgment cursor. Connection ID не является message ID.

### Модель данных

```text
conversation(
  conversation_id, listing_id, buyer_id, seller_id,
  created_at, status, last_message_seq
)

message(
  conversation_id, seq, message_id, client_message_id,
  sender_id, kind, body_or_attachment_ref, created_at
)

user_conversation(
  user_id, bucket, last_activity_at, conversation_id,
  peer_id, listing_id, last_message_preview, unread_count, projection_version
)

read_cursor(user_id, conversation_id, read_through_seq, updated_at)
device_inbox(user_id, device_id, inbox_seq, event_ref, expires_at)
outbox(event_id, aggregate_id, aggregate_version, payload, published_at)
```

Unique constraint на `(listing_id, buyer_id, seller_id)` определяет, должен ли повторный переход создавать тот же чат. Если бизнес разрешает несколько чатов по одному объявлению, это правило меняется явно.

`message` partition key — `conversation_id`: history и sequence локальны. `user_conversation` partition key — `user_id` плюс bucket: он отвечает на список независимо от message storage. У обычного пользователя bucket один; heavy-seller переводится на несколько stable buckets по hash `conversation_id`, а query merge-ит top-N. Migration требует dual-read до полного backfill.

## Архитектура и критические потоки

### Компоненты

```text
Client -> API/WS Gateway -> Auth
                        -> Conversation/Message Service -> message store
                                                    \-> outbox
outbox -> event stream -> user-list projector
                    \-> device-inbox/fanout -> WS gateways
                    \-> push worker
Attachment API -> signed upload -> object storage -> scanner -> attachment metadata
```

Gateway держит connections и backpressure, но не владеет историей. Message Service отвечает за authorization, idempotency и per-conversation order. Durable stream допускает at-least-once delivery; consumers дедуплицируют `event_id` по правилам [[40 Распределённые системы/At-most-once, at-least-once и effectively-once processing|delivery semantics]].

### Отправка

1. Client посылает `client_message_id`; API аутентифицирует sender, проверяет membership и согласованный byte limit. До уточнения единицы исходные «10 КБ» нельзя молча превращать в `10 KiB`.
2. Owner shard атомарно дедуплицирует `(conversation_id, client_message_id)`, назначает следующий `seq`, пишет message и outbox.
3. После quorum/durable commit sender получает `message_id`, `seq`, `accepted_at`. Потерянный response безопасно повторяется.
4. Outbox publisher отправляет event. Projectors обновляют обе `user_conversation` rows и durable device inbox.
5. Connection router находит active gateways; event доставляется с `inbox_seq`. Duplicate delivery клиент отбрасывает.
6. Если online acknowledgment не пришёл за policy window, push worker отправляет notification. Push никогда не является источником message body/history.

Per-conversation sequence можно назначать транзакционно на shard leader. Чаты короткие и P2P, поэтому это не создаёт общего global sequencer. При failover новый owner получает fencing epoch; старый leader не может подтверждать новые writes после потери lease, что следует из [[40 Распределённые системы/Leases, distributed locks и fencing tokens|fencing tokens]].

### Reconnect и read

Client хранит durable inbox cursor. После reconnect gateway запрашивает события после cursor. Если cursor вышел за retention, сервер возвращает `resync_required`, а client перечитывает список и history из canonical stores. Read cursor монотонен: update `max(old, new)`, поэтому late retry не помечает сообщения непрочитанными.

### Изображения

Bytes не проходят через Message Service. Client инициирует upload, получает scoped signed URL, загружает object, затем finalize проверяет size/checksum и запускает scan. Только status `available` разрешает сослаться на attachment в message. State machine и orphan cleanup соответствуют [[50 Проектирование систем/Проектирование файлового хранилища|проектированию файлового хранилища]].

## Масштабирование и надёжность

- Message shards: consistent partition mapping по `conversation_id`, replication across zones; rebalance с forwarding/epoch.
- User-list projection: обычный `user_id` locality, heavy-user suffix buckets, bounded k-way merge; метрика hottest bucket определяет split.
- WebSocket gateways: stateless относительно durable state; connection registry имеет TTL/heartbeat и переживает stale mappings.
- Fanout: отдельные consumer groups для list, online delivery и push; slow push provider не задерживает send.
- Backpressure: per-connection bounded queue. Slow consumer disconnect-ится с resume cursor, а не накапливает RAM без лимита.
- Consistency: message/history — strong within shard; list/unread/push — eventual. Read-your-send возвращает committed message напрямую, не ждёт projection.
- DR: multi-AZ synchronous/quorum commit. Cross-region RPO/RTO задаются только после требования бизнеса; source их не содержит.

## Failure modes

| Отказ | Обнаружение | Реакция |
| --- | --- | --- |
| Response потерян после commit | retry с тем же `client_message_id` | вернуть прежний `message_id/seq`, не писать duplicate |
| Outbox publisher упал | растёт oldest-unpublished age | новый worker дочитывает rows; idempotent consumers принимают duplicate |
| Gateway умер | heartbeat/connection drop | reconnect к другой replica и replay после durable cursor |
| Stale connection registry | delivery ack отсутствует | удалить mapping по TTL, сохранить event в inbox, при необходимости push |
| User projection отстаёт | projection lag и несоответствие source version | список может быть stale в рамках SLO; replay/rebuild из log |
| Heavy seller перегрел bucket | p99, queue depth, partition CPU | online split на suffix buckets, dual-read и backfill |
| Stream backlog угрожает 3 секундам | accepted-to-delivered histogram, consumer lag | autoscale, приоритет text delivery над push/analytics, load shedding необязательных событий |
| Attachment scan недоступен | age в `verifying` | text работает; файл остаётся quarantine, retry/reconciliation |

## Безопасность

- Каждый send/history/list проверяет authenticated user и membership; знание `conversation_id` не даёт доступ.
- Seller/buyer IDs и message bodies — PII: encryption in transit/at rest, least privilege, retention/deletion и audit access. Модель следует [[20 Бэкенд/Обработка PII|обработке PII]].
- Rate limits разделяются по account, device, IP, conversation и attachment bytes; ban/block version должен быстро попадать в authorization path.
- Maximum size проверяется до allocation/decompression; text валидируется как UTF-8 по контракту.
- Signed upload ограничивает object key, size, content type и expiry; download заново авторизуется.
- Logs/traces не содержат message body и signed URLs. Moderation получает отдельный, audited access path.

## Observability и SLO

Главный SLI — `delivery_at - accepted_at` по message ID для online recipient. Его нельзя заменять broker lag: очередь может быть быстрой, а connection routing — сломанным. Нужны:

- send availability/latency и доля idempotent retries;
- accepted-to-inbox и accepted-to-online-delivery p50/p95/p99;
- oldest outbox age, consumer lag, projection version lag;
- active connections, reconnect rate, slow-consumer disconnects, bytes/connection;
- hot shard/bucket, heavy-user merge fanout;
- duplicate/redelivery rate и resync frequency;
- push provider latency/failures отдельно от core SLO;
- synthetic users, которые отправляют, переподключаются и читают message end-to-end.

Алерт строится по error-budget burn, а dashboard связывает API, stream, projector и gateway через trace/message IDs по [[50 Проектирование систем/Observability в System Design|методике observability]].

## Эволюция решения и миграции

1. Старт: modular service, transactional database для conversations/messages/user projection, outbox, несколько gateway replicas.
2. Рост: отделить event stream и projectors; вынести attachments; shard messages по conversation.
3. Heavy sellers: ввести bucket column, dual-write old/new projection, backfill, compare reads, затем переключить cursor version.
4. Multi-region только по измеренному требованию: назначить home region conversation и определить RPO/RTO до репликации.

Каждый этап обратим: consumers можно отключить без потери source log, а старая projection остаётся доступной до сверки. Общий protocol rollout описан в [[50 Проектирование систем/Миграция и rollout без остановки|заметке о миграциях]].

## Trade-offs и альтернативы

- WebSocket даёт low-latency bidirectional connection; long polling проще инфраструктурно, но увеличивает reconnect/request overhead. Durable inbox нужен в обоих вариантах.
- Fanout-on-write делает online/list reads дешёвыми, но дублирует events на devices/users. Fanout-on-read снижает writes, зато усложняет resume и создаёт latency на каждом reconnect.
- SQL удобен для uniqueness/membership и начального масштаба. Wide-column message log легче shard-ится на большой истории, но потребует отдельной transactional metadata model.
- Один user partition упрощает list. Suffix buckets снимают hot seller, но добавляют read fanout и сложный cursor.
- Один active region на conversation упрощает порядок. Multi-leader снижает write latency в разных регионах, но conflict/order semantics для одного P2P-чата становятся значительно дороже.

## Типичные ошибки

- Подтверждать send до durable commit: crash оставляет sender с «успешным» потерянным message.
- Использовать connection ID как identity операции: reconnect создаёт duplicate.
- Шардировать только по user: одно сообщение принадлежит двум user lists, а conversation history теряет локальность.
- Шардировать только по conversation и считать list бесплатным: сбор всех чатов требует fanout по всем shards.
- Обещать exactly-once transport: broker/gateway retry всё равно возможен; нужен идемпотентный logical effect.
- Считать 50 символов 50 bytes и игнорировать неуточнённый предел «10 КБ», envelope и attachments.
- Включать push provider в core acceptance path: внешний сбой ломает отправку сообщения.

## Когда применять

Решение отвечает именно Avito P2P messenger: короткие чаты, связь с объявлением, редкие hot sellers и 3-second online target. Для group chat потребуется другая fanout policy, а для E2EE изменятся moderation, search и key management. На интервью важнее всего проговорить два независимых partitioning axes — conversation history и user chat list — и провести send через неизвестный исход, duplicate delivery и gateway failure.

## Источники

- Исходное условие Avito: `90 Вложения/Авито/Авитою. Систем дизайн.txt`, проверено 2026-07-18.
- [RFC 6455: The WebSocket Protocol](https://datatracker.ietf.org/doc/html/rfc6455) — IETF, RFC 6455, декабрь 2011, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://datatracker.ietf.org/doc/html/rfc9110) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [Amazon S3 data consistency model](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel) — Amazon Web Services, проверено 2026-07-18; пример object storage, не обязательный выбор продукта.
