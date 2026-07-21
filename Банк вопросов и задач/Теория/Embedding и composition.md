---
aliases:
  - "Теоретический вопрос: Embedding и composition"
tags:
  - область/go
  - тема/язык
  - тип/вопрос
статус: проверено
---

# Embedding и composition

## Вопрос

Объясните тему «Embedding и composition» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Embedding объявляет поле только именем типа и позволяет продвигать (**promote**) его поля и методы в selectors внешнего struct. Это синтаксическая композиция, не наследование: внешний тип не становится подтипом embedded типа, promoted method сохраняет исходный receiver, а «переопределение» метода внешним типом не создаёт virtual dispatch внутри embedded реализации.

Полный разбор: [[60 Go/Embedding и composition|Embedding и composition]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Embedding — composition с promoted selectors, а не inheritance. Внешний `Woman.Intro` shadow promoted `Person.Intro`; квалифицированный `woman.Person.Intro()` остаётся доступен. Promotion влияет на method set по правилам value/pointer embedding, разобранным в заметке об embedding.» — [[CurseHunter/6609/05 Структуры#Урок 41. Embedding|CurseHunter/6609/05 Структуры, раздел «Урок 41. Embedding»]].

## Источники

- [The Go Programming Language Specification: Struct types, Selectors, Method sets, Embedded interfaces](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Спецификация Go из исходников](https://go.googlesource.com/go/+/refs/tags/go1.26.5/doc/go_spec.html) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
