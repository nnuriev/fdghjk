---
aliases:
  - "Теоретический вопрос: Миграция и rollout без остановки"
tags:
  - область/проектирование-систем
  - тема/миграции
  - тип/вопрос
статус: проверено
---

# Миграция и rollout без остановки

## Вопрос

Как раскрыть на System Design интервью тему «Миграция и rollout без остановки»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

Безостановочная миграция — это временный протокол совместимости между старым и новым состоянием. Безопасный порядок обычно выглядит как `expand -> observe -> migrate -> switch -> contract`: сначала новая версия принимает старые и новые формы, затем данные копируются и сравниваются, traffic переключается малым blast radius, а необратимое удаление происходит после доказанного отсутствия старых readers/writers.

Rollback возможен только до определённой границы. После несовместимой записи, внешнего эффекта или удаления данных чаще нужен roll-forward/repair. План обязан назвать эту границу, source of truth на каждом этапе, критерии продолжения/остановки и способ reconciliation.

Полный разбор: [[50 Проектирование систем/Миграция и rollout без остановки|Миграция и rollout без остановки]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/05 Архитектура, устойчивость и консенсус#Развёртывание|Развёртывание]] — вопрос о rolling, blue-green, canary и expand-contract migration.
- [[CurseHunter/7091/01 Основы отказоустойчивости и SRE#8. Безопасные изменения|8. Безопасные изменения]] — вопрос о rolling, blue/green, canary, flags и expand-contract migration.
- «Каждый этап обратим: consumers можно отключить без потери source log, а старая projection остаётся доступной до сверки. Общий protocol rollout описан в заметке о миграциях.» — [[Авито/Решения/System Design/Messenger BE#Эволюция решения и миграции|Авито/Решения/System Design/Messenger BE, раздел «Эволюция решения и миграции»]].

- [[Telegram Собесы/Remotely — 2026-04-27 — 7125 USD/Бланк вопросов и заданий#Ожидания, мотивация и infrastructure — `00:26:38–00:47:17`|Ожидания, мотивация и infrastructure — `00:26:38–00:47:17`]] — точная проверенная формулировка соответствующего технического блока интервью.

- [[Telegram Собесы/Авито — 2026-04-20 — 470к/Бланк вопросов и заданий#Online data fix: 10 млн строк — `01:26:10–01:32:22`|Online data fix: 10 млн строк — `01:26:10–01:32:22`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [Canarying Releases](https://sre.google/workbook/canarying-releases/) — Google, The Site Reliability Workbook, глава 16, проверено 2026-07-18.
- [Data Processing Pipelines](https://sre.google/workbook/data-processing/) — Google, The Site Reliability Workbook, rollout и correctness для pipelines, проверено 2026-07-18.
- [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) — Kubernetes, документация v1.36, rolling update и rollback, проверено 2026-07-18.
- [PostgreSQL 18: ALTER TABLE](https://www.postgresql.org/docs/18/sql-altertable.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
