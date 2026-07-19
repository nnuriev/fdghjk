---
aliases:
  - Concurrency safety Go component
  - Потокобезопасность Go-компонента
tags:
  - область/проектирование-систем
  - область/go
  - тема/конкурентность
статус: черновик
---

# Concurrency safety Go-компонента

## TL;DR

Concurrency-safe компонент сохраняет предметные инварианты при любом допустимом чередовании вызовов. Отсутствия data race для этого мало: код может синхронно и без гонок дважды списать один ресурс, зависнуть на callback под lock или вернуть наружу alias внутренней map.

Сначала задают владельца состояния, инварианты и linearization point каждой операции. Затем весь связанный mutable state защищают одним понятным protocol: mutex для коротких синхронных операций либо owner goroutine и channel для передачи команд. Публичный контракт отдельно фиксирует, какие методы можно вызывать конкурентно, кому принадлежат возвращённые данные и как компонент останавливается.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-18.
- GOOS и GOARCH: гарантии memory model и `sync.Mutex` платформонезависимы; стоимость contention зависит от workload и платформы.
- Компоненты: structs с mutable state, `sync`, channels, callbacks и публичный concurrent API.
- Вне scope: lock-free algorithms и распределённая конкурентность между процессами.

## Ментальная модель

Проверка идёт по четырём слоям:

1. **State ownership:** кто вправе читать и менять каждую часть состояния.
2. **Safety invariant:** какие состояния запрещены независимо от scheduling.
3. **Synchronization:** какой documented edge публикует изменения другим goroutines согласно [[60 Go/Модель памяти Go и happens-before|модели памяти Go]].
4. **Liveness:** может ли операция завершиться при callback, cancellation, shutdown и saturation.

Mutex защищает инвариант, а не отдельное поле. Если `used` равно сумме активных leases, map и счётчик меняются в одной critical section. Linearization point операции `Acquire` находится в моменте совместной записи lease и нового `used`: любой конкурентный вызов можно мысленно расположить до либо после этой точки.

## Как устроено

Для in-memory компонента полезно письменно зафиксировать:

- `0 <= used <= limit`;
- `used == sum(leases)`;
- один `id` соответствует не более чем одному активному lease;
- ошибка не меняет состояние;
- возвращённый snapshot не даёт caller доступ к внутренней map;
- пользовательский код и blocking I/O не выполняются под lock.

Один `sync.Mutex` часто лучше нескольких locks: proof помещается в одну critical section. Делить lock стоит после профиля и только вместе с новыми независимыми инвариантами. `RWMutex` сам по себе не ускоряет reads; решение требует измерения, как разобрано в [[60 Go/Mutex, RWMutex и примитивы координации sync|заметке о примитивах sync]].

`Limiter` содержит `sync.Mutex`, поэтому его нельзя копировать после первого использования. Публичный contract требует хранить и передавать только `*Limiter`, который вернул `New`; callers не должны разыменовывать pointer в новое value, передавать `Limiter` по значению или embed-ить его как value. Все методы используют pointer receivers.

Channel выбирают, когда очередь, ordering, backpressure и lifecycle входят в контракт. Для короткого доступа к map owner goroutine с request/reply protocol обычно сложнее mutex; критерий выбора разобран в [[60 Go/Каналы или mutex|сравнении channels и mutex]].

## Код

```go
package limiter

import (
	"errors"
	"sync"
)

var (
	ErrInvalidLimit = errors.New("limit must not be negative")
	ErrInvalidLease = errors.New("invalid lease")
	ErrDuplicate    = errors.New("lease already exists")
	ErrCapacity     = errors.New("capacity exceeded")
	ErrUnknown      = errors.New("unknown lease")
)

type Snapshot struct {
	Limit  int
	Used   int
	Leases map[string]int
}

type Limiter struct {
	mu     sync.Mutex
	limit  int
	used   int
	leases map[string]int
}

func New(limit int) (*Limiter, error) {
	if limit < 0 {
		return nil, ErrInvalidLimit
	}
	return &Limiter{limit: limit, leases: make(map[string]int)}, nil
}

func (l *Limiter) Acquire(id string, cost int) error {
	if id == "" || cost <= 0 {
		return ErrInvalidLease
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	if _, exists := l.leases[id]; exists {
		return ErrDuplicate
	}
	if cost > l.limit-l.used {
		return ErrCapacity
	}
	l.leases[id] = cost
	l.used += cost
	return nil
}

func (l *Limiter) Release(id string) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	cost, exists := l.leases[id]
	if !exists {
		return ErrUnknown
	}
	delete(l.leases, id)
	l.used -= cost
	return nil
}

func (l *Limiter) Snapshot() Snapshot {
	l.mu.Lock()
	defer l.mu.Unlock()
	leases := make(map[string]int, len(l.leases))
	for id, cost := range l.leases {
		leases[id] = cost
	}
	return Snapshot{Limit: l.limit, Used: l.used, Leases: leases}
}
```

## Ожидаемый результат

`limiter, err := New(10)` должен вернуть non-nil pointer и `nil`; `New(-1)` возвращает `ErrInvalidLimit`. `Acquire("", 1)` и `Acquire("x", 0)` возвращают machine-readable `ErrInvalidLease` без изменения snapshot. Для любого interleaving успешных `Acquire` выполняется `Used <= Limit`, duplicate и capacity errors тоже оставляют snapshot прежним, а изменение `Snapshot.Leases` caller-ом не меняет компонент. Тест должен запускать конкурентные acquire/release и проверяться командой `go test -race`.

Код не выполнен: в доступной среде нет локальной toolchain Go. Поэтому ожидаемый результат и отсутствие races пока не подтверждены исполнением, а статус заметки остаётся `черновик`.

## Trade-offs

- Один mutex упрощает доказательство атомарности, но сериализует операции. Sharding уменьшает contention ценой нескольких owners и сложного global snapshot.
- Copy-on-read закрывает aliasing, но стоит `O(n)` времени и памяти. Immutable value либо iterator под внутренним контролем могут быть дешевле, если API это допускает.
- Callback после unlock не удерживает lock, зато состояние может измениться до завершения callback. Передавайте immutable event с revision и задавайте delivery semantics отдельно.
- Atomic подходит для одного независимо интерпретируемого значения. Несколько полей с общим инвариантом требуют protocol; россыпь atomics не создаёт транзакцию.

## Типичные ошибки

- **Неверное предположение:** `-race` прошёл, значит компонент корректен. **Симптом:** два последовательных, но логически несовместимых обновления. **Причина:** detector ищет data races, а не предметные инварианты. **Исправление:** тестировать запрещённые состояния и linearization points.
- **Неверное предположение:** getter можно читать без lock. **Симптом:** race либо несовместимый snapshot полей. **Причина:** read участвует в том же invariant. **Исправление:** тот же lock или immutable published snapshot.
- **Неверное предположение:** callback безопасно вызвать под mutex. **Симптом:** deadlock или длинный tail latency. **Причина:** чужой код повторно входит в компонент либо блокируется. **Исправление:** собрать immutable event под lock, вызвать после unlock.
- **Неверное предположение:** возврат map только для чтения безопасен. **Симптом:** caller меняет внутреннее состояние без синхронизации. **Причина:** map передана по ссылке. **Исправление:** defensive copy или API без mutable alias.
- **Неверное предположение:** тип с mutex можно копировать. **Симптом:** разные копии lock защищают разделяемые aliases. **Причина:** `Mutex` нельзя копировать после первого использования. **Исправление:** pointer receiver, constructor возвращает pointer, компонент не копируют.

## Когда применять

На LLD-интервью для каждого mutable компонента назовите owner, invariants, linearization point, blocking operations и shutdown contract. Затем проверьте safety отдельно от progress по [[60 Go/Data races, deadlocks и livelocks|модели races, deadlocks и livelocks]]. Реализацию подтверждают table tests, stress test, `go test -race` и профиль contention; один удачный concurrent run доказательством не служит.

## Источники

- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, редакция 2022-06-06, применима к Go 1.26, проверено 2026-07-18.
- [Package sync](https://pkg.go.dev/sync@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Data Race Detector](https://go.dev/doc/articles/race_detector) — The Go Project, документация toolchain Go 1.26.5, проверено 2026-07-18.
- [Go Code Review Comments: Goroutine Lifetimes](https://go.dev/wiki/CodeReviewComments#goroutine-lifetimes) — The Go Project, проверено 2026-07-18.
