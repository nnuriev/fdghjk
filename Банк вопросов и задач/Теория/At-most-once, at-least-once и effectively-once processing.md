---
aliases:
  - "Теоретический вопрос: At-most-once, at-least-once и effectively-once processing"
tags:
  - область/распределённые-системы
  - тема/доставка-сообщений
  - механизм/повторная-обработка
  - тип/вопрос
статус: проверено
---

# At-most-once, at-least-once и effectively-once processing

## Вопрос

Как работает «At-most-once, at-least-once и effectively-once processing»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

После timeout отправитель не знает, потерялся запрос или только ответ. Отказ от retry ограничивает sender одной попыткой; end-to-end **at-most-once processing** дополнительно требует, чтобы transport не делал redelivery либо receiver дедуплицировал запрос. Повтор до `ack` при durable storage и eventual recovery даёт **at-least-once delivery**. Чтобы получить at-least-once business effect, receiver должен подтверждать сообщение только после durable effect и не прекращать recovery навсегда.

**Effectively-once processing** — не третья магическая доставка, а композиция: повторяемая at-least-once доставка плюс механизм, который делает повторно наблюдаемый бизнес-результат эквивалентным одному применению. Это может быть идемпотентная операция, inbox с уникальным `event_id`, атомарная запись эффекта вместе с маркером обработки или транзакции внутри явно очерченной системы. Граница гарантии важнее названия: Kafka transaction не делает exactly-once вызов произвольного внешнего API.

Полный разбор: [[40 Распределённые системы/At-most-once, at-least-once и effectively-once processing|At-most-once, at-least-once и effectively-once processing]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/7091/04 Очереди и асинхронная коммуникация#4. Delivery semantics без магии|4. Delivery semantics без магии]] — вопрос о границе Kafka EOS и effectively-once business effect.
- «CAP и PACELC, Delivery semantics и Idempotency и deduplication.» — [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/Магнит — 2025-08-19 — 460к, раздел «Минимальный маршрут по vault»]].
- «Gateway держит connections и backpressure, но не владеет историей. Message Service отвечает за authorization, idempotency и per-conversation order. Durable stream допускает at-least-once delivery; consumers дедуплицируют `event_id` по правилам delivery semantics.» — [[Авито/Решения/System Design/Messenger BE#Компоненты|Авито/Решения/System Design/Messenger BE, раздел «Компоненты»]].

- [[Telegram Собесы/Ennabl — 2026-04-27 — 6150 EUR/Бланк вопросов и заданий#Referral system — `00:12:52–00:17:09`|Referral system — `00:12:52–00:17:09`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Plata — 2026-04-13 — 4252 EUR/Бланк вопросов и заданий#Брокеры, повторный перевод, delivery semantics и Outbox — `01:11:00–01:20:45`|Брокеры, повторный перевод, delivery semantics и Outbox — `01:11:00–01:20:45`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Авито — 2026-04-20 — 470к/Бланк вопросов и заданий#Гарантии доставки и processing — `00:16:13–00:29:16`|Гарантии доставки и processing — `00:16:13–00:29:16`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [Implementing Remote Procedure Calls](https://birrell.org/andrew/papers/ImplementingRPC.pdf) — Andrew D. Birrell и Bruce Jay Nelson, ACM TOCS 2(1), 1984, проверено 2026-07-18.
- [Message Delivery Semantics](https://kafka.apache.org/43/design/design/#message-delivery-semantics) — Apache Kafka, документация 4.3, проверено 2026-07-18.
- [Kafka producer configurations: `enable.idempotence`](https://kafka.apache.org/43/configuration/producer-configs/#producerconfigs_enable.idempotence) — Apache Kafka, документация 4.3, проверено 2026-07-18.
- [Kafka consumer configurations: `isolation.level`](https://kafka.apache.org/43/configuration/consumer-configs/#consumerconfigs_isolation.level) — Apache Kafka, документация 4.3, проверено 2026-07-18.
- [Consumer acknowledgements and publisher confirms](https://www.rabbitmq.com/docs/4.2/confirms) — RabbitMQ, документация 4.2, проверено 2026-07-18.
- [RFC 9110, § 9.2.2 Idempotent Methods](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.2.2) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
