---
aliases:
  - "Теоретический вопрос: Паттерны Strategy, Adapter, Factory, Decorator, Observer и State в Go"
tags:
  - область/проектирование-систем
  - область/go
  - тема/паттерны
  - тип/вопрос
статус: черновик
---

# Паттерны Strategy, Adapter, Factory, Decorator, Observer и State в Go

## Вопрос

Как раскрыть на System Design интервью тему «Паттерны Strategy, Adapter, Factory, Decorator, Observer и State в Go»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

Паттерн полезен, когда называет конкретную ось изменения. Strategy меняет алгоритм, Adapter переводит чужой contract, Factory централизует создание, Decorator оборачивает тот же contract, Observer доставляет событие подписчикам, State меняет поведение вместе с lifecycle объекта.

В Go эти роли обычно выражаются functions, маленькими interfaces и composition. Иерархия классов не нужна. Сначала пишут прямой код; abstraction вводят, когда уже видны две политики, внешняя несовместимая boundary, повторяемая обёртка либо реальный state machine.

Полный разбор: [[50 Проектирование систем/Паттерны Strategy, Adapter, Factory, Decorator, Observer и State в Go|Паттерны Strategy, Adapter, Factory, Decorator, Observer и State в Go]].

Канонический разбор пока имеет статус `черновик`; эта карточка сохраняет ту же степень проверенности.

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Factory и другие patterns можно повторить по Паттерны в Go, а сам overload-кейс удобно проговаривать в формате Архитектурное решение с trade-offs.» — [[Telegram Собесы/Редлаб — 2026-06-30 — 300к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Редлаб — 2026-06-30 — 300к, раздел «Сопоставление с материалами vault»]].

- [[Telegram Собесы/Редлаб — 2026-06-30 — 300к/Бланк вопросов и заданий#Порождающие паттерны — `01:16:43–01:18:16`|Порождающие паттерны — `01:16:43–01:18:16`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [Design Patterns: Elements of Reusable Object-Oriented Software](https://www.pearson.com/en-us/subject-catalog/p/design-patterns-elements-of-reusable-object-oriented-software/P200000009480/9780321700698) — Erich Gamma, Richard Helm, Ralph Johnson, John Vlissides; Addison-Wesley, 1994, проверено 2026-07-18.
- [Package slices: SortFunc](https://pkg.go.dev/slices@go1.26.5#SortFunc) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Package net/http: HandlerFunc and RegisterOnShutdown](https://pkg.go.dev/net/http@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Package io: LimitReader and TeeReader](https://pkg.go.dev/io@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Go Code Review Comments: Interfaces](https://go.dev/wiki/CodeReviewComments#interfaces) — The Go Project, проверено 2026-07-18.
