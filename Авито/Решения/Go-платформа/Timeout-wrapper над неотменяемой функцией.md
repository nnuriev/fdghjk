---
aliases:
  - Avito Go — timeout wrapper
  - Timeout над неотменяемой функцией
tags:
  - область/go
  - тема/конкурентность
  - тема/cancellation
  - компания/авито
  - тип/кейс
статус: проверено
---

# Timeout-wrapper над неотменяемой функцией

## TL;DR

Если функция не принимает `context.Context` и не предоставляет другого cancel API, wrapper не может её остановить. Он способен ограничить только время ожидания caller: запускает function в отдельной goroutine и выбирает между result и `ctx.Done()`.

Result channel должен иметь buffer `1`. После timeout caller больше не читает канал; buffer позволяет producer завершить единственную отправку, когда function всё-таки вернётся. Но если сама function зависла навсегда, зависнет и goroutine. Настоящее исправление — cancellation/deadline внутри операции или изоляция в процессе, который можно завершить.

## Условие и контракт

Дана синхронная `func() int64`. Нужно вызвать её с timeout и вернуть result вместе с фактически прошедшим временем.

Нормализованный контракт `Call`:

- `timeout` должен быть положительным, `fn` — не `nil`;
- уже отменённый parent context возвращается до запуска worker; его более ранний deadline ограничивает child context;
- если result получен раньше cancellation, вернуть его и `nil` error;
- если первым наблюдается `ctx.Done()`, прекратить ожидание и вернуть `context.Canceled` или `context.DeadlineExceeded`;
- elapsed измеряется от входа в `Call` до выбранного исхода;
- wrapper не обещает остановить `fn`.

### Неоднозначности исходника

- На границе, где result и timeout уже одновременно готовы, Go `select` выбирает одну ready case псевдослучайно. Контракт должен допускать оба исхода; для жёсткого «result выигрывает» нужна дополнительная protocol/state machine, но абсолютного физического порядка событий она всё равно не восстановит.
- Не задана реакция на panic в `fn`. В этой реализации panic в отдельной goroutine остаётся panic процесса; превращать его в error можно только явным `recover` policy.
- `time.Duration` измеряет прошедшее wall/monotonic время вызова, а не CPU time функции.
- Возвращаемый `0` при timeout не получен из функции; различать эти исходы позволяет обязательный `error`.

## Ментальная модель

Есть два lifecycle:

1. lifecycle caller, который заканчивается при result или timeout;
2. lifecycle вычисления `fn`, который заканчивается только когда сама function вернётся или процесс завершится.

Wrapper связывает их только result channel. Он не получает control point внутри `fn`, поэтому не может безопасно «убить goroutine»: такая операция нарушила бы invariants runtime, locks и memory ownership.

Buffer `1` соответствует protocol «ровно один producer, ровно одно сообщение». Если caller уже выбрал timeout, поздний `resultCh <- fn()` всё равно завершается и producer goroutine освобождается. Unbuffered channel оставил бы producer навсегда на send. Buffer не помогает, пока `fn()` не вернулась.

`context.WithTimeout` наследует более ранний parent deadline. `defer cancel()` освобождает связанные timer resources при любом исходе. Сам механизм deadline и закрытия channel разобран в [[60 Go/select, cancellation и timeout|заметке о select и cancellation]].

## Concurrency invariants

- После проверки уже отменённого context создаётся ровно одна worker goroutine и один result channel ёмкостью `1`; child timer создаётся не больше одного.
- Worker выполняет ровно одну отправку, поэтому buffer `1` достаточен и не скрывает unbounded queue.
- Caller читает не больше одного result и возвращается после одной выбранной `select` case.
- `defer cancel()` выполняется при success, parent cancellation и timeout.
- Timeout ограничивает ожидание `Call`, но не lifetime worker; leak-freedom зависит от того, вернётся ли `fn`.
- `started` вычисляется до создания child context, поэтому elapsed включает setup wrapper и ожидание выбранного исхода.

## Код Go 1.26.5

`timeoutwrap.go`:

```go
package timeoutwrap

import (
	"context"
	"errors"
	"time"
)

type Func func() int64

// Call limits how long the caller waits. It cannot stop fn itself.
func Call(ctx context.Context, timeout time.Duration, fn Func) (int64, time.Duration, error) {
	if timeout <= 0 {
		return 0, 0, errors.New("timeout must be positive")
	}
	if fn == nil {
		return 0, 0, errors.New("function is required")
	}

	started := time.Now()
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return 0, time.Since(started), err
	}

	resultCh := make(chan int64, 1)
	go func() {
		resultCh <- fn()
	}()

	select {
	case result := <-resultCh:
		return result, time.Since(started), nil
	case <-ctx.Done():
		return 0, time.Since(started), ctx.Err()
	}
}
```

## Tests

`timeoutwrap_test.go`:

```go
package timeoutwrap

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
)

func TestCallReturnsFastResult(t *testing.T) {
	got, elapsed, err := Call(context.Background(), time.Second, func() int64 { return 42 })
	if err != nil || got != 42 {
		t.Fatalf("Call() = (%d, %v, %v)", got, elapsed, err)
	}
	if elapsed >= time.Second {
		t.Fatalf("elapsed = %v, want less than timeout", elapsed)
	}
}

func TestCallTimesOutAndWrappedFunctionCanFinish(t *testing.T) {
	release := make(chan struct{})
	finished := make(chan struct{})
	_, _, err := Call(context.Background(), 20*time.Millisecond, func() int64 {
		defer close(finished)
		<-release
		return 7
	})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Call() error = %v, want deadline exceeded", err)
	}

	close(release)
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("wrapped function did not finish")
	}
}

func TestCallHonorsEarlierParentCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var called atomic.Bool
	_, _, err := Call(ctx, time.Second, func() int64 {
		called.Store(true)
		return 1
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Call() error = %v, want context canceled", err)
	}
	if called.Load() {
		t.Fatal("function started after parent cancellation")
	}
}
```

## Проверка результата

Первый test получает `42` раньше секундного timeout. Второй удерживает function дольше `20 ms`, получает `DeadlineExceeded`, затем разрешает самой function завершиться; единственная поздняя отправка помещается в свободный buffer. Третий test подтверждает, что уже отменённый parent context не запускает вычисление.

Код прошёл `go test`, `go vet` и `go test -race` на Go 1.26.5 `darwin/arm64`, проверено 2026-07-18.

## Почему измерение времени записано именно так

Нужно сначала сохранить `started := time.Now()`, а при выбранном исходе вычислить `time.Since(started)`. Аргументы deferred call вычисляются в момент выполнения `defer`, поэтому конструкция вроде `defer fmt.Println(time.Since(time.Now()))` почти сразу зафиксирует duration около нуля и напечатает уже это значение при возврате. Closure в `defer func() { fmt.Println(time.Since(started)) }()` вычислила бы `Since` позже, но здесь duration входит в result, поэтому явные return branches проще.

## Сложность и ресурсы

На начатое вычисление требуется `O(1)` CPU bookkeeping, один channel, одна goroutine и не больше одного timer child context. Уже отменённый context возвращает error до создания goroutine. При success ресурсы освобождаются после возврата worker. После timeout channel выдерживает одно позднее сообщение, однако goroutine и захваченные `fn` resources живут до фактического завершения function.

Если `fn` может зависнуть навсегда, повторные timeout calls создают unbounded число goroutines: memory растёт `O(number of never-returning calls)`. Это [[60 Go/Goroutine и channel leaks|goroutine leak]], а не полноценная cancellation.

## Trade-offs и альтернативы

- Лучший API — `func(context.Context) (int64, error)`: operation сама проводит cancellation до blocking boundary и возвращает причину failure.
- Для network I/O нужны socket/client deadlines, а context задаёт end-to-end budget. Один внешний timer не прерывает произвольный syscall или библиотеку, которая не поддерживает отмену.
- Если чужая function неотменяема, но гарантированно bounded, wrapper ограничивает latency caller и buffer предотвращает channel leak. Гарантию bounded времени нужно получить из API/документации, а не предположить.
- Если недоверенная операция может зависнуть или удерживать глобальный lock, безопаснее вынести её в отдельный process и завершать process по deadline. Это дороже, но создаёт реальную isolation boundary.
- Pool фиксированного размера ограничит число одновременно зависших workers и даст backpressure, но не освободит уже зависшие workers; после исчерпания pool система перестанет принимать работу.

## Типичные ошибки

- **Считать, что timeout останавливает `fn` → после каждого timeout число goroutines растёт → wrapper прекратил только ожидание → передавать context внутрь операции или изолировать её в process.**
- **Использовать unbuffered result channel → завершившаяся после timeout function навсегда блокируется на send → receiver уже ушёл → buffer `1` для единственного позднего результата.**
- **Поставить большой buffer «на всякий случай» → protocol и memory bound становятся неясными → ёмкость не выведена из числа sends → buffer равен доказанному максимуму сообщений.**
- **Не вызвать `cancel` при быстром result → timer и ссылки живут до deadline → child context не освобождён раньше времени → всегда `defer cancel()` сразу после создания.**
- **Требовать детерминированный исход на точной границе → flaky test иногда видит result, иногда timeout → обе `select` cases готовы → не тестировать несуществующую гарантию либо проектировать явный arbitration protocol.**
- **Вернуть только `int64` → `0` результата неотличим от timeout → error channel потерян → возвращать result вместе с error.**

## Когда применять выводы

Такой wrapper допустим как адаптер над legacy API, когда function доказанно заканчивается, но caller не должен ждать весь срок. Он не подходит как защита от зависшей или враждебной работы. Ownership и ёмкость result channel подробнее разобраны в [[60 Go/Буферизация, ownership и закрытие каналов|заметке о channels]].

## Источники

- [[90 Вложения/Авито/Go.pdf|Backend платформа Go]] — предоставленное условие задачи «Timeout function», состояние материалов 2024 года, проверено 2026-07-18.
- [Package context](https://pkg.go.dev/context@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, `WithTimeout`, parent deadlines и обязанность вызывать cancel, проверено 2026-07-18.
- [Select statements](https://go.dev/ref/spec#Select_statements) — The Go Project, спецификация языка Go 1.26, выбор одной ready communication, проверено 2026-07-18.
- [Defer statements](https://go.dev/ref/spec#Defer_statements) — The Go Project, спецификация языка Go 1.26, момент вычисления function value и arguments, проверено 2026-07-18.
- [Package time](https://pkg.go.dev/time@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, duration, monotonic clock и timers, проверено 2026-07-18.
