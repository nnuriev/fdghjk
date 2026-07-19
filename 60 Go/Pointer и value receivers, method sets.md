---
aliases:
  - Receivers and method sets в Go
tags:
  - область/go
  - тема/язык
статус: проверено
---

# Pointer и value receivers, method sets

## TL;DR

Value receiver получает копию `T`; pointer receiver получает копию `*T`, указывающую на исходный объект. Method set `T` содержит методы с receiver `T`, а method set `*T` — методы с receiver `T` и `*T`. Сокращение `x.PointerMethod()` для addressable `x` не добавляет этот метод в method set `T`, поэтому `T` может не реализовать interface, хотя прямой вызов компилируется.

## Область применимости

- Версия Go: 1.26; стабильная toolchain при проверке — Go 1.26.5.
- GOOS/GOARCH: не влияют на правила method sets; стоимость копии зависит от размера и архитектуры.
- Область: defined types, method declarations, method expressions, interface implementation.

## Ментальная модель

Есть два разных вопроса:

1. **Можно ли записать вызов `x.M()`?** Компилятор может взять адрес addressable `x`.
2. **Входит ли `M` в method set типа `x`?** Именно это определяет interface implementation.

Не выводите второе из первого. Method set — статический контракт типа, а automatic address-taking — удобство конкретного call expression. Условия addressability и само устройство `T`/`*T` подробнее заданы в [[60 Go/Структуры, указатели и методы|модели структур, указателей и методов]].

## Как устроено

- Для defined type `T` method set включает методы, объявленные с receiver `T`.
- Для pointer `*T`, где `T` не pointer и не interface, method set включает методы с receiver `T` и `*T`.
- Value-receiver метод можно вызвать и на `T`, и на `*T`; во втором случае compiler разыменует pointer для копирования receiver.
- Pointer-receiver метод можно вызвать на `*T` и на addressable `T` через сокращение `(&x).M()`.
- [[60 Go/Интерфейсы и неявная реализация|Interface реализуется неявно]], если method set типа содержит все методы interface.
- Method value `x.M` связывает receiver в момент вычисления. Method expression `T.M` превращает receiver в явный первый аргумент.

Embedding может продвигать методы в method set внешнего типа, но правила различаются для embedded `T` и `*T`; поэтому итоговый контракт проверяют по [[60 Go/Embedding и composition|правилам embedding и composition]], а не только по синтаксису вызова.

Value receiver не гарантирует deep immutability: согласно [[60 Go/Zero values, семантика значений и копирование|семантике значений и поверхностного копирования]], копия struct со slice или map продолжает ссылаться на общие данные. Pointer receiver не гарантирует mutation: он может быть выбран из-за identity или запрета копирования.

Для одного логического типа обычно сохраняют единообразный receiver kind. Смешение допустимо, но повышает вероятность ошибиться в interface satisfaction и ожиданиях копирования. Типы с `sync.Mutex` или другим `noCopy`-подобным состоянием должны использовать pointer receivers и не копироваться после начала использования.

## Код

```go
package main

import "fmt"

type Counter int

func (c Counter) Value() int { return int(c) }
func (c *Counter) Inc()      { *c++ }

type Valuer interface {
	Value() int
}

type Incrementer interface {
	Inc()
}

var _ Valuer = Counter(0)
var _ Valuer = (*Counter)(nil)
var _ Incrementer = (*Counter)(nil)

func main() {
	var c Counter
	c.Inc() // c addressable, поэтому это (&c).Inc()
	fmt.Println(c.Value())
}
```

## Ожидаемый результат

```text
1
```

Строка `var _ Incrementer = Counter(0)` не скомпилировалась бы: method `Inc` отсутствует в method set `Counter`, хотя `c.Inc()` допустим для addressable переменной.

## Trade-offs

Value receiver хорошо выражает immutable-подобную операцию над маленьким самостоятельным value и позволяет и `T`, и `*T` удовлетворять interface. Но он копирует receiver и может скрыто сохранить aliasing вложенных reference-like полей.

Pointer receiver позволяет менять объект, избегает копирования большого struct и нужен для non-copyable состояния. Цена: только `*T` реализует interfaces с такими методами; появляются nil receiver и общий mutable state.

Не выбирайте receiver на основании одного предполагаемого allocation. Compiler способен inline-ить методы и размещать значения независимо от синтаксиса receiver. Семантика API первична, performance подтверждается benchmark.

## Типичные ошибки

**Неверное предположение:** если `x.M()` компилируется, `T` реализует interface с `M`. **Симптом:** compile-time error при присваивании `T` interface. **Причина:** automatic `&x` относится к вызову, не к method set. **Исправление:** проверять `var _ I = (*T)(nil)`/`T{}` и выбирать receiver осознанно.

**Неверное предположение:** value receiver защищает все данные от mutation. **Симптом:** метод меняет элементы общего slice или map. **Причина:** копия receiver поверхностная. **Исправление:** клонировать вложенные данные или явно документировать mutation.

**Неверное предположение:** можно свободно смешивать receivers. **Симптом:** разные формы одного типа неожиданно реализуют разные interfaces. **Причина:** method sets расходятся. **Исправление:** использовать один receiver kind для согласованного набора методов, кроме обоснованных исключений.

## Когда применять

- Value receiver: небольшое value, операция логически не меняет identity, копирование безопасно.
- Pointer receiver: mutation, identity, крупное/non-copyable состояние или необходимость разделять один объект.
- Добавляйте compile-time interface assertions на границах package.
- Проверяйте addressability отдельно от method set.

## Источники

- [The Go Programming Language Specification: Method sets, Method declarations, Calls](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Go Wiki: MethodSets](https://go.dev/wiki/MethodSets) — The Go Project, Go 1.x, проверено 2026-07-15.
- [Спецификация Go из исходников](https://go.googlesource.com/go/+/refs/tags/go1.26.5/doc/go_spec.html) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
