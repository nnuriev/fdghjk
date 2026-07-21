---
aliases:
  - "Теоретический вопрос: Backpressure, load shedding, bulkheads и graceful degradation"
tags:
  - область/распределённые-системы
  - тема/перегрузка
  - тип/вопрос
статус: черновик
---

# Backpressure, load shedding, bulkheads и graceful degradation

## Вопрос

Как backpressure, load shedding, bulkheads и graceful degradation ограничивают распространение перегрузки?

## Короткий ориентир

Backpressure замедляет producer по сигналу ограниченного consumer; если накопление уже нарушает resource/SLO budget, load shedding отклоняет часть работы. Bulkhead разделяет concurrency/resources между dependencies, чтобы один отказ не исчерпал всё. Graceful degradation сохраняет сокращённый полезный ответ, когда полная функция недоступна, но его semantics задают заранее.

Полные разборы:

- [[40 Распределённые системы/Backpressure и queue buildup|Backpressure и queue buildup]]
- [[40 Распределённые системы/Load shedding|Load shedding]]
- [[70 Практические кейсы/Bulkheads и dependency isolation|Bulkheads и dependency isolation]]
- [[70 Практические кейсы/Graceful degradation|Graceful degradation]]

## Варианты follow-up

- Как bounded queue передаёт backpressure producer?
- По какому budget load shedding начинает отклонять работу?
- Как bulkhead ограничивает blast radius одной dependency?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/05 Архитектура, устойчивость и консенсус#Rate limiting, load shedding и backpressure|Rate limiting, load shedding и backpressure]] — сравнительный вопрос о policy limit, saturation и feedback upstream.
- [[CurseHunter/5785/05 Архитектура, устойчивость и консенсус#Graceful degradation и fallback|Graceful degradation и fallback]] — вопрос о допустимой потере качества без нарушения инвариантов.
- [[CurseHunter/7091/03 Контроль нагрузки#2. Bulkhead|2. Bulkhead]] — вопрос о разделении реальной точки saturation на failure domains.
- [[CurseHunter/7091/03 Контроль нагрузки#7. Adaptive concurrency и материал QA|7. Adaptive concurrency и материал QA]] — вопрос о permit lifecycle, bounded queue и adaptive limit.
- [[CurseHunter/7091/03 Контроль нагрузки#5. Backpressure|CourseHunter 7091, backpressure]].
- [[CurseHunter/7091/03 Контроль нагрузки#6. Load shedding|CourseHunter 7091, load shedding]].
- [[CurseHunter/7091/02 Ошибки, повторы и деградация#4. Hedging против tail latency|CourseHunter 7091, hedging]].
- [[CurseHunter/7091/02 Ошибки, повторы и деградация#7. Graceful degradation и fallback|CourseHunter 7091, degradation]].

## Источники

- [Reactive Streams JVM Specification](https://github.com/reactive-streams/reactive-streams-jvm/blob/v1.0.4/README.md#specification) — Reactive Streams, версия 1.0.4, проверено 2026-07-18.
- [RabbitMQ Consumer Prefetch](https://www.rabbitmq.com/docs/4.2/consumer-prefetch) — RabbitMQ, документация 4.2, проверено 2026-07-18.
- [RabbitMQ Queues](https://www.rabbitmq.com/docs/4.2/queues) — RabbitMQ, документация 4.2, проверено 2026-07-18.
- [Kafka consumer groups and Share Consumers](https://kafka.apache.org/43/design/design/) — Apache Kafka, документация 4.3, classic consumer groups и Share Groups, проверено 2026-07-18.
- [Handling Overload](https://sre.google/sre-book/handling-overload/) — Google, Site Reliability Engineering book, 2016, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://datatracker.ietf.org/doc/html/rfc9110#name-503-service-unavailable) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [Overload manager](https://www.envoyproxy.io/docs/envoy/v1.38.3/configuration/operations/overload_manager/overload_manager) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Overload manager architecture](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/operations/overload_manager) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [API Priority and Fairness](https://kubernetes.io/docs/concepts/cluster-administration/flow-control/) — Kubernetes, документация 1.36.2; feature Stable с 1.29, проверено 2026-07-18.
- [Using load shedding to avoid overload](https://builder.aws.com/content/3Eun1EEyX6p2e3VYNyRLSJzLuMV/using-load-shedding-to-avoid-overload) — Amazon Web Services, first-party operational guidance, опубликовано 2026-06, проверено 2026-07-18.
- [Bulkhead pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/bulkhead) — Microsoft, Azure Architecture Center, обновлено 2026-03-19, проверено 2026-07-18.
- [REL10-BP03 Use bulkhead architectures to limit scope of impact](https://docs.aws.amazon.com/wellarchitected/latest/framework/rel_fault_isolation_use_bulkhead.html) — Amazon Web Services, AWS Well-Architected Framework latest, cell boundaries и fixed maximum size, проверено 2026-07-18.
- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering, глава 22, shared resource exhaustion и isolation, проверено 2026-07-18.
- [Production Services Best Practices](https://sre.google/sre-book/service-best-practices/) — Google, Site Reliability Engineering, production checklist и degraded results, проверено 2026-07-18.
