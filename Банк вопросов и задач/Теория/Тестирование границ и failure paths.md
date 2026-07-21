---
aliases:
  - "Теоретический вопрос: Тестирование границ и failure paths"
tags:
  - область/бэкенд
  - тема/тестирование
  - тема/надёжность
  - тип/вопрос
статус: черновик
---

# Тестирование границ и failure paths

## Вопрос

Как работает «Тестирование границ и failure paths» и какие ограничения, failure modes и trade-offs нужно учитывать в backend-системе?

## Короткий ориентир

Boundary test выбирает значения непосредственно по обе стороны от каждого разрыва поведения: minimum, maximum, deadline, capacity, state transition или version boundary. Failure-path test вводит отказ в конкретной фазе операции и проверяет не только returned error, но и durable state, внешние effects, освобождение ресурсов, retry semantics и observability.

Главный oracle звучит не «метод вернул ошибку», а «при outcome X система сохранила invariants Y». Для операции записи особенно различаются отказ до side effect, подтверждённый rollback и потеря ответа после успешного commit: одинаковый timeout на client не доказывает одинаковое состояние server.

Полный разбор: [[20 Бэкенд/Тестирование границ и failure paths|Тестирование границ и failure paths]].

Канонический разбор пока имеет статус `черновик`; эта карточка сохраняет ту же степень проверенности.

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Граница unit/integration test и управляемые HTTP dependencies раскрыты в Тестирование и httptest и Тестирование границ и failure paths.» — [[Telegram Собесы/Редлаб — 2026-06-30 — 300к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Редлаб — 2026-06-30 — 300к, раздел «Сопоставление с материалами vault»]].

## Источники

- [CWE-20: Improper Input Validation](https://cwe.mitre.org/data/definitions/20.html) — MITRE, CWE 4.20, проверено 2026-07-18.
- [ISO/IEC/IEEE 29119-4:2021: Software testing — Test techniques](https://www.iso.org/standard/79430.html) — ISO/IEC/IEEE, Edition 2, проверено 2026-07-18.
- [Secure Software Development Framework](https://doi.org/10.6028/NIST.SP.800-218) — NIST, SP 800-218 Version 1.1, проверено 2026-07-18.
- [Go Fuzzing](https://go.dev/doc/security/fuzz/) — The Go Project, документация Go 1.26.5, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, RFC 9110, проверено 2026-07-18.
- [RFC 9457: Problem Details for HTTP APIs](https://www.rfc-editor.org/rfc/rfc9457.html) — IETF, RFC 9457, проверено 2026-07-18.
