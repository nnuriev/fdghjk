---
aliases:
  - Debugging memory leaks
  - Диагностика утечек памяти
  - Memory leak runbook
tags:
  - область/reliability-performance-operations
  - тема/диагностика
  - тема/производительность
  - технология/go
статус: проверено
---

# Диагностика memory leaks

## TL;DR

Растущий RSS ещё не доказывает Go heap leak. Production-диагностика должна разделить live Go objects, allocation churn, goroutine/thread stacks, runtime metadata, страницы, не возвращённые ОС, и native/cgo/mmap memory. Для удержания важен устойчивый рост live heap после GC и diff двух сопоставимых `inuse_space` profiles; `alloc_space` отвечает на другой вопрос — сколько памяти было выделено за время процесса.

Если memory headroom позволяет, timebox-ните сбор metrics и двух sampled profiles до restart; при близком OOM containment имеет приоритет над полнотой evidence. Heap dump используйте только когда sampled evidence недостаточно и оправданы stop-the-world, размер и чувствительность содержимого. Обзор различий memory, CPU и goroutine leak уже есть в [[70 Практические кейсы/Memory, CPU и goroutine leaks|широкой заметке об утечках]]; здесь — отдельный runbook поиска retention path.

## Контекст

Scope — Go 1.26.5 на `linux/amd64`, проверено 2026-07-18. Process RSS и cgroup accounting зависят от ОС/container runtime. `/memory/classes/total:bytes` описывает read-write memory, mapped Go runtime, но прямо исключает memory, mapped через cgo или `syscall`, поэтому расхождение с RSS ожидаемо и само по себе не является ошибкой метрики.

Сначала определите, какой resource нарушает бюджет: container memory, process RSS, Go runtime memory, live heap bytes, число objects, stacks или native allocation. `GOMEMLIMIT` — soft limit управляемой runtime memory, а не жёсткий предел RSS; он не освобождает достижимые objects и не покрывает всю native memory.

## Симптомы и влияние

Типичные incident signals:

- RSS или cgroup usage монотонно приближаются к limit и restart временно сбрасывает slope;
- live heap после завершённых GC cycles растёт при сопоставимой нагрузке;
- GC становится чаще, растут mark assists/GC CPU, а goodput и p99 ухудшаются;
- число goroutines/stacks или mapped/native memory объясняет рост вне heap;
- OOM kill, swap/reclaim или memory throttling начинают влиять на соседние processes.

Зафиксируйте uptime, момент начала slope, request mix, cache cardinality, in-flight/queue, goroutines, release/config и изменение dependency/data size. Сравнивайте одинаковую фазу workload: batch, warm-up и cache fill законно растят live set до плато.

## Ментальная модель и гипотезы

Memory leak — нарушение lifecycle: объект или внешний resource остаётся достижимым после окончания полезного владения.

```text
allocated bytes = live bytes + garbage not yet collected
RSS = Go runtime mappings + stacks/metadata + native/mmap + accounting effects
leak evidence = retained resource grows across completed lifecycles without bounded reason
```

Приоритетные классы гипотез:

1. **Go heap retention:** unbounded map/cache, slice backing array, timer/callback, closure, queue или object graph из global/long-lived owner.
2. **Goroutine retention:** blocked goroutines держат stacks и reachable graph; проверяется вместе с goroutine states/stacks.
3. **Allocation churn:** heap после GC стабилен, но `alloc_space` и GC CPU высоки; это performance problem, не retention leak.
4. **Legitimate growth:** bounded cache, larger working set, больше in-flight или schema/payload; должен существовать прогнозируемый bound и plateau.
5. **Non-Go memory:** cgo allocator, explicit `mmap`, OS thread stacks, file mappings или driver/library outside runtime accounting.
6. **Release/accounting delay:** runtime уже считает pages idle/released, но RSS/cgroup отображает их иначе; нужно сверять OS и runtime breakdown.

## Диагностика

### 1. Сохранить evidence до restart

Снимите временной ряд cgroup/RSS, `/memory/classes/*`, heap goal/live bytes, GC cycles/CPU/pauses, allocation rate, goroutine states, queue/in-flight и workload cardinality. Зафиксируйте instance, uptime, Go/build ID, release/config и timestamps профилей.

Сохраните два heap profiles через интервал, в котором воспроизводится slope, при сопоставимом traffic. Heap profile отражает allocation samples live objects на момент последнего завершённого GC; принудительный GC делает snapshot свежее, но сам влияет на процесс, поэтому используйте его только в пределах incident budget. Профили и особенно dumps могут быть чувствительными: храните их в закрытом хранилище, ограничьте retention и не прикрепляйте к публичному ticket.

Если OOM близок, evidence timebox должен быть короче mitigation. Безопаснее снять один profile и постепенно вывести instance из traffic, чем потерять весь fleet ради идеальной пары.

### 2. Разложить RSS по слоям

Сопоставьте:

- cgroup/process RSS и memory limit;
- `/memory/classes/total:bytes` и runtime breakdown;
- heap objects/bytes после GC;
- `/memory/classes/heap/stacks:bytes` и OS-thread stack accounting;
- profiler/debug overhead и goroutine count;
- native/cgo/mmap accounting, если RSS заметно больше runtime total.

Если RSS растёт, а runtime total и live heap стабильны, не оптимизируйте Go allocation sites вслепую: ищите native owner, mappings и OS accounting. Если runtime total растёт за счёт heap objects, переходите к retention profile. Если главным компонентом стали stacks, запускайте [[70 Практические кейсы/Диагностика goroutine leaks|goroutine lifecycle runbook]].

### 3. Отличить retention от churn

Для retention смотрите `inuse_space` и `inuse_objects`; для churn — `alloc_space`/`alloc_objects` и allocation rate. Большой cumulative allocator может создавать много короткоживущих objects и не удерживать ни одного. Наоборот, редкая allocation одного крупного object graph способна доминировать live heap, но почти не выделяться по числу objects.

Сравните profiles как пару, а не как два независимых `top`: ищите stacks, чья live contribution выросла между timestamps. Allocation site показывает, где object создан, но не обязательно кто удерживает его сейчас. От allocation stack переходите к возможным owners: globals, maps, caches, queues, goroutine stacks, closures, timers и pending operations.

### 4. Связать рост с cardinality и lifecycle

Для каждого suspect type задайте:

1. какая business cardinality создаёт экземпляр;
2. кто становится owner после allocation;
3. какое событие удаляет/закрывает его;
4. какой bound должен ограничивать число или bytes;
5. что происходит при cancellation, error и partial initialization.

Сопоставьте live object growth с tenant/key/cache entries, active sessions, queue length и goroutine stack group. Если heap растёт на 80 MiB/min вместе с cache entries на 10 000/min, это сильнее абстрактной корреляции с uptime. Проверьте, существует ли path eviction/delete на всех outcomes.

### 5. Использовать heap dump только как эскалацию

Heap dump содержит полный snapshot Go heap и останавливает выполнение всех goroutines на время записи. Он значительно тяжелее sampled profile и может содержать секреты или пользовательские данные. Снимайте dump с изолированной replica при достаточном disk/memory headroom, если sampled profile не показывает retention path или sampling скрывает редкий крупный graph.

Dump не заменяет time dimension: один большой legitimate cache похож на leak. Нужны lifecycle, cardinality и повтор после контролируемого изменения.

### 6. Проверить причинность

Сформулируйте прогноз: «если revision cache не удаляет старые entries, запрет добавления новых revisions остановит рост entry count и live bytes без изменения native memory». Примените ограниченный flag/rollback на canary или воспроизведите representative workload на стенде. После изменения должны одновременно исчезнуть suspect object slope и общий live-heap slope; один меньший RSS после restart ничего не доказывает.

## Сквозная трассировка сценария

Ниже приведён сценарий, а не универсальная норма.

После `v62` RSS replica растёт с `0,9 GiB` до `3,1 GiB` за `47 min` при прежних `1 100 requests/s`; limit равен `4 GiB`. Live heap после GC растёт с `620 MiB` до `2,45 GiB`, число goroutines остаётся около `430`, а `/memory/classes/total:bytes` объясняет большую часть RSS.

1. Два `inuse_space` profiles с интервалом `15 min` показывают прирост около `570 MiB` в allocation path `tenantConfigCache.storeRevision`; `alloc_space` велик и в других местах, но их live contribution не растёт.
2. Metric `cache_entries` растёт на `12 000` за тот же интервал, хотя active tenants остаются около `2 000`. В entries ключ включён как `(tenantID, revision)`.
3. Change diff показывает, что `v62` сохраняет новую revision после каждого update, но удаляет только entry по ключу `(tenantID)`, которого в новой map больше нет. Старые revisions остаются достижимы из process-global map.
4. На affected canary feature flag прекращает добавлять history. `cache_entries` и live heap выходят на плато около уже достигнутого уровня: slope исчезает, но старые достижимые entries закономерно не освобождаются.
5. Исправленная canary начинается с чистого process state, хранит один current entry на tenant и bounded diagnostic history вне serving cache. При тех же update rate live heap стабилизируется около `760 MiB`; RSS снижается не мгновенно, но не возобновляет рост.

Доказательство опирается на три независимых связи: растёт именно live heap, profile указывает allocation type/path, а business cardinality и faulty delete объясняют retention.

## Root cause

Root cause сценария — несогласованный key contract cache после перехода от `tenantID` к `(tenantID, revision)`. Insert использовал составной key, cleanup — старый key, поэтому process-global map сохраняла все revisions. GC работал корректно: объекты оставались достижимы и не могли быть собраны.

Рост RSS и GC CPU были последствиями увеличившегося live set. Увеличение частоты GC или уменьшение `GOMEMLIMIT` не исправило бы ownership и могло лишь потратить больше CPU.

## Исправление

### Немедленное

- Остановить rollout/feature, создающую новые retained entries, или перевести affected traffic на healthy cohort.
- Снять profile и постепенно restart-ить instances только после остановки trigger; избегать одновременного cold-cache herd.
- Ограничить admission/background updates, если до OOM осталось мало headroom.
- Не уменьшать memory limit как «лечение»: это сокращает время до OOM при прежнем live set.

### Долгосрочное

- Сделать ownership и delete/close path симметричными; покрыть success, error, cancellation и replacement.
- Задать cache bound по entries и bytes, eviction policy и допустимую stale semantics.
- Экспортировать business cardinality рядом с bytes: entries, tenants, sessions, queued items.
- Добавить soak/regression test с повторными revisions и проверкой plateau после завершённых GC cycles.
- Для native resources использовать explicit `Close`/free и instrumentation, а не полагаться на финализаторы.

## Проверка результата

Повторите тот же traffic mix, update/cardinality rate и длительность, достаточную превысить прежнее время проявления. Должны выполняться все условия:

- live heap после GC и suspect object count выходят на объяснимое плато;
- diff profiles не показывают прежнего retention path;
- RSS/runtime/native breakdown согласуется с моделью и сохраняет headroom;
- GC CPU/allocation rate не ухудшили latency и goodput;
- cache correctness, hit ratio и stale behavior соответствуют контракту;
- restart больше не нужен для стабилизации.

Если heap plateau появился, но RSS продолжает расти вне runtime total, Go heap defect исправлен, но incident ещё не закрыт: нужен отдельный native/mmap owner.

## Профилактика

Наблюдайте не только текущие bytes, но и slope, время до limit, live heap после GC, allocation rate, GC CPU, goroutine/stacks и cardinality owners. Alert по RSS должен оставлять время на capture.

Для каждого cache/pool/registry запишите capacity, owner, eviction/close path и поведение при update/delete. В code review особенно проверяйте изменение key schema и partial initialization. [[60 Go/Аллокации, GC и GC pressure|Модель GC pressure]] помогает выбрать memory budget, но не заменяет lifecycle invariant.

## Эволюция и версии

| Версия | Изменение | Практический эффект для runbook | Источник |
| --- | --- | --- | --- |
| Go 1.19 | Появились `GOMEMLIMIT` и `debug.SetMemoryLimit` | Можно задать soft runtime-memory budget с headroom для non-Go memory; достижимую утечку это не освобождает | [Go 1.19 Release Notes](https://go.dev/doc/go1.19) |

## Trade-offs

Bounded cache гарантирует memory ceiling, но eviction уменьшает hit ratio и может создать downstream load. TTL проще, однако не даёт строгий byte bound и способен синхронно истечь у большого числа keys. Size-aware LRU точнее контролирует bytes, но сложнее и добавляет synchronization.

Restart быстро возвращает память, но стирает time-local evidence и создаёт cold-cache load. Heap profile sampled и обычно дешевле, но может пропустить редкий object graph. Heap dump полнее, зато тяжелее, чувствительнее и останавливает goroutines на запись.

Более низкий memory limit раньше включает GC и уменьшает headroom для transient heap. Цена — CPU и latency; если live set близок к limit, collector не может освободить достижимые objects.

## Типичные ошибки

- **Неверное предположение:** растущий RSS доказывает Go heap leak. **Симптом:** heap profile стабилен, а команда оптимизирует Go allocations. **Причина:** рост находится в cgo/mmap/stacks или accounting. **Исправление:** разложить RSS по runtime classes и native owner.
- **Неверное предположение:** большой `alloc_space` означает удержание. **Симптом:** уменьшили churn, но live heap slope остался. **Причина:** cumulative allocations смешивают собранные и живые objects. **Исправление:** для retention сравнивать `inuse_space`/`inuse_objects` после GC.
- **Неверное предположение:** allocation site всегда является owner. **Симптом:** переписали constructor, но object всё ещё живёт. **Причина:** удерживает global map, queue, closure или goroutine stack. **Исправление:** от stack перейти к retention/lifecycle path.
- **Неверное предположение:** высокий cache hit ratio оправдывает любой рост. **Симптом:** memory достигает limit после долгого uptime. **Причина:** нет конечного capacity contract. **Исправление:** задать bound и измерить hit/cost trade-off.
- **Неверное предположение:** принудительный GC исправляет leak. **Симптом:** heap почти не уменьшается, CPU растёт. **Причина:** retained objects достижимы. **Исправление:** устранить owner/reference, а GC использовать только для сопоставимого измерения.
- **Неверное предположение:** restart подтверждает root cause. **Симптом:** slope начинается заново. **Причина:** restart удалил весь process state, не выделив faulty owner. **Исправление:** сохранить pair profiles, cardinality и controlled-disable result.

## Когда применять выводы

Runbook запускают при устойчивом memory slope, повторных OOM/restarts, росте live heap, необъяснимом расхождении RSS/runtime или росте GC cost. Для разового peak сначала проверьте burst, cache warm-up и batch phase: leak требует нарушения lifecycle и отсутствия ожидаемого plateau.

Диагностика завершена, когда известны memory layer, retaining owner, событие потери lifecycle, controlled evidence исправления и новый bound. «После restart память низкая» этим критериям не соответствует.

## Источники

- [Package runtime/pprof](https://pkg.go.dev/runtime/pprof@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, heap/allocs sample indexes и момент snapshot, проверено 2026-07-18.
- [Исходный код heap/allocs profiles](https://github.com/golang/go/blob/go1.26.5/src/runtime/pprof/pprof.go) — репозиторий golang/go, tag `go1.26.5`, файл `src/runtime/pprof/pprof.go`, разделы `Heap profile` и `Allocs profile`, проверено 2026-07-18.
- [Package runtime/metrics](https://pkg.go.dev/runtime/metrics@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, memory classes, GC и stack metrics, проверено 2026-07-18.
- [A Guide to the Go Garbage Collector](https://go.dev/doc/gc-guide) — The Go Project, модель live heap, GC CPU и memory limit; living document явно описывает состояние collector для Go 1.19, проверено 2026-07-18.
- [Package runtime/debug](https://pkg.go.dev/runtime/debug@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, `WriteHeapDump` и `SetMemoryLimit`, проверено 2026-07-18.
- [Diagnostics](https://go.dev/doc/diagnostics) — The Go Project, heap profiling, runtime statistics и heap dump, проверено 2026-07-18.
- [Go 1.19 Release Notes](https://go.dev/doc/go1.19) — The Go Project, Go 1.19, введение soft memory limit, проверено 2026-07-18.
