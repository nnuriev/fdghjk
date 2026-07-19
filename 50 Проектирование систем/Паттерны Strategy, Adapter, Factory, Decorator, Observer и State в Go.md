---
aliases:
  - Go design patterns
  - Strategy Adapter Factory Decorator Observer State Go
tags:
  - область/проектирование-систем
  - область/go
  - тема/паттерны
статус: черновик
---

# Паттерны Strategy, Adapter, Factory, Decorator, Observer и State в Go

## TL;DR

Паттерн полезен, когда называет конкретную ось изменения. Strategy меняет алгоритм, Adapter переводит чужой contract, Factory централизует создание, Decorator оборачивает тот же contract, Observer доставляет событие подписчикам, State меняет поведение вместе с lifecycle объекта.

В Go эти роли обычно выражаются functions, маленькими interfaces и composition. Иерархия классов не нужна. Сначала пишут прямой код; abstraction вводят, когда уже видны две политики, внешняя несовместимая boundary, повторяемая обёртка либо реальный state machine.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-18.
- GOOS и GOARCH: не влияют.
- Область: in-process component design; distributed pub/sub и durable workflows требуют дополнительных guarantees.

## Ментальная модель

| Паттерн | Что меняется | Типичная форма в Go | Ближайшая альтернатива |
| --- | --- | --- | --- |
| Strategy | algorithm/policy | function type или маленький interface | локальный `switch` |
| Adapter | форма чужого API | wrapper type/function | протащить vendor type внутрь domain |
| Factory | выбор и проверка при создании | `New...` function | struct literal у caller |
| Decorator | cross-cutting behavior вокруг contract | wrapper с тем же interface | изменить core implementation |
| Observer | fan-out событий | subscription + callback/channel | прямой вызов одного collaborator |
| State | поведение по lifecycle state | enum + transition method либо state object | flags и разбросанные conditions |

Паттерны не обязаны занимать отдельные packages. Если Strategy используется в одном месте, named function рядом с consumer честнее `strategies/` с десятком типов.

## Как устроено

### Strategy

Caller или composition root передаёт policy; core вызывает её через стабильный contract. Function type подходит для одной операции, interface — для связного набора методов. Стандартный пример: `slices.SortFunc` получает comparison strategy. Strategy оправдана, когда алгоритм меняется независимо от orchestration; одна ветка `if` abstraction не требует.

### Adapter

Adapter переводит внешний тип, ошибки и единицы в локальный contract. `http.HandlerFunc` официально адаптирует обычную function к `http.Handler`. На архитектурной boundary adapter также не даёт vendor errors/types протечь в domain. В отличие от Decorator, его входной и выходной contracts различаются.

### Factory

Обычная Go factory — named constructor или selector function: валидирует config, устанавливает invariants и выбирает concrete implementation. Это не обязательно GoF Factory Method, где subclass переопределяет создание продукта. В Go ту же вариативность чаще выражают функцией и composition. Constructor возвращает concrete type, если скрытие нескольких implementations не входит в API.

`Core` не имеет пригодного zero value: у `Core{}` поля `rule` и `save` равны nil, поэтому `Handle` завершится panic. Public contract требует создавать core только через успешно завершившийся `NewCore` и использовать возвращённый `*Core`; прямой struct literal и `new(Core)` не поддерживаются.

### Decorator

Decorator принимает и возвращает тот же behavioral contract. Так добавляют metrics, tracing, authorization или retry вокруг core. Порядок обёрток наблюдаем: `retry(metrics(core))` измеряет attempts, а `metrics(retry(core))` — одну logical operation. `io.LimitReader` и `io.TeeReader` сохраняют contract `io.Reader`, добавляя ограничение либо копирование прочитанных bytes.

Проверка `next == nil` отсекает только nil interface. Public contract `WithAudit` отдельно запрещает typed-nil implementation: caller должен передать non-nil handler, например `*Core` из успешно завершившегося `NewCore`. Для одной операции named function type, как `HandlerFunc`, даёт более узкий contract, но его nil value тоже нельзя упаковывать в interface и вызывать.

### Observer

Subject хранит subscriptions и сообщает об event. Contract обязан назвать sync/async delivery, ordering, reentrancy, unsubscribe, backpressure и поведение при panic/error subscriber. Для thread-safe subject список subscribers копируют под lock, а callbacks вызывают после unlock. `http.Server.RegisterOnShutdown` показывает lifecycle registration; документация отдельно предупреждает, что `Shutdown` не ждёт завершения этих functions.

Observer не равен brokered pub/sub: in-process subject обычно знает registrations и делит судьбу процесса, а broker добавляет persistence, redelivery, consumer groups и lag.

### State

State меняет допустимое поведение вслед за внутренним lifecycle. Strategy обычно выбирается снаружи и остаётся policy; State изменяется через события самого объекта. Для небольшого автомата enum и один `Apply` проще набора state objects. Когда у каждого state много операций, отдельные implementations могут уменьшить conditions. Guards и terminal states разобраны в [[50 Проектирование систем/State transitions и конечный автомат|заметке о конечном автомате]].

## Код

```go
package design

import (
	"context"
	"errors"
	"fmt"
)

type Request struct{ Amount int }
type Rule func(Request) error                 // Strategy
type Save func(context.Context, Request) error

var ErrRejected = errors.New("rejected")

func NewRule(kind string, limit int) (Rule, error) { // Factory
	if limit < 0 { return nil, errors.New("negative limit") }
	switch kind {
	case "max":
		return func(r Request) error {
			if r.Amount < 0 || r.Amount > limit { return ErrRejected }
			return nil
		}, nil
	default:
		return nil, fmt.Errorf("unknown rule %q", kind)
	}
}

type Handler interface {
	Handle(context.Context, Request) error
}

type HandlerFunc func(context.Context, Request) error // Adapter
func (f HandlerFunc) Handle(ctx context.Context, r Request) error { return f(ctx, r) }

type Core struct {
	rule Rule
	save Save
}

func NewCore(rule Rule, save Save) (*Core, error) {
	if rule == nil || save == nil {
		return nil, errors.New("rule and save are required")
	}
	return &Core{rule: rule, save: save}, nil
}
func (c *Core) Handle(ctx context.Context, r Request) error {
	if err := c.rule(r); err != nil { return err }
	return c.save(ctx, r)
}

func WithAudit(next Handler, record func(error)) (Handler, error) { // Decorator
	// The contract forbids a typed-nil Handler; this checks a nil interface.
	if next == nil || record == nil {
		return nil, errors.New("next and record are required")
	}
	return HandlerFunc(func(ctx context.Context, r Request) error {
		err := next.Handle(ctx, r)
		record(err)
		return err
	}), nil
}
```

## Ожидаемый результат

`NewRule("max", 1000)` создаёт policy, затем `NewCore(rule, save)` возвращает non-nil `*Core`; zero value `Core` не входит в API. `WithAudit(core, record)` проверяет nil interface и nil function, после чего возвращает decorator. Caller по contract не передаёт typed-nil handler: такая interface value пройдёт `next == nil` и позже panic на `next.Handle`. Для amount `700` decorator вызывает `save` и затем `record(nil)`; для `1500` возвращает `ErrRejected`, не вызывает `save` и передаёт ошибку в `record`. Отрицательные limit и amount отклоняются. Порядок audit после core входит в выбранную semantics decorator.

Код не выполнен: локальная toolchain Go недоступна. До compile/test на Go 1.26.5 статус остаётся `черновик`.

## Trade-offs

- Паттерн делает variation point явным, но добавляет indirect call и новые имена. Если изменение локально, прямой branch легче читать.
- Decorator хорошо комбинируется, пока порядок обёрток документирован. Глубокая цепочка затрудняет error ownership и profiling.
- Observer снижает прямое coupling publisher/subscribers, но повышает temporal coupling: эффект труднее проследить. Для одного обязательного collaborator прямой вызов яснее.
- State objects локализуют behavior, но переходы между objects могут стать менее обозримыми, чем одна таблица FSM.

## Типичные ошибки

- **Неверное предположение:** любое различие требует Strategy. **Симптом:** interface с одной implementation и один caller. **Причина:** variation угадан заранее. **Исправление:** оставить branch, извлечь policy после второго реального use case.
- **Неверное предположение:** Adapter должен повторять vendor API. **Симптом:** domain зависит от vendor types. **Причина:** wrapper делегирует без перевода contract. **Исправление:** локальные values, errors и semantics на boundary.
- **Неверное предположение:** Factory скрывает любой constructor. **Симптом:** callers не могут использовать возможности concrete type. **Причина:** без причины возвращён interface. **Исправление:** concrete return по умолчанию.
- **Неверное предположение:** `next == nil` отклоняет typed-nil implementation. **Симптом:** `WithAudit` успешно возвращает decorator, а `Handle` panic. **Причина:** [[60 Go/Nil, type assertions и type switches в интерфейсах|interface хранит non-nil dynamic type и nil dynamic value]]. **Исправление:** не передавать typed nil; собирать handler из результата успешного constructor, а для одной операции рассмотреть function contract.
- **Неверное предположение:** Observer callback безопасен под lock. **Симптом:** deadlock/reentrancy. **Причина:** чужой код выполняется в critical section. **Исправление:** immutable event и snapshot subscribers, вызов после unlock.
- **Неверное предположение:** Decorator order неважен. **Симптом:** metrics или retry считают другой outcome. **Причина:** composition меняет observable boundary. **Исправление:** зафиксировать порядок тестом.

## Когда применять

На интервью назовите axis of change, ближайшую прямую альтернативу и цену indirection. После этого покажите public contract, constructor/wiring и один failure path. Название паттерна без объяснения, какое изменение он изолирует, архитектурным аргументом не служит.

## Источники

- [Design Patterns: Elements of Reusable Object-Oriented Software](https://www.pearson.com/en-us/subject-catalog/p/design-patterns-elements-of-reusable-object-oriented-software/P200000009480/9780321700698) — Erich Gamma, Richard Helm, Ralph Johnson, John Vlissides; Addison-Wesley, 1994, проверено 2026-07-18.
- [Package slices: SortFunc](https://pkg.go.dev/slices@go1.26.5#SortFunc) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Package net/http: HandlerFunc and RegisterOnShutdown](https://pkg.go.dev/net/http@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Package io: LimitReader and TeeReader](https://pkg.go.dev/io@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Go Code Review Comments: Interfaces](https://go.dev/wiki/CodeReviewComments#interfaces) — The Go Project, проверено 2026-07-18.
