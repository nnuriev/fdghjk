---
aliases:
  - "Теоретический вопрос: defer, panic и recover"
tags:
  - область/go
  - тема/язык
  - тип/вопрос
статус: проверено
---

# defer, panic и recover

## Вопрос

Объясните тему «defer, panic и recover» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

`defer` регистрирует вызов при выходе из текущей function; function value и arguments вычисляются сразу, а вызовы выполняются LIFO. `panic` прекращает обычное выполнение и раскручивает stack этой goroutine, запуская defers. `recover` останавливает раскрутку только когда вызван напрямую deferred function той же panicking goroutine. Это механизм для защиты process boundary и инвариантов, а не замена [[60 Go/Обработка ошибок|обычной обработке ошибок]].

Полный разбор: [[60 Go/defer, panic и recover|defer, panic и recover]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «Closure без argument читает captured variable в момент выполнения body, поэтому её поведение отличается от заранее вычисленного argument. Полная модель — в заметке о defer, panic и recover.» — [[CurseHunter/6609/07 Defer#Урок 52. Три правила|CurseHunter/6609/07 Defer, раздел «Урок 52. Три правила»]].
- «Точные модели `panic/recover`, slices, races, escape analysis и GC уже есть в defer, panic и recover, массивах и слайсах, race detector, стеках и escape analysis и GC pressure. Для идемпотентности платежей и POST-операций нужен полный protocol из заметки о ключах идемпотентности, а не только случайный token.» — [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Go и API — `00:22:43–00:33:03`|Telegram Собесы/M.Tech — 2026-07-17 — 350к, раздел «Go и API — `00:22:43–00:33:03`»]].
- «Фраза «`defer` замораживает всё» опасна: она не объясняет разницу между параметром deferred call и переменной, которую closure читает позже. Точная семантика связана с моментом вычисления deferred call и захватом переменных closure.» — [[Telegram Собесы/Ozon — 2026-07-03 — 300к/Бланк вопросов и заданий#Правильная модель|Telegram Собесы/Ozon — 2026-07-03 — 300к, раздел «Правильная модель»]].
- «| `defer` и receiver | defer, panic и recover | Прямое совпадение момента вычисления аргументов | В Ozon отдельно сравнивают value receiver, pointer receiver и closure |» — [[Telegram Собесы/Ozon — 2026-07-03 — 300к/Бланк вопросов и заданий#Сопоставление с материалами репозитория|Telegram Собесы/Ozon — 2026-07-03 — 300к, раздел «Сопоставление с материалами репозитория»]].
- «`error` против `panic`, `defer` и `recover`: Обработка ошибок, defer, panic и recover.» — [[Авито/roadmap#Язык Go|Авито/roadmap, раздел «Язык Go»]].

- [[Telegram Собесы/Lunar Rails — 2026-04-27 — 7800 USD/Бланк вопросов и заданий#Go — `00:23:13–00:28:20`|Go — `00:23:13–00:28:20`]] — точная проверенная формулировка соответствующего технического блока интервью.

- [[Telegram Собесы/Магнит — 2025-12-26 — 400к/Бланк вопросов и заданий#`defer`, channel edge cases, deadlock и panic — `00:49:24–00:54:57`|`defer`, channel edge cases, deadlock и panic — `00:49:24–00:54:57`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/ШИФТ — 2026-04-20 — 500к/Бланк вопросов и заданий#`defer`, `context`, channels и control flow — `00:54:11–01:06:33`|`defer`, `context`, channels и control flow — `00:54:11–01:06:33`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [The Go Programming Language Specification: Defer statements, Handling panics](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Package builtin: panic and recover](https://pkg.go.dev/builtin@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Go 1.21 Release Notes: panic(nil)](https://go.dev/doc/go1.21) — The Go Project, Go 1.21, проверено 2026-07-15.
