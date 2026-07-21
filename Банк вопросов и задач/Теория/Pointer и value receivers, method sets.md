---
aliases:
  - "Теоретический вопрос: Pointer и value receivers, method sets"
tags:
  - область/go
  - тема/язык
  - тип/вопрос
статус: проверено
---

# Pointer и value receivers, method sets

## Вопрос

Объясните тему «Pointer и value receivers, method sets» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Value receiver получает копию `T`; pointer receiver получает копию `*T`, указывающую на исходный объект. Method set `T` содержит методы с receiver `T`, а method set `*T` — методы с receiver `T` и `*T`. Сокращение `x.PointerMethod()` для addressable `x` не добавляет этот метод в method set `T`, поэтому `T` может не реализовать interface, хотя прямой вызов компилируется.

Полный разбор: [[60 Go/Pointer и value receivers, method sets|Pointer и value receivers, method sets]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Но value receiver не означает deep immutability: slice, map, pointer или interface field в копии могут ссылаться на те же данные. Это подробно разобрано в заметке о receivers и method sets.» — [[CurseHunter/6609/05 Структуры#Задача курса|CurseHunter/6609/05 Структуры, раздел «Задача курса»]].
- «Кандидат правильно описал implicit satisfaction и общий смысл polymorphism, но не ответил про dynamic type/value, method sets и runtime representation. Для подготовки эта секция напрямую связана с интерфейсами, method sets и typed nil/type assertions.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Interfaces — `00:03:31–00:04:16`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Interfaces — `00:03:31–00:04:16`»]].

## Источники

- [The Go Programming Language Specification: Method sets, Method declarations, Calls](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Go Wiki: MethodSets](https://go.dev/wiki/MethodSets) — The Go Project, Go 1.x, проверено 2026-07-15.
- [Спецификация Go из исходников](https://go.googlesource.com/go/+/refs/tags/go1.26.5/doc/go_spec.html) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
