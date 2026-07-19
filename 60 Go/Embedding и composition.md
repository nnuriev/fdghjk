---
aliases:
  - Embedding and composition в Go
tags:
  - область/go
  - тема/язык
статус: проверено
---

# Embedding и composition

## TL;DR

Embedding объявляет поле только именем типа и позволяет продвигать (**promote**) его поля и методы в selectors внешнего struct. Это синтаксическая композиция, не наследование: внешний тип не становится подтипом embedded типа, promoted method сохраняет исходный receiver, а «переопределение» метода внешним типом не создаёт virtual dispatch внутри embedded реализации.

## Область применимости

- Версия Go: 1.26; стабильная toolchain при проверке — Go 1.26.5.
- GOOS/GOARCH: не влияют.
- Область: embedded fields, promoted selectors/methods, method sets и embedded interfaces.

## Ментальная модель

```go
type Service struct {
	Logger
}
```

Это означает: у `Service` есть обычное поле с именем `Logger` и типом `Logger`; оно подчиняется обычным [[60 Go/Структуры, указатели и методы|правилам структур и selectors]]. Выражение `s.Print()` может быть сокращением `s.Logger.Print()`, если на минимальной глубине есть ровно один подходящий selector.

Никакой связи `Service is-a Logger` язык не создаёт. Значение `Service` нельзя передать как `Logger` без явного выбора `s.Logger`. Promotion добавляет удобные selectors и влияет на method set, но не меняет identity receiver.

## Как устроено

- Embedded field задаётся как type name `T` или pointer to non-interface type `*T`; имя поля выводится из unqualified type name.
- Поля и методы продвигаются, если `x.f` образует допустимый selector через embedded path.
- Если на одной минимальной глубине найдено несколько одинаковых имён, selector ambiguous и не компилируется. Более глубокие совпадения скрываются более мелким.
- Внешний тип может объявить поле или метод с тем же именем и тем самым скрыть promoted selector, но embedded member остаётся доступен по полному пути.
- Если struct содержит embedded `T`, method sets `S` и `*S` получают promoted методы с receiver `T`; только `*S` получает также promoted методы `*T`. Это частный случай общих [[60 Go/Pointer и value receivers, method sets|правил pointer/value receivers и method sets]].
- Если embedded field — `*T`, и `S`, и `*S` получают promoted методы с receivers `T` и `*T`.
- При embedding interface его методы добавляются в method set внешнего interface, а итоговый type set становится пересечением type sets всех interface elements. Это композиция контрактов из [[60 Go/Интерфейсы и неявная реализация|модели интерфейсов и неявной реализации]], а не полей.

Вызов метода из реализации embedded типа использует его статически выбранный receiver. Он не ищет метод с тем же именем у внешнего struct, как virtual method в иерархии классов.

## Код

```go
package main

import "fmt"

type Base struct{ Name string }

func (b Base) Label() string { return "base:" + b.Name }
func (b Base) Describe() string {
	return "describe " + b.Label()
}

type Widget struct{ Base }

func (w Widget) Label() string { return "widget:" + w.Name }

func main() {
	w := Widget{Base: Base{Name: "x"}}
	fmt.Println(w.Label())
	fmt.Println(w.Describe())
	fmt.Println(w.Base.Label())
}
```

## Ожидаемый результат

```text
widget:x
describe base:x
base:x
```

`Widget.Label` скрывает promoted `Base.Label` для selector `w.Label`. Но promoted `Describe` выполняется с receiver `Base`; его внутренний `b.Label()` вызывает `Base.Label`, а не `Widget.Label`.

## Trade-offs

С named field (`logger Logger`) dependency path и forwarding остаются явными, поэтому API внешнего типа не расширяется случайно. Embedding уменьшает boilerplate и полезен, когда promoted API действительно входит в семантику внешнего типа.

Embedding concrete implementation связывает публичный method set внешнего типа с эволюцией embedded типа: новый метод может неожиданно стать promoted или столкнуться с именем. Embedding маленького interface выражает композицию capabilities устойчивее, но большой embedded interface наследует его высокую стоимость изменений.

Embedding pointer позволяет разделять optional/shared component и продвигает pointer methods, но zero value внешнего struct может panic при вызове promoted method через nil field. Embedding value чаще даёт полезный zero value, если zero value компонента пригоден.

## Типичные ошибки

**Неверное предположение:** embedding создаёт наследование и virtual override. **Симптом:** embedded метод вызывает свою реализацию, а не одноимённый метод outer type. **Причина:** receiver остаётся embedded value. **Исправление:** передать dependency через interface/callback либо явно реализовать orchestration во внешнем типе.

**Неверное предположение:** все promoted имена всегда доступны. **Симптом:** `ambiguous selector`. **Причина:** на одинаковой глубине есть несколько кандидатов. **Исправление:** выбрать полный path или объявить явный forwarding method.

**Неверное предположение:** embedding не меняет публичный API. **Симптом:** новый метод dependency меняет interface satisfaction или создаёт collision. **Причина:** promotion участвует в method set. **Исправление:** на стабильной границе предпочитать named field и явные методы.

**Неверное предположение:** zero value с embedded pointer безопасен. **Симптом:** nil dereference в promoted method. **Причина:** embedded field равен nil. **Исправление:** embed value, проверять nil или обеспечить constructor-инвариант.

## Когда применять

- Embed interface, если внешний interface — точная композиция нескольких capabilities.
- Embed implementation, когда promoted API намеренно должен стать API внешнего типа.
- Используйте named field для внутренних dependencies и delegation, которые не должны «протекать» наружу.
- Проверяйте method sets compile-time assertions после добавления embedded полей.

## Источники

- [The Go Programming Language Specification: Struct types, Selectors, Method sets, Embedded interfaces](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Спецификация Go из исходников](https://go.googlesource.com/go/+/refs/tags/go1.26.5/doc/go_spec.html) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
