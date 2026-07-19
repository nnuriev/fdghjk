---
aliases:
  - Playlist backend system design
  - Проектирование Spotify
  - Music playlist and playback state
tags:
  - тип/разбор
  - область/проектирование-систем
  - компания/авито
  - тема/playlist
статус: проверено
---

# Spotify

## TL;DR

Playlist и playback session — разные aggregates. Playlist хранит versioned ordered track references. При Shuffle Queue Service фиксирует `playlist_version`, один раз создаёт permutation и сохраняет immutable queue. Повторное открытие или другое устройство читает ту же queue, а не «случайно перемешивает заново».

Playback state хранит `(queue_id, index, position_ms, paused, state_version, device_epoch)` и checkpoint-ится периодически плюс на pause/track change. Single-active-device lease с fencing не даёт старому устройству перетереть прогресс нового. Исходные 10 секунд ограничивают cross-device lag при доступной authority, но не задают RPO после потери региона. Поэтому baseline подтверждает checkpoint после durable commit внутри региона и реплицирует его в paired region асинхронно; синхронный cross-region ack включают только после отдельного требования к региональному RPO. Playlist content и immutable queues можно реплицировать/cached более свободно.

При 50 млн DAU основная write load — не создание playlist, а 250 млн additions/day и potentially сотни тысяч playback checkpoints/s. Поэтому state path — отдельный partitioned low-latency store, а playlist reads/cached snapshots и queue generation масштабируются независимо.

## Контекст и ментальная модель

Стриминг audio и загрузка tracks уже реализованы. Нужно спроектировать backend playlists:

- создать playlist и добавить существующий track;
- перемешать и начать playback в случайном порядке;
- pause и resume с того же места на другом device, сохранив queue;
- получить playlist contents и generated queue;
- работать глобально, отказоустойчиво, p95 response до 200 мс;
- cross-device resume отстаёт максимум на 10 секунд.

Ментальная модель:

```text
playlist version --shuffle--> immutable queue
                                  |
                                  v
                         mutable playback cursor
```

Playlist edit не переписывает уже начатую queue. Queue — snapshot decision, cursor — часто меняющееся состояние конкретной сессии.

## Требования

### Функциональные

- Создать playlist; идемпотентно добавить track в определённую позицию/конец.
- Получить playlist page и version.
- Создать shuffle queue на snapshot playlist; повтор запроса не создаёт другую queue.
- Получить queue страницами.
- Запустить, pause, advance и checkpoint playback position.
- Перенести active session на другое device с прежней queue и состоянием не старше 10 секунд.
- Восстановить данные после zone/region failure согласно явно выбранной consistency policy; точный региональный RPO исходником не задан.

### Нефункциональные и SLO

Из условия:

- p95 ответа — до 200 мс;
- cross-device state lag — не больше 10 секунд;
- глобальность и fault tolerance;
- рост со 100k до 50M DAU за год.

Уточняем контракт:

- p95 200 мс относится к server-side playlist/queue/state APIs и не включает audio streaming;
- 10 секунд отсчитываются от последнего **успешно подтверждённого** checkpoint; device без сети не может синхронизировать состояние;
- playlist mutation и playback checkpoint после success durable;
- queue immutable и сохраняет order до завершения/expiration session;
- analytics, play counters и recommendations eventual.

Проектные цели сверх условия: 99,95% read/state availability и p99 до 500 мс для bounded requests. Baseline делает local multi-AZ durable commit и асинхронную cross-region replication: WAN partition не останавливает checkpoint, но rollback после region loss может превысить 10 секунд. Если интервьюер отдельно требует региональный RPO не больше 10 секунд, policy меняется на synchronous paired-region ack с соответствующей ценой по latency и availability.

### Вне scope

- Audio delivery/CDN, licensing/DRM, track upload и recommendation ML.
- Shared collaborative editing, public follower feeds и social functions.
- Billing/subscriptions и accounting plays.
- Точная UX-policy одновременного playback; выбираем один active device per session.

## Оценка нагрузки и ёмкости

Целевые вводные из задания: 50M DAU, 250M registered users, 30M tracks. На пользователя в день: 30 listened tracks, 5 playlist additions, 5 reads playlist/queue; создаётся 3 playlists/year. Среднее — 5 playlists на active user и 300 tracks/playlist, размер не ограничен.

На 50M DAU:

- track starts: `50M × 30 = 1,5B/day`, average `≈17,4k/s`;
- playlist additions: `250M/day`, average `≈2,9k/s`;
- playlist/queue reads: `250M/day`, average `≈2,9k/s`;
- playlist creates: `150M/year`, average `≈4,8/s`.

Peak factor 10 — наше capacity assumption, пока нет hourly profile: примерно `174k track starts/s`, `28,9k additions/s` и `28,9k content/queue reads/s`. Создание playlist не определяет write capacity.

Средний active-user corpus: `50M × 5 × 300 = 75B playlist item references`. При planning footprint 64 bytes/item — ID, rank, metadata и indexes до реплик — это `≈4,8 TB logical`. 64 bytes не источник Avito, а placeholder; version history, tombstones и database overhead измеряют sample data.

Checkpoint load нельзя вывести без concurrent listening. Если `A` active playback sessions и interval пять секунд, `checkpoint_rps = A/5`. Иллюстрация, не исходная аналитика: если средний track длится три минуты, то 30 tracks дают 90 listening minutes/user/day, `A ≈50M × 90/1 440 = 3,125M`, а average checkpoints — `≈625k/s`. Даже если assumption ошибается в разы, он показывает необходимость отдельного state path. Нужны реальные listening duration, concurrent devices и foreground/background behavior.

Queue materialization среднего playlist: 300 track IDs × 8 bytes = 2,4 KiB raw, но actual envelope/chunks больше. Unbounded maximum требует pagination и асинхронного/lazy path; нельзя выделять память пропорционально непроверенному input.

## API и модель данных

### API

```http
POST /v1/playlists
Idempotency-Key: playlist-create-42
{"name":"Road trip"}

PUT /v1/playlists/{playlist_id}/items/{item_id}
If-Match: "playlist-version-17"
{"track_id":"t9","after_item_id":"i8"}

GET /v1/playlists/{playlist_id}/items?cursor=...&limit=100

POST /v1/playback-sessions
Idempotency-Key: shuffle-42
{"playlist_id":"p1","playlist_version":18,"mode":"shuffle"}

GET /v1/playback-sessions/{session_id}/queue?cursor=...&limit=100

PUT /v1/playback-sessions/{session_id}/state
If-Match: "state-version-901"
{"device_epoch":7,"client_seq":481,"queue_index":12,"position_ms":43100,"paused":false}

POST /v1/playback-sessions/{session_id}:take-over
```

Item identity отделена от `track_id`: один track можно добавить дважды. `after_item_id` или fractional rank выражает order; optimistic playlist version предотвращает lost update. Cursor содержит playlist/queue version и last rank/index.

### Модель данных

```text
playlist(
  playlist_id, owner_id, name, version,
  item_count, created_at, updated_at
)

playlist_item(
  playlist_id, rank, item_id, track_id,
  added_at, item_version, tombstone
)

owner_playlist(owner_id, updated_at, playlist_id, playlist_version)

playback_session(
  session_id, user_id, playlist_id, playlist_version,
  queue_id, shuffle_algorithm_version, seed_ref,
  state_version, device_epoch, active_device_id,
  queue_index, position_ms, paused, updated_at, lease_until
)

queue_chunk(
  queue_id, chunk_no, track_item_ids[], checksum
)

idempotency_record(user_id, key, request_fingerprint, result_id, expires_at)
outbox(event_id, aggregate_id, aggregate_version, payload)
```

Playlist shard key — `playlist_id`; owner index — отдельная projection по `owner_id`. Playback state shard — `user_id` или `session_id` с directory от user, чтобы takeover и current session находились одним routing lookup. Queue chunks immutable и могут жить в replicated KV/object store; hot cache key включает `queue_id`, а не mutable playlist.

## Архитектура и критические потоки

```text
Client -> global edge -> user home-cell router

Playlist API -> playlist store + outbox -> owner/search/cache invalidation
Queue API -> playlist snapshot reader -> shuffle worker -> immutable queue store/cache
State API -> fenced session state store -> synchronous paired-region replica
                                     \-> event stream -> analytics (eventual)
```

### Добавление track

1. API проверяет owner, существование track и request size.
2. Idempotency key + fingerprint находят прежний result либо transaction проверяет expected playlist version.
3. В transaction создаётся unique `item_id`, rank, увеличивается playlist version и outbox.
4. Response возвращает new version. Cache keys старой version immutable и могут истечь; latest pointer invalidated/versioned.

Если два devices редактируют playlist одновременно, один conditional write конфликтует. Client перечитывает version и решает merge. Silent last-write-wins для ordered list теряет additions.

### Shuffle и очередь

1. Queue request фиксирует exact `playlist_version`. Если client не передал version, server выбирает current и возвращает её.
2. Snapshot reader получает ordered item IDs этой version. Для средней 300-item playlist Queue Service выполняет Fisher–Yates-like permutation с cryptographically unpredictable server seed, сохраняет algorithm version и materializes queue chunks.
3. Transaction/idempotency record публикует один `queue_id`. Retry с тем же key возвращает тот же order.
4. Playback session ссылается на immutable queue. Playlist edits создают следующую playlist version, но активная queue не меняется.

Хранить только seed компактнее, но воспроизведение зависит от неизменного algorithm и exact input snapshot. Materialized queue проще отдать и доказать при migration. Для очень большого playlist queue генерируется chunks/background; API возвращает operation state, а не удерживает request дольше 200 мс.

### Checkpoint и смена device

Active device получает `device_epoch` и короткий renewable lease. Он отправляет checkpoint каждые пять секунд, на pause, seek и track transition. State store принимает update, только если:

- epoch равна текущей;
- `client_seq` больше последней для этого device;
- expected `state_version` совпадает либо command имеет определённую merge semantics;
- queue index/position входят в bounds.

`take-over` атомарно увеличивает epoch и назначает новый device. Старое устройство после network pause продолжает играть локально, но его writes отклоняются fencing check. Это применение [[40 Распределённые системы/Leases, distributed locks и fencing tokens|lease с fencing]], а не доверие expiry само по себе.

Исходный cross-device lag не определяет поведение при потере home region. В baseline acknowledgment следует после durable multi-AZ commit в home region, а paired region получает состояние асинхронно. Это сохраняет write availability при WAN partition, но фактический failover RPO измеряется отдельно и может быть больше 10 секунд.

Если бизнес добавляет самостоятельный контракт «подтверждённый checkpoint переживает region loss с RPO ≤10 секунд», запись синхронно фиксируется в paired region до acknowledgment. Тогда WAN latency входит в 200 мс budget, а при partition API не сможет подтвердить новый durable checkpoint. Выбор между двумя policy — явный trade-off по [[40 Распределённые системы/CAP и PACELC|CAP/PACELC]], а не следствие исходного требования о смене устройства.

### Global reads

Пользователь имеет home cell. Playlist snapshots и queue chunks реплицируются асинхронно и кэшируются regionally; mutable playback state идёт в current home/paired authority. Global directory содержит только routing metadata и last-known-good copy, поэтому его временный отказ не останавливает existing sessions.

Public/global popular playlists не заданы. Если появятся, immutable snapshot/CDN cache защищает origin, но follower feeds и rights filtering потребуют отдельного дизайна.

## Масштабирование и надёжность

- Playlist store hash-shard-ится по `playlist_id`; owner list — отдельная projection. One huge playlist разбивается по ordered ranges/chunks.
- State store hash-shard-ится по session/user; partition leader serializes versions. Для выбранной cross-region policy измеряются replication lag, ack latency и failover RPO.
- Queue generation autoscale-ится отдельно; bounded worker concurrency не позволяет huge playlists вытеснить средние.
- Queue/content caches versioned и immutable; request coalescing предотвращает stampede при cache miss.
- Outbox гарантирует, что playlist mutation не потеряет invalidation/event; consumers version-aware.
- Analytics/play events не входят в checkpoint transaction. Их lag не ломает resume.
- Backpressure: client coalesces intermediate position updates, но никогда не теряет pause/track transition; server отвечает retry-after/load shed до unbounded queue.
- DR drills проверяют DB promotion, directory routing, epoch monotonicity и отсутствие двух active writers.

## Failure modes

| Отказ | Обнаружение | Реакция |
| --- | --- | --- |
| Add committed, response потерян | same idempotency key | вернуть item/version, не добавить track второй раз |
| Queue worker упал посередине | operation age/incomplete chunks | chunks скрыты до manifest publish; retry той же operation |
| Playlist изменился после Shuffle | queue хранит snapshot version | активная queue не меняется; новый shuffle использует новую version |
| Старое device прислало поздний checkpoint | stale `device_epoch`/client seq | отклонить, не откатывать position |
| State response потерян | retry expected/current version | вернуть current state либо idempotent success |
| Paired region lag/partition | synchronous ack timeout, replication SLI | checkpoint не подтверждать; client retry/coalesce |
| Home region потерян | health + fencing epoch | promote paired authority, увеличить epoch, global router переключить |
| Directory временно недоступен | routing errors | existing clients/cache use signed last-known-good home mapping |
| Huge playlist перегружает queue generator | item count/worker saturation | async chunked generation, quota/fair scheduling |
| Cache stampede | origin amplification/miss burst | request coalescing, jittered TTL, serve immutable version |

## Безопасность

- Playlist и session читаются/изменяются только owner-ом; UUID не заменяет authorization.
- Listening history, device identity и playback position — behavioral PII: retention, export/delete, regional residency и audited access.
- Queue/playlist API не возвращает DRM/audio credentials; track existence проверяется с current availability/rights policy. Если track стал недоступен, queue сохраняет order, но playback отмечает item unavailable и идёт дальше по product rule.
- Idempotency records scoped by user; attacker не может угадать чужой key и получить result.
- Input bounds: name length, item batch count, cursor signature, playlist maximum processing budget даже при «неограниченном» product size.
- Internal services используют least privilege; logs не содержат playlist names, listening position и device IDs в открытом виде.
- Cross-region replication шифруется, keys/retention соответствуют data-residency policy.

## Observability и SLO

- p95/p99 по playlist add/read, queue create/read, checkpoint/takeover отдельно по home cell.
- End-to-end resume staleness: `resume_read.updated_at - last_acknowledged_checkpoint_at`; DB replication lag измеряется отдельно и не заменяет этот SLI.
- Checkpoint QPS, coalescing ratio, conditional conflicts, stale-epoch rejects, active sessions.
- Paired-region ack latency/timeout, replication lag, failover RPO and epoch monotonicity.
- Queue generation duration по item-count buckets, incomplete operations, cache hit/stampede.
- Playlist version conflicts, outbox age, projector lag, hottest shards/huge playlists.
- Synthetic two-device flow: create playlist, add, shuffle, play/checkpoint, takeover, проверить тот же queue/position; затем controlled failover.

Alert на average latency скрывает tail и региональные failures. SLO считается по user journey и per-region burn rate согласно [[50 Проектирование систем/SLO в System Design|методике SLO]].

## Эволюция решения и миграции

1. 100k DAU: relational playlist store, versioned items, state table, queue materialization, single region multi-AZ.
2. Отделить playback state и queue workers при росте checkpoint/CPU; добавить home routing.
3. Shard playlist/state independently; owner projection и immutable caches.
4. Paired-region state replication, drills and fencing; async либо sync checkpoint policy выбирается после фиксации регионального RPO.
5. 50M DAU: cell architecture, automated rebalancing и fair queues для huge playlists.

Shuffle algorithm меняется versioned. Новые sessions используют v2; существующие materialized queues не пересчитываются. State schema мигрирует expand/contract: readers понимают обе версии, writers dual-write только на bounded period, backfill проверяется, затем старое поле удаляется.

## Trade-offs и альтернативы

- Materialized queue требует storage, зато order независим от algorithm changes и быстро читается. Seed-only дешевле, но требует immutable snapshot и вечной совместимости generator.
- Checkpoint каждые пять секунд удовлетворяет 10-second target с margin, но создаёт большую write load. Client-side coalescing и event checkpoints уменьшают её; interval ближе к 10 секундам не оставляет budget на network/replication.
- Single-active-device упрощает conflicts. Multi-device simultaneous playback потребует branch sessions или explicit leader merge; last-write-wins ломает position.
- Sync paired-region ack обеспечивает отдельно согласованный региональный RPO, ухудшая write availability/latency при WAN issue. Async replication делает playback устойчивее к partition, но допускает больший rollback после потери региона.
- Fractional ranks уменьшают массовое renumbering при inserts. Они требуют compaction и careful pagination; простой integer position дешевле, если additions только в конец.
- SQL облегчает transactions и early stage. Distributed KV/state log нужен, когда measured checkpoint load и global latency превышают возможности partitioned SQL.

## Типичные ошибки

- Перемешивать playlist заново на каждом device: queue меняется и resume нарушается.
- Ссылаться на mutable playlist без version: edit незаметно меняет уже играющую session.
- Хранить только random seed, но не algorithm/input version: rollout переставляет queue.
- Делать last-write-wins по timestamp между devices: clock skew и delayed old device откатывают position.
- Считать 3 playlists/year главным write path и не посчитать 5 additions/day/checkpoints.
- Обещать 10-second cross-region lag с async replication без решения, что делать при partition/failover.
- Загружать unlimited playlist целиком в память/request: один пользователь нарушает p95 всех.

## Когда применять

Дизайн применим к personal playlists и cross-device playback state при уже существующем audio streaming. Если playback queue должна динамически включать recommendations или совместное DJ-редактирование, immutable snapshot заменяется versioned queue event log, но fencing и checkpoint invariants остаются. На интервью сильный ответ сначала фиксирует snapshot/queue/state, затем считает checkpoint load и отделяет исходную границу cross-device lag от дополнительно согласуемого регионального RPO.

## Источники

- Исходное условие Avito: `90 Вложения/Авито/Авитою. Систем дизайн.txt`, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://datatracker.ietf.org/doc/html/rfc9110) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RFC 6455: The WebSocket Protocol](https://datatracker.ietf.org/doc/html/rfc6455) — IETF, RFC 6455, декабрь 2011, проверено 2026-07-18.
- [PostgreSQL 18 transaction isolation](https://www.postgresql.org/docs/18/transaction-iso.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Consistent hashing and random trees](https://dl.acm.org/doi/10.1145/258533.258660) — Karger et al., ACM Symposium on Theory of Computing, 1997, проверено 2026-07-18; первичная работа о partitioning primitive, не предписание конкретного storage.
