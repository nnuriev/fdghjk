---
aliases:
  - Pprof в Go
tags:
  - область/go
  - тема/диагностика
  - тема/производительность
статус: проверено
---

# Профилирование с pprof

## TL;DR

Pprof агрегирует samples или events по stack traces и отвечает «где накапливается CPU, memory allocation или blocking cost». CPU profile показывает sampled on-CPU stacks; heap и allocs различают live memory и cumulative allocation churn; block и mutex profiles показывают разные причины ожидания. Pprof не хранит полную временную последовательность — для causal timeline нужен [[60 Go/Execution trace|execution trace]]. Сначала выбирайте правильный profile и sample index, затем проверяйте `top`, call graph и source view; проценты без понимания denominator легко приводят к неверной оптимизации.

## Область применимости

- Версия Go: packages `runtime/pprof` и `net/http/pprof` Go 1.26.5.
- GOOS/GOARCH: основной baseline linux/amd64; sampling и symbolization зависят от kernel, architecture и build.
- Компоненты: CPU, heap/allocs, goroutine, block, mutex и threadcreate profiles.
- Вне scope: distributed tracing и application business metrics.

## Ментальная модель

Profile — multiset stack traces с weight:

- CPU: samples времени исполнения;
- `heap`: sampled [[60 Go/Аллокации, GC и GC pressure|allocations живых objects]], default index `inuse_space`;
- `allocs`: те же allocation records, default `alloc_space` за жизнь процесса;
- block: cumulative время, проведённое в synchronization blocking, по месту блокировки;
- mutex: cumulative waiters time, attributed к концу critical section, который создал contention;
- goroutine: stacks существующих goroutines.

Flat показывает weight непосредственно в function, cumulative — function вместе с callees. Большой cumulative при маленьком flat часто означает orchestration function, а не место дорогой работы.

## Как устроено

CPU profiler периодически samples running goroutines и потому может пропустить очень короткое редкое событие. Heap profiler samples allocations; точные byte counts оцениваются статистически. `runtime.MemProfile` может отставать до двух GC cycles, поэтому перед offline snapshot часто вызывают `runtime.GC`, если дополнительная pause приемлема: это делает статистику актуальнее, но не превращает sampled profile в строго текущую точную картину live heap.

Block и mutex profiling нужно включить rates через `runtime.SetBlockProfileRate` и `runtime.SetMutexProfileFraction`; нулевой/default sampling не обязан собирать нужную детализацию. Высокая частота повышает diagnostic overhead.

Получить profile можно тремя штатными путями:

- flags `go test -cpuprofile/-memprofile`;
- API `runtime/pprof` в standalone process;
- HTTP handlers `net/http/pprof` для live process.

HTTP endpoint раскрывает stack traces, function names и workload characteristics. Его нельзя бездумно публиковать наружу; нужен internal listener или authentication/network policy.

## Код

Пример создаёт live heap и пишет snapshot:

~~~go
package main

import (
	"fmt"
	"os"
	"runtime"
	"runtime/pprof"
)

var keep [][]byte

func main() {
	for range 32 {
		keep = append(keep, make([]byte, 1<<20))
	}

	runtime.GC()

	f, err := os.Create("heap.pprof")
	if err != nil {
		panic(err)
	}
	if err := pprof.WriteHeapProfile(f); err != nil {
		panic(err)
	}
	if err := f.Close(); err != nil {
		panic(err)
	}

	fmt.Println("heap.pprof written")
}
~~~

Команды:

~~~text
go run main.go
go tool pprof -top -sample_index=inuse_space heap.pprof
~~~

## Ожидаемый результат

Первая команда печатает:

~~~text
heap.pprof written
~~~

и создаёт non-empty `heap.pprof`. Вторая успешно читает profile и выводит table с колонками `flat`, `flat%`, `sum%`, `cum`, `cum%`; allocation из `main.main` должна доминировать live application heap. Точные sampled bytes и проценты не фиксируются. Программа выполнена в официальном Go Playground на Go 1.26.5 и сообщила о записи profile; отдельный запуск `go tool pprof` над удалённым файлом недоступен, проверено 2026-07-15.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| 1.22–1.24 | Runtime-internal mutex contention мог атрибутироваться необычно | — | Runtime locks и `sync.Mutex` читались неодинаково | [Go 1.25 Release Notes](https://go.dev/doc/go1.25) |
| 1.25 | — | Runtime mutex profile указывает на конец critical section, создавшей delay | Проще искать holder, а не waiter | [Go 1.25 Release Notes](https://go.dev/doc/go1.25) |
| 1.26 | Web UI `pprof -http` открывал graph view | Default стал flame graph; graph остался в menu | Изменился стартовый view, не profile semantics | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |
| 1.26 | [[60 Go/Goroutine и channel leaks|Permanent goroutine leaks]] искали косвенно | Добавлен experimental profile `goroutineleak` под `GOEXPERIMENT=goroutineleakprofile` | Можно диагностировать часть unreachable blocked goroutines; API пока experimental | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |

## Trade-offs

CPU profile имеет небольшой контролируемый sampling overhead и хорошо находит устойчивые hotspots, но редкая latency spike может не попасть в samples. Execution trace дороже и объёмнее, зато показывает causal ordering и scheduler/blocking latency.

`inuse_space` отвечает, кто удерживает memory на момент снятия профиля; `alloc_space` — кто создавал allocation churn. Оптимизация только одного может ухудшить другое: [[60 Go/Снижение аллокаций и sync.Pool|pooling]] уменьшает `alloc_space`, но увеличивает `inuse_space`.

Continuous profiling ловит редкие периоды и regressions, но требует storage, labels и контроля доступа. On-demand profile проще, однако может быть снят не в проблемном состоянии.

## Типичные ошибки

**Неверное предположение:** heap profile показывает все bytes process RSS. **Симптом:** profile мал, а container memory велика. **Причина:** RSS включает stacks, runtime metadata, mappings, cgo и kernel effects. **Исправление:** сочетать heap/allocs, runtime metrics и OS metrics.

**Неверное предположение:** top cumulative function надо оптимизировать первой. **Симптом:** меняют dispatcher без эффекта. **Причина:** cost находится в callees. **Исправление:** различать flat/cum и проходить call graph до leaf work.

**Неверное предположение:** mutex profile указывает место ожидания. **Симптом:** исправляют caller `Lock`, а critical section остаётся длинной. **Причина:** current profile относит contention к stack trace holder в момент освобождения lock. **Исправление:** сокращать/разделять critical section, подтвердив call graph.

**Неверное предположение:** публичный `/debug/pprof` безопасен, потому что read-only. **Симптом:** утечка internals или diagnostic DoS. **Причина:** endpoint раскрывает runtime data и запускает затратный сбор. **Исправление:** отдельный защищённый listener и operational limits.

## Когда применять

- CPU profile — при устойчивом CPU saturation; эффект исправления закрепляйте отдельным [[60 Go/Бенчмарки|benchmark]] с контролируемой средой.
- `allocs` — при высоком allocation rate и GC CPU.
- `heap` — при retention или memory limit pressure.
- block/mutex — при synchronization latency.
- Execution trace — когда важен порядок событий, а не aggregate stacks.

## Источники

- [Package runtime/pprof](https://pkg.go.dev/runtime/pprof@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Package net/http/pprof](https://pkg.go.dev/net/http/pprof@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Diagnostics: Profiling](https://go.dev/doc/diagnostics) — The Go Project, документация Go 1.26, проверено 2026-07-15.
- [runtime/pprof/pprof.go: predefined profile semantics](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/pprof/pprof.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/mprof.go: MemProfile lag](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/mprof.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [Go 1.25 Release Notes: mutex profile](https://go.dev/doc/go1.25) — The Go Project, Go 1.25, проверено 2026-07-15.
- [Go 1.26 Release Notes: pprof UI and goroutineleak profile](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
