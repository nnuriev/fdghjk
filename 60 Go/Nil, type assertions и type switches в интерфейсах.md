---
aliases:
  - Nil interfaces and type assertions в Go
tags:
  - область/go
  - тема/язык
статус: проверено
---

# Nil, type assertions и type switches в интерфейсах

## TL;DR

Interface равен nil только когда у него нет ни dynamic type, ни dynamic value. Pointer с nil-значением, присвоенный interface, создаёт non-nil interface с dynamic type `*T`. Type assertion проверяет dynamic type во время выполнения: одно-result форма panic при несовпадении, comma-ok возвращает `false`; type switch группирует такие проверки без повторных assertions.

## Область применимости

- Версия Go: 1.26; стабильная toolchain при проверке — Go 1.26.5.
- GOOS/GOARCH: не влияют.
- Область: interface values, nil, assertions и type switches; особенно `error`.

## Ментальная модель

Представляйте interface как пару:

```text
(dynamic type, dynamic value)
```

Zero value interface — `(нет типа, нет значения)` и равен nil. После `var p *MyError; var err error = p` состояние становится `(*MyError, nil)`: dynamic value nil, но тип присутствует, поэтому `err != nil`. Эта пара напрямую следует из базовой [[60 Go/Интерфейсы и неявная реализация|модели interface и неявной реализации]].

Assertion `x.(T)` задаёт вопрос: «содержит ли `x` dynamic value, чей тип удовлетворяет `T`?» Для concrete `T` dynamic type должен совпасть; для interface `T` dynamic type должен реализовать его.

## Как устроено

- Сравнение interface с nil проверяет пустоту всей пары, а не nil-ность возможного dynamic value; сравнение двух non-nil interface дополнительно подчиняется [[60 Go/Равенство и comparability типов|правилам comparability dynamic values]].
- Вызов метода на interface с typed nil всё равно dispatch-ится методу `*T`. Метод может осознанно обработать nil receiver, но разыменование внутри него вызовет panic.
- `v := x.(T)` вызывает panic, если assertion неверна или `x` nil. Это programmer invariant, а не обычная ветвь обработки; границы допустимого recovery описаны в [[60 Go/defer, panic и recover|defer, panic и recover]].
- `v, ok := x.(T)` возвращает zero value `T` и `false` без panic.
- В `switch v := x.(type)` case-ветви задают concrete types или interfaces; `case nil` ловит только nil interface, не typed nil pointer.
- Assertions допустимы только для interface expression. Для generics используются type constraints; type switch по type parameter напрямую не заменяет обычный constraint.

Самая опасная форма встречается при возврате `error`: функция создаёт `var e *MyError = nil` и возвращает `e`. Вызывающий видит non-nil error и считает операцию неуспешной, поэтому [[60 Go/Обработка ошибок|контракт обработки ошибок]] требует literal `nil` на успешной ветви.

## Код

```go
package main

import "fmt"

type Problem struct{ message string }

func (p *Problem) Error() string {
	if p == nil {
		return "<nil Problem>"
	}
	return p.message
}

func inspect(x any) {
	switch v := x.(type) {
	case nil:
		fmt.Println("nil interface")
	case error:
		fmt.Printf("error %T: %s\n", v, v.Error())
	default:
		fmt.Printf("other %T\n", v)
	}
}

func main() {
	var p *Problem
	var err error = p

	fmt.Println(err == nil)
	inspect(nil)
	inspect(err)
	_, ok := any(42).(string)
	fmt.Println(ok)
}
```

## Ожидаемый результат

```text
false
nil interface
error *main.Problem: <nil Problem>
false
```

`case nil` не срабатывает для `err`, потому что dynamic type `*main.Problem` уже установлен.

## Trade-offs

Comma-ok assertion подходит на динамической границе, где несколько типов — часть контракта. Interface method лучше, когда ветвление выражает устойчивое поведение: compiler тогда проверяет реализации, а новый type не требует менять центральный switch.

Nil interface удобно обозначает «значения нет». Typed nil может быть полезен внутри конкретного API, но при стирании типа в interface он неоднозначен. Для `error` безопасный контракт — возвращать literal `nil` при успехе.

Reflection умеет исследовать произвольные типы глубже, но сложнее, медленнее и переносит ошибки в runtime. Type switch предпочтительнее для конечного известного множества dynamic types.

## Типичные ошибки

**Неверное предположение:** nil pointer внутри interface делает interface nil. **Симптом:** `err != nil` после успешной операции. **Причина:** dynamic type присутствует. **Исправление:** возвращать `nil` interface напрямую; создавать typed error только при реальной ошибке.

**Неверное предположение:** `case nil` поймает любой typed nil. **Симптом:** выполнение попадает в case конкретного или interface-типа, а затем возникает panic. **Причина:** switch смотрит на dynamic type. **Исправление:** не передавать typed nil либо внутри конкретной ветви проверять nil, когда контракт это допускает.

**Неверное предположение:** одно-result assertion безопасна для внешних данных. **Симптом:** panic на новом или повреждённом типе. **Причина:** mismatch считается нарушением programmer invariant. **Исправление:** использовать comma-ok и явную ошибку на trust boundary; panic оставлять для доказанного инварианта.

## Когда применять

- Возвращайте `nil` как `error` при отсутствии ошибки, а не typed nil.
- Используйте comma-ok, если mismatch ожидаем и должен обрабатываться.
- Type switch применяйте для закрытого набора представлений на boundary parsing/adaptation.
- Если switch растёт вместе с числом реализаций, пересмотрите interface contract.

## Источники

- [The Go Programming Language Specification: Interface types, Type assertions, Type switches, Comparison operators](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [The Laws of Reflection: The representation of an interface](https://go.dev/blog/laws-of-reflection) — The Go Project, Go 1.x, проверено 2026-07-15.
- [Package builtin: error](https://pkg.go.dev/builtin@go1.26.5#error) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
