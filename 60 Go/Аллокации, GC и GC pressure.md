---
aliases:
  - Heap allocations и garbage collector в Go
tags:
  - область/go
  - тема/runtime
  - тема/производительность
статус: проверено
---

# Аллокации, GC и GC pressure

## TL;DR

Garbage collector (GC) Go освобождает недостижимую heap memory. Число allocations — лишь один из факторов его стоимости. Ключевые величины — allocation rate, live heap, объём pointer-rich roots и частота циклов. `GOGC` выбирает CPU/memory trade-off, а `GOMEMLIMIT` задаёт soft limit для памяти, управляемой runtime. Сначала устраняйте лишний lifetime и горячие allocations, затем настраивайте GC; уменьшение `GOGC` не лечит retention, а слишком жёсткий memory limit может превратить процесс в почти непрерывный GC.

## Область применимости

- Версия Go: Go 1.26; toolchain и runtime Go 1.26.5.
- GOOS/GOARCH: модель GC переносима; основной implementation baseline — linux/amd64. Vectorized scanning Green Tea зависит от поколения amd64 CPU.
- Компоненты: allocator, concurrent tracing GC, pacer, `runtime/metrics`, `runtime/debug`.
- Вне scope: память C/cgo, mmap приложения и RSS как точный синоним Go heap.

## Ментальная модель

Разделите heap на:

- **live heap** — объекты, достижимые после tracing;
- **new heap** — память, выделенная после прошлого цикла;
- garbage — уже недостижимые объекты, которые следующий цикл сможет освободить;
- roots — globals и pointer-containing [[60 Go/Стеки и escape analysis|goroutine stacks]], от которых начинается tracing.

GC CPU расходуется главным образом на tracing live objects и roots. Allocation rate определяет, как быстро программа исчерпывает запас new heap и запускает следующий цикл. Поэтому одинаковый live heap при вдвое большей allocation rate обычно означает более частые циклы, а удержание большого live graph делает дорогим каждый цикл.

GC pressure — наблюдаемая цена churn и retention: CPU GC workers и assists, pauses, больший heap target, cache pressure и latency. Это не отдельная runtime metric.

## Как устроено

Go использует tracing GC; значительная часть mark выполняется concurrent с приложением. Короткие stop-the-world точки нужны для фазовых переходов и root preparation. Когда concurrent workers не успевают за allocation rate, allocating goroutines выполняют mark assists: latency операции начинает включать часть GC work.

Документированная модель pacer из GC Guide (страница описывает Go 1.19), согласующаяся с формой target в исходниках Go 1.26.5:

~~~text
Target heap = Live heap + (Live heap + GC roots) * GOGC / 100
~~~

При `GOGC=100` runtime ориентируется примерно на один объём scan work дополнительного heap между циклами. Это target, а не hard cap: крупная allocation, scheduling и concurrent progress могут дать отклонение.

`GOMEMLIMIT` ограничивает суммарную memory, которой управляет runtime, а не RSS контейнера. Этот лимит soft: runtime старается соблюдать его, но сохраняет progress и не обещает немедленный OOM вместо превышения. В лимит не входят, например, память C и mapping самого binary. Поэтому лимит контейнера оставляют выше `GOMEMLIMIT`, сохраняя headroom для non-Go memory и kernel accounting.

В Go 1.26 Green Tea GC включён по умолчанию. Он меняет реализацию marking/scanning, но не отменяет базовую модель: меньше live pointer graph и allocation churn обычно означают меньше GC work.

## Код

Пример измеряет одну гарантированно escaping allocation на вызов:

~~~go
package main

import (
	"fmt"
	"testing"
)

var sink []byte

func allocate() {
	sink = make([]byte, 1024)
}

func main() {
	fmt.Printf("%.0f\n", testing.AllocsPerRun(1000, allocate))
}
~~~

Команда:

~~~text
go run main.go
~~~

## Ожидаемый результат

~~~text
1
~~~

Backing array остаётся доступен через global `sink`, поэтому каждый вызов требует одну heap allocation. Если такой вызов происходит N раз в секунду, он создаёт примерно N KiB/s allocation traffic независимо от того, что одновременно live остаётся только последний buffer. Пример выполнен в официальном Go Playground на Go 1.26.5; `testing.AllocsPerRun` вернул `1`, проверено 2026-07-15.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| до 1.18 | `GOGC` target учитывал live heap без root set | — | Много goroutine stacks могло занижать оценку scan work | [GC Guide](https://go.dev/doc/gc-guide) |
| 1.18 | — | В target включены GC roots | Модель лучше учитывает приложения с большим числом goroutines | [GC Guide](https://go.dev/doc/gc-guide) |
| 1.19 | Жёсткого runtime memory limit не было | Добавлены `GOMEMLIMIT` и `debug.SetMemoryLimit` | Можно согласовать GC с memory budget, оставив внешний headroom | [Go 1.19 Release Notes](https://go.dev/doc/go1.19) |
| 1.25 | Классический collector был default | Green Tea доступен как experiment | Можно было сравнить новую реализацию через `GOEXPERIMENT=greenteagc` | [Go 1.25 Release Notes](https://go.dev/doc/go1.25) |
| 1.26 | Green Tea требовал opt-in | Green Tea включён по умолчанию; временный opt-out — `GOEXPERIMENT=nogreenteagc` | Performance baseline изменился; старые GC benchmarks нужно повторить | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |

## Trade-offs

Более высокий `GOGC` реже запускает GC и обычно снижает GC CPU, но допускает больший heap. Более низкий экономит heap ценой частых циклов и assists. `GOMEMLIMIT` лучше выражает внешний memory budget, однако слишком маленький limit не уменьшает live set и может создать GC thrashing.

Устранение allocation через reuse снижает churn, но увеличивает lifetime и retained capacity. Маленький краткоживущий object иногда дешевле, чем общий [[60 Go/Снижение аллокаций и sync.Pool|`sync.Pool`]] с synchronization, reset protocol и oversized buffers.

Pointer-free contiguous data дешевле сканировать, чем граф многих pointer-rich objects, но преобразование модели данных ради GC может ухудшить clarity и обновления. Менять layout стоит только после heap/CPU profile.

## Типичные ошибки

**Неверное предположение:** высокий RSS означает memory leak в Go heap. **Симптом:** ищут retained Go objects, но [[60 Go/Профилирование с pprof|heap profile]] мал. **Причина:** RSS включает released-but-not-returned pages, stacks, binary mappings, cgo и kernel effects. **Исправление:** сопоставлять `runtime/metrics`, heap profile, RSS и внешние allocations.

**Неверное предположение:** больше allocations всегда означает больший live heap. **Симптом:** оптимизируют count, хотя проблема — один удерживаемый graph. **Причина:** churn и retention — разные величины. **Исправление:** смотреть одновременно `alloc_space` и `inuse_space`.

**Неверное предположение:** маленький `GOMEMLIMIT` гарантирует отсутствие OOM. **Симптом:** процесс тратит CPU на GC и всё равно превышает container limit. **Причина:** limit soft и не покрывает всю process memory. **Исправление:** измерить non-Go headroom и не ставить limit ниже устойчивого live set.

**Неверное предположение:** ручной `runtime.GC` — нормальная оптимизация request path. **Симптом:** pauses и throughput regression. **Причина:** приложение ломает работу pacer. **Исправление:** дать pacer управлять циклами; принудительный GC оставить для диагностики и редких lifecycle boundaries с измерением.

## Когда применять

- Начинайте с heap profile и allocation profile, затем связывайте их с `runtime/metrics`.
- Уменьшайте lifetime и allocation rate в hottest paths до настройки knobs.
- Задавайте `GOMEMLIMIT` с запасом относительно container limit.
- Проверяйте влияние GC на tail latency в [[60 Go/Execution trace|execution trace]], где видны workers, assists и stop-the-world intervals.
- Повторяйте [[60 Go/Бенчмарки|бенчмарки]] после обновления collector/toolchain.

## Источники

- [A Guide to the Go Garbage Collector](https://go.dev/doc/gc-guide) — The Go Project, документированная модель для Go 1.19; сопоставлена с Go 1.26.5, проверено 2026-07-15.
- [Package runtime: environment variables and MemStats](https://pkg.go.dev/runtime@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Package runtime/metrics](https://pkg.go.dev/runtime/metrics@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [runtime/mgc.go: garbage collector](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/mgc.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/mgcpacer.go: GC pacer](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/mgcpacer.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [Go 1.19 Release Notes: soft memory limit](https://go.dev/doc/go1.19) — The Go Project, Go 1.19, проверено 2026-07-15.
- [Go 1.25 Release Notes: experimental Green Tea GC](https://go.dev/doc/go1.25) — The Go Project, Go 1.25, проверено 2026-07-15.
- [Go 1.26 Release Notes: Green Tea GC by default](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
