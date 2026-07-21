---
aliases:
  - "Теоретический вопрос: Эволюция API и backward compatibility"
tags:
  - область/бэкенд
  - тема/api
  - тип/вопрос
статус: черновик
---

# Эволюция API и backward compatibility

## Вопрос

Как изменять API без одновременного обновления всех clients и где нужна новая версия контракта?

## Короткий ориентир

Совместимое изменение сохраняет поведение существующих clients на период rollout; additive wire shape не гарантирует semantic compatibility. Контракт включает поля, defaults, errors, ordering, pagination и side effects. Несовместимое изменение требует migration path: параллельные версии, tolerant readers, deprecation window и наблюдаемое удаление старого пути.

Полные разборы:

- [[20 Бэкенд/Контракты API и обратная совместимость|Контракты API и обратная совместимость]]
- [[20 Бэкенд/Версионирование API|Версионирование API]]

## Варианты follow-up

- Почему additive field может нарушить semantic compatibility?
- Когда tolerant reader помогает rolling upgrade?
- Какими сигналами доказать, что старую API version уже можно удалить?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/02 Кэш, API и observability#Версионирование|CourseHunter 5785, versioning]].

- [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Кеширование и contract-first|Кеширование и contract-first]] — точный prompt cluster о contract-first, code generation, review и rollout OpenAPI-контракта.

## Источники

- [OpenAPI Specification 3.2.0](https://spec.openapis.org/oas/v3.2.0.html) — OpenAPI Initiative, версия 3.2.0 от 2025-09-19, проверено 2026-07-18.
- [AIP-180: Backwards compatibility](https://google.aip.dev/180) — Google, Approved, changelog до 2025-10-21, проверено 2026-07-18.
- [Protocol Buffers Proto3 Language Guide: Updating a Message Type](https://protobuf.dev/programming-guides/proto3/#updating) — Google, Proto3, проверено 2026-07-18.
- [GraphQL Specification, September 2025 Edition](https://spec.graphql.org/September2025/) — GraphQL Foundation, сентябрь 2025, проверено 2026-07-18.
- [JSON Schema Draft 2020-12](https://json-schema.org/draft/2020-12) — JSON Schema, Draft 2020-12 от 2022-06-16, проверено 2026-07-18.
- [JSON Schema Validation Vocabulary](https://json-schema.org/draft/2020-12/json-schema-validation) — JSON Schema, Draft 2020-12 от 2022-06-16, проверено 2026-07-18.
- [Kubernetes API deprecation policy](https://kubernetes.io/docs/reference/using-api/deprecation-policy/) — Kubernetes project, online policy, проверено 2026-07-18.
- [AIP-185: API Versioning](https://google.aip.dev/185) — Google, Approved, версия от 2024-10-22, проверено 2026-07-18.
- [RFC 9745: The Deprecation HTTP Response Header Field](https://www.rfc-editor.org/rfc/rfc9745.html) — IETF, март 2025, проверено 2026-07-18.
- [RFC 8594: The Sunset HTTP Header Field](https://www.rfc-editor.org/rfc/rfc8594.html) — IETF, май 2019, проверено 2026-07-18.
- [GitHub REST API versions](https://docs.github.com/en/rest/about-the-rest-api/api-versions) — GitHub, актуальная версия `2026-03-10`, проверено 2026-07-18.
- [Stripe API versioning](https://docs.stripe.com/api/versioning) — Stripe, актуальная версия `2026-06-24.dahlia`, проверено 2026-07-18.
