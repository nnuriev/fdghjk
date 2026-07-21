---
aliases:
  - "Теоретический вопрос: OLTP, OLAP и выбор аналитического хранилища"
tags:
  - область/данные
  - тема/модели-нагрузки
  - тип/вопрос
статус: черновик
---

# OLTP, OLAP и выбор аналитического хранилища

## Вопрос

Чем различаются OLTP- и OLAP-нагрузки и по каким требованиям выбирать операционное или аналитическое хранилище?

## Короткий ориентир

OLTP обслуживает короткие конкурентные операции над небольшим числом записей, а OLAP читает большие наборы данных ради агрегаций и аналитики. Выбор начинается с формы запросов, latency, объёма записи, freshness и требуемых гарантий; название СУБД само по себе решение не определяет.

Полные разборы:

- [[30 Данные/OLTP и OLAP|OLTP и OLAP]]

## Варианты follow-up

- Почему PostgreSQL оказался медленнее ClickHouse именно в наблюдаемом сценарии?
- Как сравнивались durability, consistency и query requirements двух решений?
- Как проверить, что bottleneck находился в storage, а не в batching, commits или indexes?

## Варианты формулировки и происхождение

- [[Telegram Собесы/APM Group — 2026-03-16 — 3150 USD/Бланк вопросов и заданий#Database workload — `00:05:28–00:08:31`|APM Group, Database workload]].

- [[Telegram Собесы/APM Group — 2026-03-16 — 3150 USD/Бланк вопросов и заданий#Проект APM Group — `00:35:09–00:42:12`|Проект APM Group — `00:35:09–00:42:12`]] — точная проверенная формулировка соответствующего технического блока интервью.
- [[Telegram Собесы/APM Group — 2026-03-16 — 3150 USD/Бланк вопросов и заданий#Data-heavy pricing system|Data-heavy pricing system]] — точная проверенная формулировка соответствующего технического блока интервью.

- [[Telegram Собесы/VK Tech — 2025-09-12 — 350к/Бланк вопросов и заданий#Асинхронная аналитика — `01:05:45–01:08:30`|Асинхронная аналитика — `01:05:45–01:08:30`]] — точная проверенная формулировка самостоятельного технического блока интервью.

- [[Telegram Собесы/APM Group — 2026-03-16 — 3150 USD/Бланк вопросов и заданий#Опыт и последний проект — `00:00:00–00:05:28`|Опыт и последний проект — `00:00:00–00:05:28`]] — technical project prompts этого смешанного блока сохранены здесь; behavioral, motivation и culture-fit часть исключена из банка.

## Источники

- [TPC Current Specifications](https://www.tpc.org/tpc_documents_current_versions/current_specifications5.asp?mode=tpc-member) — Transaction Processing Performance Council, TPC-C 5.11.0 и TPC-H 3.0.1, проверено 2026-07-18.
- [TPC-C Standard Specification](https://www.tpc.org/TPC_Documents_Current_Versions/pdf/tpc-c_v5.11.0.pdf) — Transaction Processing Performance Council, версия 5.11.0, проверено 2026-07-18.
- [TPC-H Standard Specification](https://www.tpc.org/TPC_Documents_Current_Versions/pdf/tpc-h_v3.0.1.pdf) — Transaction Processing Performance Council, версия 3.0.1, проверено 2026-07-18.
- [PostgreSQL: Database Page Layout](https://www.postgresql.org/docs/18/storage-page-layout.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [C-Store: A Column-oriented DBMS](https://www.cs.umd.edu/~abadi/papers/vldb.pdf) — Stonebraker et al., VLDB 2005, проверено 2026-07-18.
- [MonetDB/X100: Hyper-Pipelining Query Execution](https://www.cidrdb.org/cidr2005/papers/P19.pdf) — Boncz, Zukowski и Nes, CIDR 2005, проверено 2026-07-18.
