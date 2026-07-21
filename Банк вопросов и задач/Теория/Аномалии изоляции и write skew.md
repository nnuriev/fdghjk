---
aliases:
  - "Теоретический вопрос: Аномалии изоляции и write skew"
tags:
  - область/данные
  - тема/транзакции
  - механизм/аномалии
  - тип/вопрос
статус: проверено
---

# Аномалии изоляции и write skew

## Вопрос

Объясните тему «Аномалии изоляции и write skew»: какие гарантии даёт механизм и какой ценой для чтения, записи и эксплуатации?

## Короткий ориентир

Dirty read читает uncommitted write, non-repeatable read повторно получает другое значение той же строки, phantom read повторяет predicate query и получает другой набор rows. Write skew устроен глубже: две transactions читают общий invariant, пишут разные rows и обе commit, хотя совместный результат не соответствует ни одному serial order.

Три classical phenomena не полностью характеризуют isolation. PostgreSQL Repeatable Read предотвращает все три, но допускает write skew. Для защиты нужен Serializable SSI либо explicit protocol, который заставляет contenders конфликтовать на общем lock target.

Полный разбор: [[30 Данные/Аномалии изоляции и write skew|Аномалии изоляции и write skew]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#Транзакции и аномалии|Транзакции и аномалии]] — вопрос о schedule и требуемом isolation contract.
- [[CurseHunter/5785/03 Данные, очереди и расчёт ресурсов#Транзакции и isolation|Транзакции и isolation]] — исходный блок о транзакционных аномалиях.
- [[CurseHunter/5785/03 Данные, очереди и расчёт ресурсов#Какие аномалии надо уметь воспроизвести?|Какие аномалии надо уметь воспроизвести?]] — точная формулировка вопроса о dirty/non-repeatable/phantom/lost update/write skew.
- «Кандидат перечислил несколько терминов и правильно назвал PostgreSQL `Read Committed` default. Ключевая ошибка — `Serializable` не блокирует систему до одной активной transaction: transactions выполняются concurrently, а PostgreSQL откатывает наборы, которые нельзя объяснить serial order. Подробности: аномалии, уровни изоляции и MVCC/locks.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#PostgreSQL: anomalies и isolation — `00:25:42–00:27:10`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «PostgreSQL: anomalies и isolation — `00:25:42–00:27:10`»]].

## Источники

- [A Critique of ANSI SQL Isolation Levels](https://doi.org/10.1145/223784.223785) — ACM, Hal Berenson et al., SIGMOD 1995, проверено 2026-07-18.
- [Weak Consistency: A Generalized Theory and Optimistic Implementations for Distributed Transactions](https://pmg.csail.mit.edu/papers/adya-phd.pdf) — MIT, Atul Adya, PhD thesis, 1999, проверено 2026-07-18.
- [Transaction Isolation](https://www.postgresql.org/docs/18/transaction-iso.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Serializable Snapshot Isolation in PostgreSQL](https://arxiv.org/abs/1208.4179) — PVLDB / arXiv, Dan R. K. Ports, Kevin Grittner, 5(12), 2012, проверено 2026-07-18.
- [Data Consistency Checks at the Application Level](https://www.postgresql.org/docs/18/applevel-consistency.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [PostgreSQL 18.4 release notes](https://www.postgresql.org/docs/18/release-18-4.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, release date 2026-05-14, проверено 2026-07-18.
