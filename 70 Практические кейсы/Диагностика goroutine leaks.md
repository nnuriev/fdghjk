---
aliases:
  - Debugging goroutine leaks
  - Диагностика утечек goroutines
  - Goroutine leak runbook
tags:
  - область/reliability-performance-operations
  - тема/диагностика
  - тема/конкурентность
  - технология/go
статус: проверено
---

# Диагностика goroutine leaks

## TL;DR

Рост `runtime.NumGoroutine` не равен утечке. Leak доказан, когда logical operation уже завершилась, а goroutine потеряла owner или путь к `return` и продолжает быть blocked/runnable. Нужны slope при сопоставимом workload, goroutine states, diff двух stack profiles и восстановление lifecycle от повторяющегося stack к запускающему owner.

Go 1.26 добавил approximate scheduler metrics по waiting/runnable/running/not-in-go и экспериментальный `goroutineleak` profile. Эксперимент обнаруживает только класс навсегда заблокированных goroutines по reachability и не заменяет обычный goroutine profile. Обзор ресурсных утечек находится в [[70 Практические кейсы/Memory, CPU и goroutine leaks|широкой заметке]], а channel-specific механизмы — в [[60 Go/Goroutine и channel leaks|заметке о goroutine и channel leaks]]; здесь — production runbook.

## Контекст

Scope — Go 1.26.5, baseline `linux/amd64`, проверено 2026-07-18. Scheduler state metrics приблизительны и, по контракту `runtime/metrics`, не обязаны суммироваться в `/sched/goroutines:goroutines`. Нормальный baseline зависит от server model, connections, pools и background loops.

Goroutine leak может почти не расходовать CPU, но удерживать stack, heap graph, file descriptor, connection, timer или queue slot. Runnable leak способен одновременно давать CPU spike. Поэтому count всегда сопоставляют с states, memory/resources и пользовательским impact.

## Симптомы и влияние

Сигналы incident:

- число live goroutines монотонно растёт при стабильном in-flight и traffic;
- waiting/runnable group растёт с повторяющимся stack;
- heap stack bytes, retained buffers, sockets или database connections растут вместе с count;
- graceful shutdown не завершается, потому что join ждёт потерянную работу;
- latency/CPU ухудшаются из-за scheduler pressure или lock/channel contention;
- restart временно сбрасывает count, после чего slope воспроизводится.

Зафиксируйте operation lifecycle: сколько запросов/streams/jobs началось, завершилось, отменилось и осталось in-flight. Без denominator рост created goroutines после traffic burst легко принять за leak.

## Ментальная модель и гипотезы

Для каждого `go` statement должен существовать lifecycle contract:

```text
owner starts G -> G completes or observes cancellation -> owner joins/forgets only after completion
```

Leak появляется, если потеряно хотя бы одно звено: owner ушёл, cancellation не дошла, blocking operation не имеет альтернативы, resource не закрыт или никто не выполняет join. Проверка строится вокруг пяти вопросов:

1. кто запустил goroutine;
2. какое событие означает normal completion;
3. кто и как передаёт cancellation/error;
4. что разблокирует каждый channel, lock, I/O и timer wait;
5. кто подтверждает завершение.

Приоритет гипотез:

- send/receive на channel после ухода peer;
- I/O или stream без deadline/cancellation;
- `WaitGroup`/`Cond`/mutex path, который не получает signal/unlock;
- retry/poll loop, не наблюдающий context;
- per-request background work, ошибочно использующая `context.Background()`;
- забытые `Rows`, response bodies, subscriptions или connections;
- legitimate long-lived connection goroutines либо временная очередь runnable work.

## Диагностика

### 1. Сохранить evidence до restart

Сохраните временной ряд live/created goroutines, states, memory/stacks, open connections/descriptors, in-flight и started/completed/cancelled operations. Запишите instance uptime, build/release/config, traffic и начало slope.

Снимите goroutine profiles с `debug=0` для машинного сравнения и при необходимости `debug=2` для читаемых stacks. Второй snapshot через интервал при сопоставимой нагрузке показывает растущие groups. Stack output может раскрывать code paths и labels, поэтому endpoint и artifacts должны быть закрыты.

Если resource budget позволяет, restart делайте после timeboxed capture и только поэтапно; при угрозе исчерпания ресурса containment имеет приоритет. Restart освобождает goroutines, но стирает их stacks и не исправляет lifecycle.

### 2. Классифицировать состояние

В Go 1.26.5 сопоставьте:

- `/sched/goroutines:goroutines` — live count;
- `/sched/goroutines-created:goroutines` — cumulative creations;
- `/sched/goroutines/waiting:goroutines` — ожидание resource/I/O/synchronization;
- `/sched/goroutines/runnable:goroutines` — готовые, но ещё не исполняемые;
- `/sched/goroutines/running:goroutines` — исполняемые;
- `/sched/goroutines/not-in-go:goroutines` — running/blocked в syscall или cgo.

Waiting growth направляет к goroutine/block profile и ownership. Runnable growth при CPU saturation может означать очередь полезной работы, spin/retry или отсутствие admission, а не leak. Not-in-Go growth требует проверить syscalls/cgo и external resources.

### 3. Сгруппировать и сравнить stacks

Не читайте тысячи stacks по одной. Сгруппируйте одинаковые stack signatures и найдите группы, чья численность выросла между captures. Для каждой растущей группы отметьте blocking point, operation/labels, удерживаемый resource и возможный creator path.

Goroutine profile показывает текущий stack, но не всегда место создания. От blocked function идите по коду к `go` statement и owner. Execution trace полезен, когда нужен порядок create/unblock/syscall/cancellation; block profile показывает cumulative места blocking events, а не список всех живых leaked goroutines.

### 4. Проверить reachability-profile без ложной уверенности

В Go 1.26 профиль `goroutineleak` доступен только в binary, собранной с `GOEXPERIMENT=goroutineleakprofile`; через `net/http/pprof` появляется `/debug/pprof/goroutineleak`. Runtime отмечает blocked goroutine, если concurrency primitive, на котором она ждёт, недостижим из runnable/unblockable work. Сам capture запускает GC cycle с leak detection, поэтому его также timebox-ят и не запускают конкурентно на incident instance.

Положительный результат — сильное evidence для найденного класса. Пустой профиль не опровергает leak: global channel, variable runnable goroutine или I/O resource могут оставаться reachable, хотя application protocol уже никогда не разбудит waiter. Профиль experimental по API и должен дополнять обычные stacks/lifecycle proof.

### 5. Сопоставить stack с traces и resource ownership

Найдите завершившиеся traces/requests, после которых соответствующая stack group продолжает расти. Проверьте deadline propagation, stream/subscription close, channel consumer, error path и partial initialization. Если на одну cancellation появляется одна новая blocked goroutine, slope получает causal denominator.

Осмотрите heap profile для buffers/objects, достижимых из stack, и downstream pool для удерживаемых connections. Это показывает impact, но не заменяет proof завершения.

### 6. Проверить исправление lifecycle

Сформулируйте прогноз: «если sender не наблюдает cancellation после ухода receiver, добавление `select` с `ctx.Done()` и join уберёт растущую send-stack group». Проверяйте на canary или representative stress/soak с early cancellation. Count может оставаться выше baseline до завершения старых work; важнее, что slope исчез, new operations завершаются и resources возвращаются.

## Сквозная трассировка сценария

Все значения ниже относятся к сценарию.

Streaming endpoint после `v31` держит обычный traffic, но live goroutines растут с `340` до `11 200` за час. Waiting goroutines достигают `10 700`; CPU меняется мало, heap растёт на `420 MiB`, а клиенты часто отменяют stream через `30 s`.

1. Два goroutine profiles с интервалом `10 min` показывают прирост `1 780` одинаковых stacks в `subscription.forward` на send в unbuffered `out` channel.
2. Traces соответствующих requests уже завершились с `context canceled`; число leaked stacks растёт примерно вместе с counter `client_cancelled_streams`.
3. Creator path запускает `go subscription.forward(out)`. Handler возвращается по `ctx.Done()`, но не закрывает upstream subscription, больше не читает `out` и не ждёт forwarder.
4. Sender не получает context и навсегда блокируется на `out <- event`, удерживая последний event buffer и subscription handle.
5. Canary передаёт context, выбирает send через `select { case out <- event: case <-ctx.Done(): }`, закрывает subscription и ждёт forwarder. При том же cancellation rate live count стабилизируется около `390`, suspect group не растёт, heap/stacks выходят на плато.

Root cause доказан связью «одна cancellation → одна растущая stack signature», faulty ownership path и исчезновением slope после bounded fix.

## Root cause

Root cause сценария — handler прекращал быть receiver после client cancellation, но spawned forwarder не имел cancellation path и не входил в join protocol owner. Unbuffered send сохранял goroutine blocked, а её stack удерживал event buffer и subscription.

Client cancellation была нормальным trigger, не ошибкой клиента. Latent defect — lifecycle contract, в котором owner мог завершиться раньше child.

## Исправление

### Немедленное

- Остановить rollout или отключить affected streaming path.
- Сохранить pair stack profiles и постепенно restart-ить affected replicas после прекращения trigger.
- Ограничить новые streams/admission, если count или memory приближаются к limit.
- Не закрывать общий channel вслепую: закрывает его sender/owner согласно протоколу, иначе возможна panic или потеря данных.

### Долгосрочное

- Передавать context/deadline во все child operations и проверять его в каждом blocking path.
- Делать ownership структурным: parent отменяет siblings, закрывает owned resources и ждёт их завершения.
- Ограничивать concurrency и lifetime subscriptions; не использовать detached per-request goroutines без отдельного service owner.
- Добавить regression tests для early return, cancellation, partial error, blocked send/receive и shutdown.
- Экспортировать started/completed/cancelled operations и goroutine states, чтобы count имел denominator.

## Проверка результата

Исправление подтверждено, если под прежним traffic и cancellation rate:

- live и waiting goroutine slopes равны нулю после warm-up;
- created count может расти, но started − completed остаётся bounded и объясняется in-flight;
- suspect stack group не растёт между profiles;
- buffers, stack bytes, subscriptions и connections возвращаются к plateau;
- shutdown укладывается в budget без forced termination;
- CPU/goodput не деградировали из-за нового polling или overly broad locking.

Нулевое число goroutines не является целью. Цель — объяснимый bounded population с доказанным completion path.

## Профилактика

На code review каждый `go` statement должен иметь owner, cancel, error propagation и join answer. Для server-wide daemons owner — service lifecycle; для request child — request group. [[60 Go/Goroutines и lifecycle|Заметка о lifecycle goroutines]] даёт общий контракт, а runbook проверяет его на production evidence.

В tests используйте deterministic gates вместо sleep, затем повторяйте cancellation paths и проверяйте resource plateau. Leak test по одному `NumGoroutine` ненадёжен из-за runtime/background goroutines; полезнее stack signature и domain counters.

## Эволюция и версии

| Версия | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| до Go 1.26 | Основные signals — total count, ordinary goroutine profile и execution trace | Go 1.26 добавил scheduler state/creation metrics | Можно быстрее отделить waiting growth от runnable saturation; state counts approximate | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |
| Go 1.26 | Permanent blocked leaks искались обычными stacks и lifecycle analysis | Доступен experimental `goroutineleak` при `GOEXPERIMENT=goroutineleakprofile` | Положительный profile обнаруживает класс unreachable concurrency waits, но пустой не исключает leak | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |

## Trade-offs

Buffered channel иногда позволяет child завершить send после ухода receiver, но это ограниченный запас, а не общий cancellation protocol. Буфер скрывает проблему, если число sends превышает capacity или sender держит другой resource.

Жёсткий join гарантирует cleanup, но увеличивает response/shutdown latency, если child I/O не отменяется. Forced detach быстрее возвращает handler, зато переносит ownership в никуда. Правильное решение — cancellable I/O и bounded shutdown budget.

Continuous goroutine profiling ловит редкие окна, но создаёт storage/cardinality и privacy cost. On-demand capture дешевле, однако restart или transient recovery может уничтожить evidence.

## Типичные ошибки

- **Неверное предположение:** много goroutines означает leak. **Симптом:** уменьшают полезную concurrency, а slope остаётся. **Причина:** count не нормализован по connections/in-flight. **Исправление:** сравнить states, stack groups и started/completed operations.
- **Неверное предположение:** blocked goroutine безопасна, потому что не расходует CPU. **Симптом:** растут heap, descriptors или pool exhaustion. **Причина:** stack остаётся GC root и удерживает resources. **Исправление:** найти ownership и completion path, измерить retained resources.
- **Неверное предположение:** `cancel()` принудительно убивает goroutine. **Симптом:** context завершён, stack продолжает ждать channel/I/O. **Причина:** cancellation кооперативна и не наблюдается blocking code. **Исправление:** включить `ctx.Done()`/deadline в каждый wait и join.
- **Неверное предположение:** пустой `goroutineleak` profile опровергает leak. **Симптом:** ordinary stack group продолжает расти. **Причина:** experiment неполон и зависит от reachability concurrency primitive. **Исправление:** использовать обычные profiles, states и protocol proof.
- **Неверное предположение:** закрыть channel может любой участник. **Симптом:** panic `close of closed channel` или `send on closed channel`. **Причина:** нарушено ownership закрытия. **Исправление:** назначить единственного sender/owner и документировать протокол.
- **Неверное предположение:** restart устранил утечку. **Симптом:** count снова растёт с uptime/cancellation. **Причина:** обнулён процесс, но faulty lifecycle сохранился. **Исправление:** pair profiles, fix и soak дольше прежнего проявления.

## Когда применять выводы

Runbook нужен при необъяснимом goroutine slope, росте waiting/runnable population, зависшем shutdown, удержании connections/buffers или временном улучшении после restart. При стабильном count и высокой latency сначала ищите contention/pool/I/O wait: leak не является обязательной причиной.

Завершённая диагностика называет creator, owner, blocking point, потерянное событие завершения, retained resource и proof исчезновения slope. Один screenshot `NumGoroutine` не удовлетворяет ни одному из этих критериев.

## Источники

- [Go 1.26 Release Notes](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, scheduler state metrics и experimental goroutine leak profile, проверено 2026-07-18.
- [Package runtime/metrics](https://pkg.go.dev/runtime/metrics@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, goroutine state/creation metrics и их ограничения, проверено 2026-07-18.
- [Package runtime/pprof](https://pkg.go.dev/runtime/pprof@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, ordinary и `goroutineleak` profiles, проверено 2026-07-18.
- [Исходный код `writeGoroutineLeak`](https://github.com/golang/go/blob/go1.26.5/src/runtime/pprof/pprof.go) — репозиторий golang/go, tag `go1.26.5`, файл `src/runtime/pprof/pprof.go`, GC cycle и сериализация leak-profile requests, проверено 2026-07-18.
- [Package net/http/pprof](https://pkg.go.dev/net/http/pprof@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, HTTP endpoints и profile parameters, проверено 2026-07-18.
- [Package runtime/trace](https://pkg.go.dev/runtime/trace@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, execution tracing, проверено 2026-07-18.
- [Go Concurrency Patterns: Pipelines and cancellation](https://go.dev/blog/pipelines) — The Go Project, cancellation и предотвращение blocked send, публикация 2014-03-13, проверено 2026-07-18.
