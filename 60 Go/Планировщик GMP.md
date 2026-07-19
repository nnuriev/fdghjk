---
aliases:
  - Планировщик goroutines в Go
tags:
  - область/go
  - тема/runtime
статус: проверено
---

# Планировщик GMP

## TL;DR

Планировщик Go распределяет готовые goroutines (`G`) по потокам ОС (`M`) через ограниченный набор ресурсов выполнения (`P`). `GOMAXPROCS` ограничивает число `P`, то есть максимальное число goroutines, одновременно исполняющих Go-код, но не число goroutines и не обязательно число OS threads. Блокировка goroutine на channel или pollable network I/O освобождает возможность исполнять другую работу; блокирующий syscall может временно отделить `M` от `P`. На scheduler latency влияют загрузка CPU, длина runnable-очередей, stop-the-world фазы, syscalls, preemption и oversubscription.

## Область применимости

- Версия Go: языковой контракт Go 1.26; реализация toolchain Go 1.26.5.
- GOOS/GOARCH: основное описание исходников — linux/amd64; роли G, M и P переносимы, детали preemption, syscalls и netpoll зависят от порта.
- Компоненты runtime: scheduler, timers, netpoller, garbage collector.
- Вне scope: точный формат scheduler trace и внутренние поля runtime как стабильный API.

## Ментальная модель

Разделяйте три сущности:

- **G** хранит состояние goroutine: stack, instruction pointer и статус ожидания; правила владения, завершения и утечек относятся уже к [[60 Go/Goroutines и lifecycle|lifecycle goroutine]], а не к механике scheduler.
- **M** — поток ОС, на котором фактически выполняются инструкции.
- **P** — право и локальные ресурсы для исполнения Go-кода, включая локальную runnable queue и allocator cache.

Для выполнения Go-кода нужны вместе M и P. Goroutine не закреплена навсегда ни за одним из них. Если G блокируется на channel, mutex или I/O, обслуживаемом [[60 Go/Netpoller|netpoller]], runtime паркует G, а P может продолжить работу с другим M. Если M входит в потенциально долгий syscall, runtime может передать P другому M. Исключения вроде `runtime.LockOSThread` создают явную привязку и требуют отдельного обоснования.

Практический инвариант: runnable означает «может исполняться», а не «уже получила CPU». Большой runnable backlog превращается в scheduler latency даже при отсутствии locks.

## Как устроено

В Go 1.26.5 новая runnable G обычно попадает в слот `runnext` или локальную очередь текущего P. Переполненная локальная очередь частично переносится в global queue. P без работы ищет timers и netpoll completions, проверяет global queue и крадёт часть работы у других P. Точный порядок проверок и эвристики — implementation detail функции `findRunnable`.

Scheduler старается одновременно:

1. держать достаточно M для загрузки доступных P;
2. не будить избыточное число M и не создавать wake-up storm;
3. не допустить starvation global queue, timers и netpoller;
4. дать процессорное время workers [[60 Go/Аллокации, GC и GC pressure|сборщика мусора]];
5. прерывать долго исполняющийся Go-код на safe points и, на поддерживаемых платформах, асинхронно.

`GOMAXPROCS` — не размер worker pool приложения. В Go 1.25+ при effective language version `go 1.25+` runtime по умолчанию выбирает минимум из logical CPUs, affinity mask и округлённой вверх cgroup quota/period и обновляет его не чаще примерно раза в секунду. Одна cgroup quota не снижает default ниже 2, если logical/affinity count сами не меньше 2. Для language version 1.24 и ниже defaults `containermaxprocs=0` и `updatemaxprocs=0` сохраняют legacy behavior; их можно переопределить GODEBUG. Переменная окружения `GOMAXPROCS` или вызов `runtime.GOMAXPROCS(n)` с `n > 0` отключает auto-update, даже если число не изменилось; `GOMAXPROCS(0)` только читает значение, а `runtime.SetDefaultGOMAXPROCS` восстанавливает default с учётом GODEBUG.

## Код

Пример фиксирует только публично наблюдаемый инвариант: заблокированная G не обязана удерживать единственный P.

~~~go
package main

import (
	"fmt"
	"runtime"
)

func main() {
	runtime.GOMAXPROCS(1)

	release := make(chan struct{})
	started := make(chan struct{})

	go func() {
		close(started)
		<-release
	}()

	<-started

	done := make(chan struct{})
	go func() {
		fmt.Println("second goroutine ran")
		close(done)
	}()

	<-done
	close(release)
}
~~~

Команда:

~~~text
go run main.go
~~~

## Ожидаемый результат

~~~text
second goroutine ran
~~~

Первая goroutine ждёт channel, но вторая исполняется при `GOMAXPROCS(1)`. Этот вывод доказывает возможность multiplexing goroutines на одном P, но не раскрывает конкретную очередь или M. Пример выполнен в официальном Go Playground на Go 1.26.5; вывод совпал с ожидаемым, проверено 2026-07-15.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| До Go 1.25 либо effective language version ≤1.24 с default GODEBUG | Default `GOMAXPROCS` не учитывал cgroup quota и не обновлялся автоматически | — | Новая toolchain сама по себе не включает новую policy для старого `go` directive | [GODEBUG defaults](https://go.dev/doc/godebug) |
| Go 1.25+ language version | — | Linux runtime учитывает cgroup CPU bandwidth limit и может обновлять default | Не выставляйте значение сторонней библиотекой только ради quota; при ручной policy восстановление делает `SetDefaultGOMAXPROCS` | [runtime/debug.go](https://github.com/golang/go/blob/go1.26.5/src/runtime/debug.go#L12-L120) |
| 1.26 | Наблюдение состояний scheduler требовало более косвенных сигналов | Добавлены метрики goroutine states, OS threads и общего числа созданных goroutines | Проще отличать runnable pressure от простого роста общего числа G | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |

## Trade-offs

Больше P повышает потенциальный CPU parallelism, но может усилить cache contention, runnable competition и расход CPU на GC. Меньше P ограничивает конкуренцию и иногда стабилизирует latency, но создаёт очередь для CPU-bound работы. Выбор проверяют под реальной CPU quota и профилем нагрузки.

Goroutine-per-request упрощает lifecycle и хорошо сочетается с blocking-style API. [[60 Go/Worker pool, fan-in, fan-out и bounded concurrency|Bounded worker pool]] нужен, когда предел задаёт не scheduler, а внешняя система, память, file descriptors или допустимое число одновременных операций. Само наличие дешёвых goroutines не отменяет backpressure.

`runtime.LockOSThread` оправдан для thread-local foreign API или UI event loop. Цена — ограничение свободы scheduler и риск удерживать thread при неверном lifecycle.

## Типичные ошибки

**Неверное предположение:** `GOMAXPROCS` ограничивает число goroutines. **Симптом:** память и очередь продолжают расти после уменьшения значения. **Причина:** оно ограничивает одновременно исполняемый Go-код, а не admission. **Исправление:** вводить bounded concurrency и backpressure на уровне операции.

**Неверное предположение:** одна заблокированная goroutine занимает OS thread. **Симптом:** преждевременный переход на callback-style код. **Причина:** channel, synchronization primitives и pollable network I/O обычно паркуют G. **Исправление:** сначала подтвердить OS-thread pressure через trace и thread profile; отдельно искать blocking syscalls и cgo.

**Неверное предположение:** число P надо всегда вручную приравнивать CPU quota. **Симптом:** runtime перестаёт адаптировать default после изменения cgroup limit. **Причина:** `GOMAXPROCS(n > 0)` отключает auto-update, а новая default policy ещё зависит от `go` directive/GODEBUG. **Исправление:** оставить совместимый default, для чтения вызывать `GOMAXPROCS(0)`, а после ручной policy при необходимости использовать `SetDefaultGOMAXPROCS`.

## Когда применять

- Используйте модель GMP для объяснения scheduler latency, но не проектируйте код вокруг конкретной формы очередей.
- Ограничивайте concurrency в точке владения дорогим ресурсом, а не через `GOMAXPROCS`.
- Сравнивайте runnable goroutines, utilization P, syscalls и GC pauses в [[60 Go/Execution trace|execution trace]].
- Указывайте toolchain и платформу при любом утверждении о scheduler internals.

## Источники

- [Package runtime](https://pkg.go.dev/runtime@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [runtime/proc.go: scheduler, findRunnable и run queues](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/proc.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/runtime2.go: структуры g, m и p](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/runtime2.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [Go 1.25 Release Notes: container-aware GOMAXPROCS](https://go.dev/doc/go1.25) — The Go Project, Go 1.25, проверено 2026-07-15.
- [GODEBUG defaults](https://go.dev/doc/godebug) — The Go Project, compatibility defaults для toolchain Go 1.26.5, проверено 2026-07-15.
- [runtime/debug.go: GOMAXPROCS и SetDefaultGOMAXPROCS](https://github.com/golang/go/blob/go1.26.5/src/runtime/debug.go#L12-L120) — репозиторий golang/go, tag go1.26.5, файл `src/runtime/debug.go`, проверено 2026-07-15.
- [Go 1.26 Release Notes: runtime/metrics](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
