---
aliases:
  - CourseHunter 6609 — defer
tags:
  - тип/разбор-курса
  - источник/coursehunter
  - язык/go
  - тема/defer
статус: проверено
---

# Defer: теория и 6 задач курса

## Урок 52. Три правила

![[90 Вложения/CurseHunter/6609/Кадры/052.jpg]]

1. Function value, receiver и arguments deferred call вычисляются в момент выполнения `defer` statement.
2. Сам call выполняется при выходе окружающей function: обычный return, panic и `runtime.Goexit` запускают defers.
3. Несколько calls выполняются LIFO.

Closure без argument читает captured variable в момент выполнения body, поэтому её поведение отличается от заранее вычисленного argument. Полная модель — в [[60 Go/defer, panic и recover|заметке о defer, panic и recover]].

## Урок 53. `defer` внутри loop

![[90 Вложения/CurseHunter/6609/Кадры/053.jpg]]

`defer file.Close()` в body `for` закрывает все files только при выходе всей `readFiles`, а не iteration. На длинном списке исчерпываются file descriptors. Решение — вынести одну iteration во внутреннюю function с `defer` или явно закрывать file после использования и отдельно обрабатывать close error.

## Урок 54. Момент вычисления

![[90 Вложения/CurseHunter/6609/Кадры/054.jpg]]

### Четыре задачи курса

- `defer notify(status)` при пустом `status`, затем `status="error"` напечатает пустую строку. Closure `defer func(){ notify(status) }()` увидит `error`.
- `var f func(); defer f(); f = actual` всё равно defer-ит nil function value и panic при выходе.
- Defer в недостижимом statement после unconditional `return` не регистрируется; defer под `if false` тоже нет.
- `defer handle(get()); fmt.Println("2")` печатает `1`, затем `2`, затем `3`: `get()` вычисляется сразу.

## Урок 55. Named и unnamed result

![[90 Вложения/CurseHunter/6609/Кадры/055.jpg]]

```go
func Modify(v int) (result int) {
	defer func() { result += v }()
	return v + v
}
```

Для `v=5` результат `15`: return сначала присваивает `10` named result, затем defer меняет его. В version `func Modify(v int) int` локальная `result` не является return slot, поэтому defer меняет бесполезную variable, а caller получает `10`.

## Урок 56. Производительность

![[90 Вложения/CurseHunter/6609/Кадры/056.jpg]]

Benchmark курса сравнивает deferred closure с direct assignment. Начиная с Go `1.14` большинство простых defer compiler реализует почти без overhead через open-coded defers. Это не означает zero cost всегда: defer в loop, escaping closure и paths, где open coding невозможно, могут быть дороже. Решение принимают по profile конкретной версии, а не по старому правилу «defer медленный».

## Урок 57. Порядок

![[90 Вложения/CurseHunter/6609/Кадры/057.jpg]]

Три последовательных `defer Println(3)`, `2`, `1` выводят `1 2 3`. В nested варианте курса первый исполняемый deferred closure регистрирует свои defers и выводит `1 2`, затем второй — `3 4`; итог `1 2 3 4`.

## Урок 58. Receiver и chain call

![[90 Вложения/CurseHunter/6609/Кадры/058.jpg]]

- Deferred value receiver копируется при `defer`, поэтому после mutation печатает старое `0`.
- Deferred pointer receiver фиксирует address и при выполнении видит `200`.
- В `defer MakeData(pointer).Print(pointer)` функция `MakeData` и receiver вычисляются сразу, а `Print` позже. Показанная последовательность: `MakeData: 1`, затем обычный `MakeData` с новым zero pointer печатает `0`, при выходе deferred `Print` получает ранее вычисленный argument pointer и печатает `2`.

## Источники

- [Defer statements](https://go.dev/ref/spec#Defer_statements) — Go specification, проверено 2026-07-19.
- [Return statements](https://go.dev/ref/spec#Return_statements) — Go specification, проверено 2026-07-19.
- [Go 1.14 Release Notes](https://go.dev/doc/go1.14) — Go project, оптимизация defer, проверено 2026-07-19.
- [Код модуля](https://github.com/Balun-courses/interview_go/tree/f562c12b4d0d85fd0b00cb662efc7f68edc96476/defer) — Balun-courses/interview_go, commit `f562c12`, проверено 2026-07-19.
