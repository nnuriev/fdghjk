---
aliases:
  - Performance profiling
  - Bottleneck analysis
  - Поиск узкого места
  - Анализ производительности backend
tags:
  - область/reliability-performance-operations
  - тема/производительность
  - тема/диагностика
статус: проверено
---

# Performance profiling и bottleneck analysis

## TL;DR

**Bottleneck** — ресурс или последовательная стадия, которая ограничивает throughput либо latency при конкретном workload. Самая медленная функция в одном запросе и самая высокая строка `pprof top` не обязаны быть bottleneck: запрос может большую часть времени ждать connection, queue или I/O, а профиль CPU видит только on-CPU работу.

Рабочий цикл такой: зафиксировать пользовательский симптом и нагрузку, локализовать ожидание по стадиям, выбрать профиль под предполагаемый ресурс, проверить call/retention path и провести контролируемый эксперимент. Исправление считается доказанным, когда на том же workload улучшился SLI/goodput, исчезла ожидаемая saturation и не нарушилась корректность. После этого bottleneck нередко перемещается в следующий ресурс.

## Область применимости

Метод относится к backend-системам и соединяет [[50 Проектирование систем/Observability в System Design|system metrics, distributed/request traces и logs]] с process profiles. Детали профилей приведены для Go 1.26.5; baseline `linux/amd64`, проверено 2026-07-18. SQL query plans, kernel/network profilers и cloud-specific telemetry имеют собственные версии и рассматриваются лишь как следующий инструмент после локализации слоя.

Заметка не задаёт универсальные пороги CPU или latency. Saturation зависит от quota, parallelism, service-time distribution и SLO; сравнивать нужно одинаковые workload, topology и runtime settings.

## Ментальная модель

Request latency раскладывается на работу и ожидание:

```text
latency = queue wait + on-CPU work + lock/pool wait + I/O + downstream + scheduling
```

Throughput ограничивает стадия с наименьшей эффективной capacity на текущем request mix. Очередь обычно появляется перед ней, а utilization ресурса приближается к пределу. Но utilization сам по себе неоднозначен: CPU может быть низким, пока все goroutines ждут database connection; CPU может быть высоким из-за полезной работы либо из-за GC/retry/spin.

Profile — статистическая атрибуция стоимости по stack traces. Он отвечает «где накопилась измеряемая стоимость». Bottleneck analysis добавляет причинность: «какой constraint ограничивает пользовательский результат и изменится ли результат, если снять именно его».

## Как устроено

### 1. Зафиксировать симптом и denominator

Начинают с user-visible сигнала: p95/p99 конкретной операции, completed successful operations, timeout/error rate, freshness или batch completion time. Рядом фиксируют offered load, request mix, payload size, concurrency, deployment version, число replicas и quotas.

Нужен правильный denominator. CPU process в процентах без CPU limit, latency без endpoint/tenant и throughput без success/correctness позволяют «улучшить» систему, которая лишь быстрее отказывает. Для production оптимизируют goodput и SLO, а не число attempts.

### 2. Найти границу, перед которой копится работа

Метрики дают ширину и динамику: utilization, throttling, runnable work, queue age/length, pool wait, lock wait, IOPS, network и downstream latency. Request trace раскладывает одну медленную операцию по spans и показывает, какая стадия владеет wall time. Логи нужны для payload/error/config, но редкие log lines не заменяют распределение latency.

Проверка идёт сверху вниз по critical path. Если API p99 вырос, а его self-time мал и почти всё время занимает downstream span, process CPU profile API не объяснит проблему. Если span «database» длинный, отдельно разделяют ожидание connection, server execution и чтение результата.

Для очередей действует причинная модель из [[40 Распределённые системы/Backpressure и queue buildup|заметки о queue buildup]]: растущий backlog указывает, что arrival rate устойчиво выше effective service rate, но не называет сам ограничивающий ресурс.

### 3. Выбрать профиль под гипотезу

| Наблюдение | Следующий capture | Что он способен доказать |
| --- | --- | --- |
| CPU saturation, throughput plateau | CPU profile | sampled on-CPU stacks и их flat/cumulative cost |
| live heap/RSS растёт | heap `inuse`, allocs, runtime/OS metrics | retention против churn и non-Go memory |
| CPU низкий, latency высокая | trace, goroutine, block/mutex profile | scheduling, blocking, locks и wait states |
| много goroutines | goroutine profile и state metrics | повторяющиеся stacks и runnable/blocked split |
| kernel, syscall или cgo подозрительны | execution trace и OS profiler | граница runtime, syscall/kernel/native code |
| один SQL path медленный | server metrics и query plan | scan/join/cardinality/index/lock на стороне СУБД |

Go CPU, heap, allocs, goroutine, block и mutex profiles разобраны в [[60 Go/Профилирование с pprof|заметке о pprof]]. Когда важен порядок scheduler, syscalls, GC и unblocking, нужен [[60 Go/Execution trace|execution trace]].

### 4. Читать профиль в его единицах

У CPU profile denominator — собранные CPU samples, а не wall latency запроса. У heap `inuse_space` — sampled live bytes, у `alloc_space` — cumulative allocation bytes. Block/mutex profiles агрегируют время ожидания по своим правилам и требуют включённого sampling.

`flat` показывает cost непосредственно в function, `cum` — вместе с callees. Большой cumulative dispatcher не означает, что надо оптимизировать dispatcher. Путь проходят до leaf work или до boundary, где стоимость переходит во внешний компонент.

Один profile легко перепутать с нормальным baseline. Полезнее сравнить одинаковые окна до/после regression или два production cohorts с тем же traffic mix. Profile снимают на экземпляре, который действительно испытывает симптом: средний healthy pod не представляет hot shard или noisy tenant.

### 5. Проверить причинность изменением constraint

Сформулируйте прогноз до изменения: «если JSON encoding ограничивает CPU, удаление повторного encoding снизит CPU/op, поднимет throughput plateau и уменьшит queue wait». Затем измените одну переменную и повторите тот же benchmark/load slice.

Локальный microbenchmark нужен для конкретной функции, но не доказывает end-to-end выигрыш. Production-like load проверяет pools, queues и downstream. После эксперимента сравнивают latency distribution, goodput, CPU/op, allocations/op, error rate и correctness. Если профиль изменился, а SLI нет, оптимизированная стоимость не была текущим bottleneck либо её заменил другой constraint.

## Пример или трассировка

После rollout API при 4 000 requests/s выходит на p99 `420 ms`, goodput перестаёт расти, CPU quota используется на 94%. Ошибок мало, но входная очередь растёт.

1. Traces показывают, что downstream spans не изменились, а self-time API вырос примерно на 65 ms. Это локализует проблему внутри процесса, но ещё не называет функцию.
2. CPU profile из проблемного pod показывает 37% samples в повторном JSON encoding response и его callees. `flat/cum` подтверждают leaf work; block profile не показывает сопоставимого ожидания.
3. Diff с предыдущей версией на том же request mix связывает новый path с rollout. Команда убирает второй encode и повторяет нагрузку.
4. На том же стенде CPU utilization падает до 71%, p99 — до `190 ms`, goodput растёт до 5 200 requests/s. При дальнейшем росте первым начинает увеличиваться database pool wait: bottleneck переместился.

Наблюдаемый результат подтверждает исходный механизм тремя независимыми сигналами: профиль атрибутировал on-CPU cost, code diff объяснил появление path, а controlled replay улучшил пользовательский SLI и capacity. Само уменьшение доли JSON в новом профиле без роста goodput было бы недостаточным доказательством.

## Trade-offs

Metrics дёшевы и непрерывны, но агрегируют причины. Traces связывают стадии одного запроса и tail cases, зато sampling способен пропустить редкий класс. Profiles дают глубокую process attribution, но обычно теряют business context и временной порядок. Для нетривиального bottleneck нужны все три уровня, а не один «главный» инструмент.

Высокая частота profiling повышает детализацию и overhead. Go documentation отдельно предупреждает, что некоторые diagnostic modes мешают друг другу; captures лучше разводить и заранее измерять их цену. Публичный `/debug/pprof` раскрывает stack/function data и позволяет запускать затратный сбор, поэтому endpoint держат на защищённом internal listener.

Увеличить pool/concurrency проще, чем оптимизировать код. Это выигрывает, пока ресурс имеет свободную capacity; после насыщения переносит очередь в downstream и ухудшает p99. Cache уменьшает service time для hits, но добавляет invalidation, memory и herd на miss. Выбор подтверждается профилем реального request mix.

## Типичные ошибки

- **Неверное предположение:** самая высокая функция в CPU `top` и есть bottleneck. **Симптом:** её ускорили, а p99 не изменился. **Причина:** wall time находился в I/O/pool wait либо функция не ограничивала throughput. **Исправление:** сначала локализовать critical path, затем связать профиль с SLI экспериментом.
- **Неверное предположение:** 100% CPU всегда означает нехватку CPU. **Симптом:** после добавления cores throughput почти не растёт. **Причина:** serial section, lock contention, GC churn или downstream constraint не масштабируются линейно. **Исправление:** проверить profiles, runnable/lock states и scaling curve.
- **Неверное предположение:** низкий средний CPU означает свободную capacity. **Симптом:** один shard имеет высокий p99 и backlog при 35% fleet average. **Причина:** skew, per-instance quota или один saturated resource скрыты агрегацией. **Исправление:** разрезать по replica/shard/key/tenant и смотреть max/quantiles.
- **Неверное предположение:** trace span `db` доказывает медленный SQL. **Симптом:** query plan быстрый, а span длинный. **Причина:** span смешал pool wait, network, server execution и result read. **Исправление:** инструментировать фазы и сопоставить со статистикой [[60 Go/Пакет database-sql и пулы соединений|database/sql pool]].
- **Неверное предположение:** microbenchmark гарантирует production gain. **Симптом:** allocations/op уменьшились, но end-to-end throughput тот же. **Причина:** оптимизирована стадия вне текущего constraint или изменился compiler/cache context. **Исправление:** закрепить micro-result и повторить production-like workload с SLI.
- **Неверное предположение:** один удачный profile воспроизводит regression. **Симптом:** исправляют path из healthy instance, а hot pods не меняются. **Причина:** разные request mix, phase или instance. **Исправление:** capture problem window, labels и baseline/diff на сопоставимых cohorts.

## Когда применять

Применяйте workflow при latency regression, throughput plateau, saturation, росте cost per operation и перед крупной оптимизацией. Во время инцидента сначала сохраняют короткий capture и стабилизируют SLO; длительный эксперимент под реальным overload недопустим. Если безопасного production capture нет, берут representative replica или воспроизводят request mix на изолированном стенде.

Законченный разбор оставляет воспроизводимый workload, baseline, profile/trace, проверяемую причинную гипотезу и before/after результат. Для предотвращения регрессии добавляют benchmark или load scenario с noise control, но alert строят по пользовательскому SLI и saturation, а не по имени конкретной функции: после следующего изменения bottleneck будет другим.

## Источники

- [Diagnostics](https://go.dev/doc/diagnostics) — The Go Project, документация Go 1.26, проверено 2026-07-18.
- [Package runtime/pprof](https://pkg.go.dev/runtime/pprof@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, проверено 2026-07-18.
- [Package net/http/pprof](https://pkg.go.dev/net/http/pprof@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, проверено 2026-07-18.
- [Package runtime/trace](https://pkg.go.dev/runtime/trace@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, проверено 2026-07-18.
- [Profiling Go Programs](https://go.dev/blog/pprof) — The Go Project, публикация 2011-06-24, проверено 2026-07-18.
- [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) — Google, Site Reliability Engineering book, 2016, проверено 2026-07-18.
- [Handling Overload](https://sre.google/sre-book/handling-overload/) — Google, Site Reliability Engineering book, 2016, проверено 2026-07-18.
