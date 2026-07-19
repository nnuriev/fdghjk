---
aliases:
  - Goroutine stacks и escape analysis
tags:
  - область/go
  - тема/runtime
  - тема/производительность
статус: проверено
---

# Стеки и escape analysis

## TL;DR

У каждой goroutine есть растущий stack, который runtime при необходимости заменяет большим и копирует. Отдельно компилятор выполняет escape analysis: если время жизни значения или доступ к нему нельзя безопасно ограничить stack frame, storage размещается в heap. Синтаксис `new(T)`, pointer receiver или локальная переменная сами по себе не определяют размещение. Heap allocation — не ошибка, но она добавляет работу allocator и потенциальный объём сканирования [[60 Go/Аллокации, GC и GC pressure|GC]]; оптимизировать её следует по diagnostics и профилю, а не по догадке.

## Область применимости

- Версия Go: семантика указателей Go 1.26; реализация compiler/runtime Go 1.26.5.
- GOOS/GOARCH: детали примера и исходников проверяются для linux/amd64; growable stacks переносимы, начальный размер и механика safe points — implementation details.
- Компоненты: `cmd/compile/internal/escape`, goroutine stacks, heap allocator и GC.
- Вне scope: ручное управление адресами через `unsafe`.

## Ментальная модель

Нужно разделять два решения.

Первое принимает compiler: где хранить конкретное значение так, чтобы все допустимые ссылки оставались валидными. Если ссылка переживает вызов, записывается в global, возвращается вызывающему коду или попадает в объект с более долгим lifetime, значение обычно **escapes to heap**. Если compiler доказывает обратное, даже объект, созданный через `new`, может остаться на stack.

Второе принимает runtime: достаточно ли места в stack текущей goroutine. Function prologue проверяет stack guard. При нехватке runtime выделяет больший stack, копирует живые frames и корректирует отслеживаемые Go pointers. Поэтому адрес локального значения допустимо возвращать: compiler разместит его так, чтобы lifetime был корректен.

Практический вывод: «pointer» — свойство доступа, «heap» — результат анализа lifetime. Это разные оси.

## Как устроено

В исходниках Go 1.26.5 `stackMin` равен 2048 байтам; platform-specific `stackSystem` может увеличить минимальный размер. Это не API и не основание рассчитывать глубину recursion.

Compiler строит граф потока значений между locations и помечает flows, которые выходят за lifetime frame. Диагностика `-gcflags=-m=2` объясняет основные причины. Формулировки diagnostics и решения могут меняться между point releases и из-за inlining.

Типичные причины escape:

- адрес записан в global или heap object;
- pointer возвращён из функции;
- closure переживает вызов и захватывает переменную;
- значение передано операции, для которой compiler не может доказать lifetime;
- размер объекта или frame не подходит для stack allocation конкретной версии compiler.

Обратное тоже важно: передача pointer в inlined helper не обязана создавать allocation, если pointer не сохраняется. Interface conversion и closure также не означают allocation во всех случаях.

Stack growth требует, чтобы runtime знал расположение Go pointers. `uintptr` не считается pointer и не удерживает объект живым; хранить в нём адрес между операциями, где stack или object может переместиться либо стать недостижимым, нельзя без строго документированного unsafe-протокола.

## Код

Файл `main.go`:

~~~go
package main

import "fmt"

var sink *int

//go:noinline
func escapes() {
	x := 42
	sink = &x
}

func main() {
	escapes()
	fmt.Println(*sink)
}
~~~

Команды:

~~~text
go build -gcflags="-m=2" main.go 2>&1 | grep "moved to heap: x"
go run main.go
~~~

## Ожидаемый результат

Первая команда печатает одну diagnostic line, оканчивающуюся точным фрагментом:

~~~text
moved to heap: x
~~~

Префикс содержит путь и номер строки и потому зависит от расположения файла. Вторая команда печатает:

~~~text
42
~~~

Запись `&x` в global делает lifetime больше frame `escapes`, поэтому compiler обязан сохранить storage после возврата. Программа выполнена в официальном Go Playground на Go 1.26.5 и напечатала `42`; compiler diagnostic с `-gcflags=-m=2` Playground не предоставляет, проверено 2026-07-15.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| до 1.26 | Часть backing stores для slices уходила в heap, даже когда lifetime допускал stack | — | Diagnostics и `allocs/op` зависели от версии compiler | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |
| 1.26 | — | Compiler размещает backing store slices на stack в большем числе случаев | После обновления toolchain нужно заново измерять allocations; старое объяснение escape может устареть | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |

## Trade-offs

Value parameter выражает независимое значение и уменьшает aliasing, но большой struct может копироваться. Pointer parameter позволяет изменять общий объект и иногда уменьшает копирование, но добавляет nil, aliasing и потенциальный escape. Выбор сначала делают по [[60 Go/Zero values, семантика значений и копирование|семантике значения и копирования]], затем проверяют compiler diagnostics и benchmark.

Принудительное устранение allocation часто усложняет ownership и увеличивает lifetime больших buffers. Одна allocation вне hot path обычно дешевле, чем pool, ручной arena-подобный lifecycle или небезопасный reuse.

Глубокая recursion естественно использует growable stack, но stack growth и scan roots имеют цену. Итеративная форма выигрывает, когда глубина неконтролируема или frame велик; recursion лучше сохраняет структуру алгоритма при доказанной границе.

## Типичные ошибки

**Неверное предположение:** `new(T)` всегда создаёт heap object. **Симптом:** API переписывают на values, но allocations не меняются. **Причина:** размещение выбирает escape analysis. **Исправление:** смотреть `-m=2` и `allocs/op`.

**Неверное предположение:** pointer receiver всегда быстрее. **Симптом:** больше heap allocations и GC pressure. **Причина:** pointer или захват значения продлил lifetime либо усложнил доказательство compiler. **Исправление:** выбирать [[60 Go/Pointer и value receivers, method sets|pointer или value receiver]] по mutability и identity, затем измерять.

**Неверное предположение:** diagnostic конкретной toolchain — стабильная гарантия. **Симптом:** benchmark меняется после обновления Go без изменения исходника. **Причина:** escape analysis и inlining — implementation details. **Исправление:** фиксировать toolchain в измерении и повторять его при upgrade.

**Неверное предположение:** `uintptr` удерживает адресуемый объект и корректируется при stack growth. **Симптом:** редкая порча памяти в unsafe-коде. **Причина:** `uintptr` — integer, а не tracked pointer. **Исправление:** соблюдать правила `unsafe.Pointer` и не хранить адрес как integer между операциями.

## Когда применять

- Используйте `-gcflags="-m=2"` для объяснения конкретной allocation, но подтверждайте её [[60 Go/Бенчмарки|benchmark]] и [[60 Go/Профилирование с pprof|профилем pprof]].
- Сокращайте lifetime ссылок и buffers, когда это одновременно упрощает ownership.
- Не публикуйте внутренние compiler decisions как контракт API.
- При сравнении указывайте Go 1.26.5 и GOOS/GOARCH.

## Источники

- [runtime/stack.go: stack guards, minimum stack и growth machinery](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/stack.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [cmd/compile/internal/escape](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/cmd/compile/internal/escape/) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [Package runtime](https://pkg.go.dev/runtime@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Package unsafe: Pointer rules](https://pkg.go.dev/unsafe@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Go 1.26 Release Notes: compiler](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
