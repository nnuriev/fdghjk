---
aliases:
  - Debugging CPU spikes
  - Диагностика всплесков CPU
  - CPU spike runbook
tags:
  - область/reliability-performance-operations
  - тема/диагностика
  - тема/производительность
  - технология/go
статус: проверено
---

# Диагностика CPU spikes

## TL;DR

Всплеск CPU — симптом, а не причина. Сначала докажите пользовательский impact и отделите рост полезной работы от retry amplification, нового дорогого path, allocation/GC pressure, spin и kernel/cgo. Для этого сопоставьте offered load, goodput, CPU seconds на успешную операцию, throttling, scheduler state и один CPU profile именно из проблемного окна.

Безопасный порядок во время инцидента: если impact и оставшийся resource budget допускают короткий capture, сохранить evidence до restart или rollback, не задерживая containment. Затем ограничить ущерб обратимым действием, локализовать on-CPU path и проверить причинность одним контролируемым изменением. Общий смысл профилей и bottleneck уже разобран в [[70 Практические кейсы/Performance profiling и bottleneck analysis|обзоре profiling и bottleneck analysis]]; здесь находится production runbook для внезапного CPU spike.

## Контекст

Scope — Go-сервис на Go 1.26.5, baseline `linux/amd64`, проверено 2026-07-18. Метод переносим на другие платформы, но process CPU, cgroup quota, throttling, steal time и kernel attribution зависят от среды. Порог «высокой CPU» не универсален: важны отклонение от сопоставимого baseline, приближение к capacity knee и влияние на goodput или SLO.

До диагностики зафиксируйте границу измерения. Fleet average может быть низким, пока один hot shard упирается в quota; process CPU может выглядеть как `400%`, если система считает проценты относительно одного core; runtime CPU classes нельзя напрямую сравнивать с системным CPU, потому что документация `runtime/metrics` разрешает сравнивать их только между собой.

## Симптомы и влияние

CPU spike становится инцидентом, когда вместе с ним наблюдается хотя бы один результат:

- p95/p99 или queue wait растут, а requests начинают пропускать deadline;
- completed goodput выходит на плато или падает при прежнем входе;
- instance получает throttling, растёт scheduler latency или число runnable goroutines;
- autoscaling/restart loop создаёт дополнительную нагрузку на зависимости;
- стоимость CPU seconds на одну своевременно успешную операцию заметно отклоняется от baseline.

Для временной шкалы нужны начало spike, affected replicas/shards, release и config revision, request mix, payload/tenant distribution, offered/admitted/completed rates, retries и ошибки. Совпадение с rollout повышает приоритет гипотезы, но не доказывает её: тот же момент мог совпасть с traffic shift или деградацией dependency.

## Ментальная модель и гипотезы

Полезное разложение:

```text
process CPU = useful work + repeated/lost work + runtime work + coordination + native/kernel work
CPU per good operation = process CPU seconds / timely successful operations
```

CPU profile видит sampled on-CPU stacks. Он не объясняет wall time, проведённое в network, pool или channel wait. Высокая latency при низкой CPU требует другого пути; [[60 Go/Execution trace|execution trace]] и block/mutex profiles показывают scheduling и ожидания, а не заменяют CPU profile.

Приоритет гипотез задают evidence и цена проверки:

| Наблюдение | Первая гипотеза | Быстрая развилка |
| --- | --- | --- |
| Вырос traffic или доля дорогого endpoint, CPU/op прежняя | больше полезной работы | нормализовать по operation, payload и tenant |
| Traffic прежний, CPU/op вырос после rollout | новый/изменённый code path | diff профиля problem cohort с прежней версией |
| attempts/good operation и downstream errors выросли | retry, requeue или polling loop | traces и counters попыток, backoff и cancellation |
| allocation rate, GC CPU и mark assist выросли | allocation churn или live-set pressure | CPU profile вместе с allocs/heap и runtime metrics |
| runnable goroutines и scheduler latency выросли | CPU saturation, spin или слишком много parallel work | goroutine states, trace, scaling curve |
| system CPU велик, Go profile объясняет малую долю | cgo, syscall, kernel или соседний process | per-thread/OS profiler и container/node accounting |

## Диагностика

### 1. Сохранить evidence, не усилив инцидент

Если user impact и resource budget позволяют, до restart, rollback или масштабирования timebox-ните сохранение единого временного интервала: dashboard snapshot, instance ID, binary/build ID, release/config, CPU limit и throttling, request mix, rates, errors, traces и короткий CPU profile проблемной replica. Evidence capture не должен задерживать containment при растущем impact. Артефакты профиля хранят с ограниченным доступом: function paths и labels могут раскрывать устройство сервиса или tenant context.

Не запускайте одновременно несколько дорогих captures. Официальная Go diagnostics documentation предупреждает, что diagnostics способны искажать друг друга; CPU profiling также имеет overhead. Сначала измерьте допустимую цену на canary, ограничьте длительность и снимайте профиль только с instance, на котором есть симптом. `/debug/pprof` не должен быть публичным endpoint.

### 2. Проверить, кто именно потребляет CPU

Разрежьте сигнал по node, container/process, replica, thread и времени. Проверьте quota/throttling, число cores/`GOMAXPROCS`, steal/noisy-neighbor signals и system против user CPU. Если CPU принадлежит sidecar, kernel или другому process, Go profile приложения не может быть главным доказательством.

Сопоставьте CPU с offered и completed load. Если requests/s выросли на 40%, а CPU seconds на успешный request остались прежними, первична capacity-задача. Если traffic прежний, но CPU/op удвоился, ищите amplification или regression. Ошибки и rejects входят в CPU cost, но не в goodput: иначе retry storm выглядит как рост производительности.

### 3. Локализовать workload через traces и логи

Возьмите slow/error traces из того же cohort и окна. Проверьте число child attempts, self-time, payload class, endpoint, downstream status и работу после client deadline. Логи используют для конкретного status/config/key, но rate-limited log не измеряет частоту path; нужны counters.

Если traces показывают много одинаковых попыток, сначала изучите retry policy. Если self-time вырос без новых spans, переходите к CPU profile. Если почти весь wall time находится в dependency span, локальный CPU spike может быть вторичным: сериализация повторных запросов, auth/signing или GC из-за retry objects.

### 4. Прочитать CPU profile как attribution, а не диагноз

В [[60 Go/Профилирование с pprof|заметке о pprof]] разобраны `flat`, `cum` и call graph. В incident workflow:

1. проверьте build ID и окно profile;
2. сгруппируйте stacks по operation/tenant только через заранее безопасные labels;
3. найдите leaf work и вызывающий path, а не только верхний cumulative dispatcher;
4. сравните с baseline той же версии без spike либо с предыдущим cohort при том же request mix;
5. сформулируйте прогноз, какой SLI изменится после удаления path.

Если верх профиля занимает allocator, GC или scan work, добавьте allocation и heap evidence. Если видны lock/runtime paths, сопоставьте `/sync/mutex/wait/total:seconds`, mutex/block profile и runnable states: contention способен тратить CPU на coordination, но CPU profile не показывает полное wall wait. Если значимая системная CPU не атрибутируется Go stacks, используйте OS profiler для kernel/cgo и не делайте вывод по неполному профилю.

### 5. Проверить причинность одним ограниченным изменением

До действия запишите прогноз: например, «отключение retry для `429` уменьшит attempts/s и CPU/op, при этом downstream error rate не вырастет». Затем примените один обратимый шаг на ограниченной cohort: feature flag, rollback, retry budget, снижение concurrency или admission control.

Изменение подтверждает гипотезу, только если в ожидаемом порядке меняются механизм и результат: сначала исчезает suspect path/attempt rate, затем CPU/op и runnable pressure, затем восстанавливаются goodput и latency. Падение общей CPU из-за того, что сервис стал быстрее отказывать, не является исправлением.

## Сквозная трассировка сценария

Ниже числа относятся только к сценарию и не являются универсальными нормами.

После rollout `v84` вход остаётся около `2 400 requests/s`, но CPU одной восьмиядерной replica растёт с `3,8` до `7,5 CPU-seconds/s`, p99 — со `180` до `690 ms`, а timely goodput падает до `1 950 requests/s`. Downstream начинает иногда отвечать `429`.

1. Counters показывают рост `attempts / completed request` с `1,04` до `6,7`; traffic mix и payload size не изменились.
2. Traces одного affected endpoint содержат до шести последовательных retry spans после `429`, часть продолжается после deadline caller.
3. CPU profile проблемной replica атрибутирует `31%` samples повторному request signing и `24%` serialization внутри retry path. GC CPU вырос, но allocs указывают на те же retry objects, поэтому GC — усилитель, а не исходный trigger.
4. Config diff показывает новый branch: `429` классифицирован как retryable без backoff, `Retry-After` и общего attempt/deadline budget.
5. Canary с отключённым branch возвращает attempts/request к `1,05`, CPU — к `4,0 CPU-seconds/s`, p99 — к `195 ms`, timely goodput — к прежнему диапазону. Downstream `429` остаются, но теперь быстро и явно отражаются в controlled errors.

Цепочка evidence связывает trigger, on-CPU path и impact. Одной корреляции CPU с rollout или одной строки CPU `top` для такого вывода было бы недостаточно.

## Root cause

Root cause сценария — retry policy `v84`, которая повторяла запросы после `429` без паузы и общего budget и не прекращала CPU-работу после cancellation caller. Downstream degradation была trigger, а serialization/signing каждой попытки и allocation churn усилили CPU demand. Нехватка cores не была первичной причиной: прежний workload укладывался в ту же quota, а controlled disable восстановил CPU/op.

Полное RCA отдельно фиксирует latent conditions: не было metric attempts per good operation, retry path не проходил overload test, а alert срабатывал по CPU уже после роста p99.

## Исправление

### Немедленное

- Остановить rollout или выключить новый retry branch на малой cohort, затем расширить после проверки.
- Ограничить admission/concurrency для low-priority traffic, если CPU queue уже нарушает SLO.
- Задать временный жёсткий attempt budget и прекратить работу по отменённому context.
- Сохранить profile и trace до постепенного restart; restart без устранения loop лишь начинает incident заново.

### Долгосрочное

- Классифицировать retryable outcomes по протоколу dependency, учитывать server guidance и применять bounded backoff с jitter.
- Ограничить retries общим deadline, attempt budget и retry budget на весь fleet; проверять idempotency операции.
- Не выполнять serialization/signing заново, если безопасный immutable результат можно переиспользовать.
- Добавить overload/fault test: downstream `429`/timeout, ранняя cancellation, ограниченная CPU quota и проверка attempts/goodput.
- Экспортировать CPU seconds, attempts и allocations на своевременно успешную операцию по bounded workload classes.

## Проверка результата

Исправление считается доказанным, когда на прежнем representative workload:

- CPU/op и attempts/good operation вернулись в ожидаемый диапазон;
- suspect stacks исчезли или сократились в сопоставимом CPU profile;
- runnable/scheduler latency и throttling снизились;
- p95/p99, goodput и error semantics восстановились;
- после снятия overload сервис сам опустошает очередь без restart;
- нет переноса bottleneck в database, queue или downstream.

Сравнивайте одинаковые версии зависимостей, quotas, request mix и observation window. Один короткий зелёный интервал после сброса traffic не доказывает восстановление capacity.

## Профилактика

Alert должен связывать user SLI с precursor: CPU saturation, CPU/op, runnable latency, attempts/good operation и queue age. Порог CPU без denominator создаёт тревоги на полезный traffic и пропускает дорогой request mix при умеренном среднем CPU.

Перед rollout дорогого path сохраняйте benchmark/profile baseline и проверяйте scaling curve до capacity knee. Для редких spikes continuous profiling повышает шанс поймать окно, но требует retention, access control и измеренного overhead.

## Эволюция и версии

| Версия | Изменение | Практический эффект для runbook | Источник |
| --- | --- | --- | --- |
| Go 1.26 | Добавлены `/sched/goroutines/{runnable,running,waiting,not-in-go}` и другие scheduler metrics | CPU spike проще разделить на runnable pressure, ожидание и system/cgo path; значения приблизительны и не обязаны суммироваться в total | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |

## Trade-offs

Rollback быстрее возвращает известный CPU cost, но может быть невозможен после несовместимых state changes. Feature flag имеет меньший blast radius, однако оставляет новую binary и требует доказать, что выключен весь path.

Дополнительные cores покупают время и полезны при честном росте workload. При retry/spin они увеличивают объём бесполезной работы и давление на downstream. Concurrency limit сохраняет процесс, но создаёт ранние rejects; это лучше скрытой очереди только при явной admission semantics.

Короткий on-demand profile дешевле continuous profiling по хранению, но легко пропускает spike. Более длинный capture повышает sample quality ценой overhead и более долгого воздействия на инцидентный instance.

## Типичные ошибки

- **Неверное предположение:** высокая CPU означает нехватку cores. **Симптом:** после scale-out dependency и retry traffic перегружаются сильнее. **Причина:** добавлена capacity для amplification loop. **Исправление:** сначала сравнить CPU/op, attempts и profile, затем масштабировать только подтверждённую полезную работу.
- **Неверное предположение:** первая строка `pprof top` и есть root cause. **Симптом:** ускорили serializer, но spike повторяется. **Причина:** serializer лишь исполнялся много раз из-за retry policy. **Исправление:** пройти cumulative call path до trigger и сопоставить с traces/counters.
- **Неверное предположение:** низкий fleet-average CPU опровергает saturation. **Симптом:** один shard timeout-ится при свободном среднем fleet. **Причина:** aggregation скрыла hot key, quota или uneven placement. **Исправление:** разрезать по replica/shard/tenant class и сравнить max/quantiles.
- **Неверное предположение:** Go CPU profile объясняет весь system CPU. **Симптом:** profile мал, а node CPU остаётся высокой. **Причина:** стоимость в kernel, cgo, sidecar или другом process. **Исправление:** сверить ownership CPU и применить per-thread/OS attribution.
- **Неверное предположение:** restart исправил spike. **Симптом:** CPU снова растёт после возвращения traffic. **Причина:** очищено состояние, но trigger и loop остались. **Исправление:** сохранить evidence, устранить path и подтвердить под тем же workload.
- **Неверное предположение:** падение CPU доказывает улучшение. **Симптом:** CPU снизилась вместе с completed requests. **Причина:** сервис начал раньше отклонять или терять работу. **Исправление:** проверять CPU вместе с timely goodput, correctness и error semantics.

## Когда применять выводы

Runbook применяют при внезапном росте process/container CPU, throttling, runnable pressure, росте CPU cost per operation или latency/throughput regression, подозрительно совпавшей с on-CPU work. Если CPU низкая, а latency высокая, начните с wait decomposition, а не с CPU profile.

Законченная диагностика оставляет problem-window profile, trace/counters, change correlation, причинный прогноз, результат controlled mitigation и regression test. Без этой цепочки формулировка «CPU выросла из-за функции X» остаётся гипотезой.

## Источники

- [Diagnostics](https://go.dev/doc/diagnostics) — The Go Project, общая веб-документация без release-versioning, выбор profiles/traces и предупреждение о взаимном влиянии diagnostics, проверено 2026-07-18.
- [Package runtime/pprof](https://pkg.go.dev/runtime/pprof@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, CPU и predefined profiles, проверено 2026-07-18.
- [Исходный код runtime/pprof](https://github.com/golang/go/blob/go1.26.5/src/runtime/pprof/pprof.go) — репозиторий golang/go, tag `go1.26.5`, файл `src/runtime/pprof/pprof.go`, символы `StartCPUProfile`/`StopCPUProfile`, проверено 2026-07-18.
- [Package runtime/metrics](https://pkg.go.dev/runtime/metrics@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, CPU classes и scheduler metrics, проверено 2026-07-18.
- [Package runtime/trace](https://pkg.go.dev/runtime/trace@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, execution tracing, проверено 2026-07-18.
- [Go 1.26 Release Notes](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, новые scheduler metrics, проверено 2026-07-18.
- [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) — Google, Site Reliability Engineering, глава 6, latency/traffic/errors/saturation, проверено 2026-07-18.
- [Handling Overload](https://sre.google/sre-book/handling-overload/) — Google, Site Reliability Engineering, глава 21, admission и overload control, проверено 2026-07-18.
