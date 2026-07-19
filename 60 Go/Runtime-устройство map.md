---
aliases:
  - Реализация map в runtime Go
tags:
  - область/go
  - тема/runtime
  - тема/производительность
статус: проверено
---

# Runtime-устройство map

## TL;DR

В Go 1.26.5 builtin `map` реализован вариантом Swiss Table: slots собраны в groups по восемь, control word позволяет параллельно отфильтровать кандидатов по 7-bit H2 части hash, а H1 задаёт probing и выбор table. Малые maps до восьми entries могут храниться в одной group; большие используют tables и directory с extendible hashing. Это объясняет locality, grow cost и влияние tombstones, однако языковой контракт такого устройства не гарантирует. Порядок iteration, точный layout, load factor и стратегия growth могут измениться; API-решения должны опираться на [[60 Go/Map|языковую семантику map]], а performance — на [[60 Go/Бенчмарки|benchmark]] конкретной toolchain.

## Область применимости

- Версия Go: публичная семантика Go 1.26; реализация Go 1.26.5.
- GOOS/GOARCH: основное описание — linux/amd64, где hash имеет 64-bit представление; исходник отдельно отмечает вопросы для 32-bit ports.
- Компоненты: `internal/runtime/maps`, compiler map lowering, type-specific hash/equality.
- Вне scope: data races на выполненных путях ищет [[60 Go/Race detector|race detector]], а допустимые типы ключей определяет [[60 Go/Равенство и comparability типов|comparability]]; здесь разбирается только runtime representation.

## Ментальная модель

Для lookup runtime не сравнивает ключ с каждой записью:

1. type-specific hasher вычисляет hash с per-map seed;
2. верхняя часть H1 выбирает table и начальную group;
3. control bytes всей group сравниваются с нижними 7 bits H2;
4. полное `==` вызывается только для H2-кандидатов;
5. если match нет и group содержит empty slot, ключ отсутствует; иначе продолжается quadratic probe.

Control metadata экономит дорогие equality checks и улучшает locality. H2 match не доказывает равенство: для каждого кандидата всё равно выполняется key equality.

## Как устроено

Group Go 1.26.5 содержит восемь key/value slots и 8-byte control word. Каждый control byte кодирует empty, deleted либо occupied с H2. Удаление не всегда может сделать slot empty: если probing должен пройти дальше, остаётся tombstone. Tombstones переиспользуются вставками и очищаются при rehash.

Small-map optimization хранит до восьми entries прямо в одной group без directory. После перехода к tables каждая table — самостоятельная open-addressed hash table. До текущего `maxTableCapacity` table при grow заменяется table двойной capacity; затем она split на две. Directory выбирает table по prefix hash и может содержать несколько indices на одну table. Это ограничивает единицу дорогостоящего rehash частью большой map, но константы и threshold — implementation details.

Iteration сложнее lookup. Спецификация требует не возвращать удалённую до посещения entry и допускает показать или пропустить добавленную entry. При grow iterator Go 1.26.5 продолжает обходить старую table для стабильности позиции, но перепроверяет key в replacement tables, чтобы вернуть актуальное значение или заметить delete. Порядок явно randomized и сортировкой не является.

Spec не обещает asymptotic complexity. Ожидаемое constant-time поведение — свойство текущей hash-table implementation при нормальном распределении hash, а не языковая гарантия.

## Код

Публичный пример проходит границу small-map optimization, не наблюдая внутренний layout:

~~~go
package main

import (
	"fmt"
	"strconv"
)

func main() {
	m := make(map[int]string)
	for i := 0; i < 9; i++ {
		m[i] = strconv.Itoa(i)
	}

	delete(m, 4)
	v, ok := m[4]
	fmt.Printf("%d %q %t %q\n", len(m), v, ok, m[8])
}
~~~

Команда:

~~~text
go run main.go
~~~

## Ожидаемый результат

~~~text
8 "" false "8"
~~~

Переход representation не меняет semantic contract: после delete длина равна восьми, отсутствующий key даёт zero value и `ok=false`. Код намеренно не печатает `range`, поскольку его порядок не определён. Пример выполнен в официальном Go Playground на Go 1.26.5; вывод совпал с ожидаемым, проверено 2026-07-15.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| до 1.24 | Runtime использовал прежнюю bucket-based implementation | — | Термины bucket, overflow bucket и tophash описывали тогдашние internals | [Go 1.24 Release Notes](https://go.dev/doc/go1.24) |
| 1.24 | — | Новый builtin map на основе Swiss Tables стал default; временно существовал `GOEXPERIMENT=noswissmap` | Старые layout diagrams перестали объяснять current performance | [Go 1.24 Release Notes](https://go.dev/doc/go1.24) |
| 1.26.5 | Код current implementation находится в `internal/runtime/maps` | Groups из 8 slots, directory и table splitting подтверждены fixed tag | Любое численное утверждение нужно привязывать к tag go1.26.5 | [map.go](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/runtime/maps/map.go) |

## Trade-offs

Map выигрывает при динамических sparse keys и частых lookups. Slice или array обычно лучше для плотных integer indices: меньше metadata, предсказуемее iteration и locality. Sorted slice подходит редко изменяемому набору, когда важны порядок и компактность, ценой `O(log n)` lookup и дорогих inserts.

`make(map[K]V, n)` даёт capacity hint и может уменьшить growth work, если estimate реалистичен. Завышение удерживает лишнюю память; runtime не обещает точную capacity.

Для inline element размером не более `abi.MapMaxElemBytes` (128 bytes в Go 1.26.5) `map[K]V` может избежать отдельной object allocation, но element не addressable и обновляется read-modify-write. Более крупный `V` runtime хранит indirect и при insert выделяет отдельный object, поэтому преимущество исчезает. `map[K]*V` явно даёт identity и mutation через pointer, но добавляет aliasing, nil и [[60 Go/Аллокации, GC и GC pressure|GC scan work]]; allocations обеих форм нужно измерять на конкретном layout.

## Типичные ошибки

**Неверное предположение:** bucket layout старых версий описывает Go 1.26. **Симптом:** неверная оценка growth, locality и memory. **Причина:** runtime map сменился в Go 1.24. **Исправление:** ссылаться на fixed tag текущей toolchain.

**Неверное предположение:** capacity hint резервирует ровно N entries без grow. **Симптом:** расчёт memory и latency не совпадает с production. **Причина:** hint и growth policy не являются API. **Исправление:** benchmark на реальном key/value size и distribution.

**Неверное предположение:** pointer на map element можно сохранить между grows. **Симптом:** compile error при `&m[k]` или попытка unsafe обхода. **Причина:** element не addressable, representation может rehash. **Исправление:** read-modify-write либо map of pointers с явным ownership.

**Неверное предположение:** random-looking iteration создаёт равномерную случайную выборку. **Симптом:** biased выбор первого key. **Причина:** unspecified order не гарантирует random distribution. **Исправление:** реализовать явное sampling.

## Когда применять

- Используйте internals только для объяснения профиля и выбора benchmark hypotheses.
- Указывайте Go 1.26.5 и layout key/value при memory/performance выводах.
- Не переносите thresholds и load factors в application logic.
- Сортируйте keys там, где внешний результат должен быть детерминирован.

## Источники

- [The Go Programming Language Specification: Map types and range](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Go 1.24 Release Notes: Swiss Table map](https://go.dev/doc/go1.24) — The Go Project, Go 1.24, проверено 2026-07-15.
- [internal/runtime/maps/map.go: design, Map, lookup и growth](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/runtime/maps/map.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [internal/runtime/maps/table.go: table probing и split](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/runtime/maps/table.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [internal/runtime/maps/group.go: control groups](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/runtime/maps/group.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [internal/abi/map.go: MapGroupSlots](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/abi/map.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [internal/runtime/maps/runtime.go: indirect element allocation](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/runtime/maps/runtime.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
