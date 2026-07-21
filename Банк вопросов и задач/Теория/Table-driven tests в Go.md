---
aliases:
  - "Теоретический вопрос: Table-driven tests в Go"
tags:
  - область/go
  - тема/тестирование
  - тип/вопрос
статус: черновик
---

# Table-driven tests в Go

## Вопрос

Объясните тему «Table-driven tests в Go» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Table-driven test в Go — это не отдельный тип теста, а способ отделить данные сценариев от общего механизма вызова и проверки. Каждая строка таблицы должна быть полным сценарием: имя, input, expected observable result и, если нужно, setup.

`t.Run` даёт кейсам адресуемые имена, отдельные failures и selective run. Таблица улучшает тест только пока кейсы делят один контракт. Если строки требуют разных control flow и assertions, «универсальная» таблица с набором callbacks обычно читается хуже нескольких явных tests.

Полный разбор: [[60 Go/Table-driven tests в Go|Table-driven tests в Go]].

Канонический разбор пока имеет статус `черновик`; эта карточка сохраняет ту же степень проверенности.

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «`go test`, table-driven tests, mocks/fakes и HTTP-проверки: Тестирование и httptest, Table-driven tests в Go, Mocks vs fakes.» — [[Авито/roadmap#Тестирование и диагностика Go|Авито/roadmap, раздел «Тестирование и диагностика Go»]].
- «Проверки оформлены по модели из заметки о table-driven tests: отдельно покрыты пропущенный день, равенство максимумов и некорректный дубликат.» — [[Авито/Решения/Алгоритмы/Чемпионат по шагам#Table-driven tests|Авито/Решения/Алгоритмы/Чемпионат по шагам, раздел «Table-driven tests»]].

## Источники

- [Package testing](https://pkg.go.dev/testing@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-18.
- [Go Wiki: TableDrivenTests](https://go.dev/wiki/TableDrivenTests) — Go project, official wiki, проверено 2026-07-18.
- [Using Subtests and Sub-benchmarks](https://go.dev/blog/subtests) — Go project, `T.Run`/`B.Run` с Go 1.7, проверено 2026-07-18.
- [Go 1.22 Release Notes — Changes to the language](https://go.dev/doc/go1.22#language) — Go project, Go 1.22, поведение loop variables, проверено 2026-07-18.
- [The Go Programming Language Specification — For statements](https://go.dev/ref/spec#For_statements) — Go project, спецификация для language version Go 1.26, проверено 2026-07-18.
