---
aliases:
  - "Теоретический вопрос: Idempotency и deduplication"
tags:
  - область/распределённые-системы
  - тема/доставка-сообщений
  - механизм/идемпотентность
  - тип/вопрос
статус: проверено
---

# Idempotency и deduplication

## Вопрос

Как работает «Idempotency и deduplication»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

**Idempotency** — свойство операции: повтор с тем же логическим намерением не меняет наблюдаемый результат после первого успешного применения. **Deduplication** — механизм: система узнаёт повтор по стабильному идентификатору и не запускает эффект заново либо возвращает сохранённый результат. Они дополняют друг друга, но не совпадают.

`PUT status=paid` может быть идемпотентным по состоянию, но повтор всё ещё способен дважды отправить email. Таблица dedup может увидеть одинаковый ID, но не спасёт, если эффект и отметка обработанности коммитятся раздельно. Рабочая гарантия требует определить identity, scope, payload equality, атомарную границу, retention и ответ на незавершённый первый вызов.

Полный разбор: [[40 Распределённые системы/Idempotency и deduplication|Idempotency и deduplication]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/7091/04 Очереди и асинхронная коммуникация#6. Inbox и idempotent consumer|6. Inbox и idempotent consumer]] — вопрос об atomic boundary inbox record и business effect.
- «Idempotency → Transactional outbox → очереди и DLQ.» — [[Telegram Собесы/VK Tech — 2025-09-12 — 350к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/VK Tech — 2025-09-12 — 350к, раздел «Минимальный маршрут по vault»]].
- «CAP и PACELC, Delivery semantics и Idempotency и deduplication.» — [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/Магнит — 2025-08-19 — 460к, раздел «Минимальный маршрут по vault»]].

- [[Telegram Собесы/Ennabl — 2026-04-27 — 6150 EUR/Бланк вопросов и заданий#Опыт и phone registration — `00:01:18–00:12:52`|Опыт и phone registration — `00:01:18–00:12:52`]] — technical project prompts этого смешанного блока сохранены здесь; behavioral, motivation и culture-fit часть исключена из банка.

## Источники

- [RFC 9110, § 9.2.2 Idempotent Methods](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.2.2) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [The Idempotency-Key HTTP Header Field](https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/07/) — IETF HTTPAPI Working Group, Internet-Draft `-07`, опубликован 2025-10-15, срок действия истёк 2026-04-18, проверено 2026-07-18; не является RFC.
- [Implementing Remote Procedure Calls](https://birrell.org/andrew/papers/ImplementingRPC.pdf) — Andrew D. Birrell и Bruce Jay Nelson, ACM TOCS 2(1), 1984, проверено 2026-07-18.
- [PostgreSQL 18: Unique Constraints](https://www.postgresql.org/docs/18/ddl-constraints.html#DDL-CONSTRAINTS-UNIQUE-CONSTRAINTS) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Message Delivery Semantics](https://kafka.apache.org/43/design/design/#message-delivery-semantics) — Apache Kafka, документация 4.3, проверено 2026-07-18.
