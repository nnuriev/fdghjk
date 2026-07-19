---
aliases:
  - Debugging queue backlog
  - Диагностика backlog очереди
  - Consumer lag runbook
tags:
  - область/reliability-performance-operations
  - тема/диагностика
  - тема/очереди
  - механизм/обратное-давление
статус: проверено
---

# Диагностика queue backlog

## TL;DR

Backlog растёт, когда effective arrival rate устойчиво выше effective completion rate, но сам размер не называет причину. Сначала измерьте slope и oldest age/freshness, затем разрежьте по topic/queue, partition/shard, consumer group, message class и state. Проверьте producers, assignments/consumers, handler/downstream, ack/commit, retries/redeliveries и broker capacity.

Не сбрасывайте offsets, не purge-ите queue и не ack-айте сообщения ради «зелёного lag»: это уничтожает evidence и может потерять данные. Стабилизация ограничивает новый вход или изолирует poison class, а recovery планируется по чистой скорости drain `μ − λ`. Общая причинная модель находится в [[40 Распределённые системы/Backpressure и queue buildup|заметке о backpressure и queue buildup]], а broker semantics — в [[40 Распределённые системы/Очереди, streams, группы потребителей и DLQ|заметке об очередях, streams и DLQ]].

## Контекст

Vendor-neutral workflow ниже уточнён для Apache Kafka 4.3.1 по ветке официальной документации `4.3` и RabbitMQ 4.3, проверено 2026-07-18. Термин backlog неоднозначен:

- Kafka lag относится к offset position относительно log end и измеряется per partition; client `records-lag-max` основан на current offset, а не committed offset.
- Kafka consumer-group tool отдельно показывает `CURRENT-OFFSET`, `LOG-END-OFFSET`, `LAG` и assignment.
- RabbitMQ queue length в AMQP/UI может означать messages ready; detailed Prometheus metric `rabbitmq_detailed_queue_messages` — ready + unacknowledged. Эти states диагностируются отдельно.

Ни messages, ни records сами по себе не задают одинаковую единицу работы. При разном payload/service cost добавьте bytes, processing seconds и class.

## Симптомы и влияние

Начните с бизнес-impact:

- oldest-event age/freshness SLA и сколько объектов просрочено;
- lag/depth slope и прогноз времени до retention/disk limit;
- missing/delayed side effects, duplicates и retry/DLQ volume;
- producer accepts/errors/throttling и consumer completed goodput;
- recovery debt после возвращения capacity.

Небольшой backlog с очень старым head может быть критичнее большого свежего batch. Aggregate lag может скрыть одну stuck partition/key, а средний consumer CPU — один hot consumer.

## Ментальная модель и гипотезы

```text
dQ/dt = admitted arrival rate λ - durable completion rate μ
drain rate after recovery = μ_recovered - λ_live
drain time ≈ backlog / (μ_recovered - λ_live), если μ_recovered > λ_live
```

`μ` здесь означает business-completed и корректно ack/commit работу. Handler, который быстро читает messages, но не завершает side effect, не разгружает систему. Ack/commit до side effect может нарисовать нулевой backlog при потере данных; после side effect — допускает duplicates при crash и требует idempotency.

Приоритет гипотез:

1. **Arrival вырос:** producer burst, replay, duplicate publish, retry amplification.
2. **Service rate упал:** slow code, database/dependency bottleneck, CPU/GC, oversized messages.
3. **Consumers/assignment:** crash, zero consumers, rebalance loop, insufficient partitions, hot partition/key.
4. **Ack/commit problem:** stuck commit, long unacked window, client polling/heartbeat contract.
5. **Poison/retry loop:** одна message повторно обрабатывается/requeue-ится, offset не движется.
6. **Broker/storage:** throttling, disk/memory watermark, fetch/publish latency, retention risk.

## Диагностика

### 1. Сохранить evidence до offset/purge/restart

Зафиксируйте UTC window, broker/client versions, topic/queue/group/vhost, assignments, per-partition offsets/lag либо ready/unacked, oldest age/head timestamp, producer/consumer rates, errors/retries/redeliveries, payload class, deploy/config и downstream SLI.

Сохраните representative message ID/key/schema version и error, но не копируйте чувствительный payload без необходимости. До manual skip/reset/ack создайте durable recovery evidence: исходный offset/delivery identity, причина, owner и способ replay/reconciliation.

Restart consumer может вызвать rebalance/redelivery и стереть in-process stacks. Сначала снимите goroutine/profile/trace проблемного consumer, если impact позволяет короткий capture.

### 2. Посчитать slope, age и recovery envelope

Измерьте admitted publish rate и durable completion/ack rate в одном интервале. Если `λ > μ`, backlog закономерно растёт. Если counters показывают `λ ≤ μ`, а lag растёт, проверьте разные semantics/time windows, commit lag, partition skew и duplicates.

Сразу посчитайте минимальный drain time. При live arrival `1 000/s`, recovered capacity `1 200/s` и backlog `240 000` чистая скорость всего `200/s`, то есть минимум `20 min`. Масштабирование безопасно только если downstream имеет headroom; иначе оно уменьшает `μ` через contention.

### 3. Локализовать partition/queue/state

Для Kafka сохраните consumer-group describe с `CURRENT-OFFSET`, `LOG-END-OFFSET`, `LAG`, consumer ID/host/client ID по каждой partition. Сопоставьте с client metrics `records-consumed-rate`, fetch latency/rate и `records-lag-max`; помните, что client lag использует current position, не committed position. Проверьте assignment changes, rebalance и `max.poll.interval.ms` при долгой обработке.

Для RabbitMQ разделите:

- `messages_ready` — остаются у broker и ещё не выданы;
- `messages_unacked` — уже выданы consumers, но не подтверждены;
- consumers и consumer capacity;
- delivered/acked/redelivered rates;
- prefetch, head timestamp, bytes/RAM/disk и node alarms.

Ready растёт при низком unacked — consumers отсутствуют или не успевают принимать. Unacked стабильно равно большому prefetch, а ack rate низок — работа застряла в handler/downstream. Redeliveries/requeues растут — вероятен failure loop. RabbitMQ предупреждает, что unlimited/очень высокий prefetch переносит backlog в client heap.

### 4. Найти ограничивающую стадию consumer

Разложите lifecycle message:

```text
fetch/deliver -> local queue -> handler CPU -> dependency -> side effect -> ack/commit
```

Metrics/traces/profiles должны ответить, где находится wall time. Проверьте CPU/GC/goroutines, local worker queue, database pool, dependency latency, rate limits и per-key serialization. Сопоставьте started/completed/failed/acked/committed counters.

Если одна partition отстаёт, проверьте key skew, oversized records и poison offset. Добавление consumers классической Kafka group не даст parallelism выше числа partitions и не разделит одну partition между двумя consumers. Для RabbitMQ рост consumers полезен только при broker/downstream capacity и корректном prefetch/fairness.

### 5. Проверить ack/commit и retry semantics

Для Kafka различайте current processing position и committed recovery position. Consumer может быстро fetch-ить и держать records локально, а commit отставать; crash тогда повторит большую пачку. Нельзя продвигать offset past failed record без явно принятой loss/replay semantics.

Для RabbitMQ manual ack подтверждает successful processing; requeue без delay/budget способен создать немедленный redelivery loop и потратить CPU/network. Poison message должна иметь bounded attempts, quarantine/DLQ и operator-visible reason. Auto-ack повышает throughput ценой потери при consumer failure и не даёт обычного bounded unacked window.

### 6. Стабилизировать без потери данных

Выберите действие по причине:

- throttle/pause producer или shed optional class, если `λ` вырос;
- остановить retry/requeue loop и изолировать poison key/partition;
- rollback faulty consumer;
- ограничить prefetch/local concurrency, чтобы не переносить backlog в heap;
- добавить consumers/partitions только после проверки downstream и ordering contract;
- зарезервировать recovery share сверх live traffic, не направлять всю capacity на catch-up.

Любой manual skip, offset reset, purge или mass ack требует business/data owner, сохранённого recovery artifact и reconciliation plan. «Lag стал нулём» не равно «work выполнена».

## Сквозная трассировка сценария

Все значения ниже относятся к сценарию.

Kafka topic имеет `12` partitions. Producer отправляет около `1 200 records/s`; после `v73` max lag растёт, а freshness SLO нарушается. Через `22 min` aggregate lag — около `140 000` records.

1. Consumer-group describe показывает, что `11` partitions имеют lag меньше `600`, а partition `7`: `CURRENT-OFFSET=8 410 220`, `LOG-END-OFFSET=8 548 820`, `LAG=138 600`.
2. У consumer partition `7` CPU `95%`, но completed side effects почти нулевые. Логи повторяют один event ID на offset `8 410 220`; poll/heartbeat продолжаются, поэтому assignment и rebalance count стабильны, но committed offset не движется.
3. Trace/profile показывают immediate retry validation одного record без backoff. Offset не продвигается; новая работа partition прибывает примерно `105 records/s`, поэтому lag slope близок к этой величине.
4. `v73` сделал неизвестную schema version retryable без attempt budget/quarantine. Остальные partitions работают нормально, поэтому aggregate consumer count и fleet CPU скрывали локальную остановку.
5. После сохранения original record/offset и согласования с data owner poison record помещают в durable quarantine, а consumer продолжает со следующим offset. Fix вводит bounded attempts, schema validation до дорогого side effect и DLQ/replay contract.
6. Recovered group обрабатывает `1 500 records/s` при live arrival `1 200/s`; чистый drain `300/s`, поэтому `138 600` records требуют минимум `462 s` (`7,7 min`). Наблюдаемый lag падает примерно с этим slope, а oldest age возвращается в SLO.

Root cause доказан per-partition offset, повторяющимся event, stack/trace retry path и восстановлением движения после bounded quarantine — не просто scale-out.

## Root cause

Root cause сценария — классификация unsupported schema как бесконечно retryable в `v73`. Один poison record остановил progress partition `7`; immediate retry сжигал CPU, а отсутствие DLQ/replay contract не позволяло безопасно продолжить. Partition ordering превратил локальную ошибку в растущий backlog всех последующих records этой partition.

Trigger — первый record новой schema version. Amplifier — retry без delay/budget. Detection gap — alert был по aggregate lag, а не max per-partition lag и oldest age.

## Исправление

### Немедленное

- Остановить faulty rollout/retry loop и сохранить offsets/message evidence.
- Изолировать affected partition/key или poison message по согласованной quarantine/replay процедуре.
- Ограничить producers/optional replay, если retention/freshness budget заканчивается.
- Выделить controlled recovery capacity, следя за database/dependency saturation.

### Долгосрочное

- Разделить transient, permanent и unknown errors; задать bounded attempts/backoff и DLQ/quarantine.
- Версионировать schema и проверять совместимость producer/consumer до rollout.
- Сделать side effects idempotent и определить точный ack/commit point.
- Наблюдать lag/depth, oldest age, arrival/completion, retries/redeliveries и per-partition/key skew.
- Load/fault test должен включать poison event, consumer crash, slow dependency, rebalance и controlled drain.

## Проверка результата

Исправление доказано, если:

- per-partition lag и oldest age уменьшаются с предсказанным net drain slope;
- live traffic остаётся в freshness/SLO и не голодает из-за catch-up;
- completed side effects и ack/commit rate согласованы;
- retries/redeliveries bounded, poison messages видимы в quarantine/DLQ;
- downstream CPU/DB/limits сохраняют headroom;
- после crash/rebalance нет потери, неконтролируемых duplicates или возврата к stuck offset;
- backlog не был «исправлен» purge/reset без reconciliation.

## Профилактика

Alert строят на max/per-partition lag, oldest age/head timestamp и slope, а не только aggregate depth. Рядом нужны zero consumers/assignment, ack/commit, retry/redelivery, producer/consumer rates, prefetch/local queue и downstream saturation.

Capacity plan включает retention/disk envelope и recovery: сколько outage volume помещается и какая spare service rate остаётся при live traffic. Game day проверяет остановку consumer, poison record и controlled replay.

## Эволюция и версии

| Система/версия | Версионная граница | Практический эффект | Источник |
| --- | --- | --- | --- |
| Kafka 4.3.1 | Classic/Consumer group protocols сосуществуют; rebalance semantics/config различаются | При churn фиксируйте фактический group protocol и client/broker settings, а не применяйте старые предположения | [Consumer Rebalance Protocol](https://kafka.apache.org/43/operations/consumer-rebalance-protocol/) |
| RabbitMQ 4.3 | Queue metrics различают ready, unacknowledged, consumer capacity и redeliveries | Runbook должен локализовать state backlog, а не смотреть только одно `queue length` | [Monitoring with Prometheus](https://www.rabbitmq.com/docs/prometheus) |

## Trade-offs

Большой prefetch/batch скрывает network latency и повышает throughput до saturation, но переносит backlog в consumer memory, увеличивает redelivery после crash и ухудшает fairness. Малый prefetch ограничивает in-flight и ускоряет recovery ownership, но может недогружать handler.

Больше consumers повышает `μ`, пока есть partitions/queue delivery и downstream headroom. После насыщения DB/API они увеличивают contention и уменьшают effective completion rate. Новые Kafka partitions добавляют parallelism, но меняют key distribution/ordering и не лечат poison record автоматически.

Strict ordering упрощает per-key reasoning, но один poison/slow record блокирует последующие. Quarantine сохраняет progress, однако требует explicit replay/order/correctness contract.

## Типичные ошибки

- **Неверное предположение:** backlog size сам объясняет incident. **Симптом:** scale-out не меняет slope. **Причина:** неизвестны arrival/completion и limiting stage. **Исправление:** измерить `λ`, durable `μ`, age и consumer critical path.
- **Неверное предположение:** aggregate lag показывает все partitions. **Симптом:** fleet выглядит почти здоровым, одна partition нарушает freshness. **Причина:** skew/poison скрыт суммой/средним. **Исправление:** max и per-partition/key breakdown.
- **Неверное предположение:** нулевой broker backlog означает выполненную работу. **Симптом:** messages находятся в client buffer/unacked или ack выполнен до side effect. **Причина:** измеряется не business completion. **Исправление:** связать delivery, completion и ack/commit counters.
- **Неверное предположение:** больше consumers всегда ускоряет drain. **Симптом:** DB latency растёт, lag падает медленнее. **Причина:** downstream стал bottleneck. **Исправление:** end-to-end concurrency и recovery budget по реальному constraint.
- **Неверное предположение:** requeue безопасно повторять бесконечно. **Симптом:** redelivery/CPU/network растут, progress нулевой. **Причина:** poison message и отсутствие retry budget. **Исправление:** bounded attempts, delay и quarantine/DLQ.
- **Неверное предположение:** reset offsets/purge — успешная mitigation. **Симптом:** dashboard зелёный, side effects отсутствуют. **Причина:** удалена работа, а не выполнена. **Исправление:** data-owner approval, durable evidence, replay/reconciliation и explicit loss decision.

## Когда применять выводы

Runbook запускают при росте Kafka consumer lag, RabbitMQ ready/unacked, oldest age, local worker queue или delayed async side effects. При bounded плановом batch backlog нормален, если age, completion и drain соответствуют контракту.

Диагностика завершена, когда известны partition/queue/state, `λ` и durable `μ`, limiting stage, ack/commit semantics, безопасная mitigation, predicted/observed drain и план предотвращения потери/duplicate work.

## Источники

- [Kafka Monitoring](https://kafka.apache.org/43/operations/monitoring/) — Apache Kafka, Kafka 4.3.1, ветка документации `4.3`, consumer fetch/lag metrics и operational monitoring, проверено 2026-07-18.
- [Basic Kafka Operations](https://kafka.apache.org/43/operations/basic-kafka-operations/) — Apache Kafka, Kafka 4.3.1, ветка документации `4.3`, consumer-group position и per-partition lag, проверено 2026-07-18.
- [Kafka Consumer Configuration](https://kafka.apache.org/43/generated/consumer_config.html) — Apache Kafka, Kafka 4.3.1, ветка документации `4.3`, `max.poll.interval.ms` и `max.poll.records`, проверено 2026-07-18.
- [Kafka Distribution: Consumer Offset Tracking](https://kafka.apache.org/43/implementation/distribution/) — Apache Kafka, Kafka 4.3.1, ветка документации `4.3`, current/committed offsets и group coordinator, проверено 2026-07-18.
- [RabbitMQ Monitoring with Prometheus](https://www.rabbitmq.com/docs/prometheus) — RabbitMQ, документация 4.3, ready/unacknowledged/consumer/redelivery metrics, проверено 2026-07-18.
- [RabbitMQ Queues](https://www.rabbitmq.com/docs/queues) — RabbitMQ, документация 4.3, queue length и message states, проверено 2026-07-18.
- [RabbitMQ Consumer Acknowledgements and Publisher Confirms](https://www.rabbitmq.com/docs/confirms) — RabbitMQ, документация 4.3, acknowledgements, requeue и prefetch semantics, проверено 2026-07-18.
- [RabbitMQ Consumer Prefetch](https://www.rabbitmq.com/docs/consumer-prefetch) — RabbitMQ, документация 4.3, per-consumer prefetch semantics, проверено 2026-07-18.
