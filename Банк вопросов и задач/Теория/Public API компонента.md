---
aliases:
  - "Теоретический вопрос: Public API компонента"
tags:
  - область/проектирование-систем
  - тема/проектирование-компонентов
  - тема/api
  - тип/вопрос
статус: проверено
---

# Public API компонента

## Вопрос

Как раскрыть на System Design интервью тему «Public API компонента»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

Public API компонента — весь набор обещаний, на которых может строить код потребителя: импортируемый package, exported names и signatures, но также error semantics, ownership переданных значений, допустимый порядок вызовов, blocking и cancellation, concurrency safety, lifecycle и совместимость поведения. Список методов без этих условий — неполный контракт.

Хороший API минимален не по числу символов, а по числу независимых обязательств. Он выражает намерение предметными операциями, скрывает representation, не заставляет клиента собирать валидное состояние вручную и оставляет реализацию расширяемой там, где уже известна реальная ось изменения.

Полный разбор: [[50 Проектирование систем/Public API компонента|Public API компонента]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Связанные материалы vault: in-memory cache, concurrency safety, public API и самостоятельная реализация структур данных.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Что ожидалось от ответа про high contention|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Что ожидалось от ответа про high contention»]].

## Источники

- [Developing and publishing modules: Design and development](https://go.dev/doc/modules/developing) — The Go Project, документация Go modules, проверено 2026-07-18.
- [Keeping Your Modules Compatible](https://go.dev/blog/module-compatibility) — The Go Project, публикация 2020-07-07, проверено 2026-07-18.
- [Go 1 and the Future of Go Programs](https://go.dev/doc/go1compat) — The Go Project, compatibility policy Go 1, проверено 2026-07-18.
- [Go Code Review Comments: Interfaces](https://go.dev/wiki/CodeReviewComments#interfaces) — The Go Project, состояние страницы на 2026-07-18, проверено 2026-07-18.
- [Domain-Driven Design Reference: Intention-Revealing Interfaces and Assertions](https://www.domainlanguage.com/wp-content/uploads/2016/05/DDD_Reference_2015-03.pdf) — Eric Evans, 2015, проверено 2026-07-18.
