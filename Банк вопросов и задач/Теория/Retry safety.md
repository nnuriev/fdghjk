---
aliases:
  - "Теоретический вопрос: Retry safety"
tags:
  - область/основы-cs
  - тема/надёжность
  - механизм/retry
  - тип/вопрос
статус: проверено
---

# Retry safety

## Вопрос

Объясните тему «Retry safety»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

Ошибка, похожая на временную, ещё не делает retry безопасным. Перед повтором одновременно проверяют четыре вещи: семантику операции, возможность воспроизвести request, точку отказа и определённость outcome, остаток общего deadline. Если хотя бы одна неизвестна, автоматический retry превращается в риск дубликата или в заведомо бесполезную нагрузку.

`Safe`, `idempotent` и `exactly-once` — разные свойства. Safe HTTP method выражает read-only intent клиента. Idempotent operation допускает повтор с тем же intended effect, но ответы и побочные наблюдения могут различаться. Ни одно из этих свойств само по себе не даёт system-wide exactly-once: для неидемпотентного эффекта нужны [[20 Бэкенд/Ключи идемпотентности и дедупликация запросов|ключ, fingerprint и атомарная дедупликация]] либо доменный способ узнать результат первой попытки.

Полный разбор: [[10 Основы CS/Retry safety|Retry safety]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/05 Архитектура, устойчивость и консенсус#Resilience patterns|Resilience patterns]] — исходный блок о timeout, retry, breaker, degradation и DLQ.
- [[CurseHunter/5785/05 Архитектура, устойчивость и консенсус#Timeout и retry|Timeout и retry]] — вопрос об end-to-end budget, idempotency и retry amplification.
- [[CurseHunter/7091/02 Ошибки, повторы и деградация#1. Retry начинается с классификации|1. Retry начинается с классификации]] — вопрос о retryable outcome, owner retry и общем deadline.
- «Безопасность повторов non-idempotent операций дополняет Retry safety.» — [[Telegram Собесы/Редлаб — 2026-06-30 — 300к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Редлаб — 2026-06-30 — 300к, раздел «Сопоставление с материалами vault»]].

## Источники

- [RFC 9110 — HTTP Semantics: safe and idempotent methods, retries, Retry-After](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RFC 9113 — HTTP/2: GOAWAY and REFUSED_STREAM](https://www.rfc-editor.org/rfc/rfc9113.html) — IETF, RFC 9113, июнь 2022, проверено 2026-07-18.
- [RFC 9114 — HTTP/3: request cancellation and rejection](https://www.rfc-editor.org/rfc/rfc9114.html) — IETF, RFC 9114, июнь 2022, проверено 2026-07-18.
- [RFC 6585 — Additional HTTP Status Codes: 429](https://www.rfc-editor.org/rfc/rfc6585.html) — IETF, RFC 6585, апрель 2012, проверено 2026-07-18.
- [Retry](https://grpc.io/docs/guides/retry/) — gRPC Authors, официальное руководство, обновлено 2025-11-26, проверено 2026-07-18.
- [Route components: retry policy](https://www.envoyproxy.io/docs/envoy/v1.38.3/api-v3/config/route/v3/route_components.proto.html) — Envoy Project, API Envoy 1.38.3, проверено 2026-07-18.
- [Timeouts, retries, and backoff with jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/) — Amazon Web Services, Builders' Library, онлайн-публикация, проверено 2026-07-18.
