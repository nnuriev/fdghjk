---
aliases:
  - "Теоретический вопрос: SQL - joins, aggregations, subqueries, CTE и window functions"
tags:
  - область/данные
  - тема/sql
  - практика/запросы
  - тип/вопрос
статус: проверено
---

# SQL - joins, aggregations, subqueries, CTE и window functions

## Вопрос

Объясните тему «SQL - joins, aggregations, subqueries, CTE и window functions»: какие гарантии даёт механизм и какой ценой для чтения, записи и эксплуатации?

## Короткий ориентир

SQL описывает требуемое отношение, а не пошаговый алгоритм. `JOIN` формирует пары строк, `WHERE` фильтрует их, aggregation сворачивает группы, subquery вводит зависимое или независимое множество, CTE именует промежуточный результат, window function вычисляет значение по соседним строкам без схлопывания результата.

Главное практическое правило: сначала доказать cardinality каждого промежуточного отношения, потом считать агрегаты. Большинство «неверных сумм» рождается не в `SUM`, а в join, который незаметно размножил исходные строки.

Полный разбор: [[30 Данные/SQL - joins, aggregations, subqueries, CTE и window functions|SQL - joins, aggregations, subqueries, CTE и window functions]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «SQL и PostgreSQL блоки можно повторить по SQL joins и aggregations, Индексы и цена чтения/записи, Планы выполнения и Уровни изоляции.» — [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Lamoda — 2026-06-10 — 400к, раздел «Сопоставление с материалами vault»]].
- «`WHERE`, `HAVING`, aggregates и `GROUP BY`: SQL - joins, aggregations, subqueries, CTE и window functions.» — [[Авито/roadmap#СУБД и SQL|Авито/roadmap, раздел «СУБД и SQL»]].
- «Оптимизировать запрос с `GROUP BY` по всем полям — нужно исходное условие и схема; база: SQL - joins, aggregations, subqueries, CTE и window functions, Планы выполнения SQL-запросов.» — [[Авито/roadmap#DB и аналитика|Авито/roadmap, раздел «DB и аналитика»]].

- [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#SQL: joins, aggregation и порядок обработки — `00:56:13–01:12:37`|SQL: joins, aggregation и порядок обработки — `00:56:13–01:12:37`]] — точная проверенная формулировка соответствующего технического блока интервью.

## Источники

- [Table Expressions](https://www.postgresql.org/docs/18/queries-table-expressions.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Subquery Expressions](https://www.postgresql.org/docs/18/functions-subquery.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [WITH Queries](https://www.postgresql.org/docs/18/queries-with.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Window Functions](https://www.postgresql.org/docs/18/functions-window.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Aggregate Functions](https://www.postgresql.org/docs/18/functions-aggregate.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [PostgreSQL 18.4 release notes](https://www.postgresql.org/docs/18/release-18-4.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, release date 2026-05-14, проверено 2026-07-18.
