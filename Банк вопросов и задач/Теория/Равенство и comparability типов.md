---
aliases:
  - "Теоретический вопрос: Равенство и comparability типов"
tags:
  - область/go
  - тема/язык
  - тип/вопрос
статус: проверено
---

# Равенство и comparability типов

## Вопрос

Объясните тему «Равенство и comparability типов» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Comparable type допускает `==`/`!=` и может быть ключом [[60 Go/Map|map]]. Arrays comparable, если element имеет comparable type; structs — если каждый field имеет comparable type. Slices, maps и functions сравниваются только с nil. Interfaces статически comparable, но их сравнение может panic, когда dynamic value имеет несравнимый тип. Равенство языка — не универсальное предметное равенство: для float NaN, time, normalized text и containers часто нужен отдельный contract.

Полный разбор: [[60 Go/Равенство и comparability типов|Равенство и comparability типов]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «Для всех четырёх `len == 0`, `cap == 0`, `range` делает ноль итераций, а `append` допустим. Но `a == nil` и `b == nil` истинны; `c == nil` и `d == nil` ложны. Сами slices между собой сравнивать нельзя, кроме сравнения с `nil`; общая модель comparability разобрана в заметке о равенстве типов.» — [[CurseHunter/6754/Бланк вопросов и заданий#Задача 1. Чем отличаются nil slice и empty non-nil slice?|CurseHunter/6754, раздел «Задача 1. Чем отличаются nil slice и empty non-nil slice?»]].
- «Кандидат сначала отказал structs в comparability, затем сам исправился: struct сравним, если сравнимы все поля. Для полного ответа ещё нужны arrays, interface panic и различие comparable/strictly comparable из заметки о равенстве типов.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Comparable types — `00:10:14–00:11:11`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Comparable types — `00:10:14–00:11:11`»]].

## Источники

- [The Go Programming Language Specification: Comparison operators, Interface types, Type constraints](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Go 1.20 Release Notes: comparable types](https://go.dev/doc/go1.20) — The Go Project, Go 1.20, проверено 2026-07-15.
- [Package slices: Equal](https://pkg.go.dev/slices@go1.26.5#Equal) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Package maps: Equal](https://pkg.go.dev/maps@go1.26.5#Equal) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
