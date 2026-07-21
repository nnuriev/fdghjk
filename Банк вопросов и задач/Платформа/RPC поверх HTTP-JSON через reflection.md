---
aliases:
  - "Задача: RPC поверх HTTP/JSON через reflection"
tags:
  - область/go
  - тема/собеседование
  - тип/задача
  - источник/cursehunter
статус: проверено
---

# RPC поверх HTTP/JSON через reflection

## Каноническая формулировка, контракт и проверенный разбор

![[CurseHunter/6817/Бланк вопросов и заданий#14. Задание: реализовать RPC поверх HTTP/JSON через reflection]]

## Варианты формулировки и происхождение

- [[CurseHunter/6817/Бланк вопросов и заданий#14. Задание: реализовать RPC поверх HTTP/JSON через reflection|14. Задание: реализовать RPC поверх HTTP/JSON через reflection]] — каноническая проверенная постановка, contract boundary и ссылка на reference implementation курса.

## Типичные ошибки и границы решения

Ошибки, edge cases, trade-offs и version boundary сохранены в проверенном исходном разделе. Reflection не расширяет HTTP/RPC-контракт автоматически: допустимые signatures, decoding errors и паники должны обрабатываться явно.

## Версионные границы и проверка

Версия Go и commit reference implementation зафиксированы в исходном разборе. Локального Go toolchain в среде нет, поэтому карточка не выдаёт код за повторно скомпилированный.

## Релевантные вопросы из теории

- [[Банк вопросов и задач/Теория/Generics, constraints и reflection в Go|Generics, constraints и reflection в Go]] — `reflect.Type`, `reflect.Value`, addressability и method lookup задают dispatch.
- [[Банк вопросов и задач/Теория/REST, RPC, gRPC и GraphQL|REST, RPC, gRPC и GraphQL]] — transport и wire contract нужно отделять от механизма динамического вызова.
- [[Банк вопросов и задач/Теория/Пакет encoding-json|Пакет encoding-json]] — JSON decoding определяет type errors, unknown fields и representation boundary.
