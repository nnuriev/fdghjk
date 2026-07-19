---
aliases:
  - Function values в Go
  - Замыкания в Go
  - Functions as values в Go
tags:
  - область/go
  - тема/семантика-языка
статус: проверено
---

# Функции, function values и замыкания

## TL;DR

Функция в Go — значение своего function type. Её можно сохранить в переменной, передать аргументом, вернуть из другой функции и связать с данными через замыкание (closure). Method value сохраняет вычисленный receiver, а method expression делает receiver явным первым аргументом.

У function value есть `nil` как zero value, но вызвать `nil` нельзя: будет panic. Сравнивать две функции тоже нельзя — допустимо только сравнение функции с `nil`. Замыкание захватывает переменные, а не моментальный снимок их значений; если несколько goroutines обращаются к общей захваченной переменной, им нужна обычная синхронизация.

## Область применимости

- Язык: Go 1.26; toolchain Go 1.26.5, проверено 2026-07-18.
- Исполняемый пример проверен на `darwin/arm64` командами `go test`, `go vet` и `go test -race`.
- Для variables цикла отдельно рассматриваются module language versions Go 1.21 и Go 1.22+.
- Вне scope: ABI-представление function value, детали реализации closures компилятором и ручная сборка trampolines.

## Ментальная модель

Function type описывает полный контракт вызова: типы и порядок параметров, число результатов и их типы. Function value — конкретная вызываемая реализация этого контракта. Благодаря этому callback остаётся обычным типизированным значением, а функция высшего порядка (higher-order function) может принимать поведение или возвращать его без отдельного interface.

Замыкание состоит из function value и доступа к переменным из внешней лексической области. Важно именно слово «переменным»: два closure над одним `n` видят одно изменяемое состояние. Если closure переживает вызов, в котором `n` был объявлен, время жизни `n` продлевается. Язык не гарантирует конкретное размещение — stack, heap или оптимизированное представление; его исследуют через [[60 Go/Стеки и escape analysis|escape analysis]], когда это влияет на профиль.

## Как устроено

### Function types и higher-order functions

Именованный тип вроде `type Transform func(string) string` превращает сигнатуру в предметный контракт. Значения подходящих функций можно передавать в `Transform`, хранить в struct, собирать в pipeline и возвращать из factory. Это не создаёт неявной асинхронности: вызов function value остаётся обычным синхронным вызовом, пока код явно не использовал `go`.

Zero value любого function type равен `nil`. Проверка `f == nil` допустима, но `f()` при `f == nil` вызывает panic. Друг с другом function values не сравниваются и не могут быть keys встроенного map. Если function value спрятан в interface, сравнение interfaces с одинаковым dynamic type функции также приводит к panic; общие правила разобраны в [[60 Go/Равенство и comparability типов|заметке о comparability]].

### Method value и method expression

Для метода `func (p Prefixer) Add(string) string` выражение `p.Add` — **method value**. Receiver `p` вычисляется в момент создания значения и сохраняется; итоговая сигнатура — `func(string) string`. Для value receiver сохраняется соответствующее значение receiver, для pointer receiver — значение указателя, то есть alias на объект.

`Prefixer.Add` — **method expression** с сигнатурой `func(Prefixer, string) string`. Receiver ничего не захватывает: caller передаёт его первым аргументом. Method value удобен как настроенный callback, method expression — когда один алгоритм должен явно работать с разными receivers.

### Closure lifetime и concurrent access

Closure может читать и менять захваченную переменную после возврата внешней функции. Это полезно для счётчика или конфигурированного обработчика, но владение состоянием должно оставаться явным. Если closure передали нескольким goroutines, сам факт захвата не создаёт happens-before; правила остаются теми же, что в [[60 Go/Модель памяти Go и happens-before|модели памяти Go]]. Shared mutation защищают mutex/atomic либо заменяют передачей сообщений.

### Variables цикла: граница Go 1.22

До language version Go 1.22 variables, объявленные clause `for` или `range`, переиспользовались между iterations. Closures обычно наблюдали одну общую variable и могли получить её позднее значение. Начиная с language version Go 1.22 каждая iteration получает новые declared variables.

Изменение не распространяется на заранее объявленную variable, которой цикл только присваивает значение, например `var v T; for _, v = range values`: она по-прежнему одна. Поэтому при чтении старого кода сначала выясняют language version модуля и форму объявления, а уже потом диагностируют capture. Практический разбор гонок и ожидания goroutines находится в [[60 Go/Goroutines и lifecycle|заметке о lifecycle goroutine]].

## Код

`functions.go`:

```go
package functions

// Transform is a named function type.
type Transform func(string) string

// Apply passes the result of each function to the next one.
func Apply(input string, transforms ...Transform) string {
	result := input
	for _, transform := range transforms {
		result = transform(result)
	}
	return result
}

type Prefixer struct {
	Prefix string
}

func (p Prefixer) Add(value string) string {
	return p.Prefix + value
}

// Counter returns a closure that owns the captured variable n.
func Counter(start int) func() int {
	n := start
	return func() int {
		n++
		return n
	}
}
```

`functions_test.go`:

```go
package functions

import (
	"strings"
	"testing"
)

func TestFunctionValuesMethodsAndClosure(t *testing.T) {
	prefixer := Prefixer{Prefix: "go:"}
	methodValue := prefixer.Add
	methodExpression := Prefixer.Add

	if got := Apply("codex", strings.ToUpper, methodValue); got != "go:CODEX" {
		t.Fatalf("Apply() = %q, want %q", got, "go:CODEX")
	}
	if got := methodExpression(prefixer, "test"); got != "go:test" {
		t.Fatalf("method expression = %q, want %q", got, "go:test")
	}

	next := Counter(10)
	if got := next(); got != 11 {
		t.Fatalf("first counter value = %d, want 11", got)
	}
	if got := next(); got != 12 {
		t.Fatalf("second counter value = %d, want 12", got)
	}

	var transform Transform
	if transform != nil {
		t.Fatal("zero function value must be nil")
	}
}
```

## Ожидаемый результат

На Go 1.26.5 тест проходит. Pipeline сначала превращает `codex` в `CODEX`, затем method value добавляет сохранённый prefix и получает `go:CODEX`. Method expression требует receiver явно. Два вызова closure возвращают `11` и `12`, потому что используют один `n`.

Отдельный детерминированный пример с тремя closures цикла проверен в двух временных модулях одним toolchain Go 1.26.5: директива `go 1.21` в `go.mod` дала `3 3 3`, а `go 1.26` — `0 1 2`, проверено 2026-07-18. Семантику выбирает language version модуля; одной версии установленного toolchain для вывода недостаточно.

## Эволюция и версии

| Версия языка | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| До Go 1.22 → Go 1.22+ | Declared loop variables переиспользовались iterations | Для variables, объявленных самим `for`/`range`, каждая iteration создаёт новые variables | Большинство старых closure-capture bugs исчезает; заранее объявленная и присваиваемая variable остаётся общей | [Go 1.22 Release Notes](https://go.dev/doc/go1.22) |

## Trade-offs

- Function dependency компактнее interface для одной операции и естественно принимает closure. Interface лучше выражает связный protocol из нескольких методов и позволяет документировать несколько операций одним типом; критерий выбора показан в [[50 Проектирование систем/Dependency injection в Go без framework dependency|заметке о dependency injection]].
- Closure прячет небольшую конфигурацию без дополнительного struct, но скрытое mutable state усложняет lifecycle, тестирование и concurrency reasoning.
- Method value удобен, когда receiver нужно зафиксировать один раз. Method expression делает data flow явнее и не создаёт отдельного настроенного callback на каждый receiver.

## Типичные ошибки

- **Предположение:** closure сохраняет текущее значение variable. **Симптом:** несколько callbacks видят одно позднее значение или влияют друг на друга. **Причина:** захвачена variable, а не snapshot. **Исправление:** создать отдельную variable, передать значение параметром либо хранить immutable copy.
- **Предположение:** `nil` function — no-op. **Симптом:** panic при вызове optional callback. **Причина:** `nil` — допустимое значение типа, но у него нет вызываемого кода. **Исправление:** проверять `nil` на boundary или подставлять явную no-op function.
- **Предположение:** function values можно сравнить как pointers на код. **Симптом:** код не компилируется либо сравнение interfaces паникует. **Причина:** функция не comparable, кроме сравнения с `nil`. **Исправление:** сравнивать устойчивый ID/config, а не function value.
- **Предположение:** Go 1.22 устранил любой capture общего состояния. **Симптом:** race остаётся у `for _, v = range` с заранее объявленным `v` или у другого captured state. **Причина:** новая семантика относится только к variables, объявленным циклом. **Исправление:** проверить конкретное объявление и прогнать `go test -race`.

## Когда применять

Function types подходят для небольших callbacks, Strategy из одной операции, dependency injection и построения pipeline. Closure уместен, когда захваченное состояние мало, его владелец и lifetime очевидны. Если callback накапливает несколько операций, сложный lifecycle или конкурентно изменяемое состояние, явный struct с методами обычно проще сопровождать.

## Источники

- [The Go Programming Language Specification](https://go.dev/ref/spec#Function_types) — The Go Project, спецификация языка Go 1.26, function types и function values, проверено 2026-07-18.
- [Method values](https://go.dev/ref/spec#Method_values) — The Go Project, спецификация языка Go 1.26, сохранение receiver в method value, проверено 2026-07-18.
- [Method expressions](https://go.dev/ref/spec#Method_expressions) — The Go Project, спецификация языка Go 1.26, receiver как первый аргумент, проверено 2026-07-18.
- [Comparison operators](https://go.dev/ref/spec#Comparison_operators) — The Go Project, спецификация языка Go 1.26, сравнимость function values только с `nil`, проверено 2026-07-18.
- [For statements](https://go.dev/ref/spec#For_statements) — The Go Project, спецификация языка Go 1.26, iteration variables и версионная пометка Go 1.22, проверено 2026-07-18.
- [Go 1.22 Release Notes](https://go.dev/doc/go1.22) — The Go Project, Go 1.22, новая семантика loop variables, проверено 2026-07-18.
- [Package testing](https://pkg.go.dev/testing@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, проверено 2026-07-18.
