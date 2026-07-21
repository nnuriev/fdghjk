---
aliases:
  - "Теоретический вопрос: Блокировки, MVCC и deadlocks"
tags:
  - область/данные
  - тема/транзакции
  - механизм/конкурентность
  - тип/вопрос
статус: проверено
---

# Блокировки, MVCC и deadlocks

## Вопрос

Объясните тему «Блокировки, MVCC и deadlocks»: какие гарантии даёт механизм и какой ценой для чтения, записи и эксплуатации?

## Короткий ориентир

MVCC хранит несколько row versions и даёт reader snapshot, поэтому обычное чтение не блокирует запись, а запись не блокирует обычное чтение. Блокировки остаются нужны: writers конфликтуют за logical rows, DDL защищает relation structure, foreign keys охраняют referenced keys, а application может брать `FOR UPDATE`.

Deadlock возникает не от долгого ожидания, а от цикла wait-for: T1 ждёт lock T2, а T2 прямо или транзитивно ждёт T1. PostgreSQL обнаруживает цикл и aborts одну transaction. Лечение: одинаковый порядок locks, короткие transactions и полный retry, а не бесконечный timeout.

Полный разбор: [[30 Данные/Блокировки, MVCC и deadlocks|Блокировки, MVCC и deadlocks]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#Two-phase locking, 2PL|Two-phase locking, 2PL]] — вопрос о growing/shrinking phases, strictness и deadlocks.
- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#MVCC|MVCC]] — вопрос о snapshot visibility, versions и write skew.
- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#2PL или MVCC|2PL или MVCC]] — сравнительная формулировка по conflicts, lifetime и retry cost.
- [[CurseHunter/5785/03 Данные, очереди и расчёт ресурсов#2PL и MVCC|2PL и MVCC]] — сравнительный вопрос о blocking, versions и serializability.
- «Практические модели PostgreSQL индексов, транзакций и locking переиспользуются из индексов, ACID и MVCC и блокировок.» — [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Наблюдаемые ошибки и точные поправки|Telegram Собесы/M.Tech — 2026-07-17 — 350к, раздел «Наблюдаемые ошибки и точные поправки»]].
- «| PostgreSQL indexes и locks | Индексы и MVCC и locks |» — [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Сопоставление с текущим репозиторием|Telegram Собесы/M.Tech — 2026-07-17 — 350к, раздел «Сопоставление с текущим репозиторием»]].
- «Кандидат перечислил несколько терминов и правильно назвал PostgreSQL `Read Committed` default. Ключевая ошибка — `Serializable` не блокирует систему до одной активной transaction: transactions выполняются concurrently, а PostgreSQL откатывает наборы, которые нельзя объяснить serial order. Подробности: аномалии, уровни изоляции и MVCC/locks.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#PostgreSQL: anomalies и isolation — `00:25:42–00:27:10`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «PostgreSQL: anomalies и isolation — `00:25:42–00:27:10`»]].
- «Транзакции и ACID, Уровни изоляции транзакций и Блокировки, MVCC и deadlocks.» — [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/Магнит — 2025-08-19 — 460к, раздел «Минимальный маршрут по vault»]].
- «Транзакции, ACID, MVCC и deadlocks: Транзакции и ACID, Блокировки, MVCC и deadlocks.» — [[Авито/roadmap#СУБД и SQL|Авито/roadmap, раздел «СУБД и SQL»]].

- [[Telegram Собесы/АМТЕХ — 2026-04-06 — 350к/Бланк вопросов и заданий#Индексы, WAL, MVCC, HOT и `VACUUM` — `01:10:30–01:15:55`|Индексы, WAL, MVCC, HOT и `VACUUM` — `01:10:30–01:15:55`]] — точная проверенная формулировка технического блока интервью АМТЕХ.

- [[Telegram Собесы/CoinsPaid — 2026-04-27 — 6633 EUR/Бланк вопросов и заданий#PostgreSQL: isolation, locks, deadlocks и WAL — `01:31:24–01:41:21`|PostgreSQL: isolation, locks, deadlocks и WAL — `01:31:24–01:41:21`]] — точная проверенная формулировка соответствующего технического блока интервью.

- [[Telegram Собесы/Авито — 2026-04-20 — 470к/Бланк вопросов и заданий#PostgreSQL incident, VACUUM и data model — `01:10:20–01:26:10`|PostgreSQL incident, VACUUM и data model — `01:10:20–01:26:10`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Что делает `FOR SHARE` — `00:58:46–00:59:41`|Что делает `FOR SHARE` — `00:58:46–00:59:41`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [MVCC Introduction](https://www.postgresql.org/docs/18/mvcc-intro.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Explicit Locking](https://www.postgresql.org/docs/18/explicit-locking.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [System Columns](https://www.postgresql.org/docs/18/ddl-system-columns.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Routine Vacuuming](https://www.postgresql.org/docs/18/routine-vacuuming.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Lock Management](https://www.postgresql.org/docs/18/runtime-config-locks.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Viewing Locks](https://www.postgresql.org/docs/18/monitoring-locks.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [pg_locks](https://www.postgresql.org/docs/18/view-pg-locks.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Lock manager README](https://github.com/postgres/postgres/blob/REL_18_4/src/backend/storage/lmgr/README) — postgres/postgres, tag `REL_18_4`, проверено 2026-07-18.
- [SSI README](https://github.com/postgres/postgres/blob/REL_18_4/src/backend/storage/lmgr/README-SSI) — postgres/postgres, tag `REL_18_4`, проверено 2026-07-18.
- [PostgreSQL 18.4 release notes](https://www.postgresql.org/docs/18/release-18-4.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, release date 2026-05-14, проверено 2026-07-18.
