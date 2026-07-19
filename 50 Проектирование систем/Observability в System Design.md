---
aliases:
  - Observability
  - Наблюдаемость в System Design
  - Metrics logs traces
tags:
  - область/проектирование-систем
  - тема/наблюдаемость
статус: проверено
---

# Observability в System Design

## TL;DR

Observability — это способность ответить по внешним сигналам, что произошло с конкретным пользовательским путём, какой invariant или SLO нарушен и где находится ограничивающий ресурс. Она проектируется вместе с API, queues и state machines: correlation IDs, semantic attributes, error classes, queue age, data freshness и rollout version входят в контракт системы.

Metrics дают агрегированную форму и алерты, traces связывают причинный путь, structured logs сохраняют редкие подробности, audit events доказывают business/security action, profiles показывают расход ресурсов. Просто собрать все сигналы недостаточно: высокая cardinality, бесконтрольные logs и 100% tracing способны сами стать дорогой и ненадёжной системой.

## Ментальная модель

Наблюдаемость строится от вопроса к сигналу:

```text
user impact -> SLI -> symptom alert -> causal path -> component saturation -> evidence
```

Dashboard CPU без пользовательского SLI начинает расследование снизу и часто лечит не тот слой. Сначала определяется, кто пострадал и какой good event перестал быть good.

## Как устроено

### Telemetry contract

Для каждого critical path зафиксируйте:

- stable operation name и service identity;
- request/trace ID, business operation ID и idempotency key без секретов;
- tenant/region/version как контролируемые dimensions;
- start/end, status и machine-readable error class;
- dependency, retry attempt и timeout owner;
- queue enqueue/dequeue time, delivery attempt и source position;
- data version/freshness для derived reads;
- rollout/config/schema version.

OpenTelemetry задаёт общий data model для traces, metrics и logs, но semantic conventions не выбирают ваши business outcomes. `HTTP 200` может означать технический успех и неверный пустой ledger; application обязано записать доменный result.

### Metrics

Начните с пользовательских SLIs из [[50 Проектирование систем/SLO в System Design|SLO]], затем добавьте causes:

- traffic: accepted/read/write/events per second;
- errors: по operation и классифицированной причине;
- latency: histogram end-to-end и ключевых dependencies;
- saturation: CPU, memory, pools, queue depth/age, disk, shard load;
- correctness/freshness: duplicate suppression, reconciliation mismatch, replica lag, index age.

Queue depth без service rate неоднозначна. Age oldest item напрямую показывает пользовательскую задержку; arrival/processing rate объясняют, растёт ли долг.

Label cardinality ограничивают. `user_id`, `request_id`, raw URL и exception text не входят в metric labels: число time series растёт без границы. Эти значения остаются в sampled trace/log или отдельном analytics pipeline с retention.

### Traces

Trace распространяет context по sync calls и async boundaries. Для event consumer создают причинную связь с producer, но долгоживущий stream не надо превращать в один бесконечный span. Span получает stable operation, peer/dependency, retry count, queue delay и outcome.

Head sampling дешёвый, но способен потерять редкую ошибку. Tail sampling сохраняет trace по итоговому latency/error, зато требует collector state и capacity. Business-critical operations иногда получают отдельное sample rule; 100% tracing не является default.

### Structured logs и audit

Log event должен быть машинно разбираемым и иметь schema/version. Уровни не заменяют error class. Один failure логируется на owning boundary; если каждый layer печатает stack trace, один timeout создаёт шум и стоимость без новой информации.

Audit trail отделяется от debug logs. Он имеет stronger completeness, access control, retention и tamper evidence, но минимизирует PII. Security/ledger action нельзя потерять из-за sampling.

### Collection и storage path

Application не должна синхронно зависеть от удалённого observability backend на user path. Обычно SDK пишет в local/batched collector с bounded buffer. При недоступности backend telemetry drop-ится или spools в ограниченном объёме по priority; блокировать payment ради debug log опасно.

Collector pipeline нуждается в собственных metrics: dropped spans/logs, queue age, export errors, memory limiter и config version. Иначе monitoring «молча слепнет» в момент перегрузки.

### Alerting и ownership

Page создаёт действие. Symptom alert на burn rate SLO сообщает пользовательский ущерб; cause alert полезен, если оператор обязан вмешаться до SLO. Каждый alert получает owner, runbook, severity и проверенную процедуру. Ticket/forecast отделяются от срочного page.

Release annotations связывают регрессию с binary/config/schema version. Canary сравнивается с control и абсолютным SLO, иначе общий внешний incident способен сделать оба варианта одинаково плохими.

## Сквозной пример: event ingestion pipeline

Producer отправляет batch, gateway отвечает после durable append, consumers обновляют warehouse и search projection.

Telemetry проходит те же boundaries:

1. API metric считает accepted/rejected events и bytes по tenant class, не по tenant ID с миллионами значений.
2. Trace связывает request, log append и batch ID; payload не записывается.
3. Broker metrics показывают partition ingress, replication/ack latency и under-replicated state.
4. Consumer записывает source offset, processing duration, retry class и output commit version.
5. Freshness SLI равен `now - event_time` для прошедших validation событий; отдельно измеряется queue age, чтобы отличить поздний producer от lag pipeline.
6. Reconciliation job сравнивает accepted count/checksum с terminal outputs и создаёт correctness alert.

Incident: search freshness растёт, но append availability и warehouse freshness нормальны. Trace samples показывают timeout search bulk API, consumer queue age растёт только у search group. Circuit breaker и bounded retry сохраняют broker/warehouse, alert ведёт к конкретному owner. После recovery dashboard следит за drain rate и прогнозом времени до нормального age.

## Trade-offs

Metrics дёшевы для агрегатов, но теряют конкретный causal path. Logs дают детали, зато дорого индексируются и плохо показывают распределения. Traces связывают hops, но sampling и context propagation требуют дисциплины. Обычно нужны все три, с разной retention и ценой.

Высокая cardinality ускоряет ad hoc slice, но умножает memory/storage. Лучше хранить bounded dimensions в metrics, exemplars связывать с trace, а произвольные поля отправлять в logs/analytics.

Длинная retention помогает forensic и capacity trends, но повышает стоимость и privacy exposure. Raw high-volume telemetry хранится коротко, агрегаты и audit — по отдельной policy.

## Типичные ошибки

- **Неверное предположение:** инфраструктурные metrics показывают user impact. **Симптом:** CPU нормальный, а один tenant/shard недоступен. **Причина:** нет SLI и dimension по failure domain. **Исправление:** good events на boundary и controlled slicing.
- **Неверное предположение:** больше logs означает лучшую диагностику. **Симптом:** incident search тонет в duplicate stack traces, bill растёт. **Причина:** нет event schema и owning layer. **Исправление:** structured outcome, dedup/rate limits и sampling.
- **Неверное предположение:** queue depth достаточно. **Симптом:** большой стабильный backlog вызывает ложный page либо маленькая старая задача остаётся незамеченной. **Причина:** depth не учитывает age/rates. **Исправление:** oldest age, arrival/service rate и deadline miss.
- **Неверное предположение:** observability backend всегда доступен. **Симптом:** exporter блокирует request path или OOM-ит process. **Причина:** unbounded buffer/synchronous export. **Исправление:** bounded batching, priority/drop policy и self-observability.
- **Неверное предположение:** trace ID можно использовать как business ID. **Симптом:** retry/restart теряет связь попыток одной операции. **Причина:** trace описывает execution, не устойчивую business identity. **Исправление:** отдельные operation/idempotency IDs.

## Когда применять

Telemetry contract проектируют одновременно с state machine и failure matrix. Перед production проверяют SLI queries, cardinality budget, propagation через queues, redaction, alert routing и поведение exporter при outage. После запуска регулярно удаляют сигналы, которые не ведут к решению.

## Источники

- [OpenTelemetry Specification 1.59.0](https://opentelemetry.io/docs/specs/otel/) — OpenTelemetry, версия 1.59.0, проверено 2026-07-18.
- [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) — Google, Site Reliability Engineering, глава 6, проверено 2026-07-18.
- [Practical Alerting from Time-Series Data](https://sre.google/sre-book/practical-alerting/) — Google, Site Reliability Engineering, глава 10, проверено 2026-07-18.
- [Dapper, a Large-Scale Distributed Systems Tracing Infrastructure](https://research.google/pubs/dapper-a-large-scale-distributed-systems-tracing-infrastructure/) — Google, technical report dapper-2010-1, 2010, проверено 2026-07-18.
