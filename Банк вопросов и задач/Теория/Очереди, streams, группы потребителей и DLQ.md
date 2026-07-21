---
aliases:
  - "Теоретический вопрос: Очереди, streams, группы потребителей и DLQ"
tags:
  - область/распределённые-системы
  - тема/messaging
  - тип/вопрос
статус: проверено
---

# Очереди, streams, группы потребителей и DLQ

## Вопрос

Как работает «Очереди, streams, группы потребителей и DLQ»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

Очередь распределяет независимые единицы работы между конкурирующими consumers. Stream хранит упорядоченный журнал, позицию чтения в котором каждый consumer group ведёт отдельно; поэтому одни данные можно независимо обработать и переиграть несколькими группами.

Гарантию задаёт не слово «broker», а место подтверждения относительно бизнес-эффекта. Подтверждение до эффекта допускает потерю, после эффекта — повтор. На практике обработчик должен выдерживать redelivery. Партиционирование связывает порядок и параллелизм, backpressure ограничивает объём выданной, но не подтверждённой работы, а DLQ лишь изолирует необработанное сообщение и требует отдельного процесса разбора и replay.

Полный разбор: [[40 Распределённые системы/Очереди, streams, группы потребителей и DLQ|Очереди, streams, группы потребителей и DLQ]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/03 Данные, очереди и расчёт ресурсов#Брокеры и delivery semantics|Брокеры и delivery semantics]] — исходный блок об ordering, duplicates и delivery boundary.
- [[CurseHunter/5785/03 Данные, очереди и расчёт ресурсов#Зачем queue?|Зачем queue?]] — вопрос о temporal decoupling, burst absorption и цене lag.
- [[CurseHunter/5785/05 Архитектура, устойчивость и консенсус#DLQ|DLQ]] — самостоятельный вопрос об ownership, alerting и replay poison messages.
- [[CurseHunter/7091/04 Очереди и асинхронная коммуникация#2. Producer durability|2. Producer durability]] — вопрос о replication factor, ISR, acknowledgements и producer idempotence.
- [[CurseHunter/7091/04 Очереди и асинхронная коммуникация#3. Consumer groups и offsets|3. Consumer groups и offsets]] — вопрос о границе commit относительно business effect.
- [[CurseHunter/7091/04 Очереди и асинхронная коммуникация#7. Retry, retry topics и DLQ|7. Retry, retry topics и DLQ]] — вопрос о poison messages, нарушении порядка и operational contract DLQ.
- «На вопрос о consumer group кандидат сначала оставляет одну из трёх partitions без reader при двух consumers. Это неверно: coordinator распределит все три partitions, один consumer получит две, второй одну. При пяти consumers в одной group три будут заняты по одной partition, два останутся idle. Разные groups читают topic независимо. Механика assignments, offsets и rebalance разобрана в заметке об очередях, streams и consumer groups.» — [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Kafka, Outbox, CI/CD и тесты|Telegram Собесы/M.Tech — 2026-07-17 — 350к, раздел «Kafka, Outbox, CI/CD и тесты»]].
- «Idempotency → Transactional outbox → очереди и DLQ.» — [[Telegram Собесы/VK Tech — 2025-09-12 — 350к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/VK Tech — 2025-09-12 — 350к, раздел «Минимальный маршрут по vault»]].

- [[Telegram Собесы/АМТЕХ — 2026-04-06 — 350к/Бланк вопросов и заданий#Kafka: topics, partitions, groups и offsets — `00:13:56–00:17:38`|Kafka: topics, partitions, groups и offsets — `00:13:56–00:17:38`]] — точная проверенная формулировка технического блока интервью АМТЕХ.
- [[Telegram Собесы/АМТЕХ — 2026-04-06 — 350к/Бланк вопросов и заданий#Kafka и RabbitMQ — `00:17:38–00:20:12`|Kafka и RabbitMQ — `00:17:38–00:20:12`]] — точная проверенная формулировка технического блока интервью АМТЕХ.

- [[Telegram Собесы/MagnitTech — 2026-04-13 — 400200 руб/Бланк вопросов и заданий#Kafka — `01:17:33–01:23:39`|Kafka — `01:17:33–01:23:39`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Магнит — 2025-12-26 — 400к/Бланк вопросов и заданий#Kafka — `01:37:04–01:42:19`|Kafka — `01:37:04–01:42:19`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [Design](https://kafka.apache.org/43/design/design/) — Apache Kafka, документация 4.3, проверено 2026-07-18.
- [Distribution](https://kafka.apache.org/43/implementation/distribution/) — Apache Kafka, документация 4.3, проверено 2026-07-18.
- [Consumer Rebalance Protocol](https://kafka.apache.org/43/operations/consumer-rebalance-protocol/) — Apache Kafka, документация 4.3, проверено 2026-07-18.
- [Queues](https://www.rabbitmq.com/docs/queues) — RabbitMQ, документация 4.3.2, проверено 2026-07-18.
- [Consumer Acknowledgements and Publisher Confirms](https://www.rabbitmq.com/docs/confirms) — RabbitMQ, документация 4.3.2, проверено 2026-07-18.
- [Dead Letter Exchanges](https://www.rabbitmq.com/docs/dlx) — RabbitMQ, документация 4.3.2, проверено 2026-07-18.
- [Release Information](https://www.rabbitmq.com/release-information) — RabbitMQ, релиз 4.3.2, проверено 2026-07-18.
