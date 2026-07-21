---
aliases:
  - "Теоретический вопрос: Observability в System Design"
tags:
  - область/проектирование-систем
  - тема/наблюдаемость
  - тип/вопрос
статус: проверено
---

# Observability в System Design

## Вопрос

Как раскрыть на System Design интервью тему «Observability в System Design»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

Observability — это способность ответить по внешним сигналам, что произошло с конкретным пользовательским путём, какой invariant или SLO нарушен и где находится ограничивающий ресурс. Она проектируется вместе с API, queues и state machines: correlation IDs, semantic attributes, error classes, queue age, data freshness и rollout version входят в контракт системы.

Metrics дают агрегированную форму и алерты, traces связывают причинный путь, structured logs сохраняют редкие подробности, audit events доказывают business/security action, profiles показывают расход ресурсов. Просто собрать все сигналы недостаточно: высокая cardinality, бесконтрольные logs и 100% tracing способны сами стать дорогой и ненадёжной системой.

Полный разбор: [[50 Проектирование систем/Observability в System Design|Observability в System Design]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/02 Кэш, API и observability#Observability|Observability]] — исходный блок об observability и telemetry pipeline.
- [[CurseHunter/5785/02 Кэш, API и observability#Чем metrics, logs, traces и profiles отличаются?|Чем metrics, logs, traces и profiles отличаются?]] — сравнительный вопрос о назначении четырёх сигналов.
- [[CurseHunter/5785/02 Кэш, API и observability#Как проектировать alert?|Как проектировать alert?]] — вопрос об actionable alert и symptom-based paging.
- [[CurseHunter/5785/02 Кэш, API и observability#Как не потерять telemetry во время сбоя?|Как не потерять telemetry во время сбоя?]] — вопрос о bounded buffers, backpressure и независимом пути telemetry.
- [[CurseHunter/7091/01 Основы отказоустойчивости и SRE#6. Observability и алертинг|6. Observability и алертинг]] — вопрос о telemetry, saturation и actionable alerts.
- [[CurseHunter/7091/04 Очереди и асинхронная коммуникация#8. Lag и эксплуатация|8. Lag и эксплуатация]] — вариант о lag, oldest-record age, rates и rebalance metrics.
- [[CurseHunter/7091/05 Кеширование и высокая доступность#10. Observability cache|10. Observability cache]] — вариант о correctness, capacity и origin-protection metrics cache.
- «Алерт строится по error-budget burn, а dashboard связывает API, stream, projector и gateway через trace/message IDs по методике observability.» — [[Авито/Решения/System Design/Messenger BE#Observability и SLO|Авито/Решения/System Design/Messenger BE, раздел «Observability и SLO»]].

- [[Telegram Собесы/Adcamp — 2026-03-23 — 280к/Бланк вопросов и заданий#Distributed tracing — `00:26:21–00:26:56`|Distributed tracing — `00:26:21–00:26:56`]] — точная проверенная формулировка соответствующего технического блока интервью.
- [[Telegram Собесы/Adcamp — 2026-03-23 — 280к/Бланк вопросов и заданий#`context` и tracing|`context` и tracing]] — точная проверенная формулировка соответствующего технического блока интервью.
- [[Telegram Собесы/Lunar Rails — 2026-04-27 — 7800 USD/Бланк вопросов и заданий#Database indexes, testing и performance — `00:14:50–00:19:01`|Database indexes, testing и performance — `00:14:50–00:19:01`]] — точная проверенная формулировка соответствующего технического блока интервью.

- [[Telegram Собесы/FLANT — 2026-06-30 — 400к/Бланк вопросов и заданий#Компания, роль и опыт — `00:03:47–00:20:47`|Компания, роль и опыт — `00:03:47–00:20:47`]] — technical project prompts этого смешанного блока сохранены здесь; behavioral, motivation и culture-fit часть исключена из банка.

## Источники

- [OpenTelemetry Specification 1.59.0](https://opentelemetry.io/docs/specs/otel/) — OpenTelemetry, версия 1.59.0, проверено 2026-07-18.
- [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) — Google, Site Reliability Engineering, глава 6, проверено 2026-07-18.
- [Practical Alerting from Time-Series Data](https://sre.google/sre-book/practical-alerting/) — Google, Site Reliability Engineering, глава 10, проверено 2026-07-18.
- [Dapper, a Large-Scale Distributed Systems Tracing Infrastructure](https://research.google/pubs/dapper-a-large-scale-distributed-systems-tracing-infrastructure/) — Google, technical report dapper-2010-1, 2010, проверено 2026-07-18.
