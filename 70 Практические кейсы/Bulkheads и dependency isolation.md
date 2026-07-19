---
aliases:
  - Bulkhead
  - Bulkhead pattern
  - Dependency isolation
  - Изоляция зависимостей
tags:
  - область/reliability-performance-operations
  - тема/отказоустойчивость
статус: проверено
---

# Bulkheads и dependency isolation

## TL;DR

Bulkhead делит конечный ресурс на независимые бюджеты так, чтобы один tenant, dependency, priority class или cell не мог исчерпать всё. Изолировать надо ресурс, через который распространяется отказ: concurrency slots, connection/worker pools, queues, CPU/memory, instances, shards, credentials или control plane.

Отдельный semaphore поверх общего исчерпанного pool не создаёт изоляцию. Граница работает, только если за ней есть зарезервированный supply, собственный admission и bounded failure. Цена: часть capacity простаивает и появляется больше конфигурации, routing и наблюдения.

## Ментальная модель

Shared pool превращает локальную проблему в глобальную:

```text
slow dependency A -> all shared workers wait -> calls to healthy B cannot start
```

Bulkhead ограничивает максимум ущерба:

```text
A budget exhausted -> A rejects/degrades
B budget remains   -> B continues
```

Речь не о предотвращении отказа A. Цель: заранее вычислимый blast radius и сохранение capacity для остальных путей.

## Как устроено

### Изоляция на стороне caller

Для каждой зависимости или criticality выделяют собственный concurrency limit, connection pool и bounded queue. Deadline освобождает caller resource; cancellation должна доходить до фактической работы. Когда budget заполнен, новый вызов reject/degrade до захвата shared ресурсов.

[[40 Распределённые системы/Circuit breaker|Circuit breaker]] отвечает на другой вопрос: стоит ли пытаться вызвать dependency в её текущем состоянии. Bulkhead гарантирует, что даже медленные или ошибочные попытки не заберут больше выделенного бюджета. Retry остаётся внутри той же перегородки и не получает обходного pool.

### Изоляция внутри сервиса

Capacity делят по tenant, endpoint, priority или workload class. Один клиент получает не более заданной доли workers/IOPS; batch использует отдельную queue; control operations имеют зарезервированные slots. Иначе bulk tenant или дорогой endpoint создаёт head-of-line blocking для critical path.

Жёсткий резерв предсказуем. Borrowing повышает utilization: свободную capacity A временно использует B. Но заём должен быть отзывным и не нарушать минимальный reserve, иначе при возвращении A её гарантия существует только на схеме.

### Cells ограничивают инфраструктурный failure domain

Cell содержит полный data/compute slice и обслуживает стабильный набор partition keys. Cells не делят mutable state и не вызывают друг друга на critical path; router остаётся простым и масштабируемым. Fixed maximum cell size проверяется load test, рост происходит добавлением cells.

Если все cells используют одну database, queue, deployment wave или config service, общая зависимость остаётся путём коррелированного отказа. Availability Zones сами по себе тоже не изолируют application-level hot tenant, если его traffic размазан по всем zones.

### Наблюдаемость строится по границам

Для каждого bulkhead нужны in-use/limit, rejects, queue age, latency, retry load и доля общего user impact. Aggregate CPU не покажет, что pool A заполнен, а B простаивает. Routing key и cell identity входят в telemetry с ограниченной cardinality.

## Пример или трассировка

Order API имеет общий pool из 100 database connections. Endpoint каталога вызывает медленную dependency и удерживает DB transaction, пока ждёт ответ. Сто одновременных catalog requests занимают весь pool; checkout здоров технически, но не может получить connection и возвращает timeout. Локальный отказ стал глобальным.

После разделения:

```text
catalog:  30 connections, queue 10
checkout: 50 connections, queue 20
reserve:  20 connections для control/reconciliation
```

При blackhole catalog занимает максимум 30 connections и после заполнения queue быстро отклоняет новые запросы. Checkout сохраняет свои 50 slots, reserve позволяет оператору выполнить repair/control work. Наблюдаемый blast radius ограничен каталогом.

Цена видна в normal mode: если checkout пуст, catalog не использует его 50 connections и раньше получает reject. Controlled borrowing можно разрешить сверх гарантированных 30, но при росте checkout borrowed slots должны освобождаться по короткому deadline. Иначе hard isolation снова исчезает.

## Trade-offs

Мелкие bulkheads уменьшают blast radius, но создают fragmentation: свободная capacity одного класса не помогает другому. Крупный общий pool лучше утилизируется, зато tail одного workload влияет на всех. Borrowing занимает середину и требует корректного reclaim.

Per-dependency pools проще cells и защищают caller resources, но не изолируют shared data plane. Cells ограничивают bad deploy, poison key и infrastructure failure, однако требуют partition mapping, data migration, independent deployment и операционную зрелость.

Отдельный process/container даёт сильнее CPU/memory isolation, чем goroutine/thread pool, но дороже в latency, deployment и capacity. Выбирают минимальную границу, которая перерезает доказанный путь распространения отказа.

## Типичные ошибки

- **Неверное предположение:** разные logical queues уже изолированы. **Симптом:** обе останавливаются при заполнении shared workers. **Причина:** supply после очередей общий. **Исправление:** резервировать ограничивающий resource, а не только labels.
- **Неверное предположение:** circuit breaker заменяет bulkhead. **Симптом:** медленные вызовы до открытия breaker исчерпывают pool. **Причина:** breaker классифицирует состояние, но не ограничивает concurrency. **Исправление:** deadline + bulkhead + breaker как разные слои.
- **Неверное предположение:** retry получает новую независимую попытку. **Симптом:** failing class забирает reserve через повторные вызовы. **Причина:** retries не входят в budget. **Исправление:** считать attempts в том же concurrency/rate limit.
- **Неверное предположение:** cells независимы, потому что имеют разные instances. **Симптом:** один config push или shared DB выводит все cells. **Причина:** остался общий failure domain. **Исправление:** inventory shared state/control planes и staggered changes.
- **Неверное предположение:** фиксированные квоты можно выставить один раз. **Симптом:** healthy workload получает rejects при idle capacity рядом. **Причина:** distribution изменилось, borrowing отсутствует или небезопасно. **Исправление:** измерять demand, пересматривать budgets и тестировать reclaim.

## Когда применять

Bulkheads нужны, когда несколько критичных потоков конкурируют за конечный ресурс и failure одного не должен нарушать остальные. Первый кандидат: отдельные pools/limits для внешних dependencies, interactive и batch, high/low priority, крупных tenants. Cells оправданы, когда нужен архитектурный предел blast radius для data и deployments.

Перед внедрением нарисуйте propagation path: какой ресурс исчерпывается, кто его делит и какой minimum supply надо сохранить. Если граница не перерезает этот путь, она добавит сложность без изоляции.

## Источники

- [Bulkhead pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/bulkhead) — Microsoft, Azure Architecture Center, обновлено 2026-03-19, проверено 2026-07-18.
- [REL10-BP03 Use bulkhead architectures to limit scope of impact](https://docs.aws.amazon.com/wellarchitected/latest/framework/rel_fault_isolation_use_bulkhead.html) — Amazon Web Services, AWS Well-Architected Framework latest, cell boundaries и fixed maximum size, проверено 2026-07-18.
- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering, глава 22, shared resource exhaustion и isolation, проверено 2026-07-18.
