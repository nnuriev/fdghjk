---
aliases:
  - Generics, constraints and type sets в Go
tags:
  - область/go
  - тема/язык
статус: проверено
---

# Дженерики, constraints и type sets

## TL;DR

Generics позволяют объявить функцию или тип один раз для семейства типов. Constraint — interface, чей **type set** ограничивает допустимые type arguments и определяет разрешённые операции. Операция над `T` допустима, только если она корректна для каждого типа в type set constraint. Generics сохраняют статическую проверку, но не заменяют interfaces для runtime polymorphism и не гарантируют конкретную стратегию code generation.

## Область применимости

- Версия Go: 1.26; стабильная toolchain при проверке — Go 1.26.5.
- GOOS/GOARCH: языковая семантика одинакова; generated code и performance зависят от toolchain/architecture.
- Область: type parameters функций и defined types, inference, constraints, unions и approximation `~`.

## Ментальная модель

Type parameter — неизвестный, но фиксированный при instantiation тип. Constraint описывает доказанные свойства этого типа.

```go
type Integer interface {
	~int | ~int64
}
```

Type term `~int` означает все типы, чей underlying type — `int`, включая defined types. Union объединяет множества. Внутри generic body compiler разрешает только общий набор операций всех членов type set.

Basic interface, содержащий только methods, можно использовать и как runtime value. Non-basic interface с type terms или `comparable` предназначен только для constraints; различие начинается с [[60 Go/Интерфейсы и неявная реализация|общей модели interfaces и неявной реализации]].

## Как устроено

- Type arguments проверяются при instantiation: каждый должен удовлетворять соответствующему constraint.
- `any` не даёт операций кроме общих для любого типа. Для `==` нужен подходящий comparable constraint; для `<` — constraint с ordered underlying types или пакет `cmp`.
- `comparable` описывает типы, допустимые для `==`, `!=` и map keys. С Go 1.20 comparable types вроде `any` могут удовлетворять constraint `comparable`, но конкретное сравнение interface values всё ещё может panic, если dynamic value несравним; это следствие различия из [[60 Go/Равенство и comparability типов|правил равенства и comparability]].
- Type inference использует ordinary arguments и constraint unification; она не обязана угадывать type argument только из ожидаемого result type.
- Для zero value `T` объявляют `var zero T`.
- Methods не могут вводить собственные дополнительные type parameters; receiver generic defined type повторно объявляет параметры receiver base type.
- Детали monomorphization, dictionaries, inlining и shape sharing не входят в language contract.

Generics особенно полезны для containers и algorithms, где тип результата связан с типом входа. Interface лучше, когда вызывающему нужно runtime-поведение разных реализаций за одним value.

## Код

```go
package main

import "fmt"

type Integer interface {
	~int | ~int64
}

func Max[T Integer](a, b T) T {
	if a > b {
		return a
	}
	return b
}

type UserID int64

func main() {
	fmt.Println(Max(2, 5))
	fmt.Println(Max(UserID(7), UserID(3)))
}
```

## Ожидаемый результат

```text
5
7
```

Type inference выводит `int` в первом вызове и `UserID` во втором. `~int64` включает defined type `UserID`, а результат сохраняет его статический тип.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| До 1.18 | Type parameters и type sets отсутствовали | Go 1.18 добавил generics | Стали возможны type-safe algorithms/containers без `any` и code generation | [Go 1.18 Release Notes](https://go.dev/doc/go1.18) |
| 1.18–1.19 | Не каждый comparable type удовлетворял `comparable` | Go 1.20 разделил interface implementation и constraint satisfaction для этого случая | `any` и interfaces можно использовать как type argument `comparable`, сохраняя runtime-риск несравнимого dynamic value | [Go 1.20 Release Notes](https://go.dev/doc/go1.20) |
| До 1.24 | Generic alias types не были доступны по умолчанию | Go 1.24 включил type parameters у aliases | Возможны совместимые перемещения/переэкспорты generic types | [Go 1.24 Release Notes](https://go.dev/doc/go1.24) |
| До 1.26 | Generic type не мог ссылаться на себя в собственном type parameter list | Go 1.26 снял ограничение | Стали выразимы self-referential constraints вида `Adder[A Adder[A]]` | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |

## Trade-offs

Generics сохраняют concrete types и устраняют assertions, но усложняют error messages и API, если constraint выражает много несвязанных случаев. Небольшое дублирование иногда понятнее универсальной abstraction.

Interface принимает heterogeneous implementations во время выполнения; generic parameter обычно фиксирует один concrete type на instantiation. Если алгоритм вызывает поведение, method constraint уместен. Если хранится коллекция разных concrete values, нужен interface или explicit sum representation.

Union constraint привязывает API к набору representations. Method-based constraint устойчивее к появлению новых типов, но не даёт операторов, которых methods не выражают. Выбирайте по реальному инварианту.

## Типичные ошибки

**Неверное предположение:** constraint — список примеров, compiler разрешит операции по одному типу. **Симптом:** operator not defined on `T`. **Причина:** операция должна быть общей для всего type set. **Исправление:** сузить constraint или выразить поведение method.

**Неверное предположение:** `comparable` исключает runtime panic для interface values. **Симптом:** panic при сравнении dynamic slice/map. **Причина:** `any` — comparable статический interface type, но не strictly comparable. **Исправление:** не принимать произвольный interface key без валидации dynamic type либо сузить constraint.

**Неверное предположение:** generics автоматически быстрее interface. **Симптом:** усложнение API без выигрыша. **Причина:** code generation и optimization — implementation details. **Исправление:** выбирать abstraction по типовой связи, а performance измерять на целевой toolchain.

**Неверное предположение:** `~T` означает «T или pointer to T». **Симптом:** неожиданный type set. **Причина:** `~T` выбирает типы с underlying type `T`. **Исправление:** читать constraint как множество underlying types.

## Когда применять

- Контейнер или algorithm возвращает тот же/связанный concrete type.
- Операция одинакова для семейства underlying numeric/string types.
- Нужна статическая связь типов, которую `any` потерял бы.
- Не вводите type parameter, если он встречается один раз и не добавляет проверяемой связи.
- Для exported generic API считайте constraint частью versioned контракта [[60 Go/Пакеты, модули и направление зависимостей|пакета и модуля]]: его сужение ломает допустимые instantiations у consumers.

## Источники

- [The Go Programming Language Specification: Type parameter declarations, Interface types, Type inference](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Go 1.18 Release Notes: Generics](https://go.dev/doc/go1.18) — The Go Project, Go 1.18, проверено 2026-07-15.
- [Go 1.20 Release Notes: comparable types](https://go.dev/doc/go1.20) — The Go Project, Go 1.20, проверено 2026-07-15.
- [Go 1.24 Release Notes: Generic type aliases](https://go.dev/doc/go1.24) — The Go Project, Go 1.24, проверено 2026-07-15.
- [Go 1.26 Release Notes: self-referential constraints](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
