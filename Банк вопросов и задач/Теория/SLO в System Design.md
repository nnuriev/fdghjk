---
aliases:
  - "Теоретический вопрос: SLO в System Design"
tags:
  - область/проектирование-систем
  - тема/slo
  - тип/вопрос
статус: проверено
---

# SLO в System Design

## Вопрос

Как раскрыть на System Design интервью тему «SLO в System Design»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

Service level indicator (SLI) измеряет пользовательски значимое поведение, service level objective (SLO) задаёт target на окне, а service level agreement (SLA) добавляет последствия нарушения. В System Design полезно отдельно договориться об availability, latency, durability и consistency: эти свойства связаны, но не заменяют друг друга.

Availability считают по доле полезных операций, latency — как распределение для заданного класса запросов, durability — как риск необратимой утраты подтверждённых данных, consistency — как семантический контракт наблюдаемых версий. Последнюю нельзя честно свести к «99,9% consistency» без определения, какое чтение считается корректным и насколько допустимо отставание.

Полный разбор: [[50 Проектирование систем/SLO в System Design|SLO в System Design]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Alerts строятся по user-visible SLO и burn rate, как требует SLO-разбор, а не по одному CPU threshold.» — [[Авито/Решения/System Design/Avito.ru — classified#Observability и SLO|Авито/Решения/System Design/Avito.ru — classified, раздел «Observability и SLO»]].
- «Alert на average latency скрывает tail и региональные failures. SLO считается по user journey и per-region burn rate согласно методике SLO.» — [[Авито/Решения/System Design/Spotify#Observability и SLO|Авито/Решения/System Design/Spotify, раздел «Observability и SLO»]].

## Источники

- [Service Level Objectives](https://sre.google/sre-book/service-level-objectives/) — Google, Site Reliability Engineering, глава 4, проверено 2026-07-18.
- [Availability Table](https://sre.google/sre-book/availability-table/) — Google, Site Reliability Engineering, таблица допустимой недоступности, проверено 2026-07-18.
- [Data Integrity: What You Read Is What You Wrote](https://sre.google/sre-book/data-integrity/) — Google, Site Reliability Engineering, глава 26, проверено 2026-07-18.
- [Implementing SLOs](https://sre.google/workbook/implementing-slos/) — Google, The Site Reliability Workbook, глава 2, проверено 2026-07-18.
