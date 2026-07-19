---
aliases:
  - Deterministic testing concurrent code
  - Deterministic concurrency testing in Go
  - testing/synctest
tags:
  - область/go
  - тема/тестирование
  - тема/конкурентность
статус: черновик
---

# Детерминированное тестирование concurrent code

## TL;DR

Детерминированный concurrent test управляет причинными событиями — запуском, signal, cancellation, clock и quiescence, — а не надеется на «достаточно долгий» `time.Sleep`. Его цель — точно построить нужное happens-before и проверить state в известной точке protocol.

В Go 1.25+ standard package `testing/synctest` запускает goroutines в изолированной bubble, виртуализирует `time` и умеет ждать durable blocking. Он делает быстрыми тесты timers, cancellation и некоторых asynchronous protocols, но не заменяет [[60 Go/Race detector|race detector]], повторные stress runs и tests реального network/OS behavior.

## Область применимости

- Версия Go: 1.26.5. Стабильный API `testing/synctest.Test`/`Wait` доступен с Go 1.25.
- Go 1.24 содержал experimental API за `GOEXPERIMENT=synctest`; он не подчинялся compatibility promise.
- GOOS/GOARCH: core bubble semantics задана package contract; системные вызовы, real sockets и external processes остаются вне детерминированной модели.
- Пакеты в примере: `testing`, `testing/synctest`, `time`.
- Вне scope: exhaustive schedule exploration, formal verification и performance/scheduler benchmarks.

## Ментальная модель

В concurrent test есть два независимых вопроса:

1. **Достигла ли система нужной точки?** Для этого нужны channel/WaitGroup, fake boundary или quiescence.
2. **Какие memory effects к этой точке можно читать?** Для этого нужно [[60 Go/Модель памяти Go и happens-before|happens-before]], а не просто elapsed time.

`Sleep(10 * time.Millisecond)` не отвечает ни на один из них. На быстрой машине он замедляет suite, а на перегруженном CI всё ещё может быть короче scheduler pause.

Полезная модель теста:

```text
arrange initial state
-> trigger one protocol event
-> wait for causally related work to quiesce
-> observe invariant
-> trigger next event
```

Особенно важна quiescence для negative assertion: «после обработки всей текущей работы событие ещё не произошло» сильнее, чем «на текущую наносеку не успело».

## Как устроено

### Явные seams остаются базовым инструментом

Если function запускает background goroutine, ей полезно иметь observable lifecycle: returned `done`, `Stop`/`Close`, context cancellation и гарантию завершения. Такой API нужен не только тесту: owner в production тоже должен остановить и дождаться работы, чтобы не создать [[60 Go/Goroutine и channel leaks|goroutine leak]].

Для code с внешним clock классический подход — передать fake clock как dependency. Цена: весь causal path, включая библиотеки, должен использовать эту abstraction и иметь способ дождаться разбуженной работы.

### `testing/synctest` даёт bubble, fake time и quiescence

`synctest.Test` запускает function в bubble. Goroutines, созданные внутри, принадлежат той же bubble. Каждая bubble имеет fake clock, начинающийся с `2000-01-01 00:00:00 UTC`. Реальные CPU computations не двигают его. Когда все goroutines durably blocked, ожидающий `synctest.Wait` возвращается; если такого вызова нет, fake time продвигается к следующему timer event.

`synctest.Wait` ждёт, пока все остальные goroutines в bubble не будут durably blocked. Return из `Wait` даёт synchronization point, который учитывает race detector. Само прохождение fake time synchronization не даёт: перед чтением state всё равно нужен `Wait` или обычный synchronization primitive.

### Durable blocking имеет точную границу

В Go 1.26.5 durably blocking operations включают:

- blocked send/receive на channel, созданном в той же bubble;
- `select`, где все cases блокируются на таких channels;
- пустой `select {}`;
- `sync.Cond.Wait`;
- `sync.WaitGroup.Wait`, если `Add` был вызван в bubble;
- `time.Sleep`.

Захват `sync.Mutex`/`RWMutex`, network I/O и system call могут блокировать goroutine, но не считаются durable: их может разбудить событие извне bubble. Поэтому real socket мешает quiescence; для network protocol нужен in-memory fake вроде `net.Pipe` или другой controlled transport.

Bubble изолирует channels, timers/tickers и некоторые WaitGroups. Операция на bubbled object извне может panic/fatal, поэтому test должен быть self-contained и не обмениваться с глобальной goroutine.

### Жизненный цикл bubble — часть oracle

`synctest.Test` ждёт выхода всех goroutines. После return корневой goroutine fake time больше не двигается; оставшаяся sleeping goroutine приводит к deadlock failure с stacks bubble. Это ловит часть leaks, которые сводят bubble к детерминированному deadlock, но не является общим leak detector: тест всё равно обязан явно остановить background loops.

Внутренний `*testing.T`, переданный в `synctest.Test`, имеет bubble-aware `Cleanup` и `Context`, но на нём нельзя вызывать `Run`, `Parallel` и `Deadline`. Также `synctest.Test` нельзя вложить в другую bubble.

## Код

```go
package delayed

import (
	"testing"
	"testing/synctest"
	"time"
)

func signalAfter(delay time.Duration) <-chan struct{} {
	done := make(chan struct{})
	go func() {
		time.Sleep(delay)
		close(done)
	}()
	return done
}

func TestSignalAfterBoundary(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		const delay = time.Hour
		done := signalAfter(delay)

		time.Sleep(delay - time.Nanosecond)
		synctest.Wait()
		select {
		case <-done:
			t.Fatal("signal arrived before the deadline")
		default:
		}

		time.Sleep(time.Nanosecond)
		synctest.Wait()
		select {
		case <-done:
			// Expected: the timer fired and the goroutine closed done.
		default:
			t.Fatal("signal did not arrive at the deadline")
		}
	})
}
```

## Ожидаемый результат

`go test -run '^TestSignalAfterBoundary$'` должен завершиться с exit code 0 почти мгновенно, хотя protocol содержит часовой delay. До границы channel не закрыт; на границе после `Wait` он закрыт.

Пример не запускался локально: Go toolchain в среде отсутствует. Поэтому это ожидаемое поведение по контракту Go 1.26.5, а не наблюдавшийся вывод; статус заметки остаётся `черновик`.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| Go 1.24 | В standard library не было общедоступного API для bubble/fake time | Experimental `testing/synctest` за `GOEXPERIMENT=synctest`, API с `Run` | Можно было пробовать механизм, но не полагаться на compatibility | [Testing concurrent code with testing/synctest](https://go.dev/blog/synctest) |
| Go 1.25 | Experimental API требовал flag и не имел bubble-scoped `*testing.T` | `testing/synctest` вышел в general availability; `Run` заменён на `Test(t, func(*testing.T))` | Стабильный API без `GOEXPERIMENT`; cleanup/context живут в bubble | [Go 1.25 Release Notes](https://go.dev/doc/go1.25#testing-synctest) |
| Go 1.26 | Go 1.25 ещё мог показать старый API при `GOEXPERIMENT=synctest` | В public API Go 1.26.5 остались `Test` и `Wait` | Код на experimental `Run` нужно мигрировать | [Package testing/synctest](https://pkg.go.dev/testing/synctest@go1.26.5) |

## Trade-offs

- `synctest` даёт idiomatic `time` и runtime-level quiescence без протаскивания clock interface через весь code. Явный fake clock выигрывает, если нужно точно моделировать clock drift/jump или если поддерживаемая Go version ниже 1.25.
- Bubble прекрасно моделирует in-process protocol. Она не воспроизводит kernel buffers, packetization, DNS, filesystem и external processes; для них нужен integration test.
- Точный schedule упрощает oracle, но исследует только закодированные interleavings. Повторный stress run на real scheduler даёт разнообразие, но не даёт повторяемого доказательства одного state transition.
- Race detector ищет несинхронизированные memory accesses на выполненных paths. Deterministic test проверяет domain safety/liveness в заданном protocol state. Один не заменяет другой.

## Типичные ошибки

- Неверное предположение: большой `Sleep` доказывает negative assertion. Симптом: медленный flaky CI. Причина: elapsed wall time не даёт quiescence и happens-before. Исправление: signal/`Wait` или controlled fake.
- Неверное предположение: fake time само синхронизирует memory. Симптом: `-race` сообщает race после `Sleep`. Причина: timer firing не упорядочил write/read. Исправление: `synctest.Wait`, channel, mutex или atomic protocol.
- Неверное предположение: real TCP socket станет idle для bubble. Симптом: `Wait` не возвращается. Причина: network I/O может разбудить external event. Исправление: in-memory fake transport и отдельный real-network integration test.
- Неверное предположение: return из root автоматически завершит background timers. Симптом: deadlock panic с sleeping goroutine. Причина: после root return fake time останавливается, а `Test` ждёт все goroutines. Исправление: явный stop/cancel и ожидание exit.

## Когда применять

Используйте `testing/synctest` для timers, `context.AfterFunc`, timeout/cancellation, asynchronous buffer transfer и in-process protocols, которые можно целиком поместить в bubble. Стройте test как цепочку «event → `Wait` → assertion» и завершайте все goroutines до выхода.

Добавляйте три независимых слоя: deterministic protocol tests для конкретных переходов, `-race` для memory safety на выполненных paths и repeated/stress integration runs для schedule и environment diversity. Сбой, который зависит от реального mutex contention, socket или scheduler fairness, не нужно «доказывать» fake моделью.

## Источники

- [Package testing/synctest](https://pkg.go.dev/testing/synctest@go1.26.5) — Go project, Go 1.26.5, bubble, fake time, durable blocking, isolation и public API, проверено 2026-07-18.
- [Go 1.25 Release Notes — testing/synctest](https://go.dev/doc/go1.25#testing-synctest) — Go project, Go 1.25, general availability и migration с experimental API, проверено 2026-07-18.
- [Testing concurrent code with testing/synctest](https://go.dev/blog/synctest) — Go project, experimental design Go 1.24, 2025-02-19, проверено 2026-07-18.
- [Testing Time (and other asynchronicities)](https://go.dev/blog/testing-time) — Go project, stable `testing/synctest` в Go 1.25, 2025-08-26, `Wait` synchronization и изменения API, проверено 2026-07-18.
- [The Go Memory Model](https://go.dev/ref/mem) — Go project, редакция 2022-06-06, применима к Go 1.26, проверено 2026-07-18.
- [Data Race Detector](https://go.dev/doc/articles/race_detector) — Go project, toolchain Go 1.26.5, проверено 2026-07-18.
