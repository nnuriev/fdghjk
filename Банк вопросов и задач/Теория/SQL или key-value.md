---
aliases:
  - "Теоретический вопрос: SQL или key-value"
tags:
  - область/данные
  - тема/выбор-хранилища
  - тип/вопрос
статус: проверено
---

# SQL или key-value

## Вопрос

Объясните тему «SQL или key-value»: какие гарантии даёт механизм и какой ценой для чтения, записи и эксплуатации?

## Короткий ориентир

SQL-хранилище выбирают, когда база должна сама поддерживать связи и инварианты между несколькими наборами данных, а запросы будут меняться после запуска системы. Key-value store выигрывает, когда доступ заранее сводится к `get/put/delete` по полному ключу, граница атомарности совпадает с одним ключом, а предсказуемая задержка и горизонтальное распределение важнее joins и ad hoc-запросов.

Это не выбор между «медленным» и «быстрым». Простая модель key-value убирает работу из СУБД, но обычно переносит её в схему ключей, код приложения, фоновые индексы и процедуры reconciliation. SQL делает обратный обмен: платит за более богатый planner, constraints и координацию транзакций, зато хранит часть корректности рядом с данными.

Полный разбор: [[30 Данные/SQL или key-value|SQL или key-value]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/03 Данные, очереди и расчёт ресурсов#Выбор хранилища|Выбор хранилища]] — исходный блок выбора storage по access patterns и инвариантам.
- [[CurseHunter/5785/03 Данные, очереди и расчёт ресурсов#Что спросить до выбора БД?|Что спросить до выбора БД?]] — самостоятельный checklist-вопрос о workload и guarantees.
- [[CurseHunter/5785/03 Данные, очереди и расчёт ресурсов#Ближайшие альтернативы|Ближайшие альтернативы]] — сравнительная формулировка relational, document, KV, wide-column, search и OLAP.
- «Ответ кандидата слишком быстро свёл выбор к consistency/speed и затем сам признал, что consistency зависит от replication. Более сильная рамка: SQL или key-value, CAP/PACELC, модели consistency и Saga.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#SQL, NoSQL, CAP и Saga — `00:32:20–00:36:08`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «SQL, NoSQL, CAP и Saga — `00:32:20–00:36:08`»]].

## Источники

- [PostgreSQL: SQL Language](https://www.postgresql.org/docs/18/sql.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [PostgreSQL: Constraints](https://www.postgresql.org/docs/18/ddl-constraints.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Redis Strings](https://redis.io/docs/latest/develop/data-types/strings/) — Redis, Redis Open Source 8.8.0, проверено 2026-07-18.
- [Redis Transactions](https://redis.io/docs/latest/develop/using-commands/transactions/) — Redis, Redis Open Source 8.8.0, проверено 2026-07-18.
- [Redis Open Source 8.8 release notes](https://redis.io/docs/latest/operate/oss_and_stack/stack-with-enterprise/release-notes/redisce/redisos-8.8-release-notes/) — Redis, версия 8.8.0, проверено 2026-07-18.
- [Dynamo: Amazon’s Highly Available Key-value Store](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf) — Amazon, SOSP 2007, проверено 2026-07-18.
