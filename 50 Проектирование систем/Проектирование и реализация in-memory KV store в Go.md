---
aliases:
  - In-memory KV store в Go
  - Локальное key-value хранилище в Go
tags:
  - область/go
  - тема/низкоуровневое-проектирование
статус: черновик
---

# Проектирование и реализация in-memory KV store в Go

## TL;DR

Вопрос заметки: как реализовать process-local key-value store с TTL и compare-and-swap (CAS), чтобы concurrent read-modify-write не терял обновления? Один `sync.Mutex` защищает map, global revision, expiration transition и наблюдаемое содержимое записи: `[]byte` копируется на входе и выходе.

Store не вытесняет живые keys: в отличие от cache, отсутствие capacity eviction входит в его контракт. Но память процесса не durable. WAL, replication, quorum и cross-node consistency относятся к [[50 Проектирование систем/Проектирование distributed cache и KV store|distributed KV store]], а не возникают от добавления mutex к map.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-18.
- Пакеты: `sync`, `time`, built-in map.
- Scope: string keys, copied byte values, optional TTL, linearizable отдельные операции, CAS по revision.
- Вне scope: persistence, range scans, watch, multi-key transaction, memory quota и replication.

Код статически разобран, но не выполнен: локальной Go toolchain нет. Заметка остаётся черновиком.

## Ментальная модель

Каждый успешный API write/delete получает новый monotonically increasing revision. Caller читает `(value, revision)`, вычисляет новое значение и выполняет CAS с прочитанной revision. Если конкурент уже изменил или удалил key, revision не совпадает и операция возвращает conflict вместо lost update.

TTL — логический переход `present → absent` при `now >= expiresAt`. Expiration делает старую revision недействительной, но не выдаёт новую; следующий write продолжает global sequence. Cleanup ленивый: операция над ключом удаляет истёкшую запись. Поэтому visibility истечения точная, а освобождение памяти без фонового sweeper не гарантировано к тому же моменту.

## Public API и контракт

```go
func NewStore(now func() time.Time) *Store
func (s *Store) Get(key string) (Value, bool)
func (s *Store) Put(key string, data []byte, ttl time.Duration) (Value, error)
func (s *Store) CompareAndSwap(key string, expected uint64, data []byte, ttl time.Duration) (Value, error)
func (s *Store) Delete(key string, expected uint64) (deleteRevision uint64, err error)
```

- `ttl == 0` означает отсутствие expiration, `ttl < 0` — `ErrNegativeTTL`.
- `Put` безусловно создаёт или заменяет key. Для read-modify-write нужен CAS.
- В CAS `expected == 0` означает create-if-absent; иначе revision должна точно совпасть.
- `Delete` требует существующую exact revision; deletion тоже получает revision.
- `Get` возвращает копию bytes. Мутация аргумента после write и результата после read не меняет store.
- `now` намеренно вызывается под mutex: свежий sample входит в linearization point TTL/state transition, тогда как sample до lock мог бы устареть в очереди. Поэтому callback обязан быстро возвращаться, не входить повторно в store, а его внешне изменяемое состояние — иметь собственную синхронизацию.
- `Store` используют только через pointer из `NewStore` и не копируют после первого вызова: mutex и map принадлежат одной identity.

## Инварианты, state transitions и ownership

Под `mu` выполняются инварианты:

1. каждый key имеет не более одной record;
2. новая mutation получает revision больше всех ранее выданных в lifetime этого store;
3. CAS проверяет expected и записывает новое значение в одной critical section;
4. истёкшая record логически отсутствует до проверки CAS;
5. map владеет собственной копией `data`.

```text
absent  --Put/CAS(0)----------> present(rev n)
present --Put/CAS(current rev)-> present(rev n+1)
present --Delete(current rev)--> absent(delete rev n+1)
present --expiresAt-----------> absent
```

Один mutex делает каждую операцию linearizable внутри процесса. Он намеренно объединяет map и revision: раздельные locks позволили бы наблюдать запись без соответствующего version transition. Это применение той же модели, что у [[60 Go/Map|map под внешней синхронизацией]].

## Минимальная реализация

```go
package main

import (
	"errors"
	"fmt"
	"sync"
	"time"
)

var (
	ErrConflict          = errors.New("revision conflict")
	ErrNegativeTTL       = errors.New("ttl must not be negative")
	ErrRevisionExhausted = errors.New("revision exhausted")
)

type Value struct {
	Data      []byte
	Revision  uint64
	ExpiresAt time.Time
}

type record struct {
	data      []byte
	revision  uint64
	expiresAt time.Time
}

type Store struct {
	mu       sync.Mutex
	now      func() time.Time
	revision uint64
	items    map[string]record
}

func NewStore(now func() time.Time) *Store {
	if now == nil {
		now = time.Now
	}
	return &Store{now: now, items: make(map[string]record)}
}

func clone(data []byte) []byte { return append([]byte(nil), data...) }

func (s *Store) currentLocked(key string, now time.Time) (record, bool) {
	r, ok := s.items[key]
	if ok && !r.expiresAt.IsZero() && !now.Before(r.expiresAt) {
		delete(s.items, key)
		return record{}, false
	}
	return r, ok
}

func (s *Store) nextRevisionLocked() (uint64, error) {
	if s.revision == ^uint64(0) {
		return 0, ErrRevisionExhausted
	}
	s.revision++
	return s.revision, nil
}

func (s *Store) writeLocked(key string, data []byte, ttl time.Duration, now time.Time) (Value, error) {
	revision, err := s.nextRevisionLocked()
	if err != nil {
		return Value{}, err
	}
	expiresAt := time.Time{}
	if ttl > 0 {
		expiresAt = now.Add(ttl)
	}
	r := record{data: clone(data), revision: revision, expiresAt: expiresAt}
	s.items[key] = r
	return Value{Data: clone(r.data), Revision: revision, ExpiresAt: expiresAt}, nil
}

func (s *Store) Get(key string) (Value, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok := s.currentLocked(key, s.now())
	if !ok {
		return Value{}, false
	}
	return Value{Data: clone(r.data), Revision: r.revision, ExpiresAt: r.expiresAt}, true
}

func (s *Store) Put(key string, data []byte, ttl time.Duration) (Value, error) {
	if ttl < 0 {
		return Value{}, ErrNegativeTTL
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.writeLocked(key, data, ttl, s.now())
}

func (s *Store) CompareAndSwap(key string, expected uint64, data []byte, ttl time.Duration) (Value, error) {
	if ttl < 0 {
		return Value{}, ErrNegativeTTL
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	current, ok := s.currentLocked(key, now)
	if expected == 0 && ok || expected != 0 && (!ok || current.revision != expected) {
		return Value{}, ErrConflict
	}
	return s.writeLocked(key, data, ttl, now)
}

func (s *Store) Delete(key string, expected uint64) (uint64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	current, ok := s.currentLocked(key, s.now())
	if expected == 0 || !ok || current.revision != expected {
		return 0, ErrConflict
	}
	revision, err := s.nextRevisionLocked()
	if err != nil {
		return 0, err
	}
	delete(s.items, key)
	return revision, nil
}

func main() {
	now := time.Unix(0, 0)
	s := NewStore(func() time.Time { return now })
	created, _ := s.CompareAndSwap("mode", 0, []byte("safe"), 0)
	fmt.Println(string(created.Data), created.Revision)
	_, err := s.CompareAndSwap("mode", 0, []byte("duplicate"), 0)
	fmt.Println(errors.Is(err, ErrConflict))
	updated, _ := s.CompareAndSwap("mode", created.Revision, []byte("fast"), time.Second)
	fmt.Println(string(updated.Data), updated.Revision)
	now = now.Add(2 * time.Second)
	_, ok := s.Get("mode")
	fmt.Println(ok)
	recreated, _ := s.CompareAndSwap("mode", 0, []byte("new"), 0)
	fmt.Println(string(recreated.Data), recreated.Revision)
}
```

## Ожидаемый результат и trace

```text
safe 1
true
fast 2
false
new 3
```

Create-if-absent выдаёт revision 1; повтор с expected 0 конфликтует. CAS по revision 1 создаёт revision 2. После TTL key логически отсутствует, поэтому новый CAS(0) успешен, но revision не переиспользуется.

## Complexity

`Get`, `Put`, CAS и `Delete` имеют среднюю сложность `O(1)`; копирование добавляет `O(len(data))`. Память — `O(число неочищенных keys + bytes)`. Один mutex сериализует все keys, поэтому sharding нужен только после измеренного contention и с явно ограниченными cross-key invariants.

## Trade-offs

- Обычный map плюс mutex сохраняет типы и общий revision-инвариант. `sync.Map` оптимизирован для специальных workloads, а `Range` не даёт consistent snapshot.
- Копирование bytes исключает aliasing, но удваивает memory bandwidth на API-границе. Immutable value type может быть дешевле, если ownership доказуем.
- Global revision даёт единый порядок mutations, но создаёт общую точку записи. Per-key revisions масштабируются лучше, но не задают порядок между keys.
- Lazy TTL не требует goroutine. Expiration heap/sweeper освобождает память вовремя, но добавляет lifecycle, scan budget и тестирование времени.

## Типичные ошибки

- Предположение: «Get затем Put атомарны» → concurrent writer теряет update → две операции имеют разные linearization points → используйте CAS.
- Предположение: «map безопасен, потому что записи разных keys» → race/panic при concurrent access → built-in map не даёт такую гарантию → синхронизируйте весь доступ.
- Предположение: «возвращённый `[]byte` можно не копировать» → caller меняет хранимое значение без lock → backing array общий → копируйте либо передавайте immutable ownership.
- Предположение: «TTL гарантирует bounded memory» → нетронутые expired keys остаются в map → cleanup ленивый → добавьте bounded sweep, если retention важен.
- Предположение: «in-memory означает durable KV» → restart стирает acknowledged write → нет WAL/replication → не используйте как единственный business source of truth.

## Когда применять

Подходит для ephemeral configuration одного процесса, тестовых fakes, session state с допустимой потерей и локальных registries, когда CAS нужен для конкурентной корректности. Если запись должна пережить restart или быть общей для replicas, нужен внешний durable store.

## Источники

- [Go Language Specification — Map types](https://go.dev/ref/spec#Map_types) — The Go Project, language version Go 1.26, проверено 2026-07-18.
- [Go maps in action](https://go.dev/blog/maps) — The Go Project, публикация 2013-02-06, проверено 2026-07-18.
- [Package sync](https://pkg.go.dev/sync@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Package time](https://pkg.go.dev/time@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-18.
