---
aliases:
  - CourseHunter 5785 — задачи System Design
tags:
  - источник/coursehunter
  - тема/system-design/задачи
  - тема/собеседования
статус: проверено
---

# Шесть задач на System Design

## Как использовать разборы

Все решения ниже — учебные архитектуры из курса, а не утверждение о внутреннем устройстве реальных продуктов. На тренировке сначала воспроизведите только условие, 35–45 минут проектируйте сами, затем сравните требования, расчёты, state model и failure modes. Название конкретной БД не засчитывается без объяснения access pattern.

## 1. Лента друзей ВКонтакте

### Условие курса

![[90 Вложения/CurseHunter/5785/Кадры/032-feed-requirements.jpg|720]]

Функции: текстовые посты с одной картинкой, friendship add/remove, домашняя лента в обратной хронологии. Дано `50 000 000` DAU, availability `99,95%`, бессрочное хранение, в среднем `100` друзей, до `1 000 000`, один пост в `5` дней, `10` просмотров ленты в день, аудитория СНГ, без сезонности. Цели: выдача ленты `2 c`, создание поста `1 c`, friendship `0,5 c`; новый пост может появиться с небольшой задержкой.

Оценка курса:

```text
post write ≈ 50M / 5 / 86 400 ≈ 115 RPS
feed read ≈ 50M × 10 / 86 400 ≈ 5 800 RPS
media write ≈ 115 MB/s, если картинка 1 MB
media read ≈ 5 800 × 10 × 1 MB ≈ 58 GB/s, если страница содержит 10 картинок
```

### Главные вопросы интервьюера

1. Fan-out-on-write или fan-out-on-read?
2. Что делать с celebrity, у которого миллион followers?
3. Что означает «обратный хронологический порядок» при одинаковом времени и late events?
4. Как friend removal влияет на уже materialized timeline?
5. Как обеспечить read-your-writes автора и допустимую freshness друзей?
6. Где хранятся media bytes, metadata и feed entries?
7. Как cache/CDN invalidation работает при удалении поста или изменении privacy?

### Защищаемое решение

Write path: Post Service атомарно сохраняет post metadata, публикует событие через outbox; Media Service выдаёт upload URL и связывает immutable object version с post после finalize. Timeline workers получают событие из partitioned log и добавляют compact feed entry в timelines обычных followers.

Read path: Timeline Service читает candidate IDs из sharded timeline store, batch-запрашивает post/author metadata, применяет privacy/deletion filters и возвращает cursor page. Media отдаются через signed CDN URL.

Для celebrity применяют гибридную схему: посты обычных authors раскладывают fan-out-on-write, а посты authors с большим числом подписчиков подмешивают on-read. Порог выводят из fan-out cost, freshness и read amplification. Partition key timeline — viewer ID; event partition — author/aggregate ID для порядка постов автора.

![[90 Вложения/CurseHunter/5785/Кадры/032-feed-architecture.jpg|720]]

На доске курса присутствуют API Gateway, Post/Relation/Timeline/Media services, Kafka, PostgreSQL shards, Tarantool timelines, Ceph, CDN и CDC. На интервью важнее роли: durable metadata, event log, materialized read model и object delivery.

### Failure modes

- post committed, event не опубликован → transactional outbox;
- duplicate event → idempotent timeline insert по `(post_id, viewer_id)`;
- friendship removed во время fan-out → privacy check на read и asynchronous cleanup;
- hot celebrity partition → hybrid fan-out и separate rate/queue;
- timeline write lag → freshness SLI, replay и backpressure;
- deleted/private media остаётся в CDN → versioned signed URLs и purge/revocation policy.

## 2. WhatsApp-подобный мессенджер

### Условие курса

![[90 Вложения/CurseHunter/5785/Кадры/033-whatsapp-requirements.jpg|720]]

Чаты и личные сообщения, прочитанность, только текст, cross-device sync, online notifications. `50 000 000` DAU, availability `99,95%`, сообщения хранятся всегда, до `500` участников и `20 000` чатов, `20` отправок и `100` просмотров в день, send/read до `1 c`, доставка до пользователя с задержкой не более `3 c`, СНГ, без сезонности.

```text
write ≈ 50M × 20 / 86 400 ≈ 11 574 RPS
read  ≈ 50M × 100 / 86 400 ≈ 57 870 RPS
write traffic ≈ 11 574 × 4 KB ≈ 46 MB/s
```

Последняя формула предполагает сообщение `4 KB`. Read traffic зависит от page size/числа сообщений и не должен выводиться без этого параметра.

### Контракты, которые надо определить

- message ID генерирует client или server; как retry не создаёт duplicate;
- ordering нужен per chat, per sender или глобальный;
- delivery/read receipts — per device или per user;
- offline retention и reconnect cursor;
- edit/delete semantics;
- multi-device fan-out и key management, если требуется end-to-end encryption;
- presence точная или approximate.

### Защищаемое решение

Каждое device держит WebSocket к Connection Gateway. Routing directory хранит `user_id → active connection endpoints` с TTL/heartbeat. Send API аутентифицирует, дедуплицирует client message ID и append-ит сообщение в partition по `chat_id`; это задаёт порядок внутри чата. Durable message store хранит payload, Chat Service — membership и roles.

Delivery workers читают log и отправляют online devices; offline device после reconnect читает сообщения после cursor. Receipt — отдельное idempotent событие с monotonically increasing delivered/read position, а не update каждой message row для каждого пользователя.

![[90 Вложения/CurseHunter/5785/Кадры/033-whatsapp-architecture.jpg|720]]

В варианте курса: API Gateway, Chat/Message services, PostgreSQL для chat metadata, Cassandra для messages, Kafka, Notification Service и WebSocket connections. Конкретные продукты можно заменить, если сохраняются их contracts.

### Failure modes

- ответ потерян после commit → client повторяет запрос с тем же message ID;
- gateway умер → reconnect, resume cursor, duplicate delivery безопасна;
- два devices отправляют одновременно → сервер назначает sequence внутри chat partition;
- membership изменился между send и delivery → authorization snapshot/epoch;
- hot group → partition bottleneck; batching и лимиты, но полный per-chat order ограничивает parallelism;
- slow consumer → bounded per-connection buffer, backpressure/disconnect и catch-up из durable store.

## 3. Яндекс Такси-подобный сервис

### Условие курса

![[90 Вложения/CurseHunter/5785/Кадры/034-taxi-requirements.jpg|720]]

Заказ/отмена поездки, начало/конец рабочего дня водителя, подбор ближайшего водителя, принятие/отклонение заказа. `100 000 000` DAU клиентов, `5 000 000` DAU водителей, availability `99,95%`, один заказ на пользователя в день, поездка `30` минут, водитель выполняет `20` заказов в день, заказ должен создаваться до `1` минуты.

Курс оценивает около `1 157` order RPS и `450 000` location updates/s, если каждый водитель присылает примерно `7 920` обновлений в сутки. Последнее предположение надо проговорить: частота GPS зависит от online state и движения.

### State machine заказа

```text
CREATED → SEARCHING → OFFERED → ACCEPTED → ARRIVED → IN_RIDE → COMPLETED
                         ↘ EXPIRED/CANCELLED
```

Каждый transition проверяет expected version. Принятие двумя водителями решается compare-and-set/transaction по order version; проигравший получает conflict. Payment и receipt идут отдельной saga после завершения.

### Geo path

Location updates — ephemeral high-write stream. Последняя позиция хранится в geo-index, история — отдельно и с другой retention. Matching ищет candidates по expanding cells/geohash/H3, фильтрует availability и посылает offers с TTL. «Ближайший» по прямой не равен минимальному ETA: routing/traffic может уточнять top-K.

![[90 Вложения/CurseHunter/5785/Кадры/034-taxi-architecture.jpg|720]]

Схема курса разделяет Client/Driver gateways, Order Service, Geo Service, Match Service и event/state pipeline. Это позволяет масштабировать GPS updates независимо от durable orders.

### Вопросы и failure modes

- Как не назначить водителю два заказа? Reservation/driver epoch и conditional update.
- Что если offer дошёл после expiry? Order version и deadline проверяются сервером.
- Что если GPS устарел? Timestamp, maximum age и исключение stale drivers.
- Что если клиент отменяет одновременно с accept? Однозначная transition table и compensation/fee policy.
- Как пережить потерю региона? Orders требуют durable replication; location можно восстановить heartbeat-ами, но capacity failover должна выдержать burst reconnect.
- Как защититься от geo hotspot? Partition by cell, adaptive cell size, regional routing и hot-cell splitting.

## 4. LeetCode-подобный judge

### Условие курса

![[90 Вложения/CurseHunter/5785/Кадры/035-leetcode-requirements.jpg|720]]

Проверка C++ кода, test-run без сохранения и submit с сохранением. Availability `99,95%`, `1 000` задач, execution limit `5 c`, `10 000 000` DAU, `5` запусков пользователя в день, код до `2 KB`, без auth, geography и seasonality. Оценка — около `578` reads и `578` writes/s при выбранной модели.

### Почему это не обычный CRUD?

Пользовательский код недоверенный. Нужны isolation boundary, CPU/memory/process/file/network limits, immutable compiler/runtime image, deterministic test bundle, output limit и принудительное termination. Container сам по себе не является достаточным security boundary без hardening.

### Pipeline

1. API принимает source, language/runtime version, task ID и idempotency key.
2. Submission Service сохраняет metadata/source и ставит job в durable priority queue.
3. Scheduler выбирает worker pool по resource class и не превышает cluster quota.
4. Worker получает immutable task/test bundle, запускает sandbox и публикует status/result.
5. Client polling/SSE получает state: `QUEUED/RUNNING/ACCEPTED/WRONG_ANSWER/TLE/MLE/ERROR`.

![[90 Вложения/CurseHunter/5785/Кадры/035-leetcode-architecture.jpg|720]]

Доска курса использует Task/Solution/Check services, scheduler, containers, MongoDB, PostgreSQL, Ceph, Tarantool, logs и metrics. Главная граница — control plane против untrusted execution plane.

### Вопросы интервьюера

- Как скрыть test cases и при этом доставить их worker?
- Как избежать повторного платного запуска при retry?
- Как обеспечить fairness между пользователями и короткими/длинными jobs?
- Что происходит, если worker умер после выполнения, но до ack?
- Как версионировать task, compiler и test data для воспроизводимости?
- Где хранить stdout/stderr, binary artifacts и сколько времени?
- Какие метрики: queue wait, execution percentile, sandbox failures, per-language saturation?

At-least-once job delivery означает возможный повтор execution. Result commit делают conditional по attempt/lease; expired worker не должен перезаписать результат нового attempt — нужен fencing attempt number.

## 5. Google Drive-подобное файловое хранилище

### Условие курса

![[90 Вложения/CurseHunter/5785/Кадры/036-drive-requirements.jpg|720]]

Upload/download/delete, directories. `50 000 000` DAU, availability `99,95%`, файл до `5 TB`, до `1 000` файлов на пользователя, в среднем `100` файлов по `1 MB`, `5` обращений и `1` новый файл в день, пользователи в Азии и США, без сезонности.

```text
download ≈ 50M × 5 / 86 400 ≈ 2 893 RPS
upload   ≈ 50M / 86 400 ≈ 578 RPS
download traffic ≈ 2.9 GB/s при среднем файле 1 MB
upload traffic ≈ 578 MB/s
```

### Resumable upload

Command Service создаёт upload session и выдаёт signed URLs для chunks. Client отправляет chunks независимо, повтор безопасен по `(session_id, chunk_index, hash)`. Finalize проверяет manifest и атомарно публикует file metadata; до finalize chunks невидимы.

Большой файл режется на chunks; content-addressable ID может быть hash bytes. Дедупликация экономит место, но создаёт privacy side channels, reference counting и дорогой GC. Chunk size — trade-off между parallelism/resume granularity и metadata overhead.

### Metadata и bytes

Metadata store отвечает за namespace, parent relation, ownership, versions и manifest. Object store — за durable chunks. Нельзя подтверждать published file, пока manifest не указывает на durable chunks. Delete обычно tombstone/version; GC удаляет unreachable chunks после grace period и reconciliation.

![[90 Вложения/CurseHunter/5785/Кадры/036-drive-architecture.jpg|720]]

На доске: geoDNS, regional API Gateway, Command/Query services, PostgreSQL metadata, Tarantool cache, Ceph chunks и GC. Multi-region design требует определить home region пользователя, replication и conflict policy, а не только нарисовать две копии.

### Failure modes

- upload оборвался → session TTL и resume bitmap;
- finalize повторился → idempotent manifest/version commit;
- metadata committed, chunk потерян → durability quorum, scrub и repair;
- concurrent rename/move → optimistic version и cycle prevention;
- delete гоняется с download → immutable versioned object + authorization at request time;
- GC удаляет ещё нужный chunk → mark/sweep epoch, grace period, reference reconciliation;
- hot shared file → CDN, origin shielding и signed access.

## 6. Booking.com-подобное бронирование

### Условие курса

![[90 Вложения/CurseHunter/5785/Кадры/037-booking-requirements.jpg|720]]

Search hotels, hotel details/rooms, booking/cancel, text search, admin CRUD. `30 000 000` DAU, `300 000` hotels, availability `99,95%`, в среднем одно бронирование в месяц и `10` просмотров отелей в день, geography не задана, зимой и летом traffic ×2. Цели: search `5 c`, booking `2 c`.

```text
search ≈ 30M × 10 / 86 400 ≈ 3 500 RPS
booking ≈ 30M / 30 / 86 400 ≈ 11–12 RPS
```

Низкий booking RPS не делает задачу простой: inventory correctness важнее throughput.

### Модель данных

- `hotel` и `room_type` описывают каталог;
- inventory лучше хранить по `(hotel_id, room_type_id, date)` с available/held/sold или ledger reservations;
- `order` — state machine с dates, quantity, price snapshot и status;
- search index — derived view каталога/availability, но не authority для финального бронирования.

### Search и booking paths

Search Service обращается к geo/text index и возвращает candidates; availability может быть approximate для скорости. При booking Orders Service атомарно создаёт hold на нужные date buckets с TTL, фиксирует price snapshot, запускает payment saga и переводит hold в confirmed. Watchdog освобождает expired holds.

![[90 Вложения/CurseHunter/5785/Кадры/037-booking-architecture.jpg|720]]

Схема курса использует PostgreSQL shards для orders/inventory, CDC в Elasticsearch, Hotels/Orders services, payment services, saga и watchdog.

### Как не допустить double booking?

Авторитетная операция — conditional decrement/insert под transaction с uniqueness/version check. Search index и cache не подтверждают наличие. Для нескольких дат transaction должна захватить/проверить все buckets в стабильном порядке либо использовать reservation ledger с invariant `confirmed + active_holds ≤ capacity`.

### Failure modes

- payment успешен, ответ потерян → idempotency key и состояние платежа, которое можно запросить;
- payment успешен, order update не прошёл → saga reconciliation, не слепой refund-only happy path;
- hold истёк одновременно с payment → versioned state transition и server time;
- CDC/search lag → final availability recheck, freshness metric;
- popular hotel/date hotspot → partition by hotel/date, serialized inventory owner или escrow-like allocation;
- admin меняет room capacity при активных orders → effective-dated change и invariant validation;
- seasonal ×2 → pre-scaling, cache warming, queue limits и резерв capacity.

## Сравнение шести задач

| Задача | Главный bottleneck | Главный инвариант | Ключевой trade-off |
| --- | --- | --- | --- |
| Лента | fan-out и media egress | privacy/deletion видимы | write amplification vs read amplification |
| Мессенджер | connections и message fan-out | per-chat order, no lost accepted message | online latency vs durable replay |
| Такси | location stream и hot geo cells | один водитель/заказ в состоянии | freshness vs geo write cost |
| Judge | sandbox capacity | expired attempt не коммитит результат | isolation vs startup/throughput |
| Drive | object bytes и metadata GC | published manifest ссылается на durable chunks | dedup/chunking vs metadata complexity |
| Booking | hot inventory row/date | sold + held не выше capacity | fast approximate search vs strict booking |

## Источники

- [Курс System Design](https://balun.courses/courses/system_design) — Balun.Courses, список шести практических систем, проверено 2026-07-19.
- [RFC 6455: The WebSocket Protocol](https://www.rfc-editor.org/rfc/rfc6455.html) — IETF, RFC 6455, December 2011, проверено 2026-07-19.
- [Making retries safe with idempotent APIs](https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/) — Amazon Builders' Library, проверено 2026-07-19.
- [Debezium Architecture](https://debezium.io/documentation/reference/stable/architecture.html) — Debezium, stable documentation, проверено 2026-07-19.
