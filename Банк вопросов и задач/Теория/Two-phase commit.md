---
aliases:
  - "Теоретический вопрос: Two-phase commit"
tags:
  - область/распределённые-системы
  - тема/распределённые-транзакции
  - механизм/двухфазный-коммит
  - тип/вопрос
статус: проверено
---

# Two-phase commit

## Вопрос

Как работает «Two-phase commit»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

**Two-phase commit (2PC)** — протокол атомарного commit между несколькими transactional resources. В фазе `prepare` каждый participant обещает, что сможет commit позднее, и делает это обещание durable. Coordinator выбирает единственное решение: `COMMIT`, только если все проголосовали `YES`, иначе `ABORT`. Во второй фазе решение доставляется участникам.

2PC обеспечивает atomicity финального решения, но не одновременную видимость на всех participants и не глобальную isolation. Классический протокол может блокироваться: participant, уже ответивший `YES`, не вправе самовольно abort, пока не узнает решение coordinator. Подготовленная транзакция удерживает locks и другие ресурсы. Поэтому 2PC подходит для небольшого числа надёжно управляемых ресурсов с bounded recovery, но плохо сочетается с долгими бизнес-процессами, WAN partitions и внешними API.

Полный разбор: [[40 Распределённые системы/Two-phase commit|Two-phase commit]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Transactional outbox, Two-phase commit и Saga.» — [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/Магнит — 2025-08-19 — 460к, раздел «Минимальный маршрут по vault»]].

- [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Распределённые транзакции: 2PC и Saga — `01:21:02–01:24:08`|Распределённые транзакции: 2PC и Saga — `01:21:02–01:24:08`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [Consensus on Transaction Commit](https://www.microsoft.com/en-us/research/publication/consensus-on-transaction-commit/) — Jim Gray и Leslie Lamport, ACM TODS 31(1), 2006, проверено 2026-07-18.
- [PostgreSQL 18: Two-Phase Transactions](https://www.postgresql.org/docs/18/two-phase.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [PostgreSQL 18: `PREPARE TRANSACTION`](https://www.postgresql.org/docs/18/sql-prepare-transaction.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [PostgreSQL 18: `max_prepared_transactions`](https://www.postgresql.org/docs/18/runtime-config-resource.html#GUC-MAX-PREPARED-TRANSACTIONS) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
