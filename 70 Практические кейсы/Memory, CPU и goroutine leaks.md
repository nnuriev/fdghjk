---
aliases:
  - Memory leaks
  - CPU leaks
  - Goroutine leaks в production
  - Утечки ресурсов Go-сервиса
tags:
  - область/reliability-performance-operations
  - тема/производительность
  - тема/диагностика
  - технология/go
статус: проверено
---

# Memory, CPU и goroutine leaks

## TL;DR

Три похожих production-симптома требуют разных доказательств. **Memory leak** означает, что процесс продолжает удерживать ненужные достижимые объекты или внешний memory resource. **Goroutine leak** означает, что работа потеряла владельца, но goroutine не может дойти до `return`. Выражение **CPU leak** не является термином runtime: обычно так называют потерянную работу, которая продолжает исполняться, например busy loop, retry loop или вычисление после истечения deadline.

Не ставьте диагноз по одному RSS, CPU utilization или `runtime.NumGoroutine`. Сначала отделите live Go heap от allocation churn и non-Go memory, on-CPU stacks от ожидания, а число goroutines — от их состояний и назначения. Затем снимите два сопоставимых профиля в проблемном окне и найдите растущий retention/stack path.

## Область применимости и версии

Основной scope — backend на Go 1.26.5, baseline `linux/amd64`; проверено 2026-07-18. Семантика lifecycle переносима, но RSS/cgroup accounting, native allocations и OS profiler зависят от платформы.

Начиная с Go 1.26 появились scheduler metrics по состояниям goroutines и экспериментальный профиль `goroutineleak`, включаемый через `GOEXPERIMENT=goroutineleakprofile`. Он обнаруживает только часть навсегда заблокированных goroutines по reachability и не заменяет обычный goroutine profile или анализ ownership.

## Ментальная модель

Ресурс становится утечкой не потому, что его много, а потому, что он пережил полезный lifecycle без допустимой причины:

```text
owner finished/cancelled -> work or object still reachable/runnable/blocked
```

У каждого вида свой наблюдаемый инвариант:

- live memory при стабильном workload после полных GC не возвращается к устойчивому диапазону;
- leaked goroutine не имеет достижимого пути завершения, хотя её logical operation уже закончена;
- потерянная CPU-работа продолжает получать samples после cancellation/deadline или без роста goodput.

Связь не взаимно однозначна. Blocked goroutine обычно почти не расходует CPU, но её stack удерживает object graph. Busy goroutine способна сжечь core без заметного роста памяти. Высокая allocation rate увеличивает GC CPU, хотя live heap остаётся ровным: это churn, а не memory leak.

## Как устроено

### Сначала разделить memory layers

Process RSS включает Go heap, goroutine и OS-thread stacks, runtime metadata, binary/file mappings, cgo/native allocations и страницы, которые runtime освободил логически, но ещё не вернул ОС. Поэтому малый heap profile при большом RSS не опровергает memory pressure и не доказывает Go heap leak.

Для Go-сервиса сопоставляют:

- cgroup/process RSS и memory limit;
- `/memory/classes/total:bytes` и его runtime breakdown;
- heap objects/bytes после GC;
- `inuse_space` heap profile для удерживаемой памяти;
- `alloc_space`/allocs profile и allocation rate для churn;
- GC CPU, mark assist и частоту cycles;
- native/cgo и mmap accounting, если разница остаётся вне runtime memory.

`GOMEMLIMIT` ограничивает управляемую Go runtime memory мягко и не покрывает всю RSS. Малый limit способен увеличить GC CPU и всё равно не предотвратить OOM из-за cgo, mappings или слишком большого live set. Этот механизм подробнее разобран в [[60 Go/Аллокации, GC и GC pressure|заметке об аллокациях и GC pressure]].

### Goroutine: count, state, ownership

Само число goroutines зависит от нагрузки, pools и background loops. Leak выдают монотонный рост при одинаковом workload и повторяющийся stack в send/receive, mutex, timer или I/O без cancellation path. Обычный goroutine profile показывает все текущие stacks; diff двух snapshots отделяет постоянный baseline от растущей группы.

Проверка ownership для каждого `go` statement:

1. кто запускает goroutine;
2. какое событие означает нормальное завершение;
3. как передаются error, deadline и cancellation;
4. кто подтверждает завершение через join/`WaitGroup`;
5. что разблокирует каждый channel, lock и I/O wait.

Конкретные channel failure modes и проверенный пример приведены в [[60 Go/Goroutine и channel leaks|заметке о goroutine и channel leaks]].

### «CPU leak»: найти бесполезный on-CPU path

Сначала проверьте, что process действительно получает CPU, а не throttled и не ждёт resource. CPU profile показывает sampled on-CPU stacks. Высокий wall latency при низком CPU чаще указывает на queue, pool, lock или I/O; тогда нужны block/mutex profile, execution trace и spans, а не оптимизация первого function из CPU `top`.

Типичные потерянные CPU paths:

- loop с `default` в `select`, который spin-ит без работы;
- retry/requeue без backoff и budget;
- вычисление, не наблюдающее отменённый context;
- parser/compression/hash, запущенный для ответа, который caller уже не примет;
- allocation churn, из-за которого goroutines выполняют GC mark assists;
- contention, где aggregate CPU уходит на coordination, хотя goodput не растёт.

CPU saturation сама по себе не означает leak: возможно, вырос полезный traffic. Сравнивают CPU seconds на successful operation, goodput и профиль при одинаковом request mix.

### Диагностический workflow

1. **Сохранить состояние до restart.** Снять metrics, goroutine/heap/CPU profiles и recent change metadata. Restart возвращает ресурс, но уничтожает evidence.
2. **Ограничить ущерб.** Остановить suspect background job, shed low-priority traffic, ограничить concurrency, rollback недавний change. Restart делать малыми batches, если без него нарушается SLO.
3. **Классифицировать slope.** Нормализовать memory, CPU и goroutines на traffic, uptime и workload phase. Найти момент начала и корреляцию с deploy/config/tenant.
4. **Снять пару профилей.** Два heap/goroutine snapshots через интервал при сопоставимой нагрузке показывают рост; CPU profile снимают именно в окне высокой CPU. Один snapshot часто показывает лишь крупный легитимный cache.
5. **Найти owner и retention path.** Stack allocation site не всегда равен удерживающему owner. Проверить globals/maps/caches, pending requests, queues, timers, closures и blocked goroutines.
6. **Проверить исправление.** Повторить тот же workload достаточно долго: slopes должны исчезнуть, SLI и goodput — восстановиться, а profiles не должны показать перенос bottleneck.

`pprof` и смысл его sample indexes разобраны в [[60 Go/Профилирование с pprof|заметке о профилировании]], причинный timeline scheduler и blocking — в [[60 Go/Execution trace|execution trace]].

## Пример или трассировка

Handler запускает несколько workers. Каждый держит buffer размером 4 MiB и отправляет результат в unbuffered channel. После первой ошибки caller возвращается, но не отменяет оставшихся workers и больше не читает channel.

1. Оставшиеся goroutines блокируются на send. Их stacks остаются GC roots и удерживают buffers.
2. При стабильной нагрузке за минуту теряется 25 goroutines. `goroutines` растёт примерно на 25/min, а live heap — примерно на 100 MiB/min; CPU остаётся близок к baseline.
3. Heap `inuse_space` snapshots показывают рост buffers из worker path. Goroutine diff показывает растущую группу с одним stack на channel send. CPU profile не содержит соответствующего hotspot: blocked send не исполняется.
4. Owner начинает отменять siblings при первой ошибке, send выбирает между result channel и `ctx.Done()`, а handler ждёт завершения группы. После повторного теста goroutine count и live heap выходят на плато.

Наблюдаемый результат связывает три сигнала причинно: растёт live heap, а не один лишь RSS; объекты удерживает растущая группа blocked goroutines; после исправления lifecycle оба slopes исчезают без restart.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| до 1.19 | runtime не имел общего soft memory limit | `GOMEMLIMIT` и `debug.SetMemoryLimit` добавлены в Go 1.19 | GC можно согласовать с memory budget, оставив headroom вне Go runtime | [Go 1.19 Release Notes](https://go.dev/doc/go1.19) |
| до 1.26 | состояния goroutines и permanent leaks искали через count, stacks и trace | Go 1.26 добавил scheduler state metrics и экспериментальный `goroutineleak` profile | легче отличить runnable pressure от blocked growth; профиль остаётся неполным и experimental | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |

## Trade-offs

On-demand profile даёт точный проблемный контекст, но incident может закончиться до capture. Continuous profiling ловит редкие окна и regressions, зато требует хранения, безопасных labels и контроля overhead. Одновременно включённые профили способны влиять друг на друга, поэтому дорогие captures разводят по времени.

Restart быстро возвращает memory и goroutines, но может вызвать cold-cache herd и уничтожает evidence. Heap dump полнее sampled profile, однако останавливает goroutines на время записи и содержит чувствительные данные. В production обычно начинают с metrics и sampled profiles, а dump снимают только при оправданной цене.

Жёсткий cache bound предупреждает retention, но снижает hit ratio. Пул объектов уменьшает allocation churn, но способен увеличить live memory и скрыть ownership. Более частый GC уменьшает heap headroom ценой CPU; он не освобождает достижимый leak.

## Типичные ошибки

- **Неверное предположение:** растущий RSS доказывает Go heap leak. **Симптом:** heap profile мал, а pod приближается к limit. **Причина:** RSS включает non-Go memory, stacks, mappings и не возвращённые ОС страницы. **Исправление:** разложить RSS по runtime metrics, heap profile и native accounting.
- **Неверное предположение:** большой `alloc_space` означает retention. **Симптом:** оптимизируют часто создаваемые короткоживущие объекты, но OOM остаётся. **Причина:** cumulative allocations смешаны с live objects. **Исправление:** для retention смотреть `inuse_space` и diff после GC; churn анализировать отдельно.
- **Неверное предположение:** много goroutines означает leak. **Симптом:** уменьшают полезный parallelism без изменения slope. **Причина:** count не учитывает workload и state. **Исправление:** нормализовать по in-flight, сравнить stacks/states и доказать потерянный completion path.
- **Неверное предположение:** высокая CPU означает busy loop. **Симптом:** CPU profile показывает GC assists и allocator paths. **Причина:** первичен allocation churn или чрезмерный live set. **Исправление:** сопоставить CPU, allocs, heap и GC metrics, затем убрать источник allocations/retention.
- **Неверное предположение:** `cancel()` остановил работу. **Симптом:** после timeout продолжают расти CPU и goroutines. **Причина:** cancellation кооперативна, blocking/CPU loop её не наблюдает либо owner не ждёт completion. **Исправление:** проверять сигнал в каждом blocking/длинном CPU path и делать join.
- **Неверное предположение:** restart устранил root cause. **Симптом:** slopes начинаются заново с нуля. **Причина:** освобождены ресурсы процесса, но protocol ownership не изменился. **Исправление:** сохранить profiles, исправить lifecycle/bound и подтвердить длительным повтором.

## Когда применять

Runbook запускают при монотонном росте memory, goroutines или CPU-per-good-operation, при OOM/restart loop и при деградации, которая временно исчезает после restart. Alert должен срабатывать до hard limit и учитывать slope: текущий уровень без прогноза может не оставить времени на capture.

После исправления добавьте regression test с ранней отменой, ошибкой посередине fan-out и долгим soak под стабильной нагрузкой. Контролируйте число goroutines по states, live heap после GC, allocation/GC CPU, RSS headroom и успешные операции; один «ровный» график процесса не доказывает, что leak не переехал в очередь или dependency.

## Источники

- [Diagnostics](https://go.dev/doc/diagnostics) — The Go Project, документация Go 1.26, проверено 2026-07-18.
- [Package runtime/metrics](https://pkg.go.dev/runtime/metrics@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, проверено 2026-07-18.
- [Package runtime/pprof](https://pkg.go.dev/runtime/pprof@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, проверено 2026-07-18.
- [A Guide to the Go Garbage Collector](https://go.dev/doc/gc-guide) — The Go Project, документация Go 1.26, проверено 2026-07-18.
- [Go 1.26 Release Notes](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-18.
- [Go Concurrency Patterns: Pipelines and cancellation](https://go.dev/blog/pipelines) — The Go Project, публикация 2014-03-13, проверено 2026-07-18.
