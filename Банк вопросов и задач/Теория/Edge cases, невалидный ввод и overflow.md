---
aliases:
  - "Теоретический вопрос: Edge cases, невалидный ввод и overflow"
tags:
  - область/основы-cs
  - тема/алгоритмы
  - тема/собеседование
  - тип/вопрос
статус: проверено
---

# Edge cases, невалидный ввод и overflow

## Вопрос

Объясните тему «Edge cases, невалидный ввод и overflow»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

Edge case — допустимый вход на границе поведения; invalid input нарушает предусловие. Их нельзя смешивать: пустой список может быть корректным значением, а индекс вне диапазона — ошибкой контракта. До кода нужно решить, какие входы гарантирует задача и как функция сообщает отсутствие ответа или нарушение предусловия.

Overflow тоже часть контракта. В Go целочисленные операции над runtime values не обязаны выдавать ошибку: unsigned arithmetic вычисляется по модулю `2^n`, signed overflow детерминирован представлением и операцией. Поэтому проверки размера, суммы, произведения и midpoint должны предшествовать опасной операции либо использовать более широкий тип или `math/bits`.

Полный разбор: [[10 Основы CS/Edge cases, невалидный ввод и overflow|Edge cases, невалидный ввод и overflow]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Сумма чисел двух массивов — массивы, валидация и carry.» — [[Авито/roadmap#5. Остальные алгоритмы|Авито/roadmap, раздел «5. Остальные алгоритмы»]].
- «Сравнение версий — parser числовых компонентов, trailing zeros и необычный знак comparator из исходника; база: edge cases.» — [[Авито/roadmap#5. Остальные алгоритмы|Авито/roadmap, раздел «5. Остальные алгоритмы»]].

## Источники

- [The Go Programming Language Specification](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, integer types, constants, overflow и conversions, проверено 2026-07-18.
- [Package math/bits](https://pkg.go.dev/math/bits@go1.26.5) — стандартная библиотека Go, tag go1.26.5, full-width arithmetic и carry, проверено 2026-07-18.
- [SDE II Interview Prep: Coding](https://amazon.jobs/content/en/how-we-hire/sde-ii-interview-prep) — Amazon Jobs, syntactically correct code, edge cases и bad input, проверено 2026-07-18.
- [The Google Technical Interview: How to Get Your Dream Job](https://research.google.com/pubs/archive/41881.pdf) — Dean Jackson, Google Research / ACM XRDS 20(2), 2013, уточнение размера и bad inputs, проверено 2026-07-18.
