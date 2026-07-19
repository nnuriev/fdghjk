---
aliases:
  - Job scheduler and workflow engine design
  - Проектирование distributed scheduler
tags:
  - тип/разбор
  - область/проектирование-систем
  - тема/фоновые-задачи
статус: проверено
---

# Проектирование планировщика задач и workflow engine

## TL;DR

Scheduler отвечает за вопрос «когда создать работу», очередь — «кто возьмёт следующую попытку», а workflow engine — «какой долговечный шаг следует после результата предыдущего». Смешивание этих ролей обычно заканчивается полной таблицей cron-записей, бесконечными повторами и невозможностью понять, завершился ли бизнес-процесс.

Предлагаемый дизайн хранит schedule и workflow history в согласованном metadata store, материализует близкие timers по time buckets, публикует task attempts в partitioned queue и выдаёт воркерам leases. Выполнение at-least-once; единственность бизнес-эффекта обеспечивают idempotency key, state transition и fencing, а не обещание `exactly once`.

## Контекст и ментальная модель

Платформа обслуживает immediate jobs, calendar schedules и длительные workflows с retries, timers, signals и compensation. Она запускает пользовательские workers, но не исполняет их код внутри control plane.

У каждой сущности своя граница:

- `schedule` описывает повторяемое правило;
- `job` описывает требуемый результат одного запуска;
- `attempt` фиксирует аренду и попытку выполнения;
- `workflow execution` хранит детерминированный state, полученный replay-ем append-only history;
- `activity task` представляет внешний, потенциально неидемпотентный эффект.

Задача не исчезает из-за смерти worker. Worker тоже не получает исключительного права на внешний мир: lease может истечь, пока старый процесс ещё работает. Поэтому протокол согласуется с [[40 Распределённые системы/Leases, distributed locks и fencing tokens|leases и fencing tokens]], а прикладной эффект — с [[20 Бэкенд/Ключи идемпотентности и дедупликация запросов|ключами идемпотентности]].

## Требования

### Функциональные

- создать immediate/delayed job и получить стабильный `job_id`;
- создать calendar schedule с timezone, overlap и missed-run policy;
- получить статус, отменить ожидающую работу, повторить терминальную ошибку вручную;
- запускать workflow, посылать signal, ставить timer и читать history;
- ограничивать concurrency по tenant, queue и task type;
- version-aware маршрутизировать задачи совместимым workers;
- хранить attempts, причины отказа, audit и ссылки на большой payload;
- выполнять replay, backfill и controlled redrive из quarantine.

### Нефункциональные и SLO

| Характеристика | Интервью-цель |
| --- | --- |
| Доступность create/signal API | 99,99% за 30 дней |
| Доступность read/history API | 99,9% |
| Immediate dispatch latency | p99 ≤ 5 s при отсутствии tenant throttling |
| Scheduled start lateness | p99 ≤ 30 s в штатном режиме |
| Долговечность принятой команды | RPO 0 внутри региона после ack |
| Multi-region DR | RPO ≤ 1 min, RTO ≤ 15 min |
| Consistency | linearizable transition одного job/workflow; eventual visibility в поисковом индексе |
| Delivery | at-least-once для attempts; бизнес-эффект обязан быть идемпотентным |

Availability уступает safety при споре за ownership shard. Во время partition лучше временно не запускать задачи, чем разрешить двум регионам выполнять платежный workflow под одним fencing epoch.

### Вне scope

Sandbox для недоверенного кода, arbitrary DAG analytics, выделение CPU/GPU и полноценный cluster scheduler наподобие Borg остаются вне scope. Здесь workers уже имеют compute capacity.

## Оценка нагрузки и ёмкости

Сценарий использует только интервью-допущения:

- 50 млн активных schedules, в среднем один запуск в сутки;
- `50 000 000 / 86 400 = 579` materializations/s в среднем;
- top-of-hour и timezone cohorts дают пик `20 × (50 000 000 / 86 400) ≈ 11 574/s`;
- jobs и workflow steps: 5 000/s в среднем, 20 000/s peak;
- hot metadata одного шага — 1 000 B, хранится 30 дней с тремя replicas;
- один job/workflow step создаёт в среднем 3 history events по 500 B после compression.

```text
5 000 × 1 000 B × 86 400 = 432 GB/day
432 GB × 30 × 3 = 38,88 TB hot replicated state
```

Для cold history нельзя подставлять steps/s вместо events/s. При трёх events на step сценарий даёт:

```text
5 000 steps/s × 3 events/step × 500 B × 86 400 × 365 = 236,52 TB/year
```

Коэффициент `events/step` зависит от retries, timers и signals, поэтому перед production sizing его измеряют по реальным histories.

50 млн schedule records по 1 KB занимают около 50 GB primary. Проблема не в размере каталога, а в поиске due records и burst на границах минуты. Payloads больше 64 KB выносятся в object storage; в task record остаются checksum, version и pointer.

Capacity считают по максимальному из четырёх ограничений: metadata write IOPS, timer scans/s, queue dispatch/s и concurrent open workflows. Headroom должен позволять одновременно принимать peak и разбирать backlog быстрее входящего потока, иначе восстановление никогда не закончится.

## API и модель данных

```http
POST /v1/jobs
Idempotency-Key: close-day/2026-07-17

{
  "queue": "accounting",
  "task_type": "close_day.v3",
  "run_at": "2026-07-18T02:00:00Z",
  "payload_ref": "obj://jobs/...",
  "deadline": "2026-07-18T03:00:00Z"
}
```

```http
POST /v1/schedules
POST /v1/workflows/{type}:start
POST /v1/workflows/{id}:signal
POST /v1/jobs/{id}:cancel
GET  /v1/jobs/{id}
GET  /v1/workflows/{id}/history?after_event_id=...
```

Create возвращает `202`, идентификатор и revision. Повтор того же idempotency key с тем же canonical request возвращает прежний объект; с другим payload — `409 Conflict`.

Основные таблицы/коллекции:

- `schedules(schedule_id, tenant_id, rule, timezone, policy, next_fire_at, revision)`;
- `jobs(job_id, tenant_id, queue, state, scheduled_at, deadline, payload_ref, fence, revision)`;
- `attempts(job_id, attempt_no, worker_id, lease_until, started_at, outcome)`;
- `workflow_executions(workflow_id, run_id, status, last_event_id, code_version, owner_epoch)`;
- `history_events(run_id, event_id, type, payload_ref, checksum)`;
- `timers(shard_id, bucket, fire_at, workflow_id, timer_id)`.

History append и изменение `last_event_id` коммитятся атомарно. Search/visibility index строится асинхронно и не участвует в correctness.

## Архитектура и критические потоки

```text
API -> shard router -> metadata/history store -> timer materializer
                                            -> task queues -> workers
workers -> completion API -> workflow state machine -> new tasks/timers
                         -> visibility index / audit / object storage
```

Shard router вычисляет ownership по `tenant_id + workflow_id`. Для ближайшего временного окна timer service держит buckets в памяти, но источником истины остаётся durable store. Далёкие timers не надо ежесекундно сканировать: background process переносит их в near-time buckets заранее.

Workers используют long polling. Dispatcher выдаёт task вместе с `attempt`, `lease_until` и monotonically increasing fence. Heartbeat продлевает lease и переносит progress, но не коммитит бизнес-эффект. Completion с устаревшим fence отклоняется.

### Write path и end-to-end trace

Workflow `ship-order/42` ждёт оплату, затем резервирует склад и создаёт отправление.

1. `start` с idempotency key атомарно создаёт execution и событие `WorkflowStarted#1`.
2. State machine replay-ит history, решает вызвать `ReserveInventory.v2` и добавляет `ActivityScheduled#2`. После commit task появляется в queue.
3. Worker A получает attempt с fence 7, резервирует товар во внешнем сервисе с ключом `ship-order/42/reserve`, но теряет сеть до completion.
4. Lease истекает. Worker B получает fence 8 и повторяет тот же вызов. Inventory service возвращает прежний reservation по idempotency key.
5. Completion A с fence 7 отвергается; completion B добавляет `ActivityCompleted#3`. Workflow планирует `CreateShipment`.

Наблюдаемый результат: инфраструктура выполнила activity дважды, но внешний reservation создан один раз. Если внешний API не поддерживает идемпотентность, workflow должен использовать lookup/reconciliation или компенсацию, а не объявлять exactly-once.

### Read path

`GET /jobs/{id}` читает authoritative shard по ключу. Поиск «все failed workflows tenant за сутки» идёт в eventual visibility index и возвращает watermark. History pagination использует `event_id`, а не offset: append-only порядок стабилен внутри run.

## Масштабирование и надёжность

**Storage.** Согласованный SQL/KV store хранит state transitions и короткую history; append-friendly log или time-partitioned tables — события; object storage — большие payloads и архив; очередь распределяет attempts. Использовать search index как source of truth нельзя.

**Partitioning.** Jobs/workflows шардируются по стабильному business id. Timers делятся по `(time_bucket, hash(id))`, чтобы top-of-hour не стал одним partition. Queue partitions учитывают tenant и task type; per-tenant fair scheduling не даёт одному backlog занять всех workers.

**Replication.** Внутри региона metadata shard коммитится quorum-ом. Один leader/consensus group сериализует transitions. Queue допускает повторную доставку. History chunks после закрытия immutable и копируются в object storage.

**Caching.** Router кэширует shard map с epoch, workers — task-type metadata, API — immutable terminal result. Active workflow state восстанавливается replay-ем и может жить в памяти до eviction. Кэш никогда не выдаёт lease и не меняет state без authoritative CAS.

**Async.** Visibility indexing, history archival, retry scheduling, quarantine redrive и retention работают отдельно. Queue age и timer lateness ограничивают admission; при перегрузке low-priority jobs откладываются, а control commands сохраняются.

**Multi-region и DR.** Workflow имеет home region и `owner_epoch`. Второй регион принимает read и реплицирует history, но не dispatch-ит tasks. При failover coordinator получает кворум, увеличивает epoch и только затем запускает timers. Старый регион с меньшим epoch не может завершать attempts. Active-active допустим между разными workflows, но не для одного execution без общего consensus.

**Capacity и ownership.** Команда владеет shard balancing, timer skew, worker protocol compatibility, recovery tooling и runaway-workflow limits. Стоимость определяют replicated metadata IOPS, hot history, visibility index и payload egress. Архивировать history дешевле, чем держать её в OLTP, но replay старого workflow становится медленнее.

## Failure modes

| Отказ | Симптом | Обнаружение | Реакция |
| --- | --- | --- | --- |
| Worker умер после эффекта | повторная activity | lease expiry, duplicate idempotency hit | новый attempt, тот же business key, reconciliation |
| Timer shard отстал | scheduled jobs поздно стартуют | timer lateness p99, oldest due timer | перераспределить shard, ограничить catch-up, сохранить приоритет |
| Metadata quorum потерян | create/completion недоступны | quorum errors | fail closed для transitions, workers не подтверждают успех |
| Queue недоступна после state commit | task записана, но не доставлена | `scheduled` без dispatch offset | outbox/dispatcher дочитывает authoritative state |
| Poison task | бесконечные retries | attempts, repeated error class | deadline, retry budget, quarantine |
| Workflow code несовместим с history | replay nondeterminism | replay error по code version | versioned workers, patch markers, rollback |
| Split brain регионов | двойные dispatch | conflicting epochs/fences | quorum failover, reject stale epoch, reconciliation |
| Visibility index отстал | поиск не видит completed run | index watermark | показывать staleness; point read идёт в source of truth |

## Безопасность

Tenant RBAC разделяет создание, отмену, просмотр payload и ручной redrive. Worker получает короткоживущий credential только для своих queues и task types. Payload шифруется, secrets передаются по ссылке на secret store и не попадают в history, потому что history долго живёт и широко реплицируется.

Нужны ограничения на число timers, размер history, recursion/child workflows, signal rate и concurrent activities. Все административные переходы, смена ownership и ручной skip фиксируются в неизменяемом audit.

## Observability и SLO

Основные SLI: create latency/success, dispatch latency, timer lateness, oldest queue age, attempt rate, retry amplification, lease expirations, workflow replay latency, history size, shard imbalance, stale fences, visibility lag. Отдельно измеряется business completion latency от `WorkflowStarted` до terminal event.

Alert по queue depth без входной скорости мало полезен. Нужны age и drain time: `backlog / (processing_rate - arrival_rate)`. Runbook покрывает stuck shard, poison task, mass retry, region failover и rollback несовместимого worker build.

## Эволюция решения и миграции

1. **Начало:** SQL queue и один scheduler leader; подходит для тысяч jobs/s и простых retries.
2. **Шардирование:** timer buckets, отдельные queues, leases/fences, object payloads и visibility index.
3. **Workflow engine:** append-only history, deterministic replay, signals, durable timers и worker versioning.
4. **Multi-region:** home-region ownership, replicated history, tested epoch-based failover.

Миграция из старого scheduler идёт через dual materialization: старый и новый scheduler вычисляют due runs, но только один имеет право publish. Shadow сравнивает `(schedule_id, scheduled_at)`. После backfill schedules tenants переключаются canary-группами; старый путь остаётся read-only на rollback window.

Worker rollout требует совместимости с открытыми histories. Новая версия сначала обрабатывает только новые workflows, затем replay-тестируется на копиях реальных histories. Удалять старую ветку можно после завершения или Continue-As-New всех зависимых runs.

## Trade-offs и альтернативы

- **SQL queue или broker.** SQL упрощает атомарность job state и enqueue. Broker лучше масштабирует dispatch, но требует outbox между metadata и publish.
- **Polling или push.** Long polling естественно создаёт backpressure и работает за NAT. Push уменьшает задержку, но усложняет доступность worker endpoint и retries.
- **Детерминированный replay или явный state machine.** Replay даёт удобный код workflow и полную history, но требует строгой совместимости кода. Явные transitions проще анализировать, но сложнее выражают длительные процессы.
- **Active-active или home region.** Active-active для разных shards повышает локальность. Single owner одного workflow сохраняет порядок и упрощает fencing.

## Типичные ошибки

### Полный scan таблицы schedules каждую секунду

- **Неверное предположение:** индекс по `next_fire_at` решит любой масштаб.
- **Симптом:** top-of-minute создаёт lock/IO spike и запаздывание.
- **Причина:** каждый scheduler конкурирует за один near-time range.
- **Исправление:** time buckets плюс hash shards, bounded lookahead и ownership.

### Успех worker считают ровно одним выполнением

- **Неверное предположение:** ack и внешний эффект атомарны.
- **Симптом:** дубли после timeout.
- **Причина:** crash window между эффектом и completion неизбежно неоднозначно.
- **Исправление:** business idempotency, lookup/reconciliation, при необходимости compensation.

### Cron и workflow объединяют одной записью

- **Неверное предположение:** `next_run_at` описывает весь процесс.
- **Симптом:** невозможно объяснить, какой шаг завершён и что повторять.
- **Причина:** расписание, instance, attempt и history имеют разные жизненные циклы.
- **Исправление:** раздельные сущности и явные state transitions.

## Когда применять

Distributed scheduler нужен, когда delayed work должно переживать рестарты и масштабироваться по tenants. Workflow engine оправдан, когда процесс длится дольше одного запроса, ждёт внешних signals, имеет несколько effects и должен продолжиться после падения. Для одной ежедневной housekeeping-задачи платформенный CronJob проще и дешевле.

## Источники

- [Distributed Periodic Scheduling with Cron Service](https://sre.google/sre-book/distributed-periodic-scheduling/) — Google SRE Book, глава 24, проверено 2026-07-18.
- [Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/) — Kubernetes, документация v1.36, проверено 2026-07-18.
- [CronJob](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) — Kubernetes, документация v1.36, проверено 2026-07-18.
- [Temporal Server](https://github.com/temporalio/temporal/tree/v1.31.2) — temporalio/temporal, tag `v1.31.2`, проверено 2026-07-18.
- [PostgreSQL SELECT](https://www.postgresql.org/docs/18/sql-select.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, `SKIP LOCKED`, проверено 2026-07-18.
- [Large-scale cluster management at Google with Borg](https://research.google/pubs/large-scale-cluster-management-at-google-with-borg/) — Google Research, EuroSys 2015, проверено 2026-07-18.
