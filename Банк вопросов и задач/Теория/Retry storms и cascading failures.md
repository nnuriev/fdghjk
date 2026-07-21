---
aliases:
  - "Теоретический вопрос: Retry storms и cascading failures"
tags:
  - область/распределённые-системы
  - тема/устойчивость
  - механизм/повторы
  - тип/вопрос
статус: проверено
---

# Retry storms и cascading failures

## Вопрос

Как работает «Retry storms и cascading failures»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

Retry полезен, когда отдельная попытка потерялась из-за краткого сбоя. Но под перегрузкой повтор создаёт новую работу именно тогда, когда системе меньше всего хватает capacity. Возникает положительная обратная связь: latency растёт → deadlines истекают → клиенты повторяют → offered load растёт → очереди и latency растут ещё сильнее. Так локальная деградация превращается в **retry storm** и затем в **cascading failure** зависимых сервисов.

Защита строится не одним exponential backoff. Нужны end-to-end deadline, одна ответственная точка retry, ограниченный retry budget, jitter, bounded concurrency, admission control, load shedding, circuit breaker и проверенная идемпотентность. Цель — сохранить полезную пропускную способность (**goodput**) и дать системе восстановиться, а не максимизировать число попыток.

Полный разбор: [[40 Распределённые системы/Retry storms и cascading failures|Retry storms и cascading failures]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Нагрузочный кейс почти буквально соответствует Retry storms и cascading failures и Retry, exponential backoff и jitter.» — [[Telegram Собесы/Редлаб — 2026-06-30 — 300к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Редлаб — 2026-06-30 — 300к, раздел «Сопоставление с материалами vault»]].

## Источники

- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering book, 2016, проверено 2026-07-18.
- [Handling Overload](https://sre.google/sre-book/handling-overload/) — Google, Site Reliability Engineering book, 2016, проверено 2026-07-18.
- [Timeouts, retries, and backoff with jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/) — Amazon Web Services, Amazon Builders’ Library, проверено 2026-07-18.
- [RFC 9110, § 10.2.3 Retry-After](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
