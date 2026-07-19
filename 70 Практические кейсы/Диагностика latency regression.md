---
aliases:
  - Debugging latency regression
  - Диагностика регрессии latency
  - Latency regression runbook
tags:
  - область/reliability-performance-operations
  - тема/диагностика
  - тема/latency
  - технология/go
статус: проверено
---

# Диагностика latency regression

## TL;DR

Latency regression — устойчивое ухудшение распределения задержки относительно сопоставимого baseline, а не один медленный запрос. Сначала зафиксируйте operation, population, percentile/histogram, success condition и measurement boundary. Затем разложите critical path на queue wait, local CPU/GC, lock/pool, network setup, downstream execution и response transfer.

Metrics показывают ширину и время начала, traces локализуют wall time одного класса запросов, profiles объясняют локальную стоимость, а logs дают конкретный status/config. Исправление доказано, когда на том же workload исчезла изменившаяся стадия и восстановились percentile/goodput без роста ошибок. Определения percentile и ловушки агрегации разобраны в [[70 Практические кейсы/p50, p95 и p99 latency|заметке о p50/p95/p99]], а здесь находится production workflow.

## Контекст

Scope — интерактивный backend, примеры Go привязаны к Go 1.26.5; проверено 2026-07-18. Никакой percentile не имеет универсального хорошего значения. Baseline должен совпадать по endpoint/operation, success class, region, tenant/payload class, concurrency, release, topology и measurement point.

Вне scope — проектирование SLO с нуля и полный анализ capacity. Runbook начинается с уже наблюдаемого отклонения: deploy cohort против control, текущее окно против исторического seasonality или benchmark той же workload-модели.

## Симптомы и влияние

Зафиксируйте не только «p99 вырос», а полный incident contract:

- какая операция и cohort затронуты;
- p50/p95/p99, histogram buckets вокруг SLO и error/timeout rate;
- offered, admitted, completed и timely-successful rates;
- момент начала, длительность и корреляция с deploy/config/traffic/dependency;
- queue age/in-flight, saturation и downstream SLI;
- доля пользователей/tenants/regions, нарушивших SLO.

Рост только p99 при стабильном p50 указывает на tail-specific class: skew, retries, lock convoy, cold connection, hot shard или rare payload. Одновременный сдвиг всей distribution чаще соответствует изменению общей service time, queueing или measurement boundary. Это приоритеты, не доказательства.

## Ментальная модель и гипотезы

```text
end-to-end latency = admission/queue
                   + scheduler/local CPU/GC
                   + lock/pool wait
                   + DNS/connect/TLS
                   + downstream queue/execution
                   + response read/serialization/network
```

Percentile end-to-end нельзя получить сложением percentile стадий: медленные случаи могут относиться к разным запросам. Нужен trace конкретного slow population и распределения каждой фазы.

Гипотезы приоритизируют по наблюдаемому изменению:

| Evidence | Вероятный слой | Следующая проверка |
| --- | --- | --- |
| Offered load выше, service time прежняя, queue растёт | capacity/admission | saturation и completed goodput |
| Self-time span и CPU/op выросли | local code/GC | CPU/alloc profiles проблемной версии |
| CPU низкая, pool wait или runnable wait выросли | bounded resource/scheduler | pool stats, goroutine/block/trace |
| Один downstream span удлинился | dependency или client-side wait | разделить acquire/DNS/connect/TLS/server/read |
| Только один shard/tenant/payload медленный | skew/hot key/data shape | разрез cohort и query/trace labels |
| Latency graph изменился без user reports и traces | telemetry/measurement change | boundary, buckets, sampling, clocks, success filter |

## Диагностика

### 1. Сохранить baseline и problem window

До rollback/restart сохраните histogram/query definition, dashboard range, release/config/topology, affected instance IDs, representative trace IDs, rate/errors и saturation. Если система использует sampled traces, запишите sampling policy: изменение sampler способно изменить видимый tail.

Не сохраняйте request/response payload или credentials без необходимости. Trace/log labels должны иметь bounded cardinality и проходить redaction. Профили снимают с affected instance короткими раздельными captures; Go diagnostics предупреждает о взаимном влиянии инструментов.

### 2. Проверить корректность сравнения

Сравните одинаковые populations: endpoint, method, status/success, payload size, tenant class, zone, cache state и traffic phase. Убедитесь, что percentile вычислен из исходного histogram/distribution, а не усреднён из готовых per-instance p99.

Проверьте measurement boundary. Client end-to-end включает network и retries, server handler — нет; database span может включать ожидание connection и чтение rows, а может измерять только wire call. Изменение instrumentation способно создать «регрессию» без изменения user latency.

### 3. Найти первую изменившуюся стадию

Возьмите несколько traces из slow bucket и healthy control того же класса. Пройдите critical path, а не сумму всех parallel spans. Отметьте очередь до handler, local self-time, каждую попытку/retry, pool acquire, DNS/connect/TLS, time to first byte, downstream execution и response read.

Сначала ищите первую фазу, которая стала дольше относительно control. Длинный parent span не называет виноватого, а большая dependency span может скрывать client pool wait. Если tracing не разделяет фазы, добавьте временную безопасную instrumentation на canary; для Go HTTP client `net/http/httptrace` предоставляет hooks `GetConn/GotConn`, DNS, connect, TLS и first-byte lifecycle.

### 4. Сопоставить wall time с resource evidence

- Local self-time + высокая CPU: CPU profile и CPU/op.
- Local self-time + allocation/GC: allocs/heap и GC metrics.
- Долгая runnable задержка: `/sched/latencies`, runnable states и execution trace.
- Mutex/channel: mutex/block profile и stack ownership.
- Database span: `database/sql` acquire wait против server execution; используйте [[70 Практические кейсы/Диагностика database bottlenecks|database runbook]].
- Network setup: connection reuse, DNS/connect/TLS hooks, socket errors и transport config.
- Downstream execution: dependency metrics/traces и its own saturation, а не локальный profile caller.

Общий [[70 Практические кейсы/Performance profiling и bottleneck analysis|workflow bottleneck analysis]] важен: profile атрибутирует стоимость, но причинность доказывает изменение пользовательского результата после снятия constraint.

### 5. Проверить recent changes и скрытые amplifiers

Сравните binary/config/feature flags, client timeouts, connection-pool/transport settings, retry policy, cache key/TTL, query/schema, runtime version и resource limits. Изменение traffic mix рассматривайте наравне с code diff.

Особенно ищите retries и queueing. Один downstream call мог стать лишь немного медленнее, но занять pool дольше, создать очередь, вызвать deadline и повторные attempts. В таком случае proximate slow dependency и amplification loop должны быть описаны отдельно.

### 6. Стабилизировать и проверить причинность

Во время active impact выбирайте обратимое действие: остановка rollout, feature disable, bounded concurrency, load shedding, retry reduction или возврат transport/config. Увеличение timeout редко лечит regression: оно позволяет doomed work дольше удерживать slots и может ухудшить p99.

Запишите прогноз до change: «если исчезла connection reuse, возврат общего Transport уменьшит долю new connections/TLS handshakes и downstream subspan, затем p99». Меняйте одну причину на canary и проверяйте mechanism metric вместе с SLI.

## Сквозная трассировка сценария

Все числа ниже — один сценарий, не нормативные пороги.

После rollout `v118` p50 endpoint `/quote` меняется с `72` до `96 ms`, p99 — с `210` до `940 ms`; offered load остаётся около `1 600 requests/s`, error rate растёт с `0,3%` до `3,8%`, CPU держится около `46%` quota.

1. Slow traces локализуют дополнительные `80–310 ms` перед first byte downstream pricing API. Server-side latency pricing API не изменилась.
2. Фазовые hooks показывают падение `GotConnInfo.Reused=true` с `92%` до `8%`; в slow requests появляются TCP connect и TLS handshake. DNS не изменился.
3. Diff `v118` на error status возвращает ошибку сразу после `client.Do`, не читая и не закрывая `Response.Body`. Таких responses стало больше из-за нового validation path.
4. Документация `net/http` требует закрывать body; для reuse HTTP/1.x persistent connection body должен быть прочитан до EOF и закрыт. Необработанные bodies оставляют Transport без возможности reuse для следующих запросов.
5. Canary с общим long-lived `http.Client` и bounded обработкой/закрытием body возвращает reuse к `91%`; connect/TLS фазы почти исчезают из steady-state traces, p99 снижается до `225 ms`, error semantics остаётся прежней.

CPU profile здесь не был первичным инструментом: процесс большую часть regression ждал network setup. Causal evidence дали фазовый trace, code path и изменение reuse + p99 после fix.

## Root cause

Root cause сценария — error branch `v118`, который не завершал lifecycle HTTP response body. Это лишило Transport возможности устойчиво переиспользовать HTTP/1.x connections, добавило connect/TLS setup и исчерпало часть connection capacity. Рост downstream validation errors был trigger, а queueing новых connects усилил tail.

Фраза «pricing API стал медленным» была бы неверной: его server execution не изменился. Длиннее стала client-side стадия до/вокруг запроса.

## Исправление

### Немедленное

- Остановить rollout или выключить новый error path.
- Вернуть проверенный общий `Client`/`Transport`; не создавать Transport per request.
- Ограничить concurrency/retries, если connect storm уже давит на network/dependency.
- Постепенно заменить affected instances после fix, если старые resources не освобождаются достаточно быстро.

### Долгосрочное

- Централизовать HTTP client lifecycle, timeouts и response cleanup policy.
- На каждом outcome закрывать body; для reuse читать его до EOF только с явным size bound, чтобы hostile/large body не вызвал memory/latency problem.
- Инструментировать pool acquire/reuse, DNS/connect/TLS/first-byte на sampled requests.
- Добавить integration/load regression с error responses, connection reuse и representative concurrency.
- Зафиксировать latency budget по стадиям как diagnostic expectation, не как сумму percentile.

## Проверка результата

На том же endpoint/request mix/concurrency проверьте:

- end-to-end histogram и SLO bucket, а не только среднее;
- timely goodput и ошибки, чтобы latency не «улучшилась» за счёт rejects;
- исчезновение изменившейся фазы в traces;
- восстановление connection reuse и отсутствие connect/TLS storm;
- стабильность CPU, goroutines, open connections и memory;
- отсутствие нового bottleneck в dependency/pool.

Observation window должен включать warm-up, steady state и error branch, который раньше запускал regression.

## Профилактика

Храните release-aware latency histograms и exemplars/trace IDs для slow buckets. Dashboard должен связывать latency с offered/completed rates, errors, in-flight/queue, pool wait, CPU/GC и downstream phases.

Canary gate сравнивает распределения и mechanism metrics между версиями при одном traffic class. Для network clients отдельно наблюдайте reuse/new connections, connect/TLS latency и response-body errors. Benchmark функции полезен только после локализации local CPU stage.

## Эволюция и версии

В Go 1.26.5 `Client` и `Transport` остаются safe for concurrent use и должны переиспользоваться; `Transport` хранит connection cache. Новые API Go 1.26 для явного `ClientConn` не меняют основной runbook: большинство приложений должно работать через long-lived `Transport`, а не вручную создавать connection на каждый запрос.

## Trade-offs

Более длинный timeout уменьшает false timeout для законно долгих операций, но увеличивает occupancy и blast radius slow dependency. Короткий timeout быстрее освобождает budget, однако требует корректной cancellation и может повысить ошибки при нормальном tail.

Большой connection pool поглощает burst, но увеличивает sockets и concurrency downstream. Малый pool создаёт ранний wait и защищает dependency; его размер выбирают по измеренной capacity, а не лечат им lost reuse.

Подробное tracing ускоряет локализацию, но повышает overhead и cardinality/privacy risk. Sampling должен сохранять errors/tail exemplars и быть известен при сравнении cohort.

## Типичные ошибки

- **Неверное предположение:** выросший p99 означает, что все запросы стали медленнее. **Симптом:** оптимизируют common path, а tail не меняется. **Причина:** regression находится в редком payload/shard/retry class. **Исправление:** сравнить форму distribution и slow cohort.
- **Неверное предположение:** percentile стадий можно сложить. **Симптом:** сумма «p99 dependencies» превышает end-to-end или не объясняет его. **Причина:** percentile относятся к разным observations. **Исправление:** анализировать critical path конкретных traces и distributions фаз.
- **Неверное предположение:** длинный `db`/HTTP span доказывает медленный server. **Симптом:** dependency metrics здоровы. **Причина:** span включает acquire, DNS/connect/TLS или response read. **Исправление:** разделить client phases.
- **Неверное предположение:** повысить timeout — исправить regression. **Симптом:** timeout errors временно падают, но pool/queue и p99 растут. **Причина:** работа дольше удерживает конечный resource. **Исправление:** устранить изменившуюся стадию и ограничить admission.
- **Неверное предположение:** profile healthy instance представляет incident. **Симптом:** найденный hotspot не меняет affected cohort. **Причина:** skew/version/topology различаются. **Исправление:** capture проблемной replica и сопоставимый control.
- **Неверное предположение:** rollback correlation доказывает root cause. **Симптом:** latency вернулась, но mechanism неизвестен и defect повторяется. **Причина:** rollback изменил много переменных. **Исправление:** сохранить traces/config и подтвердить конкретную фазу на canary.

## Когда применять выводы

Runbook применяют при ухудшении p50/p95/p99, SLO bucket, deadline miss или user-perceived latency после code/config/traffic/dependency change. Если одновременно растёт backlog, сначала ограничьте admission и сохраните evidence; deep analysis не должен продолжать user impact.

Диагностика завершена, когда определены population и boundary, найдена первая изменившаяся стадия, mechanism связан с change, mitigation восстановила SLI, а regression scenario закреплён тестом/наблюдением.

## Источники

- [Package net/http](https://pkg.go.dev/net/http@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, reuse `Client`/`Transport` и lifecycle `Response.Body`, проверено 2026-07-18.
- [Исходный код `net/http` client lifecycle](https://github.com/golang/go/blob/go1.26.5/src/net/http/client.go) — репозиторий golang/go, tag `go1.26.5`, файл `src/net/http/client.go`, контракт `Client.Do` для `Response.Body`, проверено 2026-07-18.
- [Package net/http/httptrace](https://pkg.go.dev/net/http/httptrace@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, DNS/connect/TLS/connection hooks, проверено 2026-07-18.
- [Diagnostics](https://go.dev/doc/diagnostics) — The Go Project, общая веб-документация без release-versioning, profiles, distributed tracing и runtime diagnostics, проверено 2026-07-18.
- [Package runtime/trace](https://pkg.go.dev/runtime/trace@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, execution tracing, проверено 2026-07-18.
- [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) — Google, Site Reliability Engineering, глава 6, latency/traffic/errors/saturation, проверено 2026-07-18.
- [Distributed Systems Observability](https://opentelemetry.io/docs/concepts/observability-primer/) — OpenTelemetry, official documentation, metrics/logs/traces и distributed context, проверено 2026-07-18.
