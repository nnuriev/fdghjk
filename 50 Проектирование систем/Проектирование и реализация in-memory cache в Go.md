---
aliases:
  - In-memory cache в Go
  - Локальный LRU cache с TTL
tags:
  - область/go
  - тема/низкоуровневое-проектирование
статус: черновик
---

# Проектирование и реализация in-memory cache в Go

## TL;DR

Вопрос заметки: как спроектировать process-local cache, который ограничивает число записей, вытесняет least recently used (LRU) ключ и не возвращает значение после TTL? Минимальный компонент — `map` плюс двусвязный список под одним `sync.Mutex`. Операции над обеими структурами образуют одну критическую секцию, поэтому ключ нельзя увидеть одновременно в двух состояниях.

Это ускоритель, а не источник истины. Eviction, истечение TTL и перезапуск процесса могут удалить значение в любой момент. Если нужны репликация, согласованная invalidation или переживающие отказ записи, это уже граница [[50 Проектирование систем/Проектирование distributed cache и KV store|distributed cache или durable KV]], а не расширение локального класса ещё одним флагом.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-18.
- GOOS и GOARCH: семантика не зависит от платформы; фактическая стоимость записи зависит от представления `K`, `V` и allocator.
- Пакеты: `container/list`, `sync`, `time`.
- Scope: один процесс, LRU по числу записей, optional TTL, линейризуемые отдельные операции `Get`, `Set`, `Delete`.
- Вне scope: ограничение по байтам, distributed invalidation, persistence, refresh-ahead, negative caching и атомарная загрузка из origin.

Код ниже статически разобран, но не выполнен: локальной Go toolchain нет. Поэтому заметка остаётся черновиком.

## Ментальная модель

`map` отвечает на вопрос «где запись», список — «какая запись использовалась раньше остальных». Front списка — most recently used, back — кандидат на eviction. Каждый hit меняет metadata, поэтому `Get` требует exclusive lock.

TTL задаёт visibility, а не обязательный момент освобождения памяти: после `expiresAt` `Get` обязан вернуть miss. Без фонового cleaner нетронутая истёкшая запись может занимать память до обращения или eviction.

Expiration order не совпадает с LRU order. Поэтому lazy-вариант может при `Set` вытеснить живой back, пока истёкший node остаётся ближе к front; это ухудшает hit ratio, но не нарушает visibility и capacity.

## Public API и контракт

```go
type Cache[K comparable, V any]

func NewCache[K comparable, V any](capacity int, now func() time.Time) (*Cache[K, V], error)
func (c *Cache[K, V]) Get(key K) (V, bool)
func (c *Cache[K, V]) Set(key K, value V, ttl time.Duration) error
func (c *Cache[K, V]) Delete(key K) bool
```

- `capacity > 0`; иначе constructor возвращает ошибку.
- `ttl == 0` означает отсутствие expiration, `ttl < 0` — ошибка.
- Значение считается истёкшим при `now >= expiresAt`.
- `Get` продвигает hit в начало LRU; miss порядок не меняет.
- `Set` существующего ключа заменяет value, TTL и recency. Новый ключ сверх capacity вытесняет back списка.
- `Delete` возвращает `false` для отсутствующего и уже истёкшего ключа.
- Методы concurrency-safe, но cache не копирует `V`: если `V` содержит map, slice или pointer, конкурентная мутация самого значения остаётся ответственностью caller.
- `now` намеренно вызывается под mutex: свежий sample входит в linearization point TTL/state transition, тогда как sample до lock мог бы устареть в очереди. Поэтому callback обязан быстро возвращаться, не входить повторно в cache, а его внешне изменяемое состояние — иметь собственную синхронизацию.
- `Cache` используют только через pointer из `NewCache` и не копируют после первого вызова: внутри находятся mutex, map и list с общей identity.

## Инварианты, ownership и lifecycle

Под `mu` всегда выполняются четыре инварианта:

1. каждому ключу в `items` соответствует ровно один элемент `order`;
2. каждый элемент списка достижим из `items`;
3. `len(items) <= capacity`;
4. front→back задаёт убывание recency среди ещё хранимых записей.

`Cache` владеет nodes списка и metadata, caller — логическим содержимым `V`. Один mutex защищает составной инвариант лучше, чем независимые locks для `map` и списка. Причина та же, что в [[60 Go/Mutex, RWMutex и примитивы координации sync|выборе Mutex для связанных полей]]: промежуточное состояние не должно стать наблюдаемым.

Фоновых goroutines нет, поэтому отдельный `Close` не нужен. Цена простого lifecycle — lazy cleanup истёкших ключей.

## Минимальная реализация

```go
package main

import (
	"container/list"
	"errors"
	"fmt"
	"sync"
	"time"
)

var (
	ErrCapacity    = errors.New("capacity must be positive")
	ErrNegativeTTL = errors.New("ttl must not be negative")
)

type entry[K comparable, V any] struct {
	key       K
	value     V
	expiresAt time.Time
}

type Cache[K comparable, V any] struct {
	mu       sync.Mutex
	capacity int
	now      func() time.Time
	items    map[K]*list.Element
	order    *list.List
}

func NewCache[K comparable, V any](capacity int, now func() time.Time) (*Cache[K, V], error) {
	if capacity <= 0 {
		return nil, ErrCapacity
	}
	if now == nil {
		now = time.Now
	}
	return &Cache[K, V]{capacity: capacity, now: now, items: make(map[K]*list.Element), order: list.New()}, nil
}

func (c *Cache[K, V]) Get(key K) (V, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	el, ok := c.items[key]
	if !ok {
		var zero V
		return zero, false
	}
	e := el.Value.(*entry[K, V])
	if !e.expiresAt.IsZero() && !c.now().Before(e.expiresAt) {
		c.removeLocked(el)
		var zero V
		return zero, false
	}
	c.order.MoveToFront(el)
	return e.value, true
}

func (c *Cache[K, V]) Set(key K, value V, ttl time.Duration) error {
	if ttl < 0 {
		return ErrNegativeTTL
	}
	c.mu.Lock()
	defer c.mu.Unlock()

	expiresAt := time.Time{}
	if ttl > 0 {
		expiresAt = c.now().Add(ttl)
	}
	if el, ok := c.items[key]; ok {
		e := el.Value.(*entry[K, V])
		e.value, e.expiresAt = value, expiresAt
		c.order.MoveToFront(el)
		return nil
	}
	el := c.order.PushFront(&entry[K, V]{key: key, value: value, expiresAt: expiresAt})
	c.items[key] = el
	if len(c.items) > c.capacity {
		c.removeLocked(c.order.Back())
	}
	return nil
}

func (c *Cache[K, V]) Delete(key K) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	el, ok := c.items[key]
	if !ok {
		return false
	}
	e := el.Value.(*entry[K, V])
	expired := !e.expiresAt.IsZero() && !c.now().Before(e.expiresAt)
	c.removeLocked(el)
	return !expired
}

func (c *Cache[K, V]) removeLocked(el *list.Element) {
	delete(c.items, el.Value.(*entry[K, V]).key)
	c.order.Remove(el)
}

func main() {
	now := time.Unix(0, 0)
	c, _ := NewCache[string, int](2, func() time.Time { return now })
	_ = c.Set("a", 1, time.Second)
	_ = c.Set("b", 2, 0)
	fmt.Println(c.Get("a"))
	now = now.Add(2 * time.Second)
	fmt.Println(c.Get("a"))
	_ = c.Set("c", 3, 0)
	_ = c.Set("d", 4, 0)
	fmt.Println(c.Get("b"))
	fmt.Println(c.Get("c"))
	fmt.Println(c.Get("d"))
}
```

## Ожидаемый результат и trace

```text
1 true
0 false
0 false
3 true
4 true
```

После продвижения `a` порядок равен `a,b`; затем `a` истекает и удаляется. `c` и `d` заполняют две позиции, поэтому `b` как LRU уже вытеснен. Clock передан как функция: тест меняет время без `Sleep`.

## Complexity

`Get`, `Set` и `Delete` имеют среднюю сложность `O(1)`: map даёт lookup, список — удаление и перемещение по указателю. Память — `O(capacity)`, но capacity по entries не ограничивает байты. Один mutex делает contention общей точкой при hot cache.

## Trade-offs

- `map + Mutex + list` сохраняет составной LRU-инвариант и типы. `sync.Map` полезен для специальных write-once/read-many или disjoint-key workloads, но его `Range` не snapshot и он не связывает map с eviction order.
- Lazy expiration даёт простой lifecycle. Cleaner быстрее освобождает память, но добавляет goroutine, scan/heap, shutdown и тестирование времени.
- LRU адаптируется к locality, но каждый hit пишет metadata. Approximate eviction уменьшает contention ценой менее точного выбора.
- Для cache fill можно добавить `singleflight.Group` v0.22.0. Он coalesce-ит одновременные вычисления ключа, но не хранит результат и не заменяет cache.

## Типичные ошибки

- Предположение: «`V` потокобезопасно, потому что cache под mutex» → race после `Get` → lock защищает только container → храните immutable values, копируйте их или синхронизируйте отдельно.
- Предположение: «TTL немедленно освобождает память» → expired entries удерживают большой heap → cleanup ленивый → добавьте bounded sweep/expiration heap, если retention входит в SLO.
- Предположение: «lazy TTL всегда вытеснит сначала expired key» → исчезает живая LRU-запись, а expired node остаётся → eviction order знает recency, но не ищет весь map → добавьте sweeper или expiration index, если это существенно для hit ratio.
- Предположение: «большой capacity гарантирует hit ratio» → GC pause и RSS растут → лимит считает entries, а не bytes → измеряйте реальный footprint или вводите weight-based capacity.
- Предположение: «cache переживёт restart» → после deploy приходит miss storm → process memory потеряна → origin должен выдерживать miss, а fills — coalesce и admission-limit.

## Когда применять

Компонент подходит для повторно вычислимых данных одного процесса, когда miss корректен, допустима потеря всего содержимого, а число записей даёт разумную границу памяти. Не кладите сюда единственную копию business state, leases или security decisions без отдельного freshness-контракта.

## Источники

- [Package container/list](https://pkg.go.dev/container/list@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Package sync](https://pkg.go.dev/sync@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Package time](https://pkg.go.dev/time@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-18.
- [Package singleflight](https://pkg.go.dev/golang.org/x/sync@v0.22.0/singleflight) — Go repository `golang.org/x/sync`, tag `v0.22.0`, проверено 2026-07-18.
- [singleflight.go](https://github.com/golang/sync/blob/v0.22.0/singleflight/singleflight.go) — репозиторий `golang/sync`, tag `v0.22.0`, проверено 2026-07-18.
