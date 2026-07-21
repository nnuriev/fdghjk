---
aliases:
  - "Теоретический вопрос: Singleton, LSP и SOLID"
tags:
  - область/проектирование-систем
  - тема/дизайн-кода
  - тип/вопрос
статус: черновик
---

# Singleton, LSP и SOLID

## Вопрос

Как применять Singleton, Liskov Substitution Principle и SOLID к Go без механического переноса class inheritance?

## Короткий ориентир

Singleton совмещает единственный instance с глобальной точкой доступа и тем самым скрывает dependency и lifecycle; `sync.Once` устраняет initialization race, но не этот архитектурный coupling. В Go LSP проверяют через наблюдаемое поведение реализаций interface, а embedding остаётся composition with method promotion, не class inheritance.

Полные разборы:

- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Patterns и Singleton — `00:05:37–00:08:40`|MERLION: Singleton]]
- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#SOLID, LSP и модель Go — `00:13:57–00:21:26`|MERLION: SOLID и LSP]]
- [[50 Проектирование систем/Dependency inversion|Dependency inversion]]

## Варианты follow-up

- Почему `sync.Once` решает initialization race, но не скрытую dependency?
- Как сформулировать LSP через наблюдаемое поведение, а не inheritance syntax?
- Почему embedding в Go не делает внешний struct подтипом embedded struct?

## Варианты формулировки и происхождение

- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Patterns и Singleton — `00:05:37–00:08:40`|MERLION, Singleton]].
- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#SOLID, LSP и модель Go — `00:13:57–00:21:26`|MERLION, SOLID и LSP]].

- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#2. SOLID в Go: LSP проверяет поведение, а не embedding|2. SOLID в Go: LSP проверяет поведение, а не embedding]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Редлаб — 2026-06-30 — 300к/Бланк вопросов и заданий#SOLID — `00:41:19–00:49:03`|SOLID — `00:41:19–00:49:03`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [The Dependency Inversion Principle](https://objectmentor.com/resources/articles/dip.pdf) — Robert C. Martin, C++ Report, 1996, проверено 2026-07-18.
- [Go Code Review Comments: Interfaces](https://go.dev/wiki/CodeReviewComments#interfaces) — The Go Project, состояние страницы на 2026-07-18, проверено 2026-07-18.
- [The Go Programming Language Specification: Interface types](https://go.dev/ref/spec#Interface_types) — The Go Project, спецификация Go, проверено 2026-07-18.
- [Compile-time Dependency Injection With Go Cloud's Wire](https://go.dev/blog/wire) — The Go Project, публикация 2018-10-09, проверено 2026-07-18.
- [Domain-Driven Design Reference: Layered Architecture](https://www.domainlanguage.com/wp-content/uploads/2016/05/DDD_Reference_2015-03.pdf) — Eric Evans, 2015, проверено 2026-07-18.
- [Design Patterns: Elements of Reusable Object-Oriented Software](https://www.pearson.com/en-us/subject-catalog/p/design-patterns-elements-of-reusable-object-oriented-software/P200000009480/9780321700698) — Erich Gamma, Richard Helm, Ralph Johnson, John Vlissides; Addison-Wesley, 1994, проверено 2026-07-18.
- [Package slices: SortFunc](https://pkg.go.dev/slices@go1.26.5#SortFunc) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Package net/http: HandlerFunc and RegisterOnShutdown](https://pkg.go.dev/net/http@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Package io: LimitReader and TeeReader](https://pkg.go.dev/io@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [The Go Programming Language Specification: Struct types, Selectors, Method sets, Embedded interfaces](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Спецификация Go из исходников](https://go.googlesource.com/go/+/refs/tags/go1.26.5/doc/go_spec.html) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [A Behavioral Notion of Subtyping](https://doi.org/10.1145/197320.197383) — Barbara Liskov и Jeannette Wing, ACM TOPLAS 16(6), 1994, проверено 2026-07-19.
