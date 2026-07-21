---
aliases:
  - "Теоретический вопрос: Transactional outbox и Change Data Capture"
tags:
  - область/распределённые-системы
  - тема/согласованность
  - тип/вопрос
статус: проверено
---

# Transactional outbox и Change Data Capture

## Вопрос

Как работает «Transactional outbox и Change Data Capture»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

Transactional outbox переносит бизнес-изменение и намерение опубликовать событие в одну локальную транзакцию: сервис обновляет свои таблицы и вставляет immutable outbox row. Отдельный relay читает закоммиченные записи — polling-ом или через Change Data Capture (CDC) — и публикует их в broker.

Это устраняет dual-write окно «БД закоммичена, событие потеряно» и обратное окно «событие опубликовано, БД откатилась». В общей схеме at-least-once relay может опубликовать событие и упасть до фиксации прогресса, поэтому downstream обязан переносить дубликаты. Kafka Connect умеет сузить это окно транзакционной записью source records вместе с offsets, но не делает атомарным внешний downstream-эффект. CDC не даёт end-to-end `exactly once`; его лаг и удержание журнала становятся частью эксплуатационного контракта.

Полный разбор: [[40 Распределённые системы/Transactional outbox и Change Data Capture|Transactional outbox и Change Data Capture]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/03 Данные, очереди и расчёт ресурсов#Паттерны хранения и поставки|Паттерны хранения и поставки]] — блок о materialized views, batching, dual write и outbox/CDC.
- [[CurseHunter/5785/04 Распределённое хранение данных#CDC и альтернативные read models|CDC и альтернативные read models]] — вопрос о распространении изменений и цене duplicated state.
- [[CurseHunter/5785/05 Архитектура, устойчивость и консенсус#Transactional outbox/inbox|Transactional outbox/inbox]] — вопрос об atomic local write и at-least-once publication.
- [[CurseHunter/7091/04 Очереди и асинхронная коммуникация#5. Transactional outbox|5. Transactional outbox]] — вопрос о dual write, relay retry и обязательной дедупликации consumer.
- «Outbox кандидат описывает как запись события в реляционную базу и последующую публикацию polling-worker’ом. Не хватает главного failure window: relay может успешно отправить event и упасть до отметки `processed`, поэтому сообщение выйдет повторно. Полный механизм, CDC-альтернатива и downstream inbox разобраны в Transactional outbox и CDC.» — [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Kafka, Outbox, CI/CD и тесты|Telegram Собесы/M.Tech — 2026-07-17 — 350к, раздел «Kafka, Outbox, CI/CD и тесты»]].
- «| Transactional outbox | Механизм публикации есть в Transactional outbox и CDC, но exact задача про polling workers и lease отдельно не сохранена |» — [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Сопоставление с текущим репозиторием|Telegram Собесы/M.Tech — 2026-07-17 — 350к, раздел «Сопоставление с текущим репозиторием»]].
- «Idempotency → Transactional outbox → очереди и DLQ.» — [[Telegram Собесы/VK Tech — 2025-09-12 — 350к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/VK Tech — 2025-09-12 — 350к, раздел «Минимальный маршрут по vault»]].
- «Transactional outbox, Two-phase commit и Saga.» — [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/Магнит — 2025-08-19 — 460к, раздел «Минимальный маршрут по vault»]].
- «Отправка транзакционных сообщений клиенту — нужно исходное условие; база: Transactional outbox и Change Data Capture, Проектирование сервиса уведомлений.» — [[Авито/roadmap#System design и проектирование|Авито/roadmap, раздел «System design и проектирование»]].
- «Crash между DB commit и publish event закрывается outbox. Crash indexer после записи, но до acknowledgment приводит к повтору, который безопасен по version.» — [[Авито/Решения/System Design/Avito.ru — classified#Создание и публикация|Авито/Решения/System Design/Avito.ru — classified, раздел «Создание и публикация»]].

- [[Telegram Собесы/CoinsPaid — 2026-04-27 — 6633 EUR/Бланк вопросов и заданий#Transactional Outbox — `01:41:21–01:44:40`|Transactional Outbox — `01:41:21–01:44:40`]] — точная проверенная формулировка соответствующего технического блока интервью.

- [[Telegram Собесы/Plata — 2026-04-13 — 4252 EUR/Бланк вопросов и заданий#Брокеры, повторный перевод, delivery semantics и Outbox — `01:11:00–01:20:45`|Брокеры, повторный перевод, delivery semantics и Outbox — `01:11:00–01:20:45`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [Outbox Event Router](https://debezium.io/documentation/reference/3.6/transformations/outbox-event-router.html) — Debezium, версия 3.6.0.Final, проверено 2026-07-18.
- [Exactly once delivery](https://debezium.io/documentation/reference/3.6/configuration/eos.html) — Debezium, версия 3.6.0.Final, Kafka Connect source EOS и его ограничения, проверено 2026-07-18.
- [Exactly-once support](https://kafka.apache.org/43/kafka-connect/user-guide/#exactly-once-support) — Apache Kafka, Kafka Connect 4.3, транзакционная граница source records и offsets, проверено 2026-07-18.
- [Kafka Connect worker configuration](https://kafka.apache.org/43/configuration/kafka-connect-configs/#connectconfigs_exactly.once.source.support) — Apache Kafka, документация 4.3, настройка source EOS на workers, проверено 2026-07-18.
- [Kafka Connect source connector configuration](https://kafka.apache.org/43/configuration/kafka-connect-configs/#sourceconnectorconfigs_exactly.once.support) — Apache Kafka, документация 4.3, настройка source EOS connector, проверено 2026-07-18.
- [Kafka consumer `isolation.level`](https://kafka.apache.org/43/configuration/consumer-configs/#consumerconfigs_isolation.level) — Apache Kafka, документация 4.3, default `read_uncommitted` и поведение `read_committed`, проверено 2026-07-18.
- [Debezium connector for PostgreSQL](https://debezium.io/documentation/reference/3.6/connectors/postgresql.html) — Debezium, версия 3.6.0.Final, восстановление по LSN и replication slot, проверено 2026-07-18.
- [Debezium 3.6 Release Series](https://debezium.io/releases/3.6/) — Debezium, релиз 3.6.0.Final от 2026-07-01, проверено 2026-07-18.
- [Logical Decoding Concepts](https://www.postgresql.org/docs/18/logicaldecoding-explanation.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Logical Decoding Examples](https://www.postgresql.org/docs/18/logicaldecoding-example.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
