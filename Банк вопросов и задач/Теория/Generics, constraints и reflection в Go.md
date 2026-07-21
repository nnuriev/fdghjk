---
aliases:
  - "Теоретический вопрос: Generics, constraints и reflection в Go"
tags:
  - область/go
  - тема/система-типов
  - тип/вопрос
статус: черновик
---

# Generics, constraints и reflection в Go

## Вопрос

Где в Go выбирать type parameters и constraints, а где runtime reflection?

## Короткий ориентир

Generics выражают compile-time family типов через type parameters и constraints; reflection исследует dynamic type/value во время выполнения. Языковая спецификация не обещает конкретную compiler strategy: gcshape stenciling и dictionaries относятся к реализации, поэтому performance подтверждают benchmark конкретной версии.

Полные разборы:

- [[60 Go/Дженерики, constraints и type sets|Дженерики, constraints и type sets]]
- [[CurseHunter/6860/03 Дженерики, рефлексия и память#Reflection|CourseHunter 6860: Reflection]]

## Варианты follow-up

- Что задаёт constraint и чем type set отличается от runtime type list?
- Гарантирует ли Go specification отсутствие runtime overhead у generics?
- Когда reflection оправдана, а type parameter даёт более точный контракт?

## Варианты формулировки и происхождение

- [[CurseHunter/6860/03 Дженерики, рефлексия и память#Generics|Generics]] — вопросы о constraints, type sets, inference, operators, methods и границах implementation-dependent performance.
- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Generics, named types и reflection — `00:46:22–00:49:55`|MERLION, generics и reflection]].
- [[CurseHunter/6860/03 Дженерики, рефлексия и память#Вопросы из уроков|CourseHunter 6860, generics и reflection]].

- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#5. Generics: скорость не является language guarantee|5. Generics: скорость не является language guarantee]] — точная проверенная формулировка самостоятельного технического блока интервью.

- [[CurseHunter/6817/Бланк вопросов и заданий#10. Почему generic JSON через reflection проигрывает generated code?|10. Почему generic JSON через reflection проигрывает generated code?]] — точная формулировка вопроса курса 6817 из «Урок 10. Оптимизации в Go».
- [[CurseHunter/6817/Бланк вопросов и заданий#11. Чем `reflect.Type`, `Kind`, addressability и `CanSet` отличаются друг от друга?|11. Чем `reflect.Type`, `Kind`, addressability и `CanSet` отличаются друг от друга?]] — точная формулировка вопроса курса 6817 из «Урок 10. Оптимизации в Go».
- [[CurseHunter/6817/Бланк вопросов и заданий#12. Почему `reflect.Value.IsNil` легко вызывает panic?|12. Почему `reflect.Value.IsNil` легко вызывает panic?]] — точная формулировка вопроса курса 6817 из «Урок 10. Оптимизации в Go».
- [[CurseHunter/6817/Бланк вопросов и заданий#13. Можно ли через `reflect` изменить unexported field другого package?|13. Можно ли через `reflect` изменить unexported field другого package?]] — точная формулировка вопроса курса 6817 из «Урок 10. Оптимизации в Go».

## Источники

- [The Go Programming Language Specification: Type parameter declarations, Interface types, Type inference](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Go 1.18 Release Notes: Generics](https://go.dev/doc/go1.18) — The Go Project, Go 1.18, проверено 2026-07-15.
- [Go 1.20 Release Notes: comparable types](https://go.dev/doc/go1.20) — The Go Project, Go 1.20, проверено 2026-07-15.
- [Go 1.24 Release Notes: Generic type aliases](https://go.dev/doc/go1.24) — The Go Project, Go 1.24, проверено 2026-07-15.
- [Go 1.26 Release Notes: self-referential constraints](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
- [The Laws of Reflection](https://go.dev/blog/laws-of-reflection) — Go project, проверено 2026-07-19.
- [Go 1.18 implementation of generics via dictionaries and gcshape stenciling](https://go.googlesource.com/proposal/+/refs/heads/master/design/generics-implementation-dictionaries-go1.18.md) — Go proposal repository, design Go 1.18, проверено `2026-07-19`.
- [Shape-based stenciling implementation](https://go.googlesource.com/go/+/38edd9bd8da9d7fc7beeba5fd4fd9d605457b04e) — Go repository, commit `38edd9bd8da9d7fc7beeba5fd4fd9d605457b04e`, проверено `2026-07-19`.
