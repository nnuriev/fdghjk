---
aliases:
  - "Теоретический вопрос: Failure handling в System Design"
tags:
  - область/проектирование-систем
  - тема/отказоустойчивость
  - тип/вопрос
статус: проверено
---

# Failure handling в System Design

## Вопрос

Как раскрыть на System Design интервью тему «Failure handling в System Design»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

Failure handling начинается не с retry, а с классификации исходов. Для каждого обязательного шага нужно знать, был ли эффект невозможен, подтверждён или остался unknown; можно ли безопасно повторить; какой stale/partial результат допустим; как ограничить нагрузку; кто и из какого источника восстановит состояние.

Сильный дизайн содержит failure matrix: отказ, detection, автоматическая реакция, degraded mode, пользовательский outcome, recovery и проверяемый предел. Timeout, backoff, circuit breaker, bulkhead, load shedding и reconciliation работают как связанный контур. Любой механизм без бюджета способен ухудшить outage.

Полный разбор: [[50 Проектирование систем/Failure handling в System Design|Failure handling в System Design]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/7091/01 Основы отказоустойчивости и SRE#1. Модель отказа|1. Модель отказа]] — вопрос о неизвестном исходе remote call и классификации отказов.
- [[CurseHunter/7091/01 Основы отказоустойчивости и SRE#9. Incident response и postmortem|9. Incident response и postmortem]] — вопрос о стабилизации аварии, ролях и blameless postmortem.
- «Перед кейсами полезно пройти методику интервью, требования, оценку нагрузки и failure handling.» — [[Авито/roadmap#4. System design|Авито/roadmap, раздел «4. System design»]].

## Источники

- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering, глава 22, проверено 2026-07-18.
- [Handling Overload](https://sre.google/sre-book/handling-overload/) — Google, Site Reliability Engineering, глава 21, проверено 2026-07-18.
- [Timeouts, retries, and backoff with jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/) — Amazon Builders' Library, проверено 2026-07-18.
- [Production Services Best Practices](https://sre.google/sre-book/service-best-practices/) — Google, Site Reliability Engineering, production checklist, проверено 2026-07-18.
