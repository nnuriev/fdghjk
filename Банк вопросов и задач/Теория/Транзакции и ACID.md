---
aliases:
  - "Теоретический вопрос: Транзакции и ACID"
tags:
  - область/данные
  - тема/транзакции
  - механизм/надёжность
  - тип/вопрос
статус: проверено
---

# Транзакции и ACID

## Вопрос

Объясните тему «Транзакции и ACID»: какие гарантии даёт механизм и какой ценой для чтения, записи и эксплуатации?

## Короткий ориентир

Транзакция объединяет несколько чтений и записей в одну commit boundary. Atomicity запрещает частичный commit, consistency означает сохранение заявленных инвариантов, isolation ограничивает наблюдаемые эффекты конкуренции, durability связывает успешный commit с восстановлением после crash.

ACID не расширяет границу автоматически. Внешний HTTP-вызов, очередь без общей транзакции, cache и sequence живут по своим правилам. Гарантия точна только после ответа: какие данные входят в транзакцию, какой выбран [[30 Данные/Уровни изоляции транзакций|уровень изоляции]] и какие durability settings/устройства считаются надёжными.

Полный разбор: [[30 Данные/Транзакции и ACID|Транзакции и ACID]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Практические модели PostgreSQL индексов, транзакций и locking переиспользуются из индексов, ACID и MVCC и блокировок.» — [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Наблюдаемые ошибки и точные поправки|Telegram Собесы/M.Tech — 2026-07-17 — 350к, раздел «Наблюдаемые ошибки и точные поправки»]].
- «Транзакции и ACID, Уровни изоляции транзакций и Блокировки, MVCC и deadlocks.» — [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/Магнит — 2025-08-19 — 460к, раздел «Минимальный маршрут по vault»]].
- «Транзакции, ACID, MVCC и deadlocks: Транзакции и ACID, Блокировки, MVCC и deadlocks.» — [[Авито/roadmap#СУБД и SQL|Авито/roadmap, раздел «СУБД и SQL»]].

- [[Telegram Собесы/АМТЕХ — 2026-04-06 — 350к/Бланк вопросов и заданий#PostgreSQL: ACID и isolation — `01:07:12–01:10:30`|PostgreSQL: ACID и isolation — `01:07:12–01:10:30`]] — точная проверенная формулировка технического блока интервью АМТЕХ.

- [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Базы данных — `00:33:03–00:46:01`|Базы данных — `00:33:03–00:46:01`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#ACID — `00:35:10–00:36:01`|ACID — `00:35:10–00:36:01`]] — точная проверенная формулировка самостоятельного технического блока интервью.

- [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Команда и Partner Billing — `00:06:17–00:13:08`|Команда и Partner Billing — `00:06:17–00:13:08`]] — technical project prompts этого смешанного блока сохранены здесь; behavioral, motivation и culture-fit часть исключена из банка.

## Источники

- [Principles of Transaction-Oriented Database Recovery](https://doi.org/10.1145/289.291) — ACM, Theo Härder, Andreas Reuter, ACM Computing Surveys 15(4), 1983, проверено 2026-07-18.
- [Transactions](https://www.postgresql.org/docs/18/tutorial-transactions.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Transaction Isolation](https://www.postgresql.org/docs/18/transaction-iso.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Write-Ahead Logging](https://www.postgresql.org/docs/18/wal-intro.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [WAL Configuration](https://www.postgresql.org/docs/18/wal-configuration.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Asynchronous Commit](https://www.postgresql.org/docs/18/wal-async-commit.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Constraints](https://www.postgresql.org/docs/18/ddl-constraints.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [PostgreSQL 18.4 release notes](https://www.postgresql.org/docs/18/release-18-4.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, release date 2026-05-14, проверено 2026-07-18.
