---
aliases:
  - CourseHunter 5785 — кэш API observability
tags:
  - источник/coursehunter
  - тема/system-design/cache
  - тема/system-design/api
  - тема/system-design/observability
статус: проверено
---

# Кэш, API и observability

## Кэширование

### Какие данные стоит кэшировать?

Дорогие для вычисления/чтения, часто повторяемые, допускающие заданную staleness и достаточно компактные. Нужны четыре числа: hit ratio, object size, TTL/freshness и miss cost. «Поставим Redis» без них не объясняет выигрыш.

### Read-aside, read-through и write-through

- read-aside: приложение читает cache, на miss — source of truth и заполняет cache; просто, но первый запрос медленный и возможен stampede;
- read-through: загрузку инкапсулирует cache/provider; application проще, но provider знает storage contract;
- write-through: подтверждение записи включает source of truth и cache; свежесть лучше, write latency и coupling выше;
- write-behind: cache подтверждает раньше durable store; throughput растёт, но требуется WAL/replay и строгая модель потери.

![[90 Вложения/CurseHunter/5785/Кадры/008-cache-summary.jpg|720]]

### Какие failure modes ждёт интервьюер?

- cold start и cache warming;
- cache stampede: singleflight/request coalescing, probabilistic early refresh, jittered TTL;
- hot key и uneven sharding;
- stale data и invalidation race;
- negative caching и риск скрыть только что созданный объект;
- eviction policy: LRU/LFU/TinyLFU выбирают под workload, а не по названию;
- multi-layer cache: browser/CDN/service/local cache складывают staleness и усложняют purge.

Ключ должен включать все параметры, от которых зависит ответ: tenant, locale, auth scope, representation version. Иначе быстрый cache превращается в утечку данных.

## API

### REST, RPC/gRPC, GraphQL, polling, streaming — как выбирать?

- REST/HTTP удобен для resource semantics, caches и широких клиентов;
- RPC/gRPC — строгий контракт и эффективное service-to-service взаимодействие;
- GraphQL уменьшает under/over-fetching на сложных UI, но требует cost limits, batching и контроля N+1;
- polling прост, но создаёт пустые запросы; long polling снижает их число, сохраняя request lifecycle;
- SSE — однонаправленный server-to-client event stream поверх HTTP;
- WebSocket — двунаправленный длительный канал, требующий connection routing, heartbeat и reconnect semantics;
- webhook — сервер вызывает зарегистрированный endpoint клиента; нужны signature, retry, dedup и replay protection.

### Offset, page и cursor pagination

Offset удобен, но глубокий offset дорог и на изменяемом наборе даёт пропуски/дубли. Cursor должен кодировать стабильный total order, например `(created_at, id)`, и быть непрозрачным. Snapshot pagination нужна, если результат должен оставаться консистентным между страницами.

### Как сделать повтор безопасным?

HTTP определяет GET/PUT/DELETE как idempotent по intended effect, но бизнес-операция через POST может стать повторяемой с client request ID. Сервер атомарно связывает ключ с fingerprint намерения и итоговым ответом; одинаковый ключ с другим payload — конфликт. TTL ключа должен покрывать retry horizon.

![[90 Вложения/CurseHunter/5785/Кадры/009-idempotency-key.jpg|720]]

Ключ не решает всё: если side effect и запись результата ключа не атомарны, crash оставляет неопределённость. Нужна локальная транзакция, state machine или reconciliation.

### Версионирование

Версия в path/header — вторична. Сначала определяют compatibility policy: additive fields, tolerant readers, deprecation window, schema evolution, consumer telemetry и migration. Нельзя переиспользовать поле с новым смыслом, даже если wire type прежний.

## Observability

### Чем metrics, logs, traces и profiles отличаются?

- metrics отвечают «насколько много и как меняется»;
- logs дают дискретный контекст события;
- traces показывают causal path запроса между сервисами;
- continuous profiles объясняют, где процесс расходует CPU/allocations/lock time.

Four Golden Signals: latency, traffic, errors, saturation. Их надо считать с точки зрения пользователя и разбивать по классу операций; fast error нельзя смешивать с successful latency.

### Как проектировать alert?

Alert должен быть actionable и связан с user-visible SLO. Хороший page говорит, что нарушается, насколько быстро сгорает error budget, где начать диагностику и что уже автоматизировано. Single-host failure в распределённой системе часто noise; page по симптомам дополняют diagnostic metrics по причинам.

### Как не потерять telemetry во время сбоя?

Удалённая observability система не должна блокировать путь обработки запроса. Локальный agent/sidecar принимает telemetry, ограниченно буферизует её на диске или в памяти, применяет batching/backpressure и экспортирует дальше. При переполнении нужна явная sampling/drop policy и собственные метрики потерь.

![[90 Вложения/CurseHunter/5785/Кадры/010-observability-sidecar.jpg|720]]

## Практика: API Coin Keeper

Минимальный контракт:

- `CreateTransaction` с idempotency key и money в minor units/decimal, не `float`;
- `ListTransactions` с cursor и фильтрами по account/category/time;
- `CreateAccount`, `ListAccounts`, archive/delete semantics;
- `GetMonthlyReport`, лучше как asynchronous job при дорогой агрегации;
- optimistic version для конфликтующих edits и audit trail.

Нужно определить tenant boundary, authz на каждый account, timezone месяца, read-your-writes после создания и поведение отчёта при позднем редактировании операции.

## Источники

- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, RFC 9110, June 2022, разделы 9.2.1–9.2.3, проверено 2026-07-19.
- [RFC 6455: The WebSocket Protocol](https://www.rfc-editor.org/rfc/rfc6455.html) — IETF, RFC 6455, December 2011, проверено 2026-07-19.
- [Making retries safe with idempotent APIs](https://aws.amazon.com/builders-library/making-retries-safe-with-idempotent-APIs/) — Amazon Builders' Library, проверено 2026-07-19.
- [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) — Google SRE Book, глава 6, проверено 2026-07-19.
