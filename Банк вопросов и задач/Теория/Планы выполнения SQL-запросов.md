---
aliases:
  - "Теоретический вопрос: Планы выполнения SQL-запросов"
tags:
  - область/данные
  - тема/sql
  - практика/диагностика
  - тип/вопрос
статус: проверено
---

# Планы выполнения SQL-запросов

## Вопрос

Объясните тему «Планы выполнения SQL-запросов»: какие гарантии даёт механизм и какой ценой для чтения, записи и эксплуатации?

## Короткий ориентир

Planner превращает декларативный SQL в дерево физических operators и выбирает вариант с минимальной оценённой cost. Главный вход выбора: estimated row count на каждом узле. Ошибка cardinality внизу дерева умножается на joins и часто важнее самого типа scan.

Читайте `EXPLAIN ANALYZE` как сравнение гипотезы и наблюдения: `rows` против `actual rows`, затем `loops`, buffers, temp I/O, sort spills и время. Cost не измеряется в миллисекундах, а хороший plan на тестовых десяти строках ничего не доказывает о production distribution.

Полный разбор: [[30 Данные/Планы выполнения SQL-запросов|Планы выполнения SQL-запросов]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «SQL и PostgreSQL блоки можно повторить по SQL joins и aggregations, Индексы и цена чтения/записи, Планы выполнения и Уровни изоляции.» — [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Lamoda — 2026-06-10 — 400к, раздел «Сопоставление с материалами vault»]].
- «Индексы → планы выполнения.» — [[Telegram Собесы/VK Tech — 2025-09-12 — 350к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/VK Tech — 2025-09-12 — 350к, раздел «Минимальный маршрут по vault»]].
- «Кандидат знает названия B-tree/GiST/SP-GiST и composite indexes, но надеется, что planner «расставит порядок правильно». Planner может переставить логические predicates, однако физический порядок B-tree keys задан DDL. PostgreSQL 18 умеет skip scan в некоторых случаях, но leading columns по-прежнему определяют эффективность. См. индексы, B-tree/B+tree и планы запросов.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Indexes и ускорение запросов — `00:27:10–00:28:31`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Indexes и ускорение запросов — `00:27:10–00:28:31`»]].
- «EXPLAIN → indexes → isolation.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Минимальный маршрут по vault»]].
- «B-tree и B+tree, Индексы и цена чтения и записи и Планы выполнения SQL-запросов.» — [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/Магнит — 2025-08-19 — 460к, раздел «Минимальный маршрут по vault»]].
- «Индексы, B-tree и цена disk I/O: Индексы и цена чтения и записи, B-tree и B+tree, Планы выполнения SQL-запросов.» — [[Авито/roadmap#СУБД и SQL|Авито/roadmap, раздел «СУБД и SQL»]].
- «Оптимизировать запрос с `GROUP BY` по всем полям — нужно исходное условие и схема; база: SQL - joins, aggregations, subqueries, CTE и window functions, Планы выполнения SQL-запросов.» — [[Авито/roadmap#DB и аналитика|Авито/roadmap, раздел «DB и аналитика»]].
- «Оптимизировать запрос без фильтров — нужно исходное условие, схема и execution plan; база: Планы выполнения SQL-запросов, Индексы и цена чтения и записи.» — [[Авито/roadmap#DB и аналитика|Авито/roadmap, раздел «DB и аналитика»]].

- [[Telegram Собесы/АМТЕХ — 2026-04-06 — 350к/Бланк вопросов и заданий#Диагностика под нагрузкой — `01:15:55–01:23:23`|Диагностика под нагрузкой — `01:15:55–01:23:23`]] — точная проверенная формулировка технического блока интервью АМТЕХ.

- [[Telegram Собесы/MagnitTech — 2026-04-13 — 400200 руб/Бланк вопросов и заданий#PostgreSQL — `01:10:05–01:17:33`|PostgreSQL — `01:10:05–01:17:33`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Plata — 2026-04-13 — 4252 EUR/Бланк вопросов и заданий#PostgreSQL и диагностика медленного endpoint — `01:01:50–01:11:00`|PostgreSQL и диагностика медленного endpoint — `01:01:50–01:11:00`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/ШИФТ — 2026-04-20 — 500к/Бланк вопросов и заданий#PostgreSQL: indexes, diagnosis и scaling — `01:06:33–01:19:03`|PostgreSQL: indexes, diagnosis и scaling — `01:06:33–01:19:03`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [Using EXPLAIN](https://www.postgresql.org/docs/18/using-explain.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [EXPLAIN](https://www.postgresql.org/docs/18/sql-explain.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Statistics Used by the Planner](https://www.postgresql.org/docs/18/planner-stats.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [How the Planner Uses Statistics](https://www.postgresql.org/docs/18/planner-stats-details.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Optimizer README](https://github.com/postgres/postgres/blob/REL_18_4/src/backend/optimizer/README) — postgres/postgres, tag `REL_18_4`, проверено 2026-07-18.
- [PostgreSQL 18 release notes](https://www.postgresql.org/docs/18/release-18.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-18.
- [PostgreSQL 18.4 release notes](https://www.postgresql.org/docs/18/release-18-4.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, release date 2026-05-14, проверено 2026-07-18.
