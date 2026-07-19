---
aliases:
  - SQL и system design — GO ПРОРВЁМСЯ
tags:
  - тип/разбор-курса
  - источник/coursehunter
  - тема/базы-данных
  - тема/системный-дизайн
  - тема/собеседования
статус: проверено
---

# SQL и системный дизайн

## 86. Спроектировать БД чатов, пользователей и сообщений

![[90 Вложения/CurseHunter/7171/Кадры/7171-86-chat-schema.jpg]]

*Кадр урока 86: бизнес-правила, схема и SQL-запрос из условия.*

### Условие

Сущности и правила из видео:

- пользователь имеет имя и дату регистрации;
- чат имеет имя и дату создания;
- сообщение имеет текст, автора и дату создания;
- пользователь может состоять в нескольких чатах;
- сообщение обязательно принадлежит ровно одному чату;
- требуется описать таблицы, primary/foreign keys и написать запрос всех чатов пользователя «Вася» в формате `(chat_id, chat_name)`.

### Минимальная нормализованная схема

```sql
CREATE TABLE users (
    id            uuid PRIMARY KEY,
    name          text NOT NULL,
    registered_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE chats (
    id         uuid PRIMARY KEY,
    name       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE chat_members (
    chat_id   uuid NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    user_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    joined_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (chat_id, user_id)
);

CREATE TABLE messages (
    id         uuid PRIMARY KEY,
    chat_id    uuid NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
    author_id  uuid NOT NULL REFERENCES users(id),
    body       text NOT NULL CHECK (length(body) > 0),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX chat_members_by_user
    ON chat_members (user_id, chat_id);

CREATE INDEX messages_by_chat_time
    ON messages (chat_id, created_at DESC, id DESC);
```

`chat_members` материализует many-to-many. Composite primary key запрещает повторное membership одного пользователя в одном чате. `messages.chat_id NOT NULL` обеспечивает принадлежность одному чату на уровне строки: один foreign-key scalar не может ссылаться сразу на два чата.

Foreign key не всегда автоматически создаёт полезный index на referencing columns, поэтому индексы выбираются под query paths. Для pagination сообщений `(chat_id, created_at DESC, id DESC)` даёт deterministic keyset cursor даже при одинаковом timestamp.

### Может ли писать неучастник

Текущие два foreign keys доказывают, что chat и author существуют, но не доказывают membership автора в этом chat. Если business rule требует «писать может только участник», schema может закрепить его composite foreign key:

```sql
ALTER TABLE messages
ADD CONSTRAINT message_author_is_member
FOREIGN KEY (chat_id, author_id)
REFERENCES chat_members (chat_id, user_id);
```

Цена: удаление membership теперь конфликтует с историческими сообщениями. Варианты зависят от retention semantics:

- запрещать physical deletion membership и хранить `left_at`;
- не закреплять правило FK, а проверять membership при создании сообщения в transaction;
- отделить immutable author identity/history от current membership.

Нельзя автоматически выбрать `ON DELETE CASCADE` для автора: удаление account не обязательно означает удаление всей истории. Часто применяют soft delete/anonymization, сохраняя referential history.

### Запрос из условия

По имени, как буквально просит задача:

```sql
SELECT c.id AS chat_id, c.name AS chat_name
FROM users AS u
JOIN chat_members AS cm ON cm.user_id = u.id
JOIN chats AS c ON c.id = cm.chat_id
WHERE u.name = $1
ORDER BY c.id;
```

Parameter `$1 = 'Вася'` защищает query boundary; строка не склеивается с SQL. Но имя не обязано быть уникальным. Если в системе два «Васи», запрос объединит их чаты. Production API должен принимать authenticated `user_id`:

```sql
SELECT c.id, c.name
FROM chat_members AS cm
JOIN chats AS c ON c.id = cm.chat_id
WHERE cm.user_id = $1
ORDER BY c.id;
```

### Follow-ups интервьюера

- direct chat: unique unordered pair участников или отдельный `kind`+business constraint;
- unread count: per-membership `last_read_message_id`, но порядок ID должен соответствовать выбранной модели;
- edit/delete: version/history table либо current row + audit events;
- attachments: metadata в БД, large object в object storage;
- hot group chat: partition messages by chat/time, но только после измерения;
- message order: DB sequence/ULID/server timestamp; client timestamp не задаёт canonical order;
- multi-tenant isolation: `tenant_id` входит в keys/constraints, иначе cross-tenant references остаются возможны.

## 87. Медленный AnalyticsService на пути создания заказа

![[90 Вложения/CurseHunter/7171/Кадры/7171-87-transactional-outbox.jpg]]

*Кадр урока 87: transactional outbox, его гарантии и цена эксплуатации.*

### Исходная проблема

`OrderService` синхронно вызывает `AnalyticsService.TrackOrder` во время `CreateOrder`. Analytics отвечает долго или падает, поэтому пользователь ждёт, order flow становится зависим от необязательной аналитики, а неясная обработка failure приводит к потерянным заказам/деньгам.

Первый вопрос — является ли аналитика частью transactionally required business outcome. Если без неё заказ всё равно должен существовать, синхронный вызов находится на неправильном critical path.

### Почему «просто отправить в очередь после commit» недостаточно

Схема `commit order → publish OrderCreated` имеет dual-write window:

1. transaction заказа commit успешен;
2. process падает до publish;
3. заказ есть, события нет навсегда.

Обратный порядок тоже плох: событие может уйти, а DB transaction — rollback. Broker transaction и PostgreSQL transaction обычно не образуют одну общую atomic commit boundary.

### Transactional outbox

Order и outbox event записываются одной локальной DB transaction:

```sql
BEGIN;

INSERT INTO orders (id, customer_id, status, total)
VALUES ($1, $2, 'created', $3);

INSERT INTO outbox_events (
    event_id, aggregate_type, aggregate_id, event_type, payload, created_at
)
VALUES ($4, 'order', $1, 'OrderCreated', $5, now());

COMMIT;
```

После commit пользователь получает подтверждение. Background relay читает unpublished events, публикует в broker, ждёт publisher confirmation и помечает событие обработанным. Альтернатива polling relay — CDC: Debezium читает PostgreSQL WAL и преобразует outbox rows в events.

Главная гарантия — не «exactly once», а отсутствие рассогласования order/outbox в локальной transaction. Relay обычно даёт at-least-once: crash после broker confirm, но до отметки в БД, приводит к повторной публикации.

### Idempotent consumer

Каждый event получает стабильный `event_id`. Analytics consumer обрабатывает message и фиксирует dedup marker в одной transaction со своим side effect:

```sql
BEGIN;

INSERT INTO consumed_events (consumer, event_id, consumed_at)
VALUES ('analytics', $1, now())
ON CONFLICT DO NOTHING;

-- выполнять analytics update только если INSERT действительно вставил строку

COMMIT;
```

Одна проверка «есть ли ID» до update снова имеет race. Нужен unique key `(consumer, event_id)` и atomic insert/side-effect transaction. Если sink не transactional, применяется idempotent operation/upsert или domain-specific reconciliation.

### Retry, DLQ и circuit breaker

- transient broker/network errors: exponential backoff с jitter и upper bound;
- permanent schema/validation error: quarantine/DLQ, а не бесконечный hot retry;
- consumer подтверждает broker message только после durable success;
- poison message имеет delivery-attempt budget и наблюдаемый operator workflow;
- circuit breaker снижает нагрузку на уже failing dependency, но не хранит событие и не является delivery guarantee.

Publisher confirm означает, что broker принял публикацию в рамках выбранной durability semantics; это не подтверждение обработки AnalyticsService. Consumer acknowledgement — отдельная стадия.

### Ordering

Если события одного заказа должны применяться по порядку, `aggregate_id` используется как partition/routing key. Это сохраняет local order в одной partition/queue, но разные aggregates обрабатываются параллельно. Consumer всё равно должен выдерживать duplicate и delayed delivery; для строгой version progression событие несёт aggregate version.

### Что мониторить

- outbox oldest-unpublished age и backlog size;
- publish success/failure/confirm latency;
- consumer lag, processing latency, retries и DLQ size;
- duplicate count и idempotency conflicts;
- долю заказов без ожидаемого analytics projection;
- shutdown drain time и число in-flight deliveries.

Alert по queue length без event age может шуметь при нормальном burst и пропустить маленький, но давно застрявший backlog.

### Trade-offs

| Вариант | Когда уместен | Риск/цена |
|---|---|---|
| Синхронный вызов | Analytics действительно обязателен для ответа | latency/failure coupling; deadline и fallback обязательны |
| Async publish после commit | Потеря редкого события приемлема или есть reconciliation | dual-write gap |
| Transactional outbox + polling | Нужна надёжность без CDC platform | relay, cleanup, locking и duplicate delivery |
| Outbox + CDC | CDC уже является управляемой platform capability | connector/WAL operations, schema governance |

## Уроки без отдельного технического задания

Урок 89 анализирует востребованные навыки по вакансиям (`Go`, PostgreSQL, Docker, Linux, Git, SQL, Kubernetes, Redis, RabbitMQ/Kafka, gRPC и другие). В нём нет самостоятельного вопроса, условия задачи или code-review фрагмента, поэтому он учтён в покрытии курса, но не превращён в искусственную карточку собеседования.

Комплексная задача бесплатного урока 88 сохранена отдельно в [[CurseHunter/7171/03 Code review на собеседовании#88. MEGA CODE REVIEW: task processor целиком|разборе code review]].

## Источники

- [PostgreSQL 18 — Constraints](https://www.postgresql.org/docs/18/ddl-constraints.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-19.
- [PostgreSQL 18 — Indexes](https://www.postgresql.org/docs/18/indexes.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-19.
- [PostgreSQL 18 — Transactions](https://www.postgresql.org/docs/18/tutorial-transactions.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-19.
- [Consumer Acknowledgements and Publisher Confirms](https://www.rabbitmq.com/docs/confirms) — RabbitMQ, версия 4.3, проверено 2026-07-19.
- [Outbox Event Router](https://debezium.io/documentation/reference/stable/transformations/outbox-event-router.html) — Debezium stable documentation, проверено 2026-07-19.
- [GO ПРОРВЁМСЯ](https://olezhek28.courses/gothrough) — авторская страница курса, проверено 2026-07-19.
