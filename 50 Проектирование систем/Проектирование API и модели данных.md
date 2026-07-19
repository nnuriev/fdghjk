---
aliases:
  - API contract and data model in System Design
  - Проектирование API contract
  - Data model в System Design
tags:
  - область/проектирование-систем
  - тема/api-и-данные
статус: проверено
---

# Проектирование API и модели данных

## TL;DR

API фиксирует наблюдаемое поведение системы, модель данных — факты, ownership и инварианты, которые это поведение делают возможным. На System Design интервью их проектируют вместе от critical operations: команда получает idempotency и completion boundary, query — access pattern и consistency, event — уже состоявшийся факт и schema evolution.

Не надо превращать API в CRUD-копию таблиц. Стабильный контракт говорит на языке бизнеса, а storage schema оптимизируется под инварианты, read/write paths и выбранное хранилище.

## Ментальная модель

У каждого endpoint или message есть три слоя контракта:

```text
wire: method/path/schema/status
semantics: preconditions/outcome/idempotency/ordering
state: owner/invariant/atomic boundary/access paths
```

Совместимый JSON ещё не гарантирует совместимость поведения. Если поле осталось тем же, но `accepted` теперь означает enqueue до durable commit, клиент получил другой контракт.

## Как устроено

### Начать с операций

Для каждой core operation зафиксируйте:

- actor и authorization decision;
- command, query или event;
- business key и ресурс;
- preconditions и concurrency control;
- success boundary;
- retry/idempotency semantics;
- error model и retryability;
- consistency следующего read.

HTTP method и status выбираются после семантики по [[20 Бэкенд/HTTP-методы, статус-коды, заголовки и семантика кэширования|HTTP contract]]. Долгая операция использует [[20 Бэкенд/Синхронная и асинхронная обработка|operation resource]], если итог не помещается в request deadline.

### API contract

Mutation должна отвечать на вопрос «что знает клиент после ответа?». `201 Created` обычно означает созданный адресуемый ресурс. Стандартный `202 Accepted` сообщает лишь, что запрос принят для обработки: HTTP не гарантирует ни durable acceptance, ни завершение операции, а status monitor только рекомендует. Если конкретный API обещает сохранить команду до ответа и возвращает `operation_id` для чтения terminal state, эту более сильную гарантию надо записать в его контракте отдельно. Timeout оставляет outcome unknown, поэтому idempotency key хранится вместе с fingerprint запроса и прежним outcome.

List API заранее выбирает стабильный порядок и pagination. Offset удобен для небольшого статичного набора; cursor/continuation token связывает position с sort key и snapshot semantics по правилам [[20 Бэкенд/Пагинация offset, cursor и continuation token|пагинации]].

Error model отделяет validation, authorization, conflict, resource exhaustion, transient dependency и internal error. Машиночитаемый code стабильнее текста. `Retry-After` и idempotency определяют, можно ли безопасно повторить запрос.

Async event contract получает event ID, type/version, occurred time, producer, partition/ordering key и payload. Consumer не должен выводить семантику из имени topic. Доставка и schema compatibility остаются частью контракта.

### Data model

Сначала выпишите факты и инварианты, затем access patterns. Для каждого набора данных назовите:

- canonical owner и source of truth;
- identity и business uniqueness;
- mutable state machine;
- границу атомарного изменения;
- read keys, sort/range keys и secondary access paths;
- retention, privacy class и deletion semantics;
- derived copies и способ rebuild/reconciliation.

[[30 Данные/Моделирование данных и реляционная модель|Реляционная модель]] полезна, когда связи и multi-row invariants должны проверяться внутри storage. В key-value/wide-column модели aggregate и partition key должны совпасть с atomicity и запросами; иначе join и correctness переедут в приложение.

### Связать API с владением

Write endpoint маршрутизируется владельцу инварианта. Другой сервис не обновляет его таблицу напрямую. Read API может обслуживаться локальной projection, если контракт допускает stale result и описывает repair. Событие публикуется после commit через [[40 Распределённые системы/Transactional outbox и Change Data Capture|outbox/CDC]], когда запись и публикацию нельзя потерять между двумя системами.

Версия public API, event schema и stored payload эволюционируют независимо. Backward compatibility проверяется отдельно на wire, source и semantic layers по [[20 Бэкенд/Контракты API и обратная совместимость|правилам контрактов]].

## Сквозной пример: notification request

API принимает одну логическую отправку:

```http
POST /v1/notifications
Idempotency-Key: order-742-shipped

{
  "recipient_id": "u-17",
  "template_id": "order-shipped-v3",
  "channels": ["push", "email"],
  "variables": {"order_id": "742"}
}
```

Ответ `202` содержит `notification_id` и URL operation/status. В одной SQL transaction система:

1. проверяет `(tenant_id, idempotency_key)` и fingerprint;
2. создаёт `notification` со state `ACCEPTED`;
3. создаёт две `delivery` со своими state machines;
4. пишет outbox event.

Модель разделяет логическое намерение и попытки:

```text
notification(id, tenant_id, business_key, recipient_id, state, created_at)
delivery(notification_id, channel, state, attempt, provider_message_id, next_attempt_at)
outbox(event_id, aggregate_id, type, payload, published_at)
```

Уникальность business key не даёт повторному POST создать вторую отправку. Уникальность `(notification_id, channel)` не даёт двум workers создать две логические delivery, но provider call всё равно может повториться после unknown outcome. Для него нужен channel-specific idempotency key или reconciliation по provider ID.

`GET /v1/notifications/{id}` читает canonical state. Массовый список пользователя может идти из denormalized projection с cursor по `(created_at, id)`. Это два access path с разной freshness, и контракт должен их различать.

## Trade-offs

Ресурсный API проще кешировать и версионировать, но workflow иногда естественнее выражается командой и operation. Универсальный `POST /actions` экономит endpoints, зато теряет discoverability, authorization granularity и стабильные resource semantics.

Нормализованная canonical schema легче поддерживает invariants. Denormalized read model уменьшает joins и fan-out, но требует async update, versioning и reconciliation. Она не становится вторым бесконтрольным source of truth.

Client-generated ID облегчает idempotency и offline work, но требует validation namespace и защиты от угадывания. Server-generated ID централизует policy, зато unknown response нуждается в отдельном idempotency key.

## Типичные ошибки

- **Неверное предположение:** endpoint должен повторять таблицу. **Симптом:** rename столбца ломает clients, а один use case требует много chatty calls. **Причина:** storage schema стала public contract. **Исправление:** моделировать business operation и скрыть физическую схему.
- **Неверное предположение:** `202` означает успешный эффект. **Симптом:** клиент показывает успех, хотя worker завершился ошибкой. **Причина:** acceptance смешана с completion. **Исправление:** operation state и terminal error.
- **Неверное предположение:** UUID решает дедупликацию. **Симптом:** retry с новым UUID создаёт второй бизнес-эффект. **Причина:** технический ID не совпадает с business identity. **Исправление:** idempotency/business key и fingerprint.
- **Неверное предположение:** denormalized copy всегда актуальна. **Симптом:** UI показывает старое состояние сразу после mutation. **Причина:** read path не получил session guarantee. **Исправление:** canonical read/overlay/version token либо честная freshness boundary.
- **Неверное предположение:** schema compatibility сохраняет semantics. **Симптом:** старый consumer принимает поле, но иначе трактует default или ordering. **Причина:** проверен только wire. **Исправление:** contract scenarios и staged rollout producer/consumer.

## Когда применять

На интервью достаточно двух-трёх core operations и минимальной схемы, если по ним можно пройти invariants и paths. В реальном RFC добавляются formal OpenAPI/AsyncAPI schema, compatibility tests, migration states, ownership и retention policy.

## Источники

- [RFC 9110: HTTP Semantics](https://datatracker.ietf.org/doc/html/rfc9110) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RFC 9457: Problem Details for HTTP APIs](https://datatracker.ietf.org/doc/html/rfc9457) — IETF, RFC 9457, июль 2023, проверено 2026-07-18.
- [OpenAPI Specification 3.2.0](https://spec.openapis.org/oas/v3.2.0.html) — OpenAPI Initiative, версия 3.2.0 от 2025-09-19, проверено 2026-07-18.
- [AIP-151: Long-running operations](https://google.aip.dev/151) — Google, AIP-151, обновлено 2025-02-04, проверено 2026-07-18.
- [AsyncAPI Specification 3.1.0](https://www.asyncapi.com/docs/reference/specification/v3.1.0) — AsyncAPI Initiative, версия 3.1.0 от 2026-01-31, проверено 2026-07-18.
