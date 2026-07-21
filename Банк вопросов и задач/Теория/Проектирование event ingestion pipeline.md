---
aliases:
  - "Теоретический вопрос: Проектирование event ingestion pipeline"
tags:
  - область/проектирование-систем
  - тип/разбор
  - тема/event-ingestion
  - тип/вопрос
статус: проверено
---

# Проектирование event ingestion pipeline

## Вопрос

Как раскрыть на System Design интервью тему «Проектирование event ingestion pipeline»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

Regional ingestion gateways принимают bounded batches, аутентифицируют producer, валидируют envelope/schema и подтверждают request только после durable replicated append в partitioned event log. Partition key задаёт одновременно ordering, locality и hot-key risk. Consumers независимо читают log: raw archive пишет immutable files в object storage, stream processors строят derived datasets, а плохие records попадают в quarantine с причиной и replay path.

Pipeline обещает at-least-once приём и порядок только внутри partition key. Exactly-once до внешней БД или API не следует из broker transaction: downstream обязан использовать event ID, version/upsert либо свою transaction с offset. Backpressure, tenant quotas и overload response защищают общую платформу от одного producer.

Полный разбор: [[50 Проектирование систем/Проектирование event ingestion pipeline|Проектирование event ingestion pipeline]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Uber — proximity search, single-winner acceptance, tracking и reconciliation. База: геопоиск, ingestion, state machine, линеаризуемое принятие заказа, multi-region.» — [[Авито/roadmap#4. System design|Авито/roadmap, раздел «4. System design»]].
- «Библиотека для аналитики — нужно исходное условие; запись в исходнике продублирована. База: Проектирование event ingestion pipeline.» — [[Авито/roadmap#System design и проектирование|Авито/roadmap, раздел «System design и проектирование»]].

## Источники

- [Apache Kafka Design](https://kafka.apache.org/43/design/design/) — Apache Kafka, документация версии 4.3, проверено 2026-07-18.
- [CloudEvents Specification](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md) — CNCF CloudEvents, tag v1.0.2, проверено 2026-07-18.
- [The Log: What every software engineer should know about real-time data's unifying abstraction](https://engineering.linkedin.com/distributed-systems/log-what-every-software-engineer-should-know-about-real-time-datas-unifying) — LinkedIn Engineering, опубликовано 2013-12-16, проверено 2026-07-18.
- [Handling Overload](https://sre.google/sre-book/handling-overload/) — Google, Site Reliability Engineering, издание 2016 года, проверено 2026-07-18.
- [Trace Context](https://www.w3.org/TR/trace-context/) — W3C Recommendation, редакция 23 ноября 2021, проверено 2026-07-18.
