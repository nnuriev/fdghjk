---
aliases:
  - State transitions
  - Finite state machine в LLD
  - Конечный автомат в Go
tags:
  - область/проектирование-систем
  - область/go
  - тема/объектное-проектирование
статус: черновик
---

# State transitions и конечный автомат

## TL;DR

Конечный автомат (finite state machine, FSM) задаёт допустимые пары `текущее состояние + событие`, guards и атомарный результат перехода. Его ценность не в enum, а в закрытом пути изменения: caller не ставит `Paid` напрямую, а отправляет `Pay`; компонент проверяет исходное состояние и предусловия, затем меняет все связанные поля одной операцией.

Сильный контракт гарантирует: недопустимое событие не меняет state, terminal state не имеет исходящих переходов, guard проверяется до mutation, а внешний side effect не выполняется под lock или посередине незавершённого перехода.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-18.
- GOOS и GOARCH: не влияют на модель; пример использует `sync.Mutex` для concurrent callers.
- Подходит для order, job, connection, subscription и других сущностей с конечным числом lifecycle states.
- Вне scope: durable distributed workflow с replay; этот уровень разобран в [[50 Проектирование систем/Проектирование планировщика задач и workflow engine|проектировании workflow engine]].

## Ментальная модель

Переход описывается как частичная функция:

```text
transition(state, event, data) -> (new state, updates, error)
```

`error` означает, что observable state остался прежним. Guards проверяют данные, например наличие строк заказа или payment reference. Actions меняют связанные поля. Для успешного перехода порядок один: прочитать согласованный state, проверить маршрут и guards, подготовить все изменения, атомарно записать state и поля, вернуть immutable transition record.

Таблица для минимального order:

| From | Event | Guard | To |
| --- | --- | --- | --- |
| `Draft` | `Submit` | `items > 0` | `AwaitingPayment` |
| `Draft` | `Cancel` | нет | `Cancelled` |
| `AwaitingPayment` | `Pay` | `paymentID != ""` | `Paid` |
| `AwaitingPayment` | `Cancel` | нет | `Cancelled` |

`Paid` и `Cancelled` terminal: строк с ними в колонке `From` нет.

## Как устроено

Состояние хранится в одном поле, а не в наборе независимых flags. Метод `Apply` остаётся единственной mutation boundary. Он защищает state, revision и данные перехода тем же lock; это частный случай [[50 Проектирование систем/Concurrency safety Go-компонента|concurrency safety компонента]].

Публичный `Snapshot` берёт тот же mutex и возвращает immutable value со state, payment identity и revision. Поэтому black-box test и caller могут проверить результат перехода, не получая mutable alias и не читая внутренние поля.

`Order` содержит `sync.Mutex`, поэтому его нельзя копировать после первого использования. Публичный contract требует хранить и передавать только `*Order`, который вернул `New`; callers не должны разыменовывать pointer в новое value, передавать `Order` по значению или embed-ить его как value. Mutation API использует только pointer receivers.

`revision` делает порядок наблюдаемым и пригодится при persistence: update можно выполнить как compare-and-swap `WHERE revision = expected`. Если изменение state и публикация события должны пережить crash, одной памяти уже мало: state и outbox record пишут в одной database transaction, а publisher работает отдельно.

Внешний payment call нельзя прятать внутрь `Apply(Pay)`. Сначала workflow получает подтверждённый outcome от provider, затем применяет предметное событие с устойчивым `paymentID`. Иначе timeout оставит неясность: внешний эффект мог произойти, а локальный state остался прежним.

## Код

```go
package order

import (
	"errors"
	"sync"
)

type State string
type EventKind string

const (
	Draft           State = "draft"
	AwaitingPayment State = "awaiting_payment"
	Paid            State = "paid"
	Cancelled       State = "cancelled"

	Submit EventKind = "submit"
	Pay    EventKind = "pay"
	Cancel EventKind = "cancel"
)

var (
	ErrInvalidTransition = errors.New("invalid transition")
	ErrGuard             = errors.New("transition guard failed")
	ErrInvalidItems      = errors.New("items must not be negative")
)
type Event struct {
	Kind      EventKind
	PaymentID string
}
type Transition struct {
	From, To State
	Event    EventKind
	Revision uint64
}
type Snapshot struct {
	State     State
	PaymentID string
	Revision  uint64
}
type Order struct {
	mu        sync.Mutex
	state     State
	items     int
	paymentID string
	revision  uint64
}
func New(items int) (*Order, error) {
	if items < 0 {
		return nil, ErrInvalidItems
	}
	return &Order{state: Draft, items: items}, nil
}

func (o *Order) Snapshot() Snapshot {
	o.mu.Lock()
	defer o.mu.Unlock()
	return Snapshot{State: o.state, PaymentID: o.paymentID, Revision: o.revision}
}

func (o *Order) Apply(e Event) (Transition, error) {
	o.mu.Lock()
	defer o.mu.Unlock()

	from := o.state
	var to State
	switch {
	case from == Draft && e.Kind == Submit:
		if o.items <= 0 { return Transition{}, ErrGuard }
		to = AwaitingPayment
	case from == Draft && e.Kind == Cancel:
		to = Cancelled
	case from == AwaitingPayment && e.Kind == Pay:
		if e.PaymentID == "" { return Transition{}, ErrGuard }
		to = Paid
	case from == AwaitingPayment && e.Kind == Cancel:
		to = Cancelled
	default:
		return Transition{}, ErrInvalidTransition
	}

	if e.Kind == Pay { o.paymentID = e.PaymentID }
	o.state = to
	o.revision++
	return Transition{From: from, To: to, Event: e.Kind, Revision: o.revision}, nil
}
```

## Ожидаемый результат

Для order, созданного через `New(1)`, начальный `Snapshot` равен `{State: Draft, PaymentID: "", Revision: 0}`. `Submit` возвращает `Draft -> AwaitingPayment, revision=1`; повторный `Submit` возвращает `ErrInvalidTransition`, а `Snapshot` остаётся прежним. `Pay` с `paymentID="tx-7"` возвращает `AwaitingPayment -> Paid, revision=2`; последующий `Cancel` отклоняется и сохраняет paid snapshot. `New(-1)` возвращает `ErrInvalidItems`. Так сохранность `state`, `paymentID` и `revision` после любого rejected transition наблюдаема через public API.

Код и table tests не выполнены: в доступной среде нет локальной toolchain Go. До запуска на Go 1.26.5 заметка остаётся `черновик`.

## Trade-offs

- `switch` держит маленький автомат рядом с предметными guards и хорошо читается. Декларативная таблица уменьшает boilerplate для десятков однотипных переходов, но callbacks в таблице могут спрятать порядок mutation.
- Enum плюс один transition method проще [[50 Проектирование систем/Паттерны Strategy, Adapter, Factory, Decorator, Observer и State в Go#State|паттерна State]], пока поведение states мало. State objects окупаются, когда у каждого состояния много разных операций.
- In-memory lock даёт атомарность внутри процесса. Database CAS защищает от нескольких processes, но требует обработки conflict/retry и не делает внешний API-вызов транзакционным.

## Типичные ошибки

- **Неверное предположение:** набор boolean flags эквивалентен state. **Симптом:** одновременно `paid=true` и `cancelled=true`. **Причина:** допустимые комбинации не закодированы. **Исправление:** один state и закрытая transition function.
- **Неверное предположение:** guard можно проверить после записи state. **Симптом:** ошибка возвращена из уже изменённой сущности. **Причина:** переход выполнен частично. **Исправление:** сначала проверить все предусловия, затем commit.
- **Неверное предположение:** setter `SetState` упрощает API. **Симптом:** caller обходит guards и audit. **Причина:** API экспортирует representation вместо события. **Исправление:** методы или events предметного языка.
- **Неверное предположение:** observer можно вызвать под lock. **Симптом:** deadlock, reentrancy либо длинная critical section. **Причина:** неизвестный код включён в атомарный переход. **Исправление:** вернуть transition record и доставить его после commit.

## Когда применять

FSM нужен, когда корректность зависит от истории, а список состояний конечен и обозрим. На интервью сначала выпишите таблицу переходов, terminal states и guards, затем покажите один rejected trace и один successful trace. Для процесса с timers, retries, внешними effects и crash recovery переходите к durable workflow, не раздувая entity в скрытый оркестратор.

## Источники

- [State Machine Workflows](https://learn.microsoft.com/en-us/dotnet/framework/windows-workflow-foundation/state-machine-workflows) — Microsoft, официальная документация Windows Workflow Foundation, проверено 2026-07-18.
- [Unified Modeling Language 2.5.1](https://www.omg.org/spec/UML) — Object Management Group, UML 2.5.1, декабрь 2017, проверено 2026-07-18.
- [Tactical Domain-Driven Design](https://learn.microsoft.com/en-us/azure/architecture/microservices/model/tactical-domain-driven-design) — Microsoft, Azure Architecture Center, проверено 2026-07-18.
- [Package sync](https://pkg.go.dev/sync@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
