---
aliases: []
tags:
  - область/go
  - тема/конкурентность
статус: проверено
---

# Context, deadlines и распространение отмены

## TL;DR

`context.Context` переносит через API request-scoped deadline, cancellation signal, cause и редкие request-scoped values. `WithCancel`, `WithDeadline` и `WithTimeout` образуют дерево: отмена parent отменяет descendants; `WithoutCancel` намеренно разрывает наследование cancellation и deadline. Вызов `cancel` лишь публикует сигнал и освобождает связанные ресурсы; он не ждёт фактической остановки goroutines.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-15.
- GOOS и GOARCH: семантика API не зависит от платформы.
- Пакеты или компоненты runtime: `context`, `time`, закрытие канала `Done`.

## Ментальная модель

Context — immutable handle на ветвь дерева работы. Обычные derived contexts наследуют верхнюю границу времени parent и могут лишь сузить deadline или добавить локальную отмену. `WithoutCancel` — явный escape hatch, который создаёт новую ветвь без parent deadline и cancellation.

Context не «убивает» goroutine. Он закрывает `Done` и сохраняет ошибку. Блокирующая операция становится отменяемой, только если её protocol реально наблюдает context или выбирает `ctx.Done()` через [[60 Go/select, cancellation и timeout|`select`]]. Одного параметра `ctx` недостаточно; завершение остаётся кооперативным.

## Как устроено

`WithCancel`, `WithDeadline` и `WithTimeout` возвращают child и `CancelFunc`. Child завершается при первом из трёх событий: локальном cancel, parent cancellation или deadline. Более поздние причины уже не заменят первую.

Вызов `CancelFunc` удаляет связь child из parent и останавливает связанный timer. Поэтому `cancel` вызывают на всех путях, обычно через `defer`, даже если ожидается автоматический deadline. Неиспользованный cancel удерживает child и его descendants до отмены parent.

`WithCancelCause` отдельно хранит доменную причину. `ctx.Err()` остаётся стабильной классификацией (`context.Canceled` или `context.DeadlineExceeded`), а `context.Cause` возвращает исходную cause.

`WithoutCancel(parent)` сохраняет values, но возвращает context без deadline, ошибки и сигнала (`Done() == nil`). Работа с таким detached context должна получить нового владельца и собственный deadline; иначе shutdown parent её не ограничит.

Context передают первым параметром и не хранят в struct без особой причины. Values предназначены для request-scoped данных, проходящих границы API, а не для обязательных аргументов или options.

## Код

```go
package main

import (
	"context"
	"errors"
	"fmt"
	"time"
)

func main() {
	parent, cancelParent := context.WithCancelCause(context.Background())
	child, cancelChild := context.WithTimeout(parent, time.Hour)
	defer cancelChild()

	cancelParent(errors.New("shutdown"))
	<-child.Done()

	fmt.Println(context.Cause(child))
	fmt.Println(child.Err())
}
```

## Ожидаемый результат

```text
shutdown
context canceled
```

Parent отменён первым, поэтому child наследует cause `shutdown`; `Err` сообщает общий класс cancellation. Пример выполнен в официальном Go Playground на Go 1.26.5; вывод совпал с ожидаемым, проверено 2026-07-15.

## Trade-offs

- Context унифицирует cancellation между пакетами и стандартной библиотекой, но делает отмену кооперативной: код, игнорирующий `Done`, нарушает ожидаемый [[60 Go/Goroutines и lifecycle|lifecycle goroutine]] и не остановится.
- Локальный done channel проще внутри закрытого компонента. Context выигрывает на API-границах и при общем deadline дерева вызовов.
- `WithValue` устраняет прокидывание инфраструктурных request metadata через каждый слой, но скрывает зависимость от системы типов. Обязательные данные передавайте явно.

## Типичные ошибки

- Предположение: «`cancel()` дождался goroutines» → shutdown возвращается до освобождения ресурсов и маскирует [[60 Go/Goroutine и channel leaks|утечку]] → cancel только закрывает signal → отдельно ждите завершения.
- Предположение: «deadline child может продлить parent» → операция завершается раньше ожидаемого → эффективен самый ранний deadline → проверяйте parent budget перед созданием child.
- Предположение: «функция принимает context — значит любой её wait отменяем» → запрос зависает внутри `Mutex.Lock`, `RWMutex.Lock` или `Cond.Wait` → эти primitives не наблюдают context → меняйте ownership/protocol или выбирайте context-aware primitive.
- Предположение: «cancel можно не вызывать при timeout» → timers и descendants живут дольше операции → автоматическая отмена наступит лишь позже → всегда вызывайте возвращённый `CancelFunc`.
- Предположение: «context — контейнер параметров» → сигнатуры становятся неявными и возникают runtime type assertions → Values используйте только для request-scoped metadata с приватными ключами.

## Когда применять

Принимайте context в операциях, которые могут ждать в рамках запроса, и проектируйте I/O/channel protocol так, чтобы он действительно наблюдал отмену. Обычные `Mutex`, `RWMutex` и `Cond` сами по себе не context-aware: для отменяемого ожидания меняйте структуру владения или primitive. Передавайте тот же context вниз, сужая deadline только при отдельном локальном бюджете; для HTTP отдельно согласуйте его с [[60 Go/Тайм-ауты HTTP-сервера и клиента|тайм-аутами сервера и клиента]]. На границе владельца объединяйте cancel с явным ожиданием дочерних задач.

## Источники

- [Package context](https://pkg.go.dev/context@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
- [The Go Memory Model — Channel communication](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
