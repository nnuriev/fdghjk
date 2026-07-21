---
aliases:
  - "Теоретический вопрос: WAL, fsync и граница durability"
tags:
  - область/данные
  - тема/хранение
  - тип/вопрос
статус: черновик
---

# WAL, fsync и граница durability

## Вопрос

Как write-ahead log и `fsync` связывают успешный commit с recovery после crash?

## Короткий ориентир

WAL требует durable log record до data pages, поэтому recovery может повторить committed effects и отбросить незавершённые. `write` в page cache ещё не означает stable storage; durability boundary задают flush/fsync protocol, ordering, storage stack и commit acknowledgement. Group commit разделяет цену flush между несколькими transactions.

Полные разборы:

- [[30 Данные/Write-ahead log (WAL)|Write-ahead log (WAL)]]
- [[30 Данные/Durability и fsync|Durability и fsync]]

## Варианты follow-up

- Почему log record должен стать durable раньше data page?
- Чем `write` отличается от `fsync` для crash recovery?
- Как group commit меняет latency и throughput?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/03 Данные, очереди и расчёт ресурсов#WAL и durability|CourseHunter 5785, WAL]].
- [[CurseHunter/6593/06 Практические реализации и учебная БД#WAL: инварианты|CourseHunter 6593, WAL invariants]].

- [[Telegram Собесы/CoinsPaid — 2026-04-27 — 6633 EUR/Бланк вопросов и заданий#PostgreSQL: isolation, locks, deadlocks и WAL — `01:31:24–01:41:21`|PostgreSQL: isolation, locks, deadlocks и WAL — `01:31:24–01:41:21`]] — точная проверенная формулировка соответствующего технического блока интервью.

## Источники

- [ARIES: A Transaction Recovery Method Supporting Fine-Granularity Locking and Partial Rollbacks Using Write-Ahead Logging](https://research.ibm.com/publications/aries-a-transaction-recovery-method-supporting-fine-granularity-locking-and-partial-rollbacks-using-write-ahead-logging) — IBM Research, ACM TODS 17(1), DOI `10.1145/128765.128770`, 1992, проверено 2026-07-18.
- [Write-Ahead Logging](https://www.postgresql.org/docs/18/wal-intro.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Asynchronous Commit](https://www.postgresql.org/docs/18/wal-async-commit.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [WAL Configuration](https://www.postgresql.org/docs/18/wal-configuration.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [WAL Internals](https://www.postgresql.org/docs/18/wal-internals.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Logical Decoding Concepts](https://www.postgresql.org/docs/18/logicaldecoding-explanation.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Формирование WAL records и full-page images](https://github.com/postgres/postgres/blob/f5cc81719e6da4cbdb1f797c48b693e91018153a/src/backend/access/transam/xloginsert.c#L533-L760) — PostgreSQL, tag `REL_18_4`, commit `f5cc81719e6da4cbdb1f797c48b693e91018153a`, проверено 2026-07-18.
- [Write path RocksDB](https://github.com/facebook/rocksdb/blob/6cdeb9d9d0630763327f512e6255cab33f6834e7/db/db_impl/db_impl_write.cc#L760-L880) — RocksDB, tag `v11.1.1`, commit `6cdeb9d9d0630763327f512e6255cab33f6834e7`, проверено 2026-07-18.
- [General Concepts — File Synchronization](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap04.html) — IEEE и The Open Group, POSIX.1-2024, Issue 8, проверено 2026-07-18.
- [Reliability](https://www.postgresql.org/docs/18/wal-reliability.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [WAL Settings](https://www.postgresql.org/docs/18/runtime-config-wal.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Реализация WAL flush](https://github.com/postgres/postgres/blob/f5cc81719e6da4cbdb1f797c48b693e91018153a/src/backend/access/transam/xlog.c) — PostgreSQL, tag `REL_18_4`, commit `f5cc81719e6da4cbdb1f797c48b693e91018153a`, символы `XLogFlush` и `issue_xlog_fsync`, проверено 2026-07-18.
- [WriteOptions::sync и disableWAL](https://github.com/facebook/rocksdb/blob/6cdeb9d9d0630763327f512e6255cab33f6834e7/include/rocksdb/options.h#L2319-L2344) — RocksDB, tag `v11.1.1`, commit `6cdeb9d9d0630763327f512e6255cab33f6834e7`, проверено 2026-07-18.
