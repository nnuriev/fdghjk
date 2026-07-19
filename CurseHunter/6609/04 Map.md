---
aliases:
  - CourseHunter 6609 — map
tags:
  - тип/разбор-курса
  - источник/coursehunter
  - язык/go
  - тема/map
статус: проверено
---

# Map: теория и 6 задач курса

Языковой контракт и текущий runtime разнесены в [[60 Go/Map|заметке о map]] и [[60 Go/Runtime-устройство map|заметке о runtime map]]. Это особенно важно здесь: видео снято на Go `1.23.4` перед заменой реализации.

## Урок 30. Hash table как модель

![[90 Вложения/CurseHunter/6609/Кадры/030.jpg]]

Курс проходит путь от direct-address array к hash table: hash сжимает key space, collision требует chaining или open addressing, а load factor определяет стоимость probe и момент роста. В интервью недостаточно назвать среднее `O(1)`: нужно связать его с качеством hash, collision distribution, resize и memory locality.

## Урок 31. Устройство built-in `map`

![[90 Вложения/CurseHunter/6609/Кадры/031.jpg]]

**Утверждение курса для Go `1.23.4`:** `hmap` указывает на массив buckets; `bmap` логически содержит восемь slots, `tophash`, сгруппированные keys/values и overflow chain. Рост выполняется постепенно через evacuation старых buckets. Группировка `[8]keys` и `[8]values` сокращает padding: в показанном `darwin/arm64` примере `8 * struct{int8; int64}` занимает `128` bytes, а grouped layout — `72`.

**Версионная коррекция:** начиная с Go `1.24` built-in map основан на Swiss Tables. Поэтому `hmap`, eight-slot `bmap`, overflow buckets и load около `6.5` на bucket нельзя выдавать за текущее устройство без версии. Языковые свойства `map` при этом сохранены.

## Урок 32. Comparable keys

![[90 Вложения/CurseHunter/6609/Кадры/032.jpg]]

`map[[]int]V` не компилируется: slice не comparable. `map[any]V` компилируется, но insertion dynamic value `[]int` или `func()` panic с `hash of unhashable type`. Interface key comparable лишь тогда, когда его dynamic type comparable.

**Интервью-применение:** arrays comparable, если comparable element type; structs — если comparable все fields; slices, maps и functions — нет, кроме comparison с `nil` там, где он разрешён.

## Урок 33. Порядок iteration

![[90 Вложения/CurseHunter/6609/Кадры/033.jpg]]

Порядок `range map` **не специфицирован** и не гарантируется одинаковым между проходами. Слово «случайный» слишком сильное: API не обещает statistical randomness. `fmt.Println(map)` может сортировать keys для стабильного formatting, поэтому его вывод не доказывает порядок `range`.

## Урок 34. Изменение map во время `range`

![[90 Вложения/CurseHunter/6609/Кадры/034.jpg]]

- Если удалить entry, до которого iterator ещё не дошёл, оно не будет произведено.
- Entry, добавленное во время iteration, может попасть в текущий проход, а может нет.
- Изменение value существующего key разрешено, но наблюдаемый набор/порядок остаётся зависимым от прохода.

Следовательно, точный вывод примера с добавлением `10+key` предсказывать нельзя. Если нужен snapshot, сначала копируют keys.

## Урок 35. Освобождает ли `delete` backing memory

![[90 Вложения/CurseHunter/6609/Кадры/035.jpg]]

После удаления миллиона entries и GC map обычно продолжает удерживать bucket storage: built-in map не обещает shrink. Ссылки внутри удалённых values очищаются, поэтому сами reachable objects могут быть собраны; это не то же самое, что возврат buckets. Для заметного release создают новую map и перестают ссылаться на старую.

## Урок 36. Float key

![[90 Вложения/CurseHunter/6609/Кадры/036.jpg]]

`float32(0.3)+float32(0.6)` и отдельно округлённый `float32(0.9)` могут иметь разные bit patterns, поэтому lookup даёт `false`. Ещё опаснее `NaN`: `NaN != NaN`, из-за чего inserted key нельзя обычным lookup найти по нему же. `+0` и `-0` сравниваются равными.

Практически money и discrete identities не кодируют float key; используют integer minor units, canonical string или другой устойчивый representation.

## Урок 37. Матрица операций

![[90 Вложения/CurseHunter/6609/Кадры/037.jpg]]

| Операция | nil map | non-nil map |
| --- | --- | --- |
| lookup | zero value, `ok=false` | обычный lookup |
| `delete` | no-op | удаление/no-op |
| `range` | zero iterations | unspecified order |
| write | panic | insert/update |

Map не безопасна для конкурентного read/write без synchronization. Даже когда runtime ловит `concurrent map read and map write`, это fatal error, а не полноценный race detector и не допустимый механизм контроля.

## Источники

- [Map types](https://go.dev/ref/spec#Map_types) — Go specification, проверено 2026-07-19.
- [For statements with range clause](https://go.dev/ref/spec#For_range) — Go specification, проверено 2026-07-19.
- [Go 1.23.4 runtime/map.go](https://github.com/golang/go/blob/go1.23.4/src/runtime/map.go) — golang/go, tag `go1.23.4`, проверено 2026-07-19.
- [Go 1.24 Release Notes](https://go.dev/doc/go1.24) — Go project, новый Swiss Table runtime, проверено 2026-07-19.
- [Go 1.24 internal/runtime/maps](https://github.com/golang/go/tree/go1.24.0/src/internal/runtime/maps) — golang/go, tag `go1.24.0`, проверено 2026-07-19.
- [Код модуля](https://github.com/Balun-courses/interview_go/tree/f562c12b4d0d85fd0b00cb662efc7f68edc96476/maps) — Balun-courses/interview_go, commit `f562c12`, проверено 2026-07-19.
