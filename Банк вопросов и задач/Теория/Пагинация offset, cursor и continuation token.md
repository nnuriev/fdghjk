---
aliases:
  - "Теоретический вопрос: Пагинация offset, cursor и continuation token"
tags:
  - область/бэкенд
  - тема/api
  - тип/вопрос
статус: проверено
---

# Пагинация offset, cursor и continuation token

## Вопрос

Как работает «Пагинация offset, cursor и continuation token» и какие ограничения, failure modes и trade-offs нужно учитывать в backend-системе?

## Короткий ориентир

Пагинация — протокол обхода упорядоченного множества, которое может меняться между запросами. Offset хранит позицию в текущем результате и удобен для перехода к номеру страницы, но дорог на большой глубине и даёт gaps/duplicates при concurrent writes. Cursor привязывает продолжение к последней sort tuple; он быстрее и устойчивее к изменениям перед границей, но требует стабильного полного порядка.

Continuation token — opaque wire-контракт. Он может содержать cursor, snapshot/revision, normalized query и срок действия либо ссылаться на server-side state. Token обязан быть связан с filter, sort, tenant и authorization context, но сам не выдаёт доступ к данным.

Полный разбор: [[20 Бэкенд/Пагинация offset, cursor и continuation token|Пагинация offset, cursor и continuation token]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/02 Кэш, API и observability#Offset, page и cursor pagination|Offset, page и cursor pagination]] — вопрос о стабильном порядке и цене deep pagination.
- «`PUT` с client-generated identity выражает retry contract. Сервер проверяет payload fingerprint: тот же key с другим body возвращает conflict. Cursor списка подписывает `(user_id, last_activity_at, conversation_id, projection_version)`; правила cursor pagination раскрыты в заметке о пагинации.» — [[Авито/Решения/System Design/Messenger BE#API|Авито/Решения/System Design/Messenger BE, раздел «API»]].

## Источники

- [AIP-158: Pagination](https://google.aip.dev/158) — Google, Approved, changelog до 2025-07-08, проверено 2026-07-18.
- [PostgreSQL 18: LIMIT and OFFSET](https://www.postgresql.org/docs/18/queries-limit.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-18.
- [PostgreSQL 18: Sorting Rows](https://www.postgresql.org/docs/18/queries-order.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-18.
- [PostgreSQL 18: Indexes and ORDER BY](https://www.postgresql.org/docs/18/indexes-ordering.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-18.
- [PostgreSQL 18: Multicolumn Indexes](https://www.postgresql.org/docs/18/indexes-multicolumn.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-18.
- [GraphQL Cursor Connections Specification](https://relay.dev/graphql/connections.htm) — Relay/GraphQL specification, online edition, проверено 2026-07-18.
- [RFC 8288: Web Linking](https://www.rfc-editor.org/rfc/rfc8288.html) — IETF, октябрь 2017, проверено 2026-07-18.
- [Paginating table query results in DynamoDB](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Query.Pagination.html) — Amazon Web Services, DynamoDB API, проверено 2026-07-18.
- [DynamoDB Query API](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html) — Amazon Web Services, DynamoDB API, проверено 2026-07-18.
- [JSON:API Specification 1.1: Pagination](https://jsonapi.org/format/#fetching-pagination) — JSON:API, версия 1.1, проверено 2026-07-18.
