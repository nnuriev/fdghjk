---
aliases:
  - "Теоретический вопрос: Mocks vs fakes"
tags:
  - область/бэкенд
  - тема/тестирование
  - тип/вопрос
статус: проверено
---

# Mocks vs fakes

## Вопрос

Как работает «Mocks vs fakes» и какие ограничения, failure modes и trade-offs нужно учитывать в backend-системе?

## Короткий ориентир

Mock и fake — разные виды test double. Mock получает запрограммированные ответы и expectations о взаимодействиях; test падает, если SUT вызвал его не так. Fake — облегчённая, но работающая реализация того же API: она сама выполняет упрощённую логику и при необходимости хранит состояние, хотя не подходит для production.

Предпочтительный выбор — реальная быстрая dependency, затем проверенный fake, и только затем mock там, где interaction само входит в контракт или нужна точная fault injection. Mock повышает controllability, но легко привязывает test к внутреннему call graph. Fake даёт более реалистичное поведение, но способен тихо разойтись с production implementation.

Полный разбор: [[20 Бэкенд/Mocks vs fakes|Mocks vs fakes]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «`go test`, table-driven tests, mocks/fakes и HTTP-проверки: Тестирование и httptest, Table-driven tests в Go, Mocks vs fakes.» — [[Авито/roadmap#Тестирование и диагностика Go|Авито/roadmap, раздел «Тестирование и диагностика Go»]].

## Источники

- [Testing on the Toilet: Know Your Test Doubles](https://testing.googleblog.com/2013/07/testing-on-toilet-know-your-test-doubles.html) — Google Testing Blog, 2013, определения stub, mock и fake, проверено 2026-07-18.
- [Increase Test Fidelity By Avoiding Mocks](https://testing.googleblog.com/2024/02/increase-test-fidelity-by-avoiding-mocks.html) — Google Testing Blog, 2024, выбор real implementation, fake и mock, проверено 2026-07-18.
- [How Much Testing is Enough?](https://testing.googleblog.com/2021/06/how-much-testing-is-enough.html) — Google Testing Blog, 2021, mocks/fakes в unit и integration portfolio, проверено 2026-07-18.
- [Go Code Review Comments — Interfaces](https://go.dev/wiki/CodeReviewComments#interfaces) — The Go Project, Go Wiki без release-versioning, рекомендации по consumer-owned interfaces, проверено 2026-07-18.
- [Package testing](https://pkg.go.dev/testing@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
