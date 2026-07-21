---
aliases:
  - "Теоретический вопрос: Dependency inversion"
tags:
  - область/проектирование-систем
  - тема/проектирование-компонентов
  - тема/зависимости
  - тип/вопрос
статус: проверено
---

# Dependency inversion

## Вопрос

Как раскрыть на System Design интервью тему «Dependency inversion»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

Dependency inversion principle (DIP) направляет source dependencies к policy, а не к volatile details. Компонент с предметным решением формулирует минимальную abstraction, которая ему нужна; database, broker или provider adapter зависит от этого контракта и реализует его. Composition root знает обе стороны и соединяет object graph.

Runtime flow при этом не разворачивается: policy всё ещё вызывает repository, а repository — database. Инвертируется compile-time knowledge. Dependency injection передаёт выбранную implementation в component, но сама по себе не доказывает DIP: можно явно inject широкий vendor client и сохранить всю прежнюю связанность.

Полный разбор: [[50 Проектирование систем/Dependency inversion|Dependency inversion]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Кандидат передал общую установку «business model должен диктовать design, а не database/framework», но не смог назвать Dependency Rule. Он перепутал два связанных, но разных понятия: ubiquitous language — общий язык внутри модели, bounded context — явная граница, внутри которой эта модель и язык имеют определённый смысл. Для подготовки подходят domain model, границы сервисов, dependency inversion и направление package dependencies.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Architecture experience, EventStorming, DDD и Clean Architecture — `00:36:08–00:40:54`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Architecture experience, EventStorming, DDD и Clean Architecture — `00:36:08–00:40:54`»]].

## Источники

- [The Dependency Inversion Principle](https://objectmentor.com/resources/articles/dip.pdf) — Robert C. Martin, C++ Report, 1996, проверено 2026-07-18.
- [Go Code Review Comments: Interfaces](https://go.dev/wiki/CodeReviewComments#interfaces) — The Go Project, состояние страницы на 2026-07-18, проверено 2026-07-18.
- [The Go Programming Language Specification: Interface types](https://go.dev/ref/spec#Interface_types) — The Go Project, спецификация Go, проверено 2026-07-18.
- [Compile-time Dependency Injection With Go Cloud's Wire](https://go.dev/blog/wire) — The Go Project, публикация 2018-10-09, проверено 2026-07-18.
- [Domain-Driven Design Reference: Layered Architecture](https://www.domainlanguage.com/wp-content/uploads/2016/05/DDD_Reference_2015-03.pdf) — Eric Evans, 2015, проверено 2026-07-18.
