---
aliases:
  - Migration и rollout plan
  - Zero-downtime migration
  - Strangler pattern
tags:
  - область/проектирование-систем
  - тема/миграции
статус: проверено
---

# Миграция и rollout без остановки

## TL;DR

Безостановочная миграция — это временный протокол совместимости между старым и новым состоянием. Безопасный порядок обычно выглядит как `expand -> observe -> migrate -> switch -> contract`: сначала новая версия принимает старые и новые формы, затем данные копируются и сравниваются, traffic переключается малым blast radius, а необратимое удаление происходит после доказанного отсутствия старых readers/writers.

Rollback возможен только до определённой границы. После несовместимой записи, внешнего эффекта или удаления данных чаще нужен roll-forward/repair. План обязан назвать эту границу, source of truth на каждом этапе, критерии продолжения/остановки и способ reconciliation.

## Ментальная модель

Миграцию удобно представить как автомат состояний, а не одну дату cutover:

```text
old only -> compatible dual world -> new reads -> new authority -> cleanup
              |                         |
              +---- rollback-safe ------+
```

На каждом этапе есть разрешённые binary/schema/config versions и один владелец записи. Чем дольше dual world, тем больше цена поддержки и шанс расхождения.

## Как устроено

### 1. Зафиксировать инварианты и baseline

Перед изменением определите:

- user-visible SLO и correctness checks;
- canonical source и write authority;
- объём/скорость данных, backfill ETA и extra capacity;
- compatibility matrix clients/services/schema/events;
- privacy/retention при временных копиях;
- stop, rollback и roll-forward criteria.

Baseline сравнивает canary с контрольной версией и абсолютным SLO. Если обе версии деградировали из-за общего incident, относительное сравнение недостаточно.

### 2. Expand

Сначала выпускают backward-compatible readers/writers:

- DB schema добавляет nullable/defaulted field или новую таблицу без удаления старой;
- API/provider принимает старых clients и не требует новое поле;
- event consumer понимает старую и новую schema;
- service умеет читать обе data representations;
- feature flag выключен по умолчанию.

[[30 Данные/Миграции схемы данных|Schema migration]] отделяет metadata lock от долгого backfill. Новая колонка не должна автоматически запустить table rewrite или full scan в peak без проверки конкретной СУБД.

### 3. Migrate и verify

[[30 Данные/Online backfill|Backfill]] идёт bounded batches с checkpoint, idempotency, throttling и приоритетом ниже online traffic. Snapshot alone пропускает concurrent writes, поэтому нужен change stream, trigger/outbox либо повторный catch-up.

Dual write опасен двумя независимыми commits: один может пройти, второй нет. Предпочтительнее один authoritative write и асинхронная доставка в target с retry/reconciliation. Если dual write неизбежен, фиксируют order, failure state и repair queue по [[30 Данные/Dual read и dual write migrations|протоколу dual read/write]].

Verify сравнивает counts, keys, checksums, domain invariants и sampled full records. Равное число rows не доказывает равенство значений.

### 4. Shadow и canary

Shadow read/write выполняет новый path без влияния на user outcome, сравнивает результат и capacity. Sensitive data и external side effects требуют особой защиты: shadow payment нельзя реально capture-ить.

Canary получает небольшой tenant/traffic/data slice. Gate использует error/latency/correctness/freshness и resource saturation. Rollout расширяется ступенями с observation window, достаточно длинным для workload cycle и async completion.

### 5. Switch authority

Traffic routing, feature flag или version pointer переводит reads/writes. Read switch безопаснее после catch-up и проверки lag = 0 в определённой позиции. Write switch требует fencing: старый writer больше не имеет права commit после нового epoch.

На короткое окно read fallback способен скрыть missing target data, но он маскирует расхождение и удлиняет migration. Fallback rate должен измеряться и иметь deadline удаления.

### 6. Contract

Удаление старого field/table/topic/path происходит после telemetry, подтверждающей отсутствие старых consumers и rollback need. Сначала отключают old write, затем old read, архивируют/backup, выдерживают safety window и только потом удаляют.

Strangler pattern применяет тот же принцип к service boundary: router постепенно переводит capability на новый owner, а не копирует весь монолит одним cutover. Временный anti-corruption layer переводит модели и получает дату удаления.

## Сквозной пример: переход от одной SQL-таблицы к shard-ам

Исходно `messages` находится в одном PostgreSQL primary. Target распределяет conversations по shard и сохраняет ordered key `(conversation_id, sequence)`.

1. **Prepare:** вводится shard router library в режиме `old`; conversation получает стабильный shard key. Capacity target и backfill rate проверяются на staging/copy.
2. **Expand:** новая binary по-прежнему пишет old DB, но outbox/CDC доставляет changes в target shards. Readers умеют читать обе формы.
3. **Backfill:** rows копируются по conversation/range с checkpoint. CDC применяет concurrent writes идемпотентно по version/sequence.
4. **Verify:** per-conversation max sequence, counts и checksums сравниваются; gaps попадают в repair queue.
5. **Shadow read:** часть reads выполняется в обоих stores, user получает old result, mismatch metric разрезан по shard/version.
6. **Canary read:** internal tenants читают target; затем доля растёт. При mismatch router возвращается на old без смены write authority.
7. **Write cutover:** для выбранного bucket coordinator выдаёт новый epoch, запрещает old writer и ждёт target catch-up до fence position. Затем target становится authority; old получает change copy только для rollback window.
8. **Contract:** после полного cutover, нулевого fallback и safety window old writes отключаются, old DB переходит read-only, архивируется и удаляется отдельным change.

Простой rollback безопасен до write cutover. После target-only writes возврат требует reverse replication и проверки version; это уже отдельная миграция, поэтому чаще быстрее исправить target и roll forward.

## Failure handling и observability

Миграция имеет собственные SLO: online latency/error overhead, max replication lag, mismatch rate, backfill throughput, retry age и completion ETA. Dashboards показывают source/target version, fallback, dual-write failures и oldest unprocessed change.

Backfill конкурирует с production за IOPS, locks, cache и network. Он автоматически throttles при saturation/SLO burn и возобновляется с checkpoint. Kill switch должен останавливать создание новой работы, не повреждая уже committed batch.

План восстановления тестируется до cutover: restore target backup, replay change log, rerun verification. Operator runbook называет authority, epoch и разрешённое следующее действие.

## Trade-offs

Blue/green даёт быстрый traffic rollback, но временно удваивает compute и не решает совместимость shared data. Rolling update дешевле, зато старые и новые binaries сосуществуют и требуют overlap compatibility.

Dual read повышает confidence, но удваивает load и может изменить cache. Shadow traffic полезен только при контроле side effects и privacy. Длинное migration window снижает cutover risk, но увеличивает стоимость dual world и число версий.

Canary уменьшает blast radius, но редкие data-dependent defects требуют representative partition/tenant, а не только 1% случайных requests.

## Типичные ошибки

- **Неверное предположение:** backward-compatible schema автоматически означает безопасный deploy. **Симптом:** старая binary не понимает новое значение enum/default. **Причина:** проверен DDL, но не semantic matrix. **Исправление:** тест всех одновременно работающих readers/writers.
- **Неверное предположение:** dual write синхронизирует stores. **Симптом:** timeout оставляет один commit без второго. **Причина:** две независимые atomic boundaries. **Исправление:** один authority + durable change log и reconciliation.
- **Неверное предположение:** backfill можно запустить без capacity budget. **Симптом:** p99 и replication lag растут. **Причина:** background scan конкурирует с online workload. **Исправление:** bounded batches, throttle по SLO и headroom.
- **Неверное предположение:** equal counts доказывают correctness. **Симптом:** значения или ownership различаются при одинаковом числе rows. **Причина:** слабая verification. **Исправление:** keys/checksums/domain invariants и sampled comparison.
- **Неверное предположение:** rollback всегда простой. **Симптом:** старая версия теряет новые writes или не читает новую schema. **Причина:** пройдена irreversible boundary. **Исправление:** назвать point of no return и подготовить roll-forward/repair.
- **Неверное предположение:** cleanup можно отложить навсегда. **Симптом:** каждый следующий change поддерживает две модели. **Причина:** contract phase не имеет owner/date. **Исправление:** exit telemetry, deadline и отдельный cleanup rollout.

## Когда применять

План нужен для binary/config/API/event/schema/storage/topology/region changes. Чем выше цена несовместимости и объём state, тем подробнее compatibility matrix, verification и reversible stages. Небольшой stateless change тоже выигрывает от canary и автоматического rollback gate, но не требует искусственного dual world.

## Источники

- [Canarying Releases](https://sre.google/workbook/canarying-releases/) — Google, The Site Reliability Workbook, глава 16, проверено 2026-07-18.
- [Data Processing Pipelines](https://sre.google/workbook/data-processing/) — Google, The Site Reliability Workbook, rollout и correctness для pipelines, проверено 2026-07-18.
- [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) — Kubernetes, документация v1.36, rolling update и rollback, проверено 2026-07-18.
- [PostgreSQL 18: ALTER TABLE](https://www.postgresql.org/docs/18/sql-altertable.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
