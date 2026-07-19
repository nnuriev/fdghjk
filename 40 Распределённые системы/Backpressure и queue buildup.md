---
aliases:
  - Backpressure and queue buildup
  - Обратное давление
  - Рост очереди
tags:
  - область/распределённые-системы
  - тема/устойчивость
  - механизм/обратное-давление
статус: проверено
---

# Backpressure и queue buildup

## TL;DR

Если producers создают работу со скоростью `λ`, а consumers устойчиво обрабатывают только `μ`, при `λ > μ` backlog растёт примерно со скоростью `λ − μ`. Неограниченная очередь не устраняет перегрузку — она превращает её в задержку, память или диск и откладывает отказ до более дорогого момента.

**Backpressure** передаёт downstream saturation вверх: замедляет producer, ограничивает demand или блокирует приём. Если producer нельзя замедлить, система должна ограничить буфер и выбрать admission control, load shedding, sampling, coalescing или durable spill с конечным retention. Рабочий контракт описывает capacity, максимальный queue age, политику переполнения и способ восстановления, а не только размер очереди.

## Область применимости

Заметка охватывает synchronous pipelines, message brokers и stream processing. Языковые механизмы Go подробнее разобраны в [[60 Go/Backpressure|заметке о backpressure в Go]], а partitions, consumer groups и DLQ — в [[40 Распределённые системы/Очереди, streams, группы потребителей и DLQ|заметке об очередях и streams]]. Здесь главное — системный feedback loop.

Reactive Streams JVM сверены со спецификацией 1.0.4, RabbitMQ — с документацией 4.2, Kafka — с документацией 4.3; проверено 2026-07-18.

## Ментальная модель

Очередь — запас времени, а не источник throughput:

```text
producer λ -> [ backlog Q ] -> consumer μ
                  dQ/dt ≈ λ - μ
```

При кратком burst очередь сглаживает разницу, затем опустошается. При устойчивом `λ > μ` любой конечный буфер заполнится; бесконечный существует только на диаграмме. Чем длиннее очередь, тем старее работа к началу обработки. Request может уже превысить deadline, event — потерять бизнес-ценность, а consumer продолжает тратить ресурсы.

Backpressure — замкнутый отрицательный feedback: downstream сообщает доступный demand, upstream производит не больше него. Queue buildup без feedback — разомкнутая система, где saturation видна слишком поздно.

## Как устроено

### Demand и bounded in-flight

Reactive Streams формулирует базовый контракт: publisher не посылает больше элементов, чем subscriber запросил через demand, при этом сигналы асинхронны и обязаны быть serial. Demand — кредит на конечное число элементов, а не прогноз бесконечной capacity.

В request/response системе аналог — semaphore или concurrency limiter перед дорогим участком. Он ограничивает in-flight работу, чтобы connection pool, heap и downstream не стали скрытой очередью. Producer либо ждёт в пределах deadline, либо получает быстрый отказ.

### Где накапливается очередь

Удаление явной очереди не убирает backlog. Он перемещается в:

- socket buffers и TCP send queues;
- accept backlog, thread pool или channel;
- broker partition и unacked deliveries;
- connection pool waiters;
- database locks и storage writeback;
- retries у clients.

Нужно измерять всю цепочку. Небольшая application queue бесполезна, если тысячи requests уже ждут connection ниже.

### Broker как эластичный, но конечный буфер

Durable broker развязывает скорость producer и consumer во времени. Он полезен для burst и outage, если retention/disk выдерживают расчётный объём. Но consumer lag — отложенная работа. При постоянном lag сначала истекает freshness SLA, затем retention удаляет ещё не обработанные данные или disk watermark останавливает writes.

В классической Kafka consumer group больше consumers не даст параллелизм выше числа partitions: partition одновременно назначена одному consumer группы. Kafka 4.3 Share Groups используют другую модель — одну partition могут совместно обрабатывать несколько share consumers с individual record acknowledgements. RabbitMQ prefetch ограничивает число unacknowledged messages, отправленных consumer: слишком высокий prefetch переносит очередь в process и ухудшает fairness, слишком низкий оставляет capacity незагруженной из-за round-trip latency.

### Политики насыщения

Когда producer контролируем, применяют blocking/await, demand protocol или rate limiting. Когда источник внешний и не ждёт, нужны явные потери или упрощение:

- reject newest для независимых обязательных jobs с повтором caller;
- drop oldest для telemetry, где свежесть важнее полноты;
- coalesce updates одного key, если промежуточные состояния не нужны;
- sample низкоприоритетные events;
- [[40 Распределённые системы/Load shedding|shed]] целые классы optional работы;
- spill на disk, только если заданы capacity и replay rate.

Политика является частью бизнес-семантики. `drop oldest` недопустим для ledger, но нормален для периодического CPU gauge.

### Восстановление после backlog

После возвращения capacity live traffic конкурирует с накопленным. Без отдельного лимита aggressive catch-up снова перегружает dependency. Recovery budget делят между новым потоком и backlog, а autoscaling считают по lag/queue age вместе с service time, не только по CPU.

Если вход `λ` остаётся выше максимального `μ`, scaling временно не решает архитектурный дефицит. Нужны partitioning, более дешёвая обработка, уменьшение входа или ослабление требования к каждому элементу.

## Пример или трассировка

Consumer обрабатывает 1 000 events/s. После деградации базы его устойчивый throughput падает до 600 events/s, producer продолжает 1 000 events/s.

1. Backlog растёт на 400 events/s: через 10 минут это 240 000 events.
2. При исходном throughput только drain занимает минимум 240 секунд, даже если новый поток остановить. При продолжающемся входе и восстановленном throughput 1 200 events/s чистая скорость drain — всего 200/s, то есть 20 минут.
3. Без bounded prefetch каждый worker забирает тысячи messages, heap растёт, rebalance после crash повторяет большую пачку.
4. С prefetch 100, общим concurrency limit и alert по oldest-event age broker удерживает backlog durably. После восстановления 1 000 events/s из доступных 1 200 покрывают новый вход, а оставшиеся 200/s уменьшают backlog. Отдельная priority queue для live traffic в этом расчёте не предполагается.

Наблюдаемый результат: во время деградации lag растёт на 400/s, а после восстановления падает на 200/s. Backpressure не отменяет дефицит, но ограничивает память процессов, делает возраст очереди прогнозируемым и не даёт recovery вызвать вторую аварию.

## Trade-offs

Большой buffer лучше поглощает burst, но повышает tail latency, recovery time и объём устаревшей работы. Малый buffer раньше отказывает, зато сохраняет ресурс и делает overload заметным у источника.

Blocking backpressure сохраняет элементы, но распространяет latency и может занять upstream threads. Async demand лучше использует ресурсы, однако усложняет протокол и cancellation. Dropping сохраняет health, но допустим только при явной семантике потери.

Autoscaling добавляет `μ`, если bottleneck действительно масштабируется. Если предел — одна база, lock или внешний quota, новые consumers лишь увеличат contention. Сначала измеряют service time и bottleneck, затем выбирают scaling signal.

## Типичные ошибки

- **Неверное предположение:** большая очередь повышает throughput. **Симптом:** throughput не меняется, latency и disk растут. **Причина:** bottleneck `μ` остался прежним. **Исправление:** bounded buffer и устранение bottleneck либо снижение admission.
- **Неверное предположение:** средняя длина очереди достаточно описывает health. **Симптом:** небольшой поток критичных events ждёт час за тяжёлой задачей. **Причина:** не измеряются age, priority и service-time distribution. **Исправление:** oldest age, per-class lag и отдельные pools/queues.
- **Неверное предположение:** broker даёт бесконечный spill. **Симптом:** retention удаляет необработанные events или заканчивается диск. **Причина:** outage volume не сопоставлен с storage и drain rate. **Исправление:** capacity model, watermark alerts и проверенный recovery plan.
- **Неверное предположение:** больше consumers всегда разгружает очередь. **Симптом:** database latency растёт, lag ускоряется. **Причина:** downstream saturation и contention. **Исправление:** end-to-end concurrency limit и масштабирование истинного bottleneck.

## Когда применять

Backpressure нужен на каждой границе, где downstream capacity конечна: worker pools, connection pools, broker consumers, streaming stages и batch fan-out. Выберите единицу demand, максимальный in-flight, queue capacity, deadline, overflow policy и recovery share.

Если producer физически нельзя замедлить, сразу выберите допустимый режим: потеря части данных или ограниченный durable buffer. «Принять всё» при конечной памяти и диске не является стратегией. Проверяйте систему нагрузочным тестом, где `λ > μ` достаточно долго, чтобы очередь достигла лимита, а затем измеряйте управляемое восстановление.

## Источники

- [Reactive Streams JVM Specification](https://github.com/reactive-streams/reactive-streams-jvm/blob/v1.0.4/README.md#specification) — Reactive Streams, версия 1.0.4, проверено 2026-07-18.
- [RabbitMQ Consumer Prefetch](https://www.rabbitmq.com/docs/4.2/consumer-prefetch) — RabbitMQ, документация 4.2, проверено 2026-07-18.
- [RabbitMQ Queues](https://www.rabbitmq.com/docs/4.2/queues) — RabbitMQ, документация 4.2, проверено 2026-07-18.
- [Kafka consumer groups and Share Consumers](https://kafka.apache.org/43/design/design/) — Apache Kafka, документация 4.3, classic consumer groups и Share Groups, проверено 2026-07-18.
- [Handling Overload](https://sre.google/sre-book/handling-overload/) — Google, Site Reliability Engineering book, 2016, проверено 2026-07-18.
