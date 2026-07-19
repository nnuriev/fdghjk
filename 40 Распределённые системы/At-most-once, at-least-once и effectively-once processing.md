---
aliases:
  - At-most-once processing
  - At-least-once processing
  - Effectively-once processing
  - Семантики обработки сообщений
tags:
  - область/распределённые-системы
  - тема/доставка-сообщений
  - механизм/повторная-обработка
статус: проверено
---

# At-most-once, at-least-once и effectively-once processing

## TL;DR

После timeout отправитель не знает, потерялся запрос или только ответ. Отказ от retry ограничивает sender одной попыткой; end-to-end **at-most-once processing** дополнительно требует, чтобы transport не делал redelivery либо receiver дедуплицировал запрос. Повтор до `ack` при durable storage и eventual recovery даёт **at-least-once delivery**. Чтобы получить at-least-once business effect, receiver должен подтверждать сообщение только после durable effect и не прекращать recovery навсегда.

**Effectively-once processing** — не третья магическая доставка, а композиция: повторяемая at-least-once доставка плюс механизм, который делает повторно наблюдаемый бизнес-результат эквивалентным одному применению. Это может быть идемпотентная операция, inbox с уникальным `event_id`, атомарная запись эффекта вместе с маркером обработки или транзакции внутри явно очерченной системы. Граница гарантии важнее названия: Kafka transaction не делает exactly-once вызов произвольного внешнего API.

## Область применимости

Заметка разделяет транспортную доставку, выполнение handler и внешний бизнес-эффект. Термины в документации brokers нередко относятся только к records и offsets, а в RPC — к вызову процедуры. Поэтому любую гарантию нужно формулировать как: «какой объект, в какой системе и при каких сбоях наблюдается не более/не менее одного раза».

Современные детали Kafka сверены для Apache Kafka 4.3, RabbitMQ — для ветки 4.2, проверено 2026-07-18.

## Ментальная модель

Есть три разных события:

```text
producer sent -> broker/receiver accepted -> handler changed external state -> sender saw ack
```

Подтверждение может потеряться после любого уже выполненного шага. Отсутствие `ack` не доказывает отсутствие эффекта. Подтверждение тоже не всегда означает завершённый бизнес-эффект: consumer мог подтвердить message до commit своей базы.

Поэтому «ровно один раз» нельзя получить одним выбором retry policy. Нужно связать идентичность операции с точкой commit. Полезный инвариант effectively-once: для одного логического `operation_id` существует не более одного закоммиченного результата, а все повторы возвращают этот результат или безопасно продолжают незавершённую попытку.

## Как устроено

### At-most-once: потеря допустима, повторный эффект — нет

Простейшая sender policy — отправить один раз и не retry после неопределённого ответа. Тогда request может потеряться до выполнения: результат ноль раз. Но это гарантирует лишь одну попытку со стороны sender. Для at-most-once processing транспорт не должен повторно выдать запрос либо receiver должен дедуплицировать delivery: сеть, proxy или broker могут дублировать сообщение независимо от application retry.

RPC-система может улучшить модель, присваивая вызовам sequence number и кешируя ответы. Receiver отбрасывает повтор уже завершённого вызова и возвращает прежний ответ. Но кеш имеет scope и срок жизни; после его потери или переиспользования sequence number гарантия заканчивается. Crash между внешним эффектом и сохранением dedup record снова создаёт окно двойного эффекта, если эти записи не атомарны.

At-most-once разумен для telemetry, периодических snapshots и команд, где свежая следующая запись заменяет пропущенную. Он опасен для денежных списаний и обязательных workflow steps: отсутствие дубликата не компенсирует потерянную операцию.

### At-least-once: подтверждение управляет повтором

Sender сохраняет сообщение до `ack` и при timeout, reconnect или consumer crash доставляет снова. В очереди consumer обычно подтверждает сообщение только после успешного эффекта. Если он упал после commit эффекта, но до `ack`, broker выдаст тот же message повторно.

Гарантия «не менее одного» всегда условна: message должен пережить crash в durable storage, retry не должен прекратиться навсегда, а система должна когда-нибудь снова стать доступной. Dead-letter queue после конечного числа попыток превращает автоматическую гарантию в операционное обязательство: сообщение ещё существует, но эффект не завершён.

### Effectively-once: атомарная граница и стабильная идентичность

Есть несколько рабочих конструкций:

- операция математически или предметно идемпотентна, например `set status=closed`, а не `increment balance`;
- consumer в одной локальной транзакции вставляет `event_id` в inbox с уникальным ограничением и применяет эффект;
- state update и consumer offset коммитятся одной транзакцией в одном transaction domain;
- producer использует стабильный operation ID, а downstream хранит результат и возвращает его повтору.

Kafka transactions позволяют атомарно публиковать output records и обновлять consumed offsets в Kafka. `read_committed` consumers скрывают aborted records. Это даёт exactly-once processing для поддерживаемого контура Kafka input → transactional processing → Kafka output. Запись в PostgreSQL, отправка email или charge у платёжного провайдера не становятся частью Kafka transaction автоматически.

Аналогично [[40 Распределённые системы/Transactional outbox и Change Data Capture|transactional outbox]] атомарно связывает бизнес-commit с появлением outbox row, но relay может опубликовать row повторно. Для end-to-end результата всё равно нужен deduplication или идемпотентный consumer.

### Ack, commit и порядок восстановления

У consumer есть два опасных порядка:

```text
ack -> effect commit  # crash теряет эффект
effect commit -> ack  # crash создаёт повтор
```

Первый выбирает at-most-once обработку, второй — at-least-once. Чтобы получить effectively-once, второй порядок дополняют атомарным dedup marker. Если broker и база не участвуют в общей транзакции, duplicate delivery остаётся штатной частью протокола, а не исключением.

## Пример или трассировка

Consumer обрабатывает `DebitRequested(event_id=e7, account=42, amount=100)`.

1. Broker выдаёт `e7`; consumer начинает локальную транзакцию.
2. Он вставляет `(consumer=billing, event_id=e7)` в inbox с уникальным ключом и уменьшает баланс на 100 в той же транзакции.
3. Транзакция коммитится, но процесс падает до `ack`.
4. Broker повторно выдаёт `e7`. Новая вставка в inbox конфликтует с уникальным ключом, поэтому consumer не повторяет debit и отправляет `ack`.

Наблюдаемый баланс уменьшился один раз, хотя доставка была дважды. Если inbox вставили до debit в отдельной транзакции, crash между ними дал бы потерянный debit. Если debit выполнили раньше отдельной вставки inbox, crash дал бы двойное списание. Именно общая commit boundary, а не наличие таблицы `inbox`, создаёт гарантию.

Внешний платёжный API требует ещё одной границы: либо провайдер поддерживает тот же idempotency key, либо локальная транзакция не может атомарно доказать, был ли удалённый charge выполнен.

## Trade-offs

At-most-once проще по storage и latency, но переносит цену на пропуски. At-least-once сохраняет намерение, зато требует durable retry, контроля poison messages и защиты от повторов. Effectively-once уменьшает видимые дубликаты ценой стабильных IDs, дополнительного состояния, уникальных индексов, retention и более сложного recovery.

Глобальная распределённая транзакция может связать несколько ресурсов сильнее, но ухудшает автономность и доступность участников. Часто дешевле локально атомарный inbox/outbox и явное eventual completion, если бизнес допускает промежуточное состояние.

## Типичные ошибки

- **Неверное предположение:** timeout означает, что handler не запустился. **Симптом:** retry дважды списывает деньги. **Причина:** потерялся ответ после commit. **Исправление:** стабильный operation ID и атомарная дедупликация в точке эффекта.
- **Неверное предположение:** broker с exactly-once гарантирует один email или HTTP call. **Симптом:** внешний получатель видит дубликаты. **Причина:** внешний ресурс не входит в broker transaction. **Исправление:** назвать границу гарантии и обеспечить downstream idempotency либо reconciliation.
- **Неверное предположение:** `ack` можно отправить до commit ради throughput. **Симптом:** после crash message исчезает без результата. **Причина:** ownership передан broker до durable effect. **Исправление:** подтверждать после commit или атомарно связывать offset и state.
- **Неверное предположение:** dedup key можно хранить вечно без политики. **Симптом:** растёт таблица или старый key ошибочно принимается за новую операцию. **Причина:** не определены scope, payload fingerprint и retention. **Исправление:** формализовать namespace, срок повторов и правило повторного использования.

## Когда применять

At-most-once выбирают, когда свежесть важнее полноты и потерю можно измерить или восполнить. At-least-once — обычный выбор для бизнес-событий, которые нельзя тихо потерять. Effectively-once нужен, когда повторная доставка допустима инфраструктурно, но повторный бизнес-эффект недопустим.

На design review нужно выписать четыре вещи: логический ID, точку durable accept, точку business commit и поведение при crash между ними. Если хотя бы одна граница не названа, обещание `exactly once` непроверяемо.

## Источники

- [Implementing Remote Procedure Calls](https://birrell.org/andrew/papers/ImplementingRPC.pdf) — Andrew D. Birrell и Bruce Jay Nelson, ACM TOCS 2(1), 1984, проверено 2026-07-18.
- [Message Delivery Semantics](https://kafka.apache.org/43/design/design/#message-delivery-semantics) — Apache Kafka, документация 4.3, проверено 2026-07-18.
- [Kafka producer configurations: `enable.idempotence`](https://kafka.apache.org/43/configuration/producer-configs/#producerconfigs_enable.idempotence) — Apache Kafka, документация 4.3, проверено 2026-07-18.
- [Kafka consumer configurations: `isolation.level`](https://kafka.apache.org/43/configuration/consumer-configs/#consumerconfigs_isolation.level) — Apache Kafka, документация 4.3, проверено 2026-07-18.
- [Consumer acknowledgements and publisher confirms](https://www.rabbitmq.com/docs/4.2/confirms) — RabbitMQ, документация 4.2, проверено 2026-07-18.
- [RFC 9110, § 9.2.2 Idempotent Methods](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.2.2) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
