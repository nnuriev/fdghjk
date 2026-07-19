---
aliases:
  - Equality and comparability в Go
tags:
  - область/go
  - тема/язык
статус: проверено
---

# Равенство и comparability типов

## TL;DR

Comparable type допускает `==`/`!=` и может быть ключом [[60 Go/Map|map]]. Arrays comparable, если element имеет comparable type; structs — если каждый field имеет comparable type. Slices, maps и functions сравниваются только с nil. Interfaces статически comparable, но их сравнение может panic, когда dynamic value имеет несравнимый тип. Равенство языка — не универсальное предметное равенство: для float NaN, time, normalized text и containers часто нужен отдельный contract.

## Область применимости

- Версия Go: 1.26; стабильная toolchain при проверке — Go 1.26.5.
- GOOS/GOARCH: основные правила одинаковы; pointer identity и floating-point соответствуют спецификации/реализации платформы.
- Область: comparison operators, map keys, interfaces и generic constraint `comparable`.

## Ментальная модель

Comparability — свойство type, рекурсивно определяемое его составом. Оно отвечает, разрешена ли операция, но не гарантирует, что результат соответствует предметному понятию «одинаковые».

Есть важное различие:

- **strictly comparable** типы не содержат interfaces и гарантированно не panic при сравнении;
- обычный comparable interface type из [[60 Go/Интерфейсы и неявная реализация|модели интерфейсов]] разрешает `==`, но runtime должен сравнить dynamic values и может обнаружить несравнимый dynamic type.

`comparable` в [[60 Go/Дженерики, constraints и type sets|дженериках и type sets]] проверяет допустимость type argument. С Go 1.20 его может удовлетворять interface вроде `any`, поэтому runtime-риск dynamic value остаётся.

## Как устроено

- Booleans, integer, floating-point, complex, strings, pointers и channels comparable.
- Arrays сравниваются поэлементно; structs — по полям в source order. Если хотя бы один component несравним, весь composite type несравним.
- Slice, map и function можно сравнить только с `nil`; два значения этих типов через `==` сравнить нельзя.
- Interface values равны, когда оба nil либо имеют identical dynamic types и equal dynamic values.
- Если dynamic types совпадают, но этот type несравним, сравнение interface values вызывает panic.
- Pointer equality означает тот же variable либо специальные разрешённые спецификацией случаи. Pointers на разные zero-size variables могут быть равны или не равны; на этом нельзя строить identity.
- Floating-point NaN не равен самому себе. Поэтому NaN как map key допустим по типу, но lookup тем же NaN не находит запись по обычному equality.

Named types требуют assignability/convertibility по правилам operator operands. Для semantic equality часто уместен метод `Equal`, canonicalization или comparator function.

## Код

```go
package main

import (
	"fmt"
	"math"
)

type Key struct {
	Region string
	ID     int
}

func main() {
	a := Key{Region: "eu", ID: 7}
	b := Key{Region: "eu", ID: 7}
	fmt.Println(a == b)

	var x any = []int{1}
	var y any = []int{1}
	func() {
		defer func() { fmt.Println("interface panic:", recover() != nil) }()
		fmt.Println(x == y)
	}()

	nan := math.NaN()
	fmt.Println(nan == nan)
}
```

## Ожидаемый результат

```text
true
interface panic: true
false
```

Struct key сравнивается по полям. Interface comparison компилируется, но dynamic slices несравнимы. NaN подчёркивает разницу между type-level comparability и reflexive semantic equality.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| 1.18–1.19 | Constraint `comparable` удовлетворяли только strictly comparable type arguments | Go 1.20 разрешил всем comparable types, включая interfaces, удовлетворять `comparable` по специальному правилу constraint satisfaction | Generic map/set может принимать `any`, но сравнение несравнимого dynamic value всё ещё panic | [Go 1.20 Release Notes](https://go.dev/doc/go1.20) |

## Trade-offs

Встроенное `==` быстро, статически проверяется и идеально для identity-like keys из comparable fields. Метод `Equal` может учитывать normalization, ignored fields или constant-time требования, но должен явно определить symmetry/transitivity и поведение nil.

Pointer как map key выражает object identity, а struct key — value identity. Pointer избегает копирования большого key, но cache становится зависимым от lifetime/адресов и не объединяет равные значения. Часто компактный immutable struct — более устойчивый key.

`reflect.DeepEqual` удобен в отдельных tests, но имеет специальные правила для nil/empty, functions, NaN и cycles; это не универсальный domain comparator. Предпочитайте `slices.Equal`, `maps.Equal` или предметный comparator с нужной семантикой.

## Типичные ошибки

**Неверное предположение:** если interface можно сравнить, сравнение не panic. **Симптом:** runtime panic на `any` со slice/map/function. **Причина:** dynamic type несравним. **Исправление:** сузить interface/constraint, валидировать dynamic type или не использовать equality.

**Неверное предположение:** `comparable` означает математическое отношение эквивалентности. **Симптом:** NaN key нельзя найти, cache ведёт себя неожиданно. **Причина:** floating-point equality не reflexive для NaN. **Исправление:** запретить/канонизировать NaN или определить отдельный key representation.

**Неверное предположение:** два slices можно сравнить содержательно через `==`. **Симптом:** compile-time error. **Причина:** slice descriptor не определяет value equality и содержит mutable shared storage. **Исправление:** `slices.Equal` или предметный loop/comparator.

**Неверное предположение:** `DeepEqual` совпадает с бизнес-равенством. **Симптом:** test привязан к representation. **Причина:** reflection сравнивает структуру по собственному контракту. **Исправление:** проверять наблюдаемые поля и domain semantics.

## Когда применять

- Стройте map keys из immutable comparable values с понятной equality.
- Используйте `==` для language identity/value equality, когда она совпадает с предметной.
- Для floats, text normalization, timestamps и collections задавайте comparator явно.
- Не принимайте `any` как generic comparable key без документированной политики dynamic types.

## Источники

- [The Go Programming Language Specification: Comparison operators, Interface types, Type constraints](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Go 1.20 Release Notes: comparable types](https://go.dev/doc/go1.20) — The Go Project, Go 1.20, проверено 2026-07-15.
- [Package slices: Equal](https://pkg.go.dev/slices@go1.26.5#Equal) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Package maps: Equal](https://pkg.go.dev/maps@go1.26.5#Equal) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
