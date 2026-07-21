---
aliases:
  - "Теоретический вопрос: Итераторы Go 1.23"
tags:
  - область/go
  - тема/итераторы
  - тип/вопрос
статус: черновик
---

# Итераторы Go 1.23

## Вопрос

Как range-over-function и `iter.Seq` задают iterator protocol в Go 1.23?

## Короткий ориентир

Начиная с Go 1.23 `range` принимает функции iterator signatures. Producer вызывает `yield`; возвращённый `false` означает, что consumer прекратил обход, после чего producer обязан остановиться. Concurrent или поздний вызов `yield` нарушает protocol.

Полные разборы:

- [[CurseHunter/6860/05 Контексты, итераторы и Swiss Tables#Итераторы Go 1.23|CourseHunter 6860: Итераторы Go 1.23]]

## Варианты follow-up

- Что означает `false`, возвращённый функцией `yield`?
- Почему concurrent вызов `yield` ломает iterator protocol?
- Какие function signatures допускает range-over-function?

## Варианты формулировки и происхождение

- [[CurseHunter/6860/05 Контексты, итераторы и Swiss Tables#Итераторы Go 1.23|CourseHunter 6860, итераторы]].

## Источники

- [Go 1.23 Release Notes](https://go.dev/doc/go1.23) — range-over-function и пакет `iter`, Go `1.23`, проверено 2026-07-19.
- [Range Over Function Types](https://go.dev/blog/range-functions) — Go project, 2024, проверено 2026-07-19.
- [Package iter](https://pkg.go.dev/iter) — Go project, актуальная документация, проверено 2026-07-19.
- [The Go Programming Language Specification](https://go.dev/ref/spec) — context-independent language contracts for range and map, проверено 2026-07-19.
