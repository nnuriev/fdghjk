---
aliases:
  - Idempotency and deduplication
  - Идемпотентность и дедупликация
  - Idempotent consumer
tags:
  - область/распределённые-системы
  - тема/доставка-сообщений
  - механизм/идемпотентность
статус: проверено
---

# Idempotency и deduplication

## TL;DR

**Idempotency** — свойство операции: повтор с тем же логическим намерением не меняет наблюдаемый результат после первого успешного применения. **Deduplication** — механизм: система узнаёт повтор по стабильному идентификатору и не запускает эффект заново либо возвращает сохранённый результат. Они дополняют друг друга, но не совпадают.

`PUT status=paid` может быть идемпотентным по состоянию, но повтор всё ещё способен дважды отправить email. Таблица dedup может увидеть одинаковый ID, но не спасёт, если эффект и отметка обработанности коммитятся раздельно. Рабочая гарантия требует определить identity, scope, payload equality, атомарную границу, retention и ответ на незавершённый первый вызов.

## Область применимости

Заметка охватывает retries в API, RPC и асинхронных consumers. Подробная схема HTTP endpoint разобрана в [[20 Бэкенд/Ключи идемпотентности и дедупликация запросов|заметке о ключах идемпотентности запросов]]; здесь акцент на end-to-end механизме между распределёнными компонентами.

На 2026-07-18 HTTP-заголовок `Idempotency-Key` не стандартизован как RFC: последний документ рабочей группы — истёкший Internet-Draft `draft-ietf-httpapi-idempotency-key-header-07`. Использовать header можно как прикладной контракт, но нельзя приписывать ему нормативные гарантии IETF RFC.

## Ментальная модель

Идемпотентность можно записать как `f(f(x)) = f(x)`, но в системе нужно уточнить наблюдателя. Повтор `set balance=100` оставит то же число, однако audit log, webhook и метрика могут измениться дважды. Поэтому практический вопрос звучит так:

> Какие эффекты считаются результатом операции и какая система обеспечивает, что для одного logical operation ID они фиксируются один раз?

Dedup store — журнал принятых решений:

```text
(scope, operation_id) -> payload_hash, state, result, expires_at
```

`scope` не даёт двум клиентам столкнуться одним ключом; `payload_hash` запрещает переиспользовать key с другим намерением; `state` отличает выполняющуюся попытку от завершённой; сохранённый `result` позволяет повтору получить тот же контрактный ответ.

## Как устроено

### Идентичность операции

Transport message ID, trace ID и business operation ID решают разные задачи. Broker вправе создать новый delivery tag при redelivery, trace меняется между пользовательскими попытками, а business ID должен пережить все retries. Хорошие примеры: `payment_attempt_id`, `order_id + transition`, `event_id + consumer_name`.

Ключ должен быть уникален только в явно заданном namespace. Для API это может быть `(tenant_id, endpoint, idempotency_key)`, для consumer — `(consumer_group, event_id)`. Глобальная таблица без scope создаёт ложные совпадения; слишком узкий scope пропускает реальный повтор.

Payload fingerprint защищает смысл ключа. Если повтор пришёл с тем же key, но другой суммой или получателем, сервер не должен молча вернуть старый успех: это конфликт контракта, обычно клиентская ошибка.

### State machine записи

Минимальная модель включает:

```text
ABSENT -> IN_PROGRESS -> SUCCEEDED(result)
                    \-> FAILED_RETRYABLE или FAILED_FINAL
```

Первый запрос атомарно захватывает key. Одновременный повтор видит `IN_PROGRESS` и либо ждёт ограниченное время, либо получает предсказуемый ответ «операция выполняется». После commit повтор получает сохранённый результат. Нельзя просто считать любое наличие key успехом: процесс мог упасть сразу после вставки.

`IN_PROGRESS` требует recovery. Lease/timeout позволяет другому worker продолжить, но старый worker может ожить; для неидемпотентного внешнего ресурса нужен fencing или тот же idempotency key на downstream. Иначе две попытки выполнят effect параллельно.

### Атомарность с бизнес-эффектом

Если dedup row и effect находятся в одной базе, их записывают одной транзакцией. Для consumer типичный inbox pattern:

```sql
BEGIN;
INSERT INTO inbox(consumer, event_id) VALUES ('billing', 'e7'); -- UNIQUE
UPDATE accounts SET balance = balance - 100 WHERE id = 42;
COMMIT;
```

При unique conflict handler понимает, что `e7` уже применён. В production код обязан различать конфликт именно целевого unique constraint и другие ошибки транзакции.

Если effect находится во внешнем API, локальная транзакция его не охватывает. Тогда downstream должен принять тот же operation ID и дедуплицировать у себя, либо система хранит workflow state и выполняет reconciliation. Локальная отметка `done` до вызова теряет effect при crash, после вызова — допускает повтор.

### Retention и забывание

Deduplication не бесплатна: число keys растёт. TTL выбирают не по средней задержке, а по максимальному поддерживаемому окну повторов, retention broker, ручному replay и сроку сетевых клиентов. После удаления key тот же повтор выглядит новой операцией.

Для необратимых операций полезно иметь бессрочный естественный business key, например уникальный `provider_charge_id`, или архив решений. Для высокочастотных, воспроизводимых events допустим bounded retention, если replay старше окна явно запрещён или меняет namespace.

### Идемпотентность по конструкции

Предпочтительнее выразить намерение как состояние или факт: `ensure subscription S is cancelled` вместо `toggle subscription`; `upsert version=8` вместо «применить следующую версию». Conditional update `WHERE version = 7` не применит изменение повторно и обнаружит несовпадение версии. Однако `0 rows affected` не различает собственный прежний успех и чужую конкурентную запись: для ответа клиенту всё ещё нужны operation ID или чтение результата.

Не всякая операция допускает такую форму. `send email`, `dispense cash` и вызов legacy API требуют dedup на стороне исполнителя или reconciliation по внешнему идентификатору.

## Пример или трассировка

Клиент отправляет `CreatePayment(key=k9, amount=500)` и не получает ответ.

1. Сервер атомарно создаёт `(merchant=17, key=k9, hash=H(500), state=IN_PROGRESS)`.
2. Он передаёт `k9` платёжному провайдеру как provider idempotency key.
3. Провайдер создаёт charge `ch-81`, но ответ серверу теряется. Сервер падает, локальная запись остаётся `IN_PROGRESS`.
4. Клиент повторяет тот же запрос. Worker видит истёкший owner lease, спрашивает провайдера по `k9`, находит `ch-81` и сохраняет `SUCCEEDED(ch-81)`.
5. Следующий повтор получает тот же result. Запрос `key=k9, amount=700` отклоняется из-за другого payload hash.

Если provider не поддерживает стабильный ключ или lookup, локальная система не способна различить «charge создан, ответ потерян» и «charge не создан». Обещание effectively-once для этого вызова было бы ложным.

## Trade-offs

Чисто идемпотентная операция требует меньше дополнительного состояния, но её наблюдаемые side effects всё равно нужно проверить. Dedup table работает для произвольного handler, зато добавляет storage, contention на hot keys, cleanup и recovery `IN_PROGRESS`.

Уникальный business key обычно надёжнее случайного клиентского key, когда сама предметная область даёт естественную идентичность. Клиентский key полезен для нескольких допустимых одинаковых операций, например двух платежей одной суммы, но требует scope и payload fingerprint.

Координация через lock сериализует попытки, однако после crash lock не доказывает, выполнен ли effect. Durable decision record и downstream identity важнее взаимного исключения.

## Типичные ошибки

- **Неверное предположение:** HTTP `POST` по определению выполняется один раз. **Симптом:** пользовательский retry создаёт два заказа. **Причина:** метод не является идемпотентным по RFC, а сервер не ввёл logical key. **Исправление:** явный operation ID и атомарная фиксация результата.
- **Неверное предположение:** одинаковый key всегда означает одинаковый запрос. **Симптом:** новая сумма получает старый payment result. **Причина:** payload не сверяется. **Исправление:** сохранять fingerprint значимых полей и отклонять несовпадение.
- **Неверное предположение:** вставка dedup row до эффекта решает crash. **Симптом:** key помечен обработанным, но бизнес-состояние не изменилось. **Причина:** два независимых commit. **Исправление:** одна транзакция либо recoverable state machine и reconciliation.
- **Неверное предположение:** TTL можно взять «сутки» без связи с replay. **Симптом:** недельный replay повторяет старые эффекты. **Причина:** dedup state уже удалён. **Исправление:** согласовать TTL с полным retry/replay contract или использовать постоянный business key.

## Когда применять

Проектируйте идемпотентность до включения автоматических retries. Для каждого effect зафиксируйте logical ID, namespace, equality payload, owner первой попытки, commit boundary, поведение `IN_PROGRESS`, retention и downstream contract.

Если effect обратим и редок, допустимы at-least-once плюс ручная reconciliation. Для денег, inventory и необратимых внешних действий key и точка дедупликации должны находиться как можно ближе к реальному ресурсу, который меняется.

## Источники

- [RFC 9110, § 9.2.2 Idempotent Methods](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.2.2) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [The Idempotency-Key HTTP Header Field](https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/07/) — IETF HTTPAPI Working Group, Internet-Draft `-07`, опубликован 2025-10-15, срок действия истёк 2026-04-18, проверено 2026-07-18; не является RFC.
- [Implementing Remote Procedure Calls](https://birrell.org/andrew/papers/ImplementingRPC.pdf) — Andrew D. Birrell и Bruce Jay Nelson, ACM TOCS 2(1), 1984, проверено 2026-07-18.
- [PostgreSQL 18: Unique Constraints](https://www.postgresql.org/docs/18/ddl-constraints.html#DDL-CONSTRAINTS-UNIQUE-CONSTRAINTS) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Message Delivery Semantics](https://kafka.apache.org/43/design/design/#message-delivery-semantics) — Apache Kafka, документация 4.3, проверено 2026-07-18.
