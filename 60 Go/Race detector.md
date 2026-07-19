---
aliases:
  - Детектор гонок Go
  - Race testing
tags:
  - область/go
  - тема/конкурентность
  - тема/диагностика
статус: проверено
---

# Race detector

## TL;DR

Race detector динамически находит [[60 Go/Data races, deadlocks и livelocks|data race]]: конфликтующие non-synchronizing memory accesses, между которыми нет [[60 Go/Модель памяти Go и happens-before|happens-before]], когда две goroutines обращаются к одной memory location и хотя бы одно обращение — write. Atomic operations образуют отдельный synchronization protocol. Флаг `-race` добавляет instrumentation и race runtime, поэтому проверяются только реально выполненные paths и interleavings. Найденный report — доказательство bug; отсутствие report не доказывает safety. Detector не ищет deadlocks, leaks и нарушения бизнес-инварианта, если все отдельные accesses уже синхронизированы.

## Область применимости

- Версия Go: memory model Go 1.26; race toolchain Go 1.26.5.
- GOOS/GOARCH: доступность `-race` зависит от supported port; основной baseline — linux/amd64. В Go 1.26 добавлен linux/riscv64.
- Компоненты: compiler instrumentation, race runtime, `go test/run/build -race`.
- Вне scope: C/C++ memory accesses вне поддерживаемой cgo instrumentation.

## Ментальная модель

Detector не пытается доказать программу статически. Он наблюдает events конкретного запуска и строит causal ordering из synchronization operations:

- goroutine creation;
- channel send/receive/close;
- mutex и RWMutex;
- atomics;
- WaitGroup и другие операции, контракт которых задан memory model/package docs.

Для каждой instrumented read/write runtime проверяет, существует ли conflicting access без порядка. Wall-clock последовательность сама по себе недостаточна: важно happens-before, а не то, что два события случайно выполнились одно после другого в конкретном schedule.

Правило интерпретации report: обе stack traces показывают места конфликтующих accesses, а creation stacks объясняют lifecycle goroutines. Исправлять нужно ownership или synchronization invariant, а не только строку, на которую указывает detector.

## Как устроено

При `-race` compiler добавляет hooks вокруг memory accesses, а linker включает специальный runtime. Synchronization primitives сообщают acquire/release events. Из-за instrumentation binary потребляет существенно больше CPU и memory и имеет другой timing; его не используют как единственный performance baseline.

Coverage ограничивает результат. Unit test, который не проходит error path, не может обнаружить race там. Поэтому полезны:

1. `go test -race ./...`;
2. integration tests и fuzz inputs под `-race`;
3. staging/realistic workload для binary, собранного `go build -race`;
4. повторение flaky tests с `-count`.

Race detector задаёт build tag `race`. Исключать медленные tests этим tag допустимо только осознанно: иначе именно concurrency-heavy path исчезает из проверки.

`GORACE` настраивает report path, exit code, history size и halt behavior. Увеличение history помогает при `failed to restore the stack`, но повышает memory overhead.

## Код

Файл `counter_test.go`:

~~~go
package main

import (
	"sync"
	"testing"
)

func TestCounterRace(t *testing.T) {
	var value int
	start := make(chan struct{})

	var wg sync.WaitGroup
	wg.Add(2)
	for range 2 {
		go func() {
			defer wg.Done()
			<-start
			for range 1000 {
				value++
			}
		}()
	}

	close(start)
	wg.Wait()
}
~~~

Команда:

~~~text
go test -race -run="^TestCounterRace$" counter_test.go
~~~

## Ожидаемый результат

Команда завершается с non-zero status. Report содержит точные маркеры:

~~~text
WARNING: DATA RACE
--- FAIL: TestCounterRace
race detected during execution of test
FAIL
~~~

Addresses, goroutine numbers и line offsets различаются. `value++` — read-modify-write, и две goroutines выполняют её без synchronization между собой. Исправление — mutex, atomic counter либо single-owner goroutine. Официальный Go Playground на Go 1.26.5 выполнил обычный test из примера (`PASS`); запуск с `-race` Playground не поддерживает, поэтому сам report в доступной среде не воспроизводился, проверено 2026-07-15.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| до 1.26 | `linux/riscv64` не входил в поддерживаемые race ports | — | CI на этом port не мог запускать штатный detector | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |
| 1.26 | — | Добавлена поддержка race detector на `linux/riscv64` | Coverage можно включить непосредственно на этом target | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |

## Trade-offs

[[60 Go/Mutex, RWMutex и примитивы координации sync|Mutex]] защищает составной invariant и обычно проще для нескольких связанных полей. [[60 Go/Пакет sync-atomic|Atomic]] подходит для действительно независимого scalar state, но удаление data race не гарантирует корректность check-then-act sequence. Channel ownership делает mutation последовательной, однако добавляет queueing и lifecycle.

Race run дороже обычного test, поэтому быстрый CI может разделять jobs, но detector должен регулярно покрывать весь критичный suite. Только локальный запуск на happy path даёт ложное чувство безопасности.

Static review может доказать invariant и найти paths без tests; dynamic detector даёт конкретный report с stacks. Они дополняют, а не заменяют друг друга.

## Типичные ошибки

**Неверное предположение:** если `go test -race` прошёл один раз, races нет. **Симптом:** production report появляется на редком path. **Причина:** detector видел только выполненные accesses. **Исправление:** расширить coverage и workload, повторять schedule-sensitive tests.

**Неверное предположение:** atomic устраняет любую concurrency bug. **Симптом:** отдельные reads безопасны, но invariant между полями нарушен. **Причина:** несколько atomic operations не образуют transaction. **Исправление:** mutex/ownership вокруг полного invariant.

**Неверное предположение:** runtime panic `concurrent map writes` заменяет detector. **Симптом:** race на другом object остаётся невидимой либо [[60 Go/Map|map]] race не воспроизводится. **Причина:** panic — частичная defensive detection, а не memory-model proof. **Исправление:** синхронизация и `-race`.

**Неверное предположение:** timeout под `-race` всегда означает race. **Симптом:** test падает только из-за замедления. **Причина:** instrumentation меняет timing. **Исправление:** отдельно изучить race report; адаптировать тестовый timeout без сокрытия реального liveness bug.

## Когда применять

- В CI для unit и integration tests concurrent кода.
- После изменения ownership, caches, pools, maps или cancellation.
- Для reproducer production race с реалистичным workload.
- Вместе с memory model reasoning, а не как замена ему.

## Источники

- [Data Race Detector](https://go.dev/doc/articles/race_detector) — The Go Project, документация Go 1.26, проверено 2026-07-15.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
- [runtime/race.go и race runtime integration](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/race.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [cmd/compile/internal/ssagen/ssa.go: compiler race instrumentation](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/cmd/compile/internal/ssagen/ssa.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [Go 1.26 Release Notes: linux/riscv64 race detector](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
