---
aliases:
  - CourseHunter 6609 — ошибки и panic
tags:
  - тип/разбор-курса
  - источник/coursehunter
  - язык/go
  - тема/ошибки
статус: проверено
---

# Ошибки и panic: теория и 8 задач курса

## Урок 59. Ошибка как значение

![[90 Вложения/CurseHunter/6609/Кадры/059.jpg]]

`error` — interface с `Error() string`. Ожидаемая operational failure возвращается как error value; panic оставляют для нарушенного invariant или ситуации, где текущий frame не может продолжить. Хорошая chain через `%w` рассказывает, какая операция не удалась и сохраняет machine-readable cause. Практика собрана в [[60 Go/Обработка ошибок|заметке об обработке ошибок]].

## Урок 60. «Константная» sentinel error

![[90 Вложения/CurseHunter/6609/Кадры/060.jpg]]

Курс объявляет comparable immutable sentinel:

```go
type Error string
func (e Error) Error() string { return string(e) }
const ErrEOF = Error("EOF")
```

Его нельзя переназначить, а другое `Error("EOF")` равно по значению. Обычная `errors.New("EOF")` создаёт отдельное pointer-backed value и не равно `io.EOF` только по тексту.

`io.EOF` — exported variable, поэтому технически его можно переназначить. Делать это нельзя: mutation ломает package-wide identity и при concurrency создаёт race. Для library API чаще достаточно exported `var ErrX = errors.New(...)` плюс запрета mutation по convention; constant pattern ограничивает возможность добавлять fields.

## Урок 61. Division by zero

![[90 Вложения/CurseHunter/6609/Кадры/061.jpg]]

Integer division на runtime zero вызывает panic. Deferred closure в той же goroutine может вызвать `recover`; если function имеет unnamed result и panic recovered до обычного return, caller получает zero value результата. Constant divisor zero — compile error.

## Урок 62. Stack overflow и OOM

![[90 Вложения/CurseHunter/6609/Кадры/062.jpg]]

Stack exhaustion и out-of-memory — runtime fatal errors, на которые нельзя строить recovery. Они завершают process, а обычный defer/recover не превращает их в error. В OOM-примере страницы памяти явно touch-ятся, поэтому это не только virtual address reservation.

## Урок 63. Nil pointer dereference

![[90 Вложения/CurseHunter/6609/Кадры/063.jpg]]

Обычный nil dereference вызывает recoverable panic. Recovery должен находиться в directly deferred function той же goroutine. Это не оправдание использовать panic для validation: проверяемые input errors возвращают явно.

## Урок 64. Wrapped errors

![[90 Вложения/CurseHunter/6609/Кадры/064.jpg]]

- `fmt.Errorf("...: %w", ErrDatabase)` сохраняет chain; `errors.Is` ищет sentinel по ней.
- Wrapped typed error извлекают `errors.As`.
- Direct `err == sentinel` и type switch по outer error после wrapping не находят cause.

Идиоматическая форма `As` сохраняет результат:

```go
var dbErr DatabaseError
if errors.As(err, &dbErr) { /* use dbErr */ }
```

Показанное `errors.As(err, &DatabaseError{})` может пройти, но найденное значение сразу теряется и ухудшает читаемость.

## Урок 65. Когда defers выполняются

![[90 Вложения/CurseHunter/6609/Кадры/065.jpg]]

| Завершение | Defers | `recover` получает panic |
| --- | --- | --- |
| `panic` | да, при раскрутке stack | да |
| `runtime.Goexit` | да | нет, это не panic |
| `os.Exit` | нет | нет |

Поэтому resource cleanup через defer сохраняется при panic и `Goexit`, но не при `os.Exit`/`log.Fatal`.

## Урок 66. Тонкости `recover`

![[90 Вложения/CurseHunter/6609/Кадры/066.jpg]]

- Вызов `recover` вне directly deferred function возвращает nil.
- Panic можно recover, записать и снова `panic(e)`; внешний frame затем может recover его.
- Начиная с Go `1.21`, `panic(nil)` по умолчанию превращается в non-nil `*runtime.PanicNilError`, чтобы успешный direct recover всегда различал panic. Старое поведение управляется `GODEBUG=panicnil=1` и зависит от `go` version main module.
- Recover не пересекает goroutine boundary.

## Урок 67. Подмена panic

![[90 Вложения/CurseHunter/6609/Кадры/067.jpg]]

Во время unwinding новый panic из deferred call заменяет активный. В цепочке `panic(0)` и deferred `panic(1)`, `panic(2)`, `panic(3)` финальный recovery получает `3`. Такой код демонстрирует механизм, но production cleanup не должен сам panic: он скрывает root cause.

## Источники

- [Handling panics](https://go.dev/ref/spec#Handling_panics) — Go specification, проверено 2026-07-19.
- [Package errors](https://pkg.go.dev/errors) — Go standard library, проверено 2026-07-19.
- [Go 1.21 Release Notes](https://go.dev/doc/go1.21) — Go project, `panic(nil)`, проверено 2026-07-19.
- [Package runtime](https://pkg.go.dev/runtime#Goexit) — Go standard library, проверено 2026-07-19.
- [Package os](https://pkg.go.dev/os#Exit) — Go standard library, проверено 2026-07-19.
- [Код модуля](https://github.com/Balun-courses/interview_go/tree/f562c12b4d0d85fd0b00cb662efc7f68edc96476/errors) — Balun-courses/interview_go, commit `f562c12`, проверено 2026-07-19.
