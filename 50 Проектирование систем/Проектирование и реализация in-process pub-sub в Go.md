---
aliases:
  - In-process pub-sub в Go
  - Локальный broker в Go
tags:
  - область/go
  - тема/низкоуровневое-проектирование
статус: черновик
---

# Проектирование и реализация in-process pub-sub в Go

## TL;DR

Вопрос заметки: как внутри одного процесса доставить каждое опубликованное значение всем активным subscribers, не позволив одному медленному subscriber остановить остальных? Broker хранит отдельный bounded channel на subscription и при `Publish` делает non-blocking send в каждый. Полная очередь означает явный drop, который возвращается в результате операции.

Один общий channel не реализует pub-sub: несколько receivers делят сообщения между собой, то есть образуют fan-out worker pool. Копия для каждого subscriber появляется только при отдельной очереди. Persistence, replay, consumer groups и межпроцессная доставка относятся к [[40 Распределённые системы/Очереди, streams, группы потребителей и DLQ|распределённым очередям и streams]] и [[50 Проектирование систем/Проектирование event ingestion pipeline|event ingestion pipeline]].

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-18.
- Пакеты: `sync`, channels.
- Scope: typed messages, process-local subscriptions, bounded buffers, at-most-once best-effort delivery, явный drop count.
- Вне scope: replay, persistence, retry, acknowledgement, wildcard topics и delivery между processes.

Код статически разобран, но не выполнен из-за отсутствия локальной Go toolchain; заметка остаётся черновиком.

## Ментальная модель

Broker — не очередь, а набор очередей. `Publish(v)` проходит по snapshot активных subscriptions под read lock и для каждой независимо выбирает `delivered` либо `dropped`. Успешная отправка передаёт значение в channel; неуспешная ничего не запоминает для retry.

Контракт здесь at-most-once: после успешной отправки broker не знает, обработал ли subscriber значение. После drop или restart восстановить сообщение нельзя.

## Public API и контракт

```go
func NewBroker[T any]() *Broker[T]
func (b *Broker[T]) Subscribe(buffer int) (*Subscription[T], error)
func (b *Broker[T]) Publish(value T) (PublishResult, error)
func (b *Broker[T]) Close()

func (s *Subscription[T]) Values() <-chan T
func (s *Subscription[T]) Close()
```

- `buffer >= 0`; нулевой buffer означает rendezvous и почти всегда drop без уже ожидающего receiver.
- Каждый активный subscriber получает не более одной копии конкретного `Publish`.
- Последовательные вызовы одного publisher наблюдаются его subscriber в том же порядке, если оба доставлены. Между конкурентными publishers общего порядка нет.
- `Subscription.Close` и `Broker.Close` идемпотентны. Закрывает channel только broker, subscriber его не закрывает напрямую.
- После `Broker.Close` новые subscribe/publish возвращают `ErrClosed`, существующие channels закрыты.
- `Broker` и `Subscription` используют только через pointers из constructors и не копируют после первого вызова: оба содержат synchronization state.

## Инварианты, ownership и lifecycle

Под `mu` каждому ID соответствует ровно один открытый channel. `Publish` держит `RLock` до окончания всех non-blocking sends; unsubscribe/close берут `Lock`, поэтому channel нельзя закрыть одновременно с send.

Channel принадлежит broker, receive — subscriber. Передаваемое `T` не копируется глубоко: map, slice и pointer должны быть immutable после `Publish` либо явно копироваться на границе. Внутренних goroutines нет, значит broker не создаёт скрытый lifecycle и не может протечь из-за забытых subscribers; забытая subscription всё же удерживает channel и buffered values до `Close` broker.

State transition subscription:

```text
absent --Subscribe--> active --Subscription.Close--> canceled
                              \--Broker.Close------> closed
```

## Минимальная реализация

```go
package main

import (
	"errors"
	"fmt"
	"sync"
)

var (
	ErrClosed = errors.New("broker closed")
	ErrBuffer = errors.New("buffer must not be negative")
)

type PublishResult struct {
	Delivered int
	Dropped   int
}

type Broker[T any] struct {
	mu     sync.RWMutex
	nextID uint64
	subs   map[uint64]chan T
	closed bool
	once   sync.Once
}

type Subscription[T any] struct {
	values <-chan T
	cancel func()
	once   sync.Once
}

func NewBroker[T any]() *Broker[T] {
	return &Broker[T]{subs: make(map[uint64]chan T)}
}

func (b *Broker[T]) Subscribe(buffer int) (*Subscription[T], error) {
	if buffer < 0 {
		return nil, ErrBuffer
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return nil, ErrClosed
	}
	b.nextID++
	id, ch := b.nextID, make(chan T, buffer)
	b.subs[id] = ch
	return &Subscription[T]{values: ch, cancel: func() { b.unsubscribe(id) }}, nil
}

func (b *Broker[T]) Publish(value T) (PublishResult, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	if b.closed {
		return PublishResult{}, ErrClosed
	}
	var result PublishResult
	for _, ch := range b.subs {
		select {
		case ch <- value:
			result.Delivered++
		default:
			result.Dropped++
		}
	}
	return result, nil
}

func (b *Broker[T]) unsubscribe(id uint64) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if ch, ok := b.subs[id]; ok {
		delete(b.subs, id)
		close(ch)
	}
}

func (b *Broker[T]) Close() {
	b.once.Do(func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		b.closed = true
		for id, ch := range b.subs {
			delete(b.subs, id)
			close(ch)
		}
	})
}

func (s *Subscription[T]) Values() <-chan T { return s.values }
func (s *Subscription[T]) Close() { s.once.Do(s.cancel) }

func main() {
	b := NewBroker[int]()
	fast, _ := b.Subscribe(1)
	slow, _ := b.Subscribe(0)
	result, _ := b.Publish(42)

	fmt.Println(result.Delivered, result.Dropped)
	fmt.Println(<-fast.Values())
	slow.Close()
	b.Close()
	_, open := <-fast.Values()
	fmt.Println(open)
}
```

## Ожидаемый результат и trace

```text
1 1
42
false
```

Buffered subscriber принимает `42`; у unbuffered subscriber нет ожидающего receiver, поэтому его delivery отбрасывается. После `Close` канал `fast` закрыт. Это проверяет overload policy, но не конкурентные interleavings; код ещё не запускался с `-race`.

## Complexity

`Subscribe` и unsubscribe имеют среднюю сложность `O(1)`. `Publish` — `O(S)` по числу subscribers; память — `O(S + сумма capacity)`. Read lock допускает конкурентные publishers, но каждый проходит все channels.

## Trade-offs

- Non-blocking drop изолирует slow subscriber и ограничивает память, но теряет события. Blocking publish сохраняет их только ценой head-of-line blocking всех subscribers.
- Отдельная goroutine/неограниченная очередь на subscriber скрыла бы drop, но перенесла перегрузку в память и goroutine stacks. Bounded buffer оставляет [[60 Go/Backpressure|backpressure policy]] явной.
- Callback-based Observer проще по API, но callback может паниковать, re-enter broker или долго держать publisher. Channel отделяет выполнение, хотя не даёт acknowledgement.
- Copy-on-write snapshot сокращает время под lock для read-heavy workloads, но усложняет subscription changes и ownership channels.

## Типичные ошибки

- Предположение: «несколько receivers общего channel — subscribers» → каждое событие видит только один receiver → channel распределяет work → создайте очередь на subscription.
- Предположение: «buffer устраняет slow consumer» → спустя время он заполняется → средний consume rate ниже publish rate → выберите drop, coalesce, disconnect или durable backlog.
- Предположение: «можно закрыть channel со стороны subscriber» → panic у concurrent publisher → ownership закрытия разделён → subscriber вызывает cancel, закрывает только broker.
- Предположение: «отправленный slice уже изолирован» → subscribers видят последующую мутацию или data race → channel копирует header, не backing array → используйте immutable payload или clone.
- Предположение: «delivered означает processed» → событие теряется после receive/crash → acknowledgement отсутствует → для processing guarantees нужен другой компонент.

## Когда применять

Подходит для process-local notifications, invalidation hints, UI/event hooks и optional telemetry, если loss явно допустим. Не используйте для денежных операций, workflow или аудита, где требуются replay и подтверждённая обработка.

## Источники

- [Go Language Specification — Channel types](https://go.dev/ref/spec#Channel_types) — The Go Project, language version Go 1.26, проверено 2026-07-18.
- [Go Language Specification — Send statements](https://go.dev/ref/spec#Send_statements) — The Go Project, language version Go 1.26, проверено 2026-07-18.
- [Go Language Specification — Select statements](https://go.dev/ref/spec#Select_statements) — The Go Project, language version Go 1.26, проверено 2026-07-18.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-18.
- [Go Concurrency Patterns: Pipelines and cancellation](https://go.dev/blog/pipelines) — The Go Project, публикация 2014-03-13, проверено 2026-07-18.
- [Package sync](https://pkg.go.dev/sync@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
