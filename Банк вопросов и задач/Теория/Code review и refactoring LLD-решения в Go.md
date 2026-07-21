---
aliases:
  - "Теоретический вопрос: Code review и refactoring LLD-решения в Go"
tags:
  - область/проектирование-систем
  - область/go
  - тема/ревью-кода
  - тип/вопрос
статус: проверено
---

# Code review и refactoring LLD-решения в Go

## Вопрос

Как раскрыть на System Design интервью тему «Code review и refactoring LLD-решения в Go»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

LLD-review начинается с поведения: requirements, invariants, public API, state transitions, concurrency и error semantics. Лишь после этого имеет смысл обсуждать names и расположение методов. Самый дорогой дефект часто выглядит аккуратно, но оставляет invalid state после ошибки либо запускает goroutine без owner.

Refactoring меняет внутреннюю структуру без намеренного изменения observable behavior. Исправление бага, новый error contract и смена callback ordering — отдельные behavior changes. Сначала риск фиксируют тестом и маленьким изменением, затем упрощают структуру под зелёными tests.

Полный разбор: [[50 Проектирование систем/Code review и refactoring LLD-решения в Go|Code review и refactoring LLD-решения в Go]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Ревью кода — нужно исходное условие; база: Code review и refactoring LLD-решения в Go.» — [[Авито/roadmap#System design и проектирование|Авито/roadmap, раздел «System design и проектирование»]].

- [[Telegram Собесы/Редлаб — 2026-06-30 — 300к/Бланк вопросов и заданий#Признаки плохого кода — `00:49:03–00:59:34`|Признаки плохого кода — `00:49:03–00:59:34`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Редлаб — 2026-06-30 — 300к/Бланк вопросов и заданий#Code review и пределы TDD — `01:11:20–01:16:43`|Code review и пределы TDD — `01:11:20–01:16:43`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [What to look for in a code review](https://google.github.io/eng-practices/review/reviewer/looking-for.html) — Google Engineering Practices, проверено 2026-07-18.
- [Small CLs](https://google.github.io/eng-practices/review/developer/small-cls.html) — Google Engineering Practices, проверено 2026-07-18.
- [Refactoring](https://www.refactoring.com/) — Martin Fowler, определение и дисциплина refactoring, проверено 2026-07-18.
- [Refactoring Catalog](https://refactoring.com/catalog/) — Martin Fowler, каталог behavior-preserving transformations, проверено 2026-07-18.
- [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments) — The Go Project, проверено 2026-07-18.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, редакция 2022-06-06, применима к Go 1.26, проверено 2026-07-18.
