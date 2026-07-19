---
aliases:
  - Defer, panic and recover в Go
tags:
  - область/go
  - тема/язык
статус: проверено
---

# defer, panic и recover

## TL;DR

`defer` регистрирует вызов при выходе из текущей function; function value и arguments вычисляются сразу, а вызовы выполняются LIFO. `panic` прекращает обычное выполнение и раскручивает stack этой goroutine, запуская defers. `recover` останавливает раскрутку только когда вызван напрямую deferred function той же panicking goroutine. Это механизм для защиты process boundary и инвариантов, а не замена [[60 Go/Обработка ошибок|обычной обработке ошибок]].

## Область применимости

- Версия Go: 1.26; стабильная toolchain при проверке — Go 1.26.5.
- GOOS/GOARCH: языковые правила не зависят; некоторые fatal runtime failures не относятся к recoverable panic.
- Область: defer statements, panic/recover, named results и goroutine boundaries.

## Ментальная модель

У каждой активной function есть стек зарегистрированных deferred calls. При любом её возврате — явном, достижении конца или panic unwinding — Go выполняет эти calls в обратном порядке.

Panic принадлежит текущей goroutine. Он поднимается по её call stack, а не через channel и не к goroutine, которая её запустила. Поэтому recovery должен выполнять компонент, владеющий [[60 Go/Goroutines и lifecycle|lifecycle этой goroutine]]. Если раскрутка достигает вершины без recovery, program завершается с stack trace.

Recovery — узкая точка преобразования panic в контролируемый результат. Она должна находиться на boundary, где известны инварианты: например, вокруг одного request/plugin callback; в [[60 Go/HTTP-сервер на net-http|HTTP-сервере на net/http]] такой boundary изолирует конкретный запрос, но не делает повреждённое общее состояние безопасным. После recovery функция не продолжает с места panic; deferred function завершается, затем panicking function возвращает согласно правилам её results.

## Как устроено

Три правила `defer`:

1. Function value и arguments deferred call вычисляются при выполнении `defer`.
2. Deferred calls одной function выполняются LIFO.
3. Deferred closure может читать и менять named result variables до фактического возврата.

`recover()` возвращает panic value, только если все условия выполняются одновременно: текущая goroutine находится в состоянии panic, вызов сделан непосредственно из deferred function, а panic ещё не остановлен. В обычном коде, в другой goroutine или через дополнительную helper-function результат nil.

`runtime.Goexit` выполняет defers, но не запускает panic, поэтому `recover` возвращает nil. Не все аварии runtime можно восстановить: fatal error и некоторые memory faults завершают process.

Defer внутри loop относится ко всей surrounding function, а не к lexical block. Ресурс освободится только при выходе из function; для большого loop вынесите одну итерацию в отдельную function. Это особенно важно для `Rows` и транзакций из [[60 Go/Пакет database-sql и пулы соединений|database/sql]]: задержанный cleanup удерживает соединение из ограниченного пула.

## Код

```go
package main

import "fmt"

func guarded() (result string) {
	defer func() {
		if v := recover(); v != nil {
			result = fmt.Sprintf("recovered: %v", v)
		}
	}()

	defer fmt.Println("cleanup 1")
	defer fmt.Println("cleanup 2")
	panic("broken invariant")
}

func main() {
	fmt.Println(guarded())
}
```

## Ожидаемый результат

```text
cleanup 2
cleanup 1
recovered: broken invariant
```

Сначала выполняются defers, зарегистрированные позже. Внешний deferred closure останавливает panic и записывает named result.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| До 1.21 | `panic(nil)` мог привести к `recover() == nil`, неотличимому от отсутствия panic | С Go 1.21 `panic(nil)` создаёт non-nil `*runtime.PanicNilError`; старое поведение доступно через `GODEBUG=panicnil=1` и автоматически для main module с `go 1.20` или ниже | Deferred recovery может полагаться на non-nil result во время panic при новом language mode | [Go 1.21 Release Notes](https://go.dev/doc/go1.21) |

## Trade-offs

Явный `error` сохраняет ожидаемый failure в type signature и заставляет caller выбрать policy. Panic сокращает propagation через уровни, но скрывает control flow и может завершить весь process. Поэтому panic уместен для programmer invariant или невозможности продолжать локальную операцию, а не для network, parsing и business failures.

Defer помещает cleanup рядом с acquisition и устойчив к новым return paths. Ручной cleanup может быть чуть очевиднее в hot loop и позволяет освободить ресурс раньше. Современный compiler оптимизирует многие defers; performance-решение подтверждают benchmark, а lifecycle-решение важнее по умолчанию.

Recovery на каждой функции скрывает bugs и оставляет partially mutated state. Recovery на изолированной boundary позволяет записать diagnostic и отклонить только одну единицу работы, если данные процесса после panic всё ещё считаются надёжными.

## Типичные ошибки

**Неверное предположение:** deferred arguments вычислятся при возврате. **Симптом:** логируется старое значение. **Причина:** arguments зафиксированы при регистрации. **Исправление:** использовать closure, если нужно прочитать финальное значение.

**Неверное предположение:** `recover` сработает в обычной helper function. **Симптом:** process всё равно падает. **Причина:** recover должен быть вызван напрямую из deferred function. **Исправление:** помещать вызов в deferred closure boundary.

**Неверное предположение:** parent goroutine может recover panic child. **Симптом:** unrecovered panic завершает program. **Причина:** stacks goroutines независимы. **Исправление:** recovery ставит сама child goroutine и передаёт structured error/result.

**Неверное предположение:** defer в loop немедленно закрывает каждый ресурс. **Симптом:** исчерпаны descriptors/connections. **Причина:** defers ждут выхода surrounding function. **Исправление:** выделить тело итерации в function или закрывать ресурс явно в конце итерации.

## Когда применять

- Сразу defer-ьте release после успешного acquisition, если ресурс должен жить до конца function.
- Возвращайте error для ожидаемых отказов.
- Panic используйте для нарушенного programmer invariant или инициализации, без которой process бессмысленен.
- Recover ставьте на boundary изолированной работы, добавляйте stack diagnostic и не продолжайте с подозрительным общим состоянием.

## Источники

- [The Go Programming Language Specification: Defer statements, Handling panics](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Package builtin: panic and recover](https://pkg.go.dev/builtin@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Go 1.21 Release Notes: panic(nil)](https://go.dev/doc/go1.21) — The Go Project, Go 1.21, проверено 2026-07-15.
