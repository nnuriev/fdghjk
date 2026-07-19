---
aliases:
  - Transactional outbox
  - Change Data Capture
  - CDC
tags:
  - область/распределённые-системы
  - тема/согласованность
статус: проверено
---

# Transactional outbox и Change Data Capture

## TL;DR

Transactional outbox переносит бизнес-изменение и намерение опубликовать событие в одну локальную транзакцию: сервис обновляет свои таблицы и вставляет immutable outbox row. Отдельный relay читает закоммиченные записи — polling-ом или через Change Data Capture (CDC) — и публикует их в broker.

Это устраняет dual-write окно «БД закоммичена, событие потеряно» и обратное окно «событие опубликовано, БД откатилась». В общей схеме at-least-once relay может опубликовать событие и упасть до фиксации прогресса, поэтому downstream обязан переносить дубликаты. Kafka Connect умеет сузить это окно транзакционной записью source records вместе с offsets, но не делает атомарным внешний downstream-эффект. CDC не даёт end-to-end `exactly once`; его лаг и удержание журнала становятся частью эксплуатационного контракта.

## Область применимости

Заметка описывает outbox с log-based CDC на примере PostgreSQL 18.4 logical decoding и Debezium 3.6.0.Final Outbox Event Router. Концепция применима и к polling publisher. Здесь не разбираются настройка replication, connector security и broker cluster.

## Ментальная модель

Обычный dual write пытается согласовать две независимые системы:

```text
BEGIN DB -> UPDATE order -> COMMIT DB -> PUBLISH broker
```

Crash после `COMMIT`, но до `PUBLISH` оставляет новое состояние без события. Если поменять шаги местами, consumer увидит событие о транзакции, которая затем могла откатиться. Без общего transaction coordinator атомарного порядка для двух ресурсов нет.

Outbox заменяет вторую внешнюю запись локальной:

```text
BEGIN DB
  UPDATE order
  INSERT outbox(event_id, aggregate_id, type, payload)
COMMIT DB
        |
        +-> CDC/relay -> broker -> consumer inbox/effect
```

Главный инвариант: бизнес-состояние и outbox event видимы вместе после одного commit или не видимы вовсе после rollback. Публикация остаётся отдельным, повторяемым этапом.

## Как это устроено

### Контракт outbox row

Запись обычно содержит:

- уникальный `event_id` для дедупликации;
- `aggregate_type` и `aggregate_id`;
- стабильный event type и schema version;
- payload бизнес-события;
- метаданные корреляции и время возникновения.

Debezium Outbox Event Router ожидает по умолчанию поля `id`, `aggregatetype`, `aggregateid`, `type`, `payload`. `aggregateid` используется как message key, что помогает сохранить порядок изменений одного агрегата в одной Kafka partition. Это convention конкретного transform, а не обязательная схема паттерна.

Outbox — append-only журнал намерений. Update существующего event меняет уже опубликованный факт и усложняет recovery. Debezium Outbox Event Router ожидает `INSERT`, автоматически фильтрует `DELETE`, а `UPDATE` передаёт в обработку invalid operation; при `table.op.invalid.behavior=warn` по умолчанию connector пишет предупреждение и продолжает, также доступны `error` и `fatal`. Очистку проводят отдельно после достаточного retention, не переписывая payload.

### Атомарная запись

Код агрегата формирует событие из того же решения, которое меняет данные, и вставляет его в той же транзакции. Нельзя поручать это callback-у «после commit»: crash в callback вернёт исходную проблему. Событие должно описывать подтверждённый бизнес-факт, а не сырое изменение каждой колонки.

Transaction commit задаёт порядок событий, который видит WAL, но бизнес-порядок лучше связывать с `aggregate_id` и при необходимости с монотонной версией агрегата. Глобального порядка между независимыми агрегатами обычно нет и не требуется.

### Relay: polling или CDC

Polling publisher выбирает неопубликованные rows, арендует batch, отправляет его и отмечает прогресс. Он прост и прозрачен, но создаёт polling load, требует индексов/cleanup и имеет окно дубликата между publish и отметкой.

Log-based CDC читает журнал транзакций. В PostgreSQL logical decoding преобразует WAL во внешний поток через output plugin, а replication slot хранит позицию consumer. Debezium преобразует insert в outbox в broker event, не заставляя приложение опрашивать таблицу.

CDC снижает polling и сохраняет commit order журнала, но добавляет connector и зависимость от внутреннего change log. Replication slot удерживает WAL и нужные catalog rows, пока consumer отстаёт или отключён. Заброшенный slot способен заполнить диск; лаг, retained WAL и состояние connector надо мониторить как производственные ресурсы.

### Доставка и дедупликация

В общем случае relay не фиксирует broker publish и свою позицию одной транзакцией. При at-least-once конфигурации возможен порядок:

1. событие принято broker;
2. relay падает до продвижения offset;
3. после рестарта та же outbox row публикуется снова.

Kafka Connect source EOS — ограниченное исключение. Для Debezium 3.6 Kafka Connect должен работать в distributed mode, а `transaction.boundary` должен быть `poll` (значение по умолчанию). У workers включают `exactly.once.source.support=enabled`, у connector требуют `exactly.once.support=required`. Тогда source records и source offsets записываются в Kafka одной транзакцией, а устаревшие поколения tasks блокируются механизмом fencing. `read_committed` consumer не выдаёт records из aborted transaction, но `read_uncommitted` — это default Kafka consumer — может их прочитать; физическое наличие record в log не равно exactly-once наблюдаемому эффекту. Механизм не объединяет транзакцию исходной PostgreSQL, Kafka и внешней БД consumer. Debezium 3.6 также предупреждает о неполно исследованных edge cases Kafka transactions, поэтому `event_id` остаётся полезной защитой и частью контракта.

Поэтому consumer сохраняет `event_id` в inbox с уникальным ограничением в той же транзакции, где применяет эффект. Это тот же принцип, что у [[20 Бэкенд/Ключи идемпотентности и дедупликация запросов|дедупликации запросов]], но область ключа — consumer и событие, а не API principal и операция. Семантика ack/offset после эффекта раскрыта в [[40 Распределённые системы/Очереди, streams, группы потребителей и DLQ|заметке об очередях и streams]].

### Schema и наблюдаемость

Outbox event — внешний контракт. Переименование колонки бизнес-таблицы не должно неявно ломать consumers; payload версионируют и меняют совместимо. Полезные метрики: возраст старейшей неопубликованной row, разница WAL/connector offset, publish errors, доля повторов, размер outbox и объём WAL, удерживаемый slot.

## Сквозной пример: `OrderConfirmed`

Сервис заказов подтверждает `order_id=42`.

1. Одна транзакция меняет `orders.status` на `confirmed` и вставляет outbox row `event_id=e-42`, `aggregateid=42`, `type=OrderConfirmed`, `schema_version=1`.
2. При rollback не видно ни нового статуса, ни `e-42`. При commit видны оба.
3. Debezium читает закоммиченный insert из WAL и публикует `e-42` с ключом `42`.
4. В показанной at-least-once конфигурации broker принимает событие, после чего connector падает до сохранения своей позиции. После restart он публикует `e-42` повторно. При корректно включённом Kafka Connect source EOS запись события и offset была бы общей Kafka-транзакцией: `read_committed` consumer не увидел бы record из aborted попытки, тогда как `read_uncommitted` всё ещё мог бы его выдать.
5. Billing consumer в первой доставке создаёт invoice и атомарно вставляет `e-42` в inbox. Во второй доставке уникальный inbox key уже существует, поэтому второй invoice не создаётся.

Наблюдаемый результат: commit заказа не зависит от доступности broker. Событие догонит его после восстановления connector, только пока replication slot сохранён и нужный WAL доступен; возможный повтор не удвоит downstream-эффект. Если slot потерян или PostgreSQL уже не хранит LSN, connector не может продолжить с offset: нужны новый snapshot или сверка с сохранённым outbox, а не слепой restart. При длительном outage растут outbox/retained WAL и lag — это backpressure на хранение, а не бесплатный буфер.

## Trade-offs и альтернативы

### Outbox event или raw CDC

Raw CDC быстро экспортирует изменения существующих таблиц, но связывает consumers с физической схемой и row-level операциями. Один бизнес-факт может выглядеть как несколько технических updates, а смысл delete или промежуточного состояния остаётся неявным. Outbox требует явного event contract и дополнительной таблицы, зато отделяет доменную семантику от внутренней модели хранения.

### Polling publisher или log-based CDC

Polling проще внедрить и отладить при умеренном потоке; приложению доступны обычные транзакции и SQL. CDC обычно даёт меньшую задержку и не сканирует таблицу, но требует replication privileges, совместимого WAL, connector operations и контроля retention. В обоих вариантах publish в общей at-least-once схеме может повториться; Kafka Connect source EOS сужает это утверждение только до поддерживаемой транзакционной границы Kafka.

### Outbox или распределённая транзакция

Двухфазный commit может дать атомарность между поддерживающими его ресурсами, но связывает их availability, усложняет recovery и редко доступен для broker плюс SaaS API. Outbox выбирает локальную атомарность и eventual delivery. Цена — временное расхождение и обязательная идемпотентность consumers.

## Типичные ошибки

### Publish после commit в application callback

- **Неверное предположение:** callback обязательно выполнится.
- **Симптом:** состояние изменилось, но событие отсутствует.
- **Причина:** crash попал между локальным commit и внешней публикацией.
- **Исправление:** вставлять outbox row внутри исходной транзакции.

### Обещание end-to-end `exactly once`

- **Неверное предположение:** Kafka Connect source EOS делает всю бизнес-операцию exactly-once.
- **Симптом:** повторный invoice после restart consumer или неатомарного внешнего вызова.
- **Причина:** Connect может связать source record и source offset внутри Kafka, но внешняя БД или API consumer остаются в другом commit domain.
- **Исправление:** включать EOS там, где его граница полезна, и всё равно использовать стабильный `event_id`, inbox и идемпотентный effect для внешнего результата.

### Outbox как копия таблицы

- **Неверное предположение:** consumers восстановят бизнес-смысл из колонок.
- **Симптом:** внутренний refactoring ломает интеграции, появляются неоднозначные промежуточные события.
- **Причина:** внешний контракт совпал с persistence model.
- **Исправление:** публиковать named business events с версией schema.

### Неограниченный replication slot

- **Неверное предположение:** отключённый connector ничего не потребляет.
- **Симптом:** растёт WAL и заканчивается диск primary.
- **Причина:** slot удерживает журнал, нужный отставшему consumer.
- **Исправление:** alert по lag/retained WAL, capacity limit и процедура удаления действительно заброшенного slot.

## Когда применять

Outbox нужен, когда одна локальная транзакция должна надёжно породить сообщение, а атомарного commit с broker нет. CDC полезен, когда поток изменений велик, низкая задержка важна и команда готова эксплуатировать replication pipeline. Для редких внутренних задач polling publisher может быть дешевле и понятнее.

До внедрения фиксируют event owner, schema policy, partition key, дедупликацию consumer, допустимый lag, cleanup и восстановление connector. Без этих решений паттерн переносит проблему из dual write в невидимый backlog.

## Источники

- [Outbox Event Router](https://debezium.io/documentation/reference/3.6/transformations/outbox-event-router.html) — Debezium, версия 3.6.0.Final, проверено 2026-07-18.
- [Exactly once delivery](https://debezium.io/documentation/reference/3.6/configuration/eos.html) — Debezium, версия 3.6.0.Final, Kafka Connect source EOS и его ограничения, проверено 2026-07-18.
- [Exactly-once support](https://kafka.apache.org/43/kafka-connect/user-guide/#exactly-once-support) — Apache Kafka, Kafka Connect 4.3, транзакционная граница source records и offsets, проверено 2026-07-18.
- [Kafka Connect worker configuration](https://kafka.apache.org/43/configuration/kafka-connect-configs/#connectconfigs_exactly.once.source.support) — Apache Kafka, документация 4.3, настройка source EOS на workers, проверено 2026-07-18.
- [Kafka Connect source connector configuration](https://kafka.apache.org/43/configuration/kafka-connect-configs/#sourceconnectorconfigs_exactly.once.support) — Apache Kafka, документация 4.3, настройка source EOS connector, проверено 2026-07-18.
- [Kafka consumer `isolation.level`](https://kafka.apache.org/43/configuration/consumer-configs/#consumerconfigs_isolation.level) — Apache Kafka, документация 4.3, default `read_uncommitted` и поведение `read_committed`, проверено 2026-07-18.
- [Debezium connector for PostgreSQL](https://debezium.io/documentation/reference/3.6/connectors/postgresql.html) — Debezium, версия 3.6.0.Final, восстановление по LSN и replication slot, проверено 2026-07-18.
- [Debezium 3.6 Release Series](https://debezium.io/releases/3.6/) — Debezium, релиз 3.6.0.Final от 2026-07-01, проверено 2026-07-18.
- [Logical Decoding Concepts](https://www.postgresql.org/docs/18/logicaldecoding-explanation.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Logical Decoding Examples](https://www.postgresql.org/docs/18/logicaldecoding-example.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
