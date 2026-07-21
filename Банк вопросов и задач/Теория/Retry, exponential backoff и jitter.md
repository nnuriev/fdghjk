---
aliases:
  - "Теоретический вопрос: Retry, exponential backoff и jitter"
tags:
  - область/распределённые-системы
  - тема/устойчивость
  - тип/вопрос
статус: проверено
---

# Retry, exponential backoff и jitter

## Вопрос

Как работает «Retry, exponential backoff и jitter»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

Retry заменяет один неуспешный удалённый вызов новой попыткой. Он полезен только для временной ошибки, replayable запроса и достаточного остатка общего deadline. Каждый повтор создаёт дополнительную нагрузку именно тогда, когда система уже может быть неисправна.

Exponential backoff увеличивает паузу между попытками, cap ограничивает её сверху, а jitter разводит клиентов по времени. Без jitter клиенты, которые одновременно увидели сбой, просыпаются теми же волнами. Политика обязана также ограничивать число попыток, уважать server pushback и иметь retry budget; иначе recovery превращается в retry storm.

Полный разбор: [[40 Распределённые системы/Retry, exponential backoff и jitter|Retry, exponential backoff и jitter]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/7091/02 Ошибки, повторы и деградация#2. Backoff, jitter и amplification|2. Backoff, jitter и amplification]] — вопрос о рассинхронизации клиентов, retry amplification и budget.
- «Нагрузочный кейс почти буквально соответствует Retry storms и cascading failures и Retry, exponential backoff и jitter.» — [[Telegram Собесы/Редлаб — 2026-06-30 — 300к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Редлаб — 2026-06-30 — 300к, раздел «Сопоставление с материалами vault»]].
- «Сборка сниппета — две независимые цепочки вызовов, общий deadline и политика ошибок. База: fan-out/fan-in, context, ошибки, retry, circuit breaker.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «Retry полезен только для transient error, безопасной операции и оставшегося budget. Без jitter/limit он создаёт retry storm; критерии описаны в заметке о retry.» — [[Авито/Решения/Go-платформа/Сборка сниппета#Trade-offs и альтернативы|Авито/Решения/Go-платформа/Сборка сниппета, раздел «Trade-offs и альтернативы»]].

## Источники

- [RFC 9110: HTTP Semantics](https://datatracker.ietf.org/doc/html/rfc9110) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RFC 9112: HTTP/1.1](https://datatracker.ietf.org/doc/html/rfc9112) — IETF, RFC 9112, июнь 2022, проверено 2026-07-18.
- [Retry](https://grpc.io/docs/guides/retry/) — gRPC Authors, официальное руководство, проверено 2026-07-18.
- [gRFC A6: gRPC Retry Design](https://github.com/grpc/proposal/blob/dc9fd4fe5b94b90b82fe2833ad1d80938e6a49c1/A6-client-retries.md) — grpc/proposal, commit `dc9fd4fe5b94b90b82fe2833ad1d80938e6a49c1`, разделы Throttling и Pushback, проверено 2026-07-18.
- [Exponential Backoff and Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/) — Amazon Web Services, first-party architecture guidance, обновлено 2023-05, проверено 2026-07-18.
- [Package net/http](https://pkg.go.dev/net/http@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-18.
