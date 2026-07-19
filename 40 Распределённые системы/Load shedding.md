---
aliases:
  - Load shedding
  - Сброс нагрузки
tags:
  - область/распределённые-системы
  - тема/устойчивость
статус: проверено
---

# Load shedding

## TL;DR

Load shedding намеренно отклоняет часть входящей работы, когда сервис близок к насыщению. Цель — сохранить goodput и предсказуемую latency принятых запросов, а не добиться нулевого числа отказов. Если принимать всё, очередь растёт, deadlines истекают после уже потраченной работы, а retries усиливают перегрузку.

Хороший shedder принимает решение рано и дёшево, ограничивает concurrency и queue, учитывает приоритет и измеряет offered, accepted, shed load и goodput отдельно. `503 Service Unavailable` подходит для временной нехватки общей capacity; `429 Too Many Requests` относится к caller-specific [[20 Бэкенд/Rate limiting и quotas|rate limit или quota]].

## Область применимости

- HTTP-семантика `503` соответствует RFC 9110 от июня 2022 года.
- Механизмы overload manager описаны по Envoy 1.38.3.
- Priority and Fairness показан по Kubernetes 1.36.2; API Priority and Fairness имеет статус Stable начиная с Kubernetes 1.29.
- Операционная модель goodput и early rejection сверена с AWS Builders Library, публикация июня 2026 года.
- Вне scope: L3/L4 DDoS mitigation, autoscaler конкретной платформы и доказательство оптимальности adaptive concurrency algorithm.

## Ментальная модель

У сервиса есть конечное число одновременно полезных работ. Пока вход ниже capacity, запросы завершаются быстро. После насыщения дополнительная очередь не создаёт CPU, connections или database throughput. Она лишь откладывает неизбежное решение и удерживает память.

Разделяйте четыре величины:

- **offered load**: сколько работы попытались передать сервису;
- **accepted load**: сколько он допустил внутрь;
- **shed load**: сколько отклонил на admission boundary;
- **goodput**: сколько полезных результатов успело завершиться в контрактный deadline.

Throughput может выглядеть высоким за счёт работы, ответ на которую уже никому не нужен. Поэтому goodput важнее числа начатых операций.

## Как устроено

### Admission до дорогой работы

Решение принимают до чтения огромного body, сложной authentication, захвата connection из дефицитного pool и вызова downstream. Чем позже rejection, тем меньше ресурсов оно спасает.

Простой concurrency limiter хранит число in-flight работ. Если предел достигнут и bounded queue заполнена, новый запрос немедленно отклоняется. Адаптивная версия меняет предел по сигналам saturation: queue delay, memory pressure, CPU, event-loop lag, downstream pool wait или доля истёкших deadlines.

Сигнал должен быть связан с защищаемым ресурсом. CPU alone плохо видит насыщенную БД; latency alone растёт уже после очереди и смешивает внешнюю зависимость с локальной перегрузкой. Несколько независимых bulkheads уменьшают риск, что один endpoint займёт весь процесс. На уровне Go общий принцип продолжает [[60 Go/Backpressure|backpressure]].

### Reject или queue

Короткая bounded queue поглощает микровсплеск и повышает утилизацию. Длинная превращает перегрузку в tail latency. Запрос в очереди продолжает расходовать deadline, поэтому admission проверяет, хватит ли остатка хотя бы на минимально полезное выполнение.

Queue дисциплина определяет fairness. FIFO прост, но большая серия дешёвых или низкоприоритетных запросов блокирует критические. Priority queue сохраняет важный трафик, зато может навсегда вытеснить низкий класс. Нужны квоты, weighted fairness или отдельные pools.

Kubernetes API Priority and Fairness классифицирует запросы по flow и priority level, изолирует concurrency, а при исчерпании использует `Reject` либо ограниченную очередь с fair queuing и shuffle sharding. Shuffle sharding уменьшает число посторонних flows, которые страдают от одного noisy flow, но не отменяет общего capacity planning.

### Overload manager и действия

Envoy overload manager получает pressure от resource monitors в диапазоне `0..1` и активирует threshold либо scaled triggers. Действия могут:

- перестать принимать новые requests и connections;
- вернуть `503` на перегруженном HTTP path;
- отключить keep-alive, чтобы клиенты перераспределили новые connections;
- уменьшить тайм-ауты или сбросить высокозатратные streams;
- ограничить функции, которые увеличивают memory pressure.

Это защита самого proxy. [[40 Распределённые системы/Circuit breaker|Circuit breaker]] обычно защищает caller от нездоровой зависимости, а rate limit обеспечивает policy/fairness для клиента. Один механизм не подменяет остальные.

### Ответ клиенту и обратная связь

`503` может содержать `Retry-After`, но слепой retry каждого shed request снова перегрузит сервис. Клиенту нужны exponential backoff, jitter и retry budget. Для non-idempotent operation отказ должен произойти до принятия эффекта либо сопровождаться ясным idempotency contract.

Метрики shed load не смешивают с обычной server error rate и latency accepted requests. Нужны оба ряда: иначе ранние дешёвые отказы искусственно «улучшают» p99 и CPU, а autoscaler решает, что capacity достаточно.

## Пример или трассировка

Сервис имеет 100 worker slots, средняя полезная работа занимает 200 ms. Его ориентировочная capacity равна 500 завершениям в секунду. Queue ограничена 50 запросами, 20 slots зарезервированы для critical traffic.

1. В норме приходит 350 rps, queue почти пуста.
2. Из-за массового retry offered load прыгает до 1000 rps. Первые 100 запросов занимают slots, короткий burst заполняет queue.
3. Admission boundary начинает отклонять лишний обычный трафик `503`, не читая body и не занимая DB connection. Critical requests ещё используют свой reserve.
4. После переходного периода accepted load остаётся около доступной capacity, а excess попадает в shed load. Latency принятых запросов остаётся ограниченной; без cap очередь росла бы, и большая часть работы завершалась после client deadline.
5. Клиенты с backoff и jitter уменьшают offered load. Когда queue delay и in-flight возвращаются ниже порога, shedder постепенно открывает admission.

Наблюдаемый результат: число HTTP-отказов временно выросло, зато goodput и критический путь сохранились. Это ожидаемый обмен, а не поломка механизма.

## Trade-offs

Раннее отбрасывание максимально экономит ресурсы, но видит меньше доменного контекста. Application-level admission умеет различать стоимость и приоритет, однако уже заплатило за routing и часть parsing/authentication.

Static concurrency cap объясним и стабилен. Adaptive cap лучше следует меняющейся capacity, но может oscillate из-за задержанной обратной связи. Нужны smoothing, предел скорости изменения и безопасные min/max.

Queue повышает burst tolerance, rejection удерживает latency. Компромисс — короткая bounded queue, рассчитанная на конкретный допустимый wait, а не «сколько помещается в память».

Приоритет сохраняет критический трафик, но создаёт starvation. Separate pools дают более сильную изоляцию ценой недоиспользования capacity одного класса, когда другой перегружен.

## Типичные ошибки

### Отбрасывание начинается после дорогой работы

- **Неверное предположение:** любой `503` одинаково защищает сервис.
- **Симптом:** error rate растёт, но CPU и DB pool остаются насыщенными.
- **Причина:** запрос уже прошёл parsing, authentication и downstream call.
- **Исправление:** перенести admission как можно ближе к входу, оставив минимальный контекст для policy.

### Очередь используют как дополнительную capacity

- **Неверное предположение:** больше backlog повышает throughput.
- **Симптом:** p99 и timeout растут, goodput падает.
- **Причина:** очередь хранит работу, но не создаёт workers или DB connections.
- **Исправление:** bounded queue, deadline-aware admission и ранний reject.

### Shed requests немедленно повторяются

- **Неверное предположение:** отказ освобождает место для такого же нового вызова.
- **Симптом:** offered load не падает либо растёт.
- **Причина:** feedback loop клиента не ограничен.
- **Исправление:** `Retry-After` там, где он осмыслен, jitter, retry budget и server pushback.

### Autoscaler видит только accepted CPU

- **Неверное предположение:** низкий CPU после включения shedding означает достаточную capacity.
- **Симптом:** replicas не добавляются, shed load остаётся высоким.
- **Причина:** ранний reject маскирует реальный спрос.
- **Исправление:** масштабировать и алертить по offered/shed load, queue delay и goodput вместе с resource utilization.

## Когда применять

Load shedding нужен сервису с конечной concurrency и требованием сохранить часть функций при overload. Особенно полезен там, где длинная очередь быстро съедает deadline и создаёт retry amplification.

До включения определяют admission boundary, защищаемый ресурс, классы приоритета, response semantics и client behavior. Если нагрузка стабильно превышает capacity, shedding только сохраняет работоспособность; причину устраняют масштабированием, снижением стоимости запроса или изменением продукта.

## Источники

- [RFC 9110: HTTP Semantics](https://datatracker.ietf.org/doc/html/rfc9110#name-503-service-unavailable) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [Overload manager](https://www.envoyproxy.io/docs/envoy/v1.38.3/configuration/operations/overload_manager/overload_manager) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Overload manager architecture](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/operations/overload_manager) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [API Priority and Fairness](https://kubernetes.io/docs/concepts/cluster-administration/flow-control/) — Kubernetes, документация 1.36.2; feature Stable с 1.29, проверено 2026-07-18.
- [Using load shedding to avoid overload](https://builder.aws.com/content/3Eun1EEyX6p2e3VYNyRLSJzLuMV/using-load-shedding-to-avoid-overload) — Amazon Web Services, first-party operational guidance, опубликовано 2026-06, проверено 2026-07-18.
