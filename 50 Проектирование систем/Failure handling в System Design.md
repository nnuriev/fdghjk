---
aliases:
  - Failure handling
  - Failure matrix
  - Обработка отказов в System Design
tags:
  - область/проектирование-систем
  - тема/отказоустойчивость
статус: проверено
---

# Failure handling в System Design

## TL;DR

Failure handling начинается не с retry, а с классификации исходов. Для каждого обязательного шага нужно знать, был ли эффект невозможен, подтверждён или остался unknown; можно ли безопасно повторить; какой stale/partial результат допустим; как ограничить нагрузку; кто и из какого источника восстановит состояние.

Сильный дизайн содержит failure matrix: отказ, detection, автоматическая реакция, degraded mode, пользовательский outcome, recovery и проверяемый предел. Timeout, backoff, circuit breaker, bulkhead, load shedding и reconciliation работают как связанный контур. Любой механизм без бюджета способен ухудшить outage.

## Ментальная модель

Распределённый вызов имеет три локальных результата:

```text
definitely failed | definitely committed | outcome unknown
```

Timeout говорит только, что caller перестал ждать. Downstream мог не получить request, мог выполнить его и потерять response, мог продолжать работу после deadline. Поэтому retry safety определяется идемпотентностью операции и сохранённым outcome, а не видом сетевой ошибки.

## Как устроено

### Построить failure matrix

Для каждой зависимости и stateful boundary заполните:

| Отказ | Detection | Автоматическая реакция | Degraded mode | Recovery |
| --- | --- | --- | --- | --- |
| instance crash | health/readiness, missing heartbeat | route к replica | уменьшенная capacity | restart, inspect crash loop |
| dependency timeout | deadline/trace/error rate | limited retry или fail fast | cached/partial response | dependency recovery, drain retry queue |
| broker lag | consumer lag и age | scale/throttle producers | stale projection | replay/reconciliation |
| zone loss | black-box SLI + routing | redistribute traffic | shed optional work | rebuild capacity, verify data |
| bad deploy | canary SLO regression | stop/rollback | old version | diagnose after rollback |

Таблица не обещает одинаковую реакцию всем операциям. Read каталога может вернуть stale cache, а ledger write лучше отклонить, чем угадать результат.

### Deadlines и cancellation

End-to-end deadline делится между hops. Child deadline должен оставлять caller время обработать ответ и не превышать полезность результата. Cancellation снижает wasted work, но не откатывает уже committed side effect. Это различие раскрыто в [[20 Бэкенд/Дедлайны запросов и распространение отмены|заметке о дедлайнах]].

### Retry budget

Retry полезен для временного отказа, если операция повторяема и следующий attempt имеет шанс успеть. Нужны exponential backoff, jitter, maximum attempts и общий deadline по [[40 Распределённые системы/Retry, exponential backoff и jitter|retry policy]]. Ограничивайте retry traffic отдельным budget: при 10% первичных ошибок один retry уже добавляет до 10% нагрузки, а retries на каждом слое умножаются.

Не повторяйте permanent validation/auth errors. Для mutation outcome unknown верните прежний результат по idempotency key или проведите reconciliation, а не запускайте новый бизнес-эффект.

### Изоляция и admission

[[40 Распределённые системы/Circuit breaker|Circuit breaker]] перестаёт тратить ресурсы на явно недоступную dependency, но не является recovery protocol. Bulkhead разделяет pools/queues по dependency, tenant или priority, чтобы один класс не исчерпал всё. Bounded queue ограничивает память и latency; переполнение должно вести к явному reject/load shedding, а не к бесконечному ожиданию.

[[40 Распределённые системы/Load shedding|Load shedding]] защищает полезную capacity. Сначала отбрасывают speculative prefetch, expensive optional enrichment и batch, затем низкий priority. Admission decision должен происходить до дорогой работы.

### Graceful degradation

Degraded mode заранее задаёт урезанный, но корректный продукт:

- stale cache с age marker вместо полного outage;
- timeline без ranking enrichment;
- accepting durable command с delayed processing;
- read-only mode, если write authority потеряна;
- partial search results с явным incomplete indicator.

Нельзя деградировать инвариант молча. «Пропустим authorization, пока policy service недоступен» повышает availability ценой нарушения security boundary и обычно неприемлемо.

### Recovery и reconciliation

Automatic failover заканчивается только после failback и проверки данных. Нужны источник истины, replay position, repair throughput, quarantine для poison data и критерий завершения. Backup считается частью системы после успешного restore drill, а не после появления файла.

Multi-region recovery опирается на [[40 Распределённые системы/Disaster recovery|DR plan]], RPO/RTO и write fencing. Возврат трафика слишком рано способен перегрузить холодные caches и отстающие replicas.

## Сквозной пример: оформление заказа

Order service должен зарезервировать товар и инициировать платёж. Один synchronous distributed transaction через внешнего provider недоступен.

1. `POST /orders/{id}/confirm` с idempotency key переводит order в `CONFIRMING` и создаёт workflow/outbox в одной local transaction.
2. Inventory reservation использует `(order_id, line_id)` как business key и возвращает прежний outcome при retry.
3. Payment provider получает stable idempotency key. Если response потерян, attempt становится `UNKNOWN`; workflow не создаёт новый charge, а опрашивает/reconciles provider.
4. Success обоих шагов переводит order в `CONFIRMED`; permanent inventory failure отменяет workflow; уже выполненный charge получает refund workflow с отдельным outcome.

Failure matrix для payment timeout:

- detection: child deadline, trace и attempt state;
- автоматическая реакция: один budgeted status lookup, затем delayed reconciliation;
- degraded mode: order остаётся `CONFIRMING`, клиент видит operation status;
- recovery: reconcile по provider key; terminal outcome записывается идемпотентно;
- alert: возраст oldest `UNKNOWN` и процент orders вне business deadline.

Такой дизайн не обещает невозможное exactly-once через сеть. Он делает повторяемым локальное решение и обнаружимым неизвестный внешний исход.

## Trade-offs

Fast fail сохраняет capacity, но увеличивает видимые ошибки во время краткого blip. Retry скрывает короткий transient failure, но повышает load и tail. Hedge уменьшает read tail, зато дублирует запросы; применять его можно к безопасным reads с отдельным budget.

Большая queue сглаживает burst, но превращает overload в растущую latency и усложняет recovery. Маленькая bounded queue раньше rejects traffic, зато сохраняет SLO для принятой работы.

Active-active уменьшает зависимость от одного региона, но добавляет conflict resolution, data locality и сложный failback. Active-passive проще по authority, однако standby capacity и регулярные drills всё равно оплачиваются.

## Типичные ошибки

- **Неверное предположение:** timeout означает отсутствие эффекта. **Симптом:** duplicate payment после retry. **Причина:** outcome был unknown. **Исправление:** idempotency key, outcome store и reconciliation.
- **Неверное предположение:** retry повышает availability бесплатно. **Симптом:** transient incident превращается в [[40 Распределённые системы/Retry storms и cascading failures|retry storm]]. **Причина:** retries на нескольких слоях без budget. **Исправление:** один owning layer, backoff/jitter, max attempts и overload gate.
- **Неверное предположение:** queue устраняет overload. **Симптом:** lag растёт часами, а recovery перегружает dependency. **Причина:** arrival rate выше service rate. **Исправление:** admission, producer throttling, capacity и drain plan.
- **Неверное предположение:** health check доказывает полезность instance. **Симптом:** load balancer отправляет traffic в процесс с исчерпанным pool. **Причина:** liveness перепутана с readiness и black-box SLI. **Исправление:** readiness по ability to serve плюс внешние probes.
- **Неверное предположение:** failover завершает incident. **Симптом:** failback теряет writes или создаёт split brain. **Причина:** не определены authority, fencing и reconciliation. **Исправление:** пошаговый failback с version/data checks.

## Когда применять

Failure matrix строят после normal read/write paths и до финального выбора redundancy. На production review проверяют хотя бы instance, dependency, storage, zone/region, overload, bad deploy и operator error. Самые дорогие обещания подтверждают game day и restore drill.

## Источники

- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering, глава 22, проверено 2026-07-18.
- [Handling Overload](https://sre.google/sre-book/handling-overload/) — Google, Site Reliability Engineering, глава 21, проверено 2026-07-18.
- [Timeouts, retries, and backoff with jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/) — Amazon Builders' Library, проверено 2026-07-18.
- [Production Services Best Practices](https://sre.google/sre-book/service-best-practices/) — Google, Site Reliability Engineering, production checklist, проверено 2026-07-18.
