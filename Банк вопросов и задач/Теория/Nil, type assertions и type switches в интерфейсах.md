---
aliases:
  - "Теоретический вопрос: Nil, type assertions и type switches в интерфейсах"
tags:
  - область/go
  - тема/язык
  - тип/вопрос
статус: проверено
---

# Nil, type assertions и type switches в интерфейсах

## Вопрос

Объясните тему «Nil, type assertions и type switches в интерфейсах» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Interface равен nil только когда у него нет ни dynamic type, ни dynamic value. Pointer с nil-значением, присвоенный interface, создаёт non-nil interface с dynamic type `*T`. Type assertion проверяет dynamic type во время выполнения: одно-result форма panic при несовпадении, comma-ok возвращает `false`; type switch группирует такие проверки без повторных assertions.

Полный разбор: [[60 Go/Nil, type assertions и type switches в интерфейсах|Nil, type assertions и type switches в интерфейсах]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Interface содержит dynamic type `*MyError`, хотя dynamic value nil. Поэтому `ReadFile`, который возвращает typed nil `*os.PathError` как `error`, сообщает вызывающему non-nil error. Если ошибки нет, возвращают literal `nil`, а typed pointer создают только для настоящей ошибки. Больше edge cases — в заметке о nil и assertions.» — [[CurseHunter/6609/06 Интерфейсы#Урок 49. Typed nil|CurseHunter/6609/06 Интерфейсы, раздел «Урок 49. Typed nil»]].
- «Typed nil уже разобран в заметке про nil в interfaces и модели interface values. Условие FLANT практически является короткой проверкой этой темы.» — [[Telegram Собесы/FLANT — 2026-06-30 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/FLANT — 2026-06-30 — 400к, раздел «Сопоставление с материалами vault»]].
- «Typed nil, assertions и method sets разобраны в Интерфейсы и неявная реализация и Nil, type assertions и type switches.» — [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Lamoda — 2026-06-10 — 400к, раздел «Сопоставление с материалами vault»]].
- «Кандидат правильно описал implicit satisfaction и общий смысл polymorphism, но не ответил про dynamic type/value, method sets и runtime representation. Для подготовки эта секция напрямую связана с интерфейсами, method sets и typed nil/type assertions.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Interfaces — `00:03:31–00:04:16`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Interfaces — `00:03:31–00:04:16`»]].
- «Interfaces, method sets и typed nil: Интерфейсы и неявная реализация, Nil, type assertions и type switches в интерфейсах.» — [[Авито/roadmap#Язык Go|Авито/roadmap, раздел «Язык Go»]].

## Источники

- [The Go Programming Language Specification: Interface types, Type assertions, Type switches, Comparison operators](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [The Laws of Reflection: The representation of an interface](https://go.dev/blog/laws-of-reflection) — The Go Project, Go 1.x, проверено 2026-07-15.
- [Package builtin: error](https://pkg.go.dev/builtin@go1.26.5#error) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
