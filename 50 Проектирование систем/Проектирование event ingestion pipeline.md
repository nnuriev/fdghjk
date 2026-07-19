---
aliases:
  - Event ingestion pipeline system design
  - Проектирование конвейера приёма событий
tags:
  - область/проектирование-систем
  - тип/разбор
  - тема/event-ingestion
статус: проверено
---

# Проектирование event ingestion pipeline

## TL;DR

Regional ingestion gateways принимают bounded batches, аутентифицируют producer, валидируют envelope/schema и подтверждают request только после durable replicated append в partitioned event log. Partition key задаёт одновременно ordering, locality и hot-key risk. Consumers независимо читают log: raw archive пишет immutable files в object storage, stream processors строят derived datasets, а плохие records попадают в quarantine с причиной и replay path.

Pipeline обещает at-least-once приём и порядок только внутри partition key. Exactly-once до внешней БД или API не следует из broker transaction: downstream обязан использовать event ID, version/upsert либо свою transaction с offset. Backpressure, tenant quotas и overload response защищают общую платформу от одного producer.

## Контекст и ментальная модель

SDK и backend producers отправляют clickstream, audit и domain events. Несколько consumer teams обрабатывают один поток с разной скоростью. Нужны replay, schema evolution и raw retention.

Ментальная модель: ingress превращает ненадёжный network request в durable position в log. После acknowledgment событие становится обязательством платформы сохранить его в пределах retention и сделать доступным consumer groups. Consumer lag — отложенная работа, а не loss, пока retention не догнал offset.

## Требования

### Functional requirements

- Принимать single/batch events по HTTP/gRPC с producer identity.
- Валидировать размер, envelope, schema ID/version и tenant policy.
- Дедуплицировать retry в bounded window по scoped key `(tenant_id, source, event_id)` или обеспечить idempotent downstream по тому же ключу.
- Сохранять raw ordered log и отдавать его независимым consumer groups.
- Архивировать raw data, поддержать replay/backfill и quarantine invalid events.
- Показывать producer acknowledgment и operational status без per-event query на hot log.

### Non-functional requirements

- Один tenant не исчерпывает disk/network/partitions всего cluster.
- Acknowledged event переживает отказ broker/zone при заявленной ack policy.
- Ordering ограничен key; глобального порядка нет.
- Schema rollout совместим с old/new consumers.
- Backpressure bounded: gateway не буферизует бесконечно.

### SLO: availability, latency, durability, consistency

Interview targets:

| Путь | SLO |
| --- | --- |
| Ingest accept | 99,99% valid batches за 30 дней; p95 ≤ 100 ms, p99 ≤ 250 ms до replicated ack |
| Durability | acknowledged event не теряется при отказе одной зоны; region-loss RPO ≤ 1 min для critical topics, RTO ≤ 15 min |
| Consumer availability | 99,9% времени log доступен для fetch; lag SLO задаётся отдельно каждому consumer |
| Ordering | total order внутри одной partition; producer key contract фиксирован |
| Consistency | at-least-once end-to-end; raw archive появляется ≤ 5 min, derived views имеют собственную freshness |

### Вне scope

- OLAP query engine и dashboards.
- Бизнес-логика конкретного stream processor.
- Глобальная транзакция между всеми sinks.
- Приём бесконечно больших payload; крупные blobs загружаются отдельно, event содержит reference.

## Traffic и storage estimates

Все числа — interview assumptions.

- Average `500k events/s`, peak `1M events/s`.
- Средний serialized event 1 kB: average ingress `≈500 MB/s`, peak `≈1 000 MB/s`.
- За день: `500k × 86 400 = 43,2B events/day`; bytes `43,2 TB/day`, или `≈39,3 TiB/day`.
- 7-day hot retention: `302,4 TB`, или `≈275 TiB`, raw logical.
- Compression ratio 3:1 принят как assumption, а replication factor 3 возвращает physical hot storage примерно к raw logical: `302,4 TB / 3 × 3 = 302,4 TB`, без segment/index/headroom.
- Если целевой tested throughput partition 20 MB/s, peak bytes требуют `1 000 / 20 = 50 partitions`; 2× operational headroom — около 100. `20 MB/s` должен быть результатом load test, не product benchmark.
- Raw archive за год без compression: `43,2 TB × 365 ≈ 15,8 PB`; retention/lifecycle обязателен.

Requests/s зависит от batch size. При batch 200 events peak `1M / 200 = 5k requests/s`; слишком маленький batch тратит CPU/network overhead, слишком большой увеличивает retry blast radius и latency.

## API contract

```http
POST /v1/events:batch
Authorization: Bearer ...
Content-Encoding: zstd

{
  "events":[{
    "specversion":"1.0",
    "id":"01J...",
    "source":"orders/prod",
    "type":"order.paid",
    "time":"2026-07-18T10:15:00Z",
    "subject":"order/918",
    "dataschema":"registry://order-paid/3",
    "data":{...}
  }]
}
```

Response:

```json
{"accepted":200,"rejected":0,"batch_id":"B7","acks":[{"id":"01J...","partition":17,"offset":9912}]}
```

Atomicity batch задаётся явно. Базовый contract принимает/reject-ит весь batch при envelope/schema error, чтобы partial retry не был неоднозначен; per-event errors можно добавить с stable IDs. `429`/`503` возвращают `Retry-After`, а client применяет bounded exponential backoff с jitter.

## Data model

```text
event_envelope(specversion, id, source, type, subject, time,
               dataschema, tenant_id, partition_key, traceparent, data)

schema(subject, version, compatibility_mode, definition, state)

producer_policy(producer_id, tenant_id, allowed_types, max_bytes,
                rate_quota, active_schema_versions)

consumer_checkpoint(group_id, topic, partition, offset, updated_at)

quarantine(tenant_id, source, event_id, reason_code, schema_version,
           payload_ref, received_at, replay_state)
```

Log record хранит original producer time и server receive time. Для SLO/lag используется server time: client clock может быть неверен. Event ID уникален только в producer/source scope, поэтому canonical event key равен `(tenant_id, source, id)`. ID без source не годится ни для quarantine, ни для consumer dedup; даже scoped key не делает dedup бесконечным.

## High-level architecture

```text
producers -> global/regional LB -> ingestion gateways -> schema/policy cache
                                      |
                                      v
                              replicated event log
                         /             |              \
                 raw sink        stream processors     quarantine
                    |                  |                    |
              object storage      derived sinks          replay tool
```

Gateway stateless между requests, кроме bounded buffers. Broker/log владеет durable append. Schema registry/control plane отделены от data plane; краткая недоступность registry переносится verified cache, но неизвестную schema нельзя принимать «на глаз».

## Read path и write path

### Write path

1. Gateway аутентифицирует producer, проверяет compressed/uncompressed size, quota и batch limits.
2. Envelope валидируется; schema cache подтверждает разрешённую compatibility/version.
3. Partition key вычисляется server-side из contract либо проверяется против event subject.
4. Producer client отправляет batch лидеру partition; acknowledgment возвращается после configured replicated durability boundary.
5. Offset/partition попадают в response. Timeout оставляет неизвестный исход; retry использует тот же event IDs.

### Read path

1. Consumer group получает partitions и читает batches начиная с checkpoint.
2. Consumer обрабатывает record и фиксирует external effect idempotently.
3. Offset продвигается после effect. Если effect commit прошёл, а offset commit потерян, record повторится.
4. Raw sink группирует events по time/tenant/schema, пишет immutable object, проверяет checksum и только затем checkpoint-ит.
5. Replay создаёт новую consumer group/range; он не меняет offsets production consumer.

### Сквозная трассировка

Producer `orders/prod` tenant T4 отправляет event `E91` по key `order-918`. Broker replicated append выполняется на partition 17 offset 9912, но HTTP response теряется. Producer повторяет E91. Log может содержать две records. Billing consumer делает conditional insert `processed_event(T4, orders/prod, E91)` и применяет effect один раз; event `E91` от другого source остаётся отдельным. После crash до offset commit запись читается снова и снова пропускается. Raw archive сохраняет обе transport records либо компактизированную normalized copy по оговорённой policy, а audit может доказать происхождение duplicate.

## Выбор storage

Partitioned append-only event log нужен для ordered append, retention, sequential fetch и independent consumer positions. Эти свойства и различие queue/stream разобраны в [[40 Распределённые системы/Очереди, streams, группы потребителей и DLQ|заметке о queues и streams]].

Object storage хранит дешёвый raw archive/replay source. Schema registry и producer policies подходят SQL/KV control plane. Quarantine payload крупнее metadata и может лежать в object storage с indexed catalog.

## Partitioning и replication

- Topic разделяется по data class/retention/security, затем record partition key выбирается по нужному ordering/locality, например `order_id`.
- Random key равномернее, но ломает per-entity order. Tenant-only key создаёт hot partition у крупного tenant.
- Replication factor 3 across zones — design assumption. Ack policy требует достаточное число in-sync replicas; unsafe leader election не включается для critical topics.
- Partition count определяет max parallelism consumer group и recovery surface. Увеличить его можно, но hash mapping меняется; order одного key через старые/новые partitions требует cutover epoch.
- Cross-region pipeline принимает local events и асинхронно mirrors их. `source` включает producer namespace/region, а dedup использует полный `(tenant_id, source, id)`; глобального order нет.

## Caching

Gateway кэширует producer policy и schemas по immutable version. Revocation/version list имеет короткий TTL и push invalidation. Cache miss к registry coalesced; stale schema допустима только если её version всё ещё explicitly active.

Log page cache — часть broker design; отдельный distributed cache перед log обычно удваивает bytes без пользы. Consumer-side cache уместен для enrichment reference data, но имеет собственный freshness contract.

## Async processing

Весь pipeline после replicated append асинхронен. Consumers используют pull/bounded fetch, чтобы slow consumer накапливал lag, а не получал бесконечный push. Backfill и replay имеют отдельные quotas и consumer groups.

Schema validation делится на fast envelope check в gateway и тяжёлые semantic checks downstream. Событие с корректной schema, но неверным бизнес-смыслом, попадает в quarantine/compensating workflow, а не блокирует partition навсегда.

## Failure handling

| Failure | Сигнал | Реакция | Остаточный эффект |
| --- | --- | --- | --- |
| Broker/zone lost | ISR/replica health, produce errors | leader failover только к eligible replica; throttle producers при low redundancy | latency растёт, durability сохраняется по ack policy |
| Gateway overload | queue depth, memory, admission rejects | `429/503 Retry-After`, load shedding, per-tenant quota | producers retry, часть low-priority events rejected по contract |
| Hot partition | bytes/QPS/lag by partition | key redesign, split topic/entity, producer admission | order boundary ограничивает быстрый fix |
| Consumer poison event | repeated failure, no offset progress | bounded retries, quarantine/DLQ, advance по explicit policy | event требует owner/replay |
| Schema registry outage | registry errors, cache age | serve verified active cache; reject unknown version | новые schema rollout остановлены |
| Disk retention pressure | disk watermark, retention headroom | stop low-priority ingestion, tier/archive, add capacity; не удалять unconsumed critical data молча | availability trade-off |
| Cross-region mirror lag | source-target offset/time lag | keep local accept, alert RPO, reserve catch-up bandwidth | region-loss data exposure растёт |

## Security

- Mutual TLS/OAuth identity связывает producer с tenant и allowed event types.
- Schema/payload limits проверяются после decompression, чтобы compressed bomb не обошла quota.
- ACL разделяет produce, consume, replay и schema administration. Consumer не получает topics с чужими tenants без policy.
- Sensitive fields классифицируются в schema; raw archive encryption/retention и tokenization задаются data class.
- Event/log fields не доверяются: CSV/SQL/log injection предотвращаются в sinks, а credentials/PII редактируются.
- Audit stream имеет отдельную immutability/retention policy и не смешивается с best-effort analytics.

## Observability

Data-plane metrics: accepted/rejected events и bytes, batch size/compression, ack latency, errors по reason, per-partition throughput/skew, replica health, disk headroom, consumer lag/oldest-event age, archive watermark, quarantine rate и duplicate scoped keys. Метрика не агрегирует только по raw `event_id`, иначе collisions разных sources выглядят как retries. Control-plane metrics: schema cache age, compatibility failures, policy propagation.

Trace context из event envelope связывает producer request и downstream processing, но consumer создаёт новый span/link, а не притворяется одним многодневным synchronous trace. Synthetic producer пишет canary event; raw sink и test consumer подтверждают его по ID.

## Capacity planning

При peak `≈1 000 MB/s` и целевых `20 MB/s` на partition базовый минимум 50; 2× headroom даёт около 100 partitions. Cluster sizing учитывает replication network, fetch by multiple consumer groups, disk write/read, compaction/tiering и zone failure. Один из трёх zones может исчезнуть, а оставшиеся должны сохранить produce/fetch target либо система обязана load-shed.

Hot storage по assumption `≈302 TB physical` после compression 3:1 и RF3. Добавляем segment/index, disk watermarks и catch-up reserve. Raw archive `≈15,8 PB/year` до compression требует lifecycle/tiering и budget по data class.

## Cost trade-offs

Главные расходы — broker disks, replication traffic, cross-region mirror, raw archive и повторное чтение многими consumers. Batch compression уменьшает network/storage, но тратит producer/consumer CPU и добавляет linger latency.

Долгий broker retention облегчает replay и outages consumer, но дорог. Короткий hot log плюс object archive дешевле, однако replay из archive сложнее и медленнее. Critical audit и best-effort analytics не обязаны иметь одинаковую цену/SLO.

## Migration и rollout plan

1. Ввести versioned envelope/CloudEvents-like attributes и SDK, сохранив старый endpoint adapter.
2. Dual publish в новый log выполняется через outbox или shadow producer; consumers сравнивают counts/checksums, но старый path остаётся authority.
3. Перевести одного idempotent consumer, затем raw archive; offset и effect reconciliation обязательны.
4. Producers переключаются cohort/tenant-wise. Retry сохраняет полный `(tenant_id, source, id)` между old/new path.
5. Schema compatibility сначала проверяется в warn/shadow, затем enforce для новых versions.
6. При repartitioning создаётся topic generation N+1. Producers получают routing epoch, consumers временно читают обе generation и дедуплицируют scoped event keys.
7. Multi-region mirror включается до failover; RPO, duplicate behavior и failback проверяются game day.

## Bottlenecks

- Network bytes и replication, а не request count.
- Hot partition из-за semantic key.
- Disk headroom во время broker rebuild/catch-up.
- Consumer lag, который приближается к retention.
- Schema registry/policy dependency на hot path.
- Retry storm после outage.
- Raw archive small files и object request amplification.

## Trade-offs и альтернативы

| Выбор | Выигрыш | Цена | Когда выбирать |
| --- | --- | --- | --- |
| Synchronous DB insert per event | простой query/control | random writes, tight coupling | малый QPS/audit table |
| Partitioned log | throughput, replay, many consumers | partitions/ops/eventual sinks | большой поток |
| At-most-once | без duplicates | loss при failure | expendable telemetry |
| At-least-once | no loss within durability boundary | dedup/idempotency | default critical ingestion |
| Global ordering | единый sequence | coordination bottleneck | почти никогда для telemetry |
| Per-key ordering | parallelism + locality | hot-key risk | entity workflows |

## Типичные ошибки

- **Неверное предположение:** broker exactly-once автоматически покрывает external sink. **Симптом:** duplicate charge/row после crash. **Причина:** effect и offset в разных transaction boundaries. **Исправление:** idempotent event ID/upsert либо общая поддерживаемая transaction.
- **Неверное предположение:** больше partitions всегда безопасно. **Симптом:** order одного key меняется при cutover, rebalance/recovery растёт. **Причина:** partition mapping — часть data contract. **Исправление:** generation/epoch и измеренный sizing.
- **Неверное предположение:** queue buffer устранил overload. **Симптом:** lag растёт до retention loss. **Причина:** arrival rate выше processing. **Исправление:** admission, capacity, backpressure и drain-time model.

## Когда применять

Дизайн нужен для clickstream, audit/domain events, telemetry и CDC-like feeds с большим throughput, replay и несколькими consumers. Для request/response command с немедленным бизнес-результатом log остаётся внутренним механизмом, а внешний API должен вернуть ясный operation state.

## Источники

- [Apache Kafka Design](https://kafka.apache.org/43/design/design/) — Apache Kafka, документация версии 4.3, проверено 2026-07-18.
- [CloudEvents Specification](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md) — CNCF CloudEvents, tag v1.0.2, проверено 2026-07-18.
- [The Log: What every software engineer should know about real-time data's unifying abstraction](https://engineering.linkedin.com/distributed-systems/log-what-every-software-engineer-should-know-about-real-time-datas-unifying) — LinkedIn Engineering, опубликовано 2013-12-16, проверено 2026-07-18.
- [Handling Overload](https://sre.google/sre-book/handling-overload/) — Google, Site Reliability Engineering, издание 2016 года, проверено 2026-07-18.
- [Trace Context](https://www.w3.org/TR/trace-context/) — W3C Recommendation, редакция 23 ноября 2021, проверено 2026-07-18.
