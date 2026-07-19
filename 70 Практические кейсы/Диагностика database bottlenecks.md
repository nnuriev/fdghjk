---
aliases:
  - Debugging database bottlenecks
  - Диагностика узких мест базы данных
  - Database bottleneck runbook
tags:
  - область/reliability-performance-operations
  - тема/диагностика
  - тема/базы-данных
  - технология/postgresql
  - технология/go
статус: проверено
---

# Диагностика database bottlenecks

## TL;DR

Длинный `db` span не означает медленный SQL. Он может включать ожидание connection в приложении, server lock, planner/executor work, storage/WAL, network и чтение результата. Production workflow сначала разделяет эти фазы, затем выбирает evidence: `database/sql` pool stats, `pg_stat_activity`/wait events/blockers, `pg_stat_statements`, `pg_stat_io` и безопасный query plan.

Не начинайте с добавления connections или индекса. Больший pool может усилить contention, а `EXPLAIN ANALYZE` действительно выполняет statement и способен причинить ущерб. Сохраните activity/locks/query IDs/settings до restart/failover, стабилизируйте admission и только затем проверяйте одну причинную гипотезу. Механика `database/sql` описана в [[60 Go/Пакет database-sql и пулы соединений|заметке о пуле]], а чтение plan — в [[30 Данные/Планы выполнения SQL-запросов|заметке о планах SQL]].

## Контекст

Server-side примеры привязаны к PostgreSQL 18.4, application side — к Go 1.26.5; проверено 2026-07-18. Конкретные wait events, планы и statistics version-sensitive. Обычный пользователь PostgreSQL видит полные activity details только своих sessions; для incident access нужен заранее ограниченный monitoring role, например с подходящими правами чтения statistics.

Scope — bottleneck между Go API и одной PostgreSQL deployment. Replication/failover correctness, schema design целиком и vendor-specific proxy вынесены за границы. Runbook не задаёт универсальные thresholds connections, cache hit или query time.

## Симптомы и влияние

Соберите user impact и границы:

- affected endpoints/jobs/tenants и p95/p99/error/timeout;
- offered/completed transactions и timely goodput;
- application pool `InUse`, `Idle`, прирост `WaitCount`/`WaitDuration`;
- PostgreSQL connections/states/wait events, transaction age и blockers;
- query IDs, calls/rows/exec time/temp/shared I/O;
- server CPU, storage latency/throughput/queue, WAL/checkpoint и replica state;
- deploy/config/schema/data-volume/traffic change.

Высокий API latency при низкой DB CPU не опровергает DB bottleneck: sessions могут ждать locks или storage. Высокая `InUse == MaxOpenConns` не доказывает, что pool слишком мал: connections могут быть заняты долгими/blocked transactions.

## Ментальная модель и гипотезы

```text
db span = application pool wait
        + connect/network
        + server queue/lock wait
        + parse/plan/execute
        + storage/WAL
        + rows transfer/scan in client
```

Очередь появляется перед текущим constraint. Pool wait — application-side очередь; active sessions with `wait_event_type='Lock'` — server-side wait; temp I/O или shared reads — executor/storage evidence. Один симптом может усиливать другой: lock holder увеличивает transaction time, заполняет pool, API requests timeout-ятся и retry создаёт ещё sessions.

Приоритет гипотез:

| Evidence | Гипотеза | Проверка |
| --- | --- | --- |
| Pool wait растёт, DB sessions ниже capacity | app pool leak/слишком малый pool/долгое удержание rows | `DB.Stats`, operation lifecycle, close/transaction duration |
| Много active sessions ждут `Lock`, CPU невысока | blocking transaction | `pg_stat_activity`, `pg_blocking_pids`, transaction age |
| Query ID доминирует total time/reads/temp | медленный plan/data shape | representative params и `EXPLAIN`/safe `ANALYZE` |
| `pg_stat_io` и OS storage latency растут | I/O/checkpoint/storage saturation | read/write/fsync contexts + OS metrics |
| CPU DB высокая, waits мало | CPU-heavy queries/planning/JIT/functions | query stats, plans и server CPU attribution |
| Connections/retries растут после timeout | amplification/pool oversizing | attempts per transaction и admission |

## Диагностика

### 1. Сохранить evidence до разрушительных действий

До restart/failover/termination сохраните timestamps, PostgreSQL minor/config, topology, application release, pool settings/stats, `pg_stat_activity`, blockers, relevant query IDs/stat counters, server/OS I/O и representative traces. Query texts и parameters могут содержать персональные данные; храните query ID/normalized form и редактируйте literals.

Statistics cumulative и зависят от момента reset. Запишите `stats_reset` и используйте rate/delta за problem window. Не сбрасывайте `pg_stat_statements`, не перезапускайте server и не завершайте blocker до snapshot, если impact позволяет короткий capture.

### 2. Разделить application pool и server execution

Для Go `DB.Stats` интерпретируйте вместе:

- `InUse`/`Idle` — текущий pool state;
- delta `WaitCount` — сколько acquisition пришлось ждать;
- delta `WaitDuration` — aggregate wait time;
- `MaxOpenConnections` — предел, а не целевая загрузка;
- close counters — churn из-за idle/lifetime settings.

Инструментируйте отдельно pool acquire, server round trip и rows iteration. `Rows`/`Tx`/dedicated `Conn` удерживают connection дольше одного call. Если acquire занимает большую часть trace, следующий вопрос — почему slots заняты, а не «насколько увеличить pool».

### 3. Снять server activity и wait graph

Read-only snapshot для диагностики может выглядеть так:

```sql
SELECT
    pid,
    application_name,
    state,
    wait_event_type,
    wait_event,
    now() - xact_start AS xact_age,
    now() - query_start AS query_age,
    pg_blocking_pids(pid) AS blocking_pids
FROM pg_stat_activity
WHERE datname = current_database();
```

Запрос не запускался в этом репозитории; поля и функция сверены с PostgreSQL 18.4. `state` и `wait_event` независимы: active session может одновременно ждать. `pg_blocking_pids` предпочтительнее ручного self-join `pg_locks`, но частые вызовы имеют overhead на lock manager, поэтому snapshot не превращают в high-frequency polling.

Ищите старые `idle in transaction`, long active queries, lock wait fan-out, client wait и autovacuum/checkpoint context. У blocker зафиксируйте `xact_start`, application, owner и last query. Не завершайте PID только потому, что он старый: это может быть migration, maintenance или critical transaction.

### 4. Выделить дорогие query families

Если extension `pg_stat_statements` заранее установлена, сравните deltas `calls`, `total_exec_time`, `mean/max_exec_time`, rows, shared/temp blocks и I/O time за problem window. Высокий `total_exec_time` показывает aggregate load, высокий mean/max — per-call latency; оба могут быть важны.

```sql
SELECT
    queryid,
    calls,
    total_exec_time,
    mean_exec_time,
    rows,
    shared_blks_read,
    temp_blks_written
FROM pg_stat_statements
WHERE dbid = (
    SELECT oid
    FROM pg_database
    WHERE datname = current_database()
)
ORDER BY total_exec_time DESC
LIMIT 20;
```

Запрос также не выполнялся локально. Cumulative rows без reset/window могут скрыть regression; связывайте query ID с application trace и конкретными parameter/data classes.

### 5. Разделить plan, lock и storage

Для suspect query сначала получите plain `EXPLAIN` с теми же parameter types/settings. `EXPLAIN ANALYZE` запускает statement; для mutating/дорогого query используйте representative copy/standby, либо transaction rollback только после оценки внешних/non-transactional effects. В PostgreSQL 18 `ANALYZE` автоматически включает `BUFFERS`.

В плане найдите первое расхождение estimated/actual rows, loops, reads, temp spill, sort/hash batching и serialization. Но хороший single-query plan не исключает lock/I/O saturation под concurrency. `pg_stat_io` агрегирует по backend type/object/context и не различает physical disk от OS page cache, поэтому PostgreSQL documentation советует сопоставлять его с OS utilities.

### 6. Проверить причинность безопасным изменением

Сформулируйте прогноз по слою: «если один idle transaction держит row lock, его штатный rollback освободит waiters, снизит pool acquire wait и восстановит p99 при прежней DB CPU». Сначала остановите источник новых faulty transactions, затем выполните согласованное с DB owner действие.

Для query hypothesis примените index/statistics/query rewrite на canary/representative data и повторите concurrency, а не только один `EXPLAIN`. Для pool hypothesis меняйте limit ступенчато и следите за DB waits/I/O; рост throughput без ухудшения server saturation подтверждает свободную capacity.

## Сквозная трассировка сценария

Числа ниже — сценарий, а не нормативы.

После `v207` p99 update endpoint растёт с `190 ms` до `2,8 s`, timeout rate — до `14%`. PostgreSQL CPU остаётся около `28%`, но у Go pool `InUse=40`, `Idle=0`, `MaxOpenConnections=40`; delta `WaitDuration` за минуту растёт на `71 s`.

1. Traces разделяют `db.acquire=1,9–2,4 s` и server execution быстрых requests около `35 ms`. Значит, очередь уже находится перед pool.
2. `pg_stat_activity` показывает `27` active sessions с `wait_event_type='Lock'` и одного blocker в `idle in transaction` с `xact_age=94 s`.
3. `pg_blocking_pids` возвращает один и тот же PID для waiters. Последняя normalized query blocker обновляет строку account balance.
4. Code diff `v207` поместил внешний risk API call между `UPDATE` и `COMMIT`. Пока application ждёт network timeout, transaction удерживает row lock; retries того же account создают fan-out waiters и заполняют pool.
5. Rollout остановлен, faulty request отменён штатным rollback/закрытием connection. Lock waiters исчезают, pool `WaitDuration` перестаёт расти, p99 возвращается к `210 ms`. Canary переносит network call до transaction и держит transaction только вокруг read-check-write; fault test risk API больше не создаёт open transaction.

Низкая DB CPU была ожидаема: sessions ждали lock. Увеличение pool добавило бы waiters, но не освободило blocker.

## Root cause

Root cause сценария — внешний network call внутри write transaction после захвата row lock. При timeout risk API application переставало отправлять команды, поэтому PostgreSQL session становилась `idle in transaction`, сохраняя lock. Client retries усилили fan-out, а ограниченный `database/sql` pool перенёс задержку на все updates.

Trigger — новая последовательность `v207`; amplifier — retries без per-key isolation; detection gap — dashboard показывал DB CPU, но не lock waits, transaction age и pool acquire duration.

## Исправление

### Немедленное

- Остановить rollout и retries для affected operation/key class.
- Зафиксировать activity/blocking graph, затем штатно отменить/rollback faulty transaction через application owner.
- Если owner недоступен и impact продолжается, DB owner может завершить подтверждённую blocker session как bounded mitigation с пониманием rollback/client error; не делать массовое завершение по age.
- Ограничить admission, чтобы новые waiters не занимали весь pool.

### Долгосрочное

- Не выполнять unpredictable network I/O внутри transaction, уже удерживающей locks; сократить lock scope.
- Передавать request context в `BeginTx`/queries и гарантировать `Commit` или `Rollback` на каждом path.
- Задать scoped `statement_timeout`, `lock_timeout`, `transaction_timeout`/`idle_in_transaction_session_timeout` согласно operation; проверить совместимость с pool/proxy.
- Добавить metrics pool acquire, transaction age, lock waits/blocker fan-out, query ID и attempts.
- Проверить concurrency/fault scenario, а не только happy-path SQL latency.

## Проверка результата

На том же workload и fault condition подтвердите:

- нет старых unexpected `idle in transaction` и blocker fan-out;
- pool wait deltas и occupancy bounded;
- endpoint histogram, timely goodput и error rate восстановлены;
- query correctness/isolation invariants сохранены;
- server CPU/I/O/WAL не стали новым bottleneck;
- после снятия fault система восстанавливается без restart/failover.

Если p99 снизился после увеличения pool, но DB waits/I/O растут, это временный перенос очереди, а не доказанное исправление.

## Профилактика

Dashboard должен соединять application `DB.Stats`, transaction/lock waits, oldest transaction, query-family deltas и PostgreSQL/OS I/O. Alert по числу connections без states/waits малоинформативен.

В code review транзакции проверяют как lifecycle: что удерживается, какие внешние calls происходят, где cancellation и rollback. Query plan regression тестируют на representative cardinality/parameters; index change оценивают вместе с write/WAL cost.

## Эволюция и версии

| Версия PostgreSQL | Изменение | Практический эффект | Источник |
| --- | --- | --- | --- |
| 18 | `EXPLAIN ANALYZE` автоматически включает buffer output; добавлены дополнительные plan details | Incident plan становится информативнее по I/O, но по-прежнему выполняет statement и не заменяет concurrency/wait evidence | [PostgreSQL 18 release notes](https://www.postgresql.org/docs/18/release-18.html) |

## Trade-offs

Больший application pool уменьшает acquire wait только при свободной server capacity. После saturation он увеличивает active work, memory, locks и tail. Малый pool защищает DB и даёт backpressure, но нуждается в deadline и admission, иначе становится скрытой очередью.

`EXPLAIN ANALYZE` даёт actual rows/timing/buffers, но выполняет query и добавляет instrumentation overhead. Plain `EXPLAIN` безопаснее, однако не показывает runtime skew/spill. `auto_explain` ловит редкий production plan, но `log_analyze`/per-node timing может быть очень дорогим.

Короткие timeouts ограничивают lock/resource occupancy, но могут отменять legitimate batch. Глобальные значения опасны для разных workloads; operation/role-scoped budgets точнее, но сложнее управляются.

## Типичные ошибки

- **Неверное предположение:** длинный `db` span означает медленный SQL. **Симптом:** plan быстрый, p99 не меняется. **Причина:** span смешал pool acquire, lock и rows read. **Исправление:** инструментировать фазы и сверить server wait events.
- **Неверное предположение:** низкая DB CPU означает свободную DB. **Симптом:** requests timeout-ятся при 30% CPU. **Причина:** sessions ждут locks/storage/client. **Исправление:** смотреть wait graph, I/O и transaction age.
- **Неверное предположение:** `InUse == MaxOpenConns` требует увеличить pool. **Симптом:** после увеличения blockers/waits растут. **Причина:** slots заняты медленной/blocked работой. **Исправление:** найти owner occupancy и проверить server headroom.
- **Неверное предположение:** самый высокий mean query и есть главный bottleneck. **Симптом:** оптимизация редкого query не меняет fleet. **Причина:** aggregate cost определяется calls × cost и critical operation. **Исправление:** total time/rates + trace/SLO context.
- **Неверное предположение:** `EXPLAIN ANALYZE` read-only. **Симптом:** diagnostic statement изменил production data или усилил load. **Причина:** `ANALYZE` выполняет statement. **Исправление:** plain plan сначала, representative copy/transaction с проверкой side effects.
- **Неверное предположение:** завершить самый старый PID безопасно. **Симптом:** rollback критичной migration или дополнительный outage. **Причина:** age не доказывает blocker/ownership. **Исправление:** blocking graph, application owner, expected rollback и bounded action.

## Когда применять выводы

Runbook запускают при росте DB spans, pool wait, query latency, lock waits, storage/WAL saturation, connection exhaustion или очереди jobs, зависящих от DB. Первое решение — определить, где именно ждёт операция.

Диагностика завершена, когда layer и constraint доказаны независимыми signals, известен trigger/amplifier, mitigation восстановила SLI, а исправление выдержало representative concurrency и failure path.

## Источники

- [Package database/sql](https://pkg.go.dev/database/sql@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, `DBStats`, `Rows`, `Tx` и connection lifecycle, проверено 2026-07-18.
- [Managing connections](https://go.dev/doc/database/manage-connections) — The Go Project, connection pool limits и `DB.Stats`, проверено 2026-07-18.
- [The Cumulative Statistics System](https://www.postgresql.org/docs/18/monitoring-stats.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, `pg_stat_activity`, wait events, `pg_stat_io`, проверено 2026-07-18.
- [System Information Functions](https://www.postgresql.org/docs/18/functions-info.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, `pg_blocking_pids`, проверено 2026-07-18.
- [pg_stat_statements](https://www.postgresql.org/docs/18/pgstatstatements.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, query planning/execution statistics, проверено 2026-07-18.
- [EXPLAIN](https://www.postgresql.org/docs/18/sql-explain.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, actual execution, buffers и safety, проверено 2026-07-18.
- [Client Connection Defaults](https://www.postgresql.org/docs/18/runtime-config-client.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, statement/lock/transaction/idle-in-transaction timeouts, проверено 2026-07-18.
- [PostgreSQL 18 release notes](https://www.postgresql.org/docs/18/release-18.html) — PostgreSQL Global Development Group, PostgreSQL 18, `EXPLAIN` changes, проверено 2026-07-18.
