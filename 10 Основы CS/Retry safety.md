---
aliases:
  - Retry safety
  - Безопасность повторов
  - Безопасный retry
tags:
  - область/основы-cs
  - тема/надёжность
  - механизм/retry
статус: проверено
---

# Retry safety

## TL;DR

Ошибка, похожая на временную, ещё не делает retry безопасным. Перед повтором одновременно проверяют четыре вещи: семантику операции, возможность воспроизвести request, точку отказа и определённость outcome, остаток общего deadline. Если хотя бы одна неизвестна, автоматический retry превращается в риск дубликата или в заведомо бесполезную нагрузку.

`Safe`, `idempotent` и `exactly-once` — разные свойства. Safe HTTP method выражает read-only intent клиента. Idempotent operation допускает повтор с тем же intended effect, но ответы и побочные наблюдения могут различаться. Ни одно из этих свойств само по себе не даёт system-wide exactly-once: для неидемпотентного эффекта нужны [[20 Бэкенд/Ключи идемпотентности и дедупликация запросов|ключ, fingerprint и атомарная дедупликация]] либо доменный способ узнать результат первой попытки.

## Область применимости

- HTTP-семантика и автоматические повторы соответствуют RFC 9110; точные сигналы «request не обработан» — HTTP/2 RFC 9113 и HTTP/3 RFC 9114, все опубликованы в июне 2022 года.
- Заметка отвечает именно на вопрос «можно ли повторить этот outcome». Алгоритмы backoff, jitter, attempt limits и retry budget подробно раскрыты в [[40 Распределённые системы/Retry, exponential backoff и jitter|заметке о retry policy]].
- Доменное проектирование операций разобрано в [[20 Бэкенд/Идемпотентные и неидемпотентные операции|идемпотентных и неидемпотентных операциях]].
- Вне scope: redelivery сообщений, workflow retries длиной в часы и API конкретного SDK.

## Ментальная модель

Retry — новая физическая попытка той же логической операции. Между попытками первая уже могла изменить мир, даже если caller не получил response.

Полезен последовательный gate:

```text
1. Semantics: повтор того же намерения допустим?
2. Replayability: request можно воспроизвести по тому же контракту?
3. Outcome: доказано «не применено», известен retriable result или эффект неоднозначен?
4. Budget: хватает времени и retry capacity на паузу, попытку и ответ?

Только четыре «да» -> retry
```

Сводить эти проверки к вопросу «status входит в список?» нельзя. Один и тот же transport reset безопасен до отправки request и неоднозначен после durable commit. Один и тот же `POST` может быть защищён idempotency key в одном API и создавать новый объект при каждом вызове в другом.

Главные инварианты:

1. Retryable transport/protocol outcome не меняет бизнес-семантику операции.
2. Idempotency не означает read-only и не обещает одинаковый response.
3. Timeout после передачи request означает **unknown outcome**, пока протокол или application contract не докажет обратное.
4. Все attempts, backoff и queueing живут внутри исходного [[20 Бэкенд/Дедлайны запросов и распространение отмены|deadline]].
5. В цепочке retries должен владеть один осознанный слой; независимые политики перемножают нагрузку.

## Как устроено

### 1. Семантика операции

RFC 9110 называет `GET`, `HEAD`, `OPTIONS` и `TRACE` safe methods: клиент не просит сервер изменить состояние. Safe methods также idempotent. `PUT` и `DELETE` idempotent, хотя изменяют состояние: intended effect нескольких одинаковых requests должен совпадать с эффектом одного. Логи, метрики, billing за request и разные response codes этому не противоречат, потому что свойство относится к запрошенной семантике.

HTTP method — только начало контракта. `GET /next-sequence` с необратимым выделением номера нарушает safe intent, а `POST /payments` может стать повторяемым для конкретного клиента при обязательном idempotency key. Автоматический proxy не должен угадывать такой скрытый контракт по status code.

RFC 9110 разрешает автоматический retry non-idempotent request только когда client дополнительно знает, что операция фактически idempotent, либо способен доказать, что исходный request не был применён. Proxy не должен автоматически повторять non-idempotent request.

### 2. Replayability request

Даже семантически допустимую операцию нельзя повторить, если request невозможно снова сформировать. Небольшой body можно буферизовать; seekable file — перемотать; детерминированную команду — сериализовать заново. One-shot stream, уже прочитанный pipe или upload без local copy не replayable.

Replay сохраняет логическую операцию: тот же idempotency key, fingerprint и domain identifiers. Transport metadata иногда приходится пересоздать — например, заново подписать request или получить актуальный credential, — но это не должно превращать повтор в новую бизнес-команду. Буферизация большого body расходует память и задерживает streaming, поэтому replayability является отдельным trade-off, а не бесплатным свойством HTTP client.

### 3. Точка отказа и определённость outcome

Ошибки удобно делить не по названию exception, а по тому, что известно об application processing.

| Класс outcome | Примеры | Что известно | Правило |
|---|---|---|---|
| Доказанно не применено | DNS/connect failure до отправки request; HTTP/2 `REFUSED_STREAM`; stream выше `last-stream-id` в `GOAWAY`; HTTP/3 `H3_REQUEST_REJECTED` | Server application request не обработала | Можно пройти остальные gates даже для non-idempotent operation |
| Явный retriable response | `429`, `503`, gRPC status из согласованной policy | Response получен, но допустимость повтора задаёт API contract | Учитывать `Retry-After`/pushback и budget; code сам не даёт разрешения |
| Неоднозначно | Timeout/reset после отправки bytes; потерянный response; многие `502`/`504`; HTTP/3 `H3_REQUEST_CANCELLED` после возможной обработки | Effect мог произойти | Повторять только idempotent contract или с дедупликацией/reconciliation |
| Завершённый terminal result | Success, validation/authentication error, устойчивый domain conflict | Операция дала определённый результат | Не повторять без отдельного изменения input/state |

HTTP/2 и HTTP/3 дают редкие transport-level доказательства «не обработано». `REFUSED_STREAM` означает, что HTTP/2 stream не был обработан; `GOAWAY` сообщает последний stream, который peer мог обработать. В HTTP/3 `H3_REQUEST_REJECTED` также означает отсутствие application processing. Это сильнее обычного connection reset, где граница потеряна.

`Retry-After` отвечает «как долго желательно подождать», но не отвечает «можно ли повторять операцию». RFC 6585 разрешает передавать его с `429`; RFC 9110 — с `503` и redirect responses. Если ожидание не помещается в deadline, корректное решение — не retry, а возврат контролируемого отказа.

### 4. Общий временной бюджет и retry budget

Перед попыткой проверяют:

```text
remaining > planned_backoff + minimum_useful_attempt + response_reserve
```

Backoff должен быть interruptible cancellation и содержать jitter. Retry budget ограничивает долю добавочных attempts, особенно когда failures массовые. Когда зависимость уже перегружена, немедленные повторы конфликтуют с [[40 Распределённые системы/Load shedding|load shedding]] и удерживают breaker в плохом состоянии; [[40 Распределённые системы/Circuit breaker|circuit breaker]] нужен для быстрого локального отказа, а не для разрешения новых retries.

Если каждый из `L` слоёв делает до `A` **общих** attempts, один входящий request в худшем случае порождает `A^L` downstream attempts. Три слоя по три attempts дают 27 обращений к последней зависимости. Этот механизм и способы остановить положительную обратную связь разобраны в [[40 Распределённые системы/Retry storms и cascading failures|retry storms и cascading failures]].

### Где должен жить retry

Семантический владелец операции лучше всего знает idempotency, key retention, replayability body и общий deadline. Низкий transport может автоматически повторить случай, где протокол **доказывает**, что server application request не видела. L7 proxy может выполнить retry только при явном route/API contract; список `5xx` без семантики недостаточен.

gRPC различает transparent retry и configured retry policy. До получения response headers библиотека может восстановить отдельные низкоуровневые случаи, где request не дошёл до application; после headers RPC считается committed для механизма retry. Это правило конкретного protocol stack, а не доказательство exactly-once бизнес-эффекта.

### Наблюдаемость

Один trace должен связывать logical operation ID, idempotency key и отдельный attempt ID. Для каждого attempt записывают номер, endpoint, failure phase, bytes sent, protocol signal, response headers received, классификацию outcome, remaining deadline, backoff, причину `retry_allowed` или `retry_suppressed`.

Итоговая client latency и upstream attempt latency — разные величины. Отдельно считают retries per original request, dedup hits, exhausted budget, server pushback, attempts после cancellation и amplification по слоям. Без этого «успех после retry» маскирует деградацию зависимости.

## Пример или трассировка

Client отправляет:

```text
POST /payments
Idempotency-Key: pay-7f4c

{"order_id":"o-42","amount":1000,"currency":"RUB"}
```

Body сохранён и replayable; server атомарно связывает key с fingerprint и результатом.

1. Первый attempt полностью передан. Payment service фиксирует платёж, но connection reset происходит до response headers. Outcome для client неоднозначен: reset не доказывает rollback.
2. Gate даёт: операция non-safe, но contract с key делает повтор того же намерения допустимым; body воспроизводим; unknown outcome покрыт дедупликацией; в deadline осталось 700 ms.
3. После jittered backoff client повторяет request с тем же key и fingerprint. Server находит completed record и возвращает сохранённый payment result без второго списания.
4. Если бы body отличался, server обязан вернуть conflict/mismatch, а не связать key с другой командой. Если бы ключа не было, безопасный client вернул бы `outcome unknown` и предложил status lookup/reconciliation вместо слепого POST.

Для контраста: если первый HTTP/2 attempt получил `REFUSED_STREAM` до обработки, protocol уже доказал отсутствие application effect. Такой request можно повторить при replayable body и достаточном budget даже без idempotency key; защита от дубликата в этом конкретном failure point не нужна.

## Trade-offs

Fail-fast сохраняет capacity и не рискует дубликатом, но превращает краткий transient failure в пользовательскую ошибку. Retry повышает вероятность успеха, зато увеличивает latency и load именно в момент деградации. Решение зависит не от общей «надёжности», а от доказуемой семантики и remaining budget.

Буферизация делает body replayable и упрощает failover, но добавляет memory/disk I/O, задерживает first byte и ограничивает большие streams. Streaming без буфера экономит ресурсы и latency, но после частичной передачи часто оставляет только reconciliation.

Retry в client ближе к бизнес-контракту и end-to-end deadline. Retry в proxy централизует policy и может выбрать другой endpoint, однако хуже знает side effects и рискует скрыть число attempts. Transport-level retry приемлем для строго доказанных «not processed» случаев.

## Типичные ошибки

### Повторяют любой `5xx` или timeout

- **Неверное предположение:** transient-looking status означает, что effect не произошёл.
- **Симптом:** duplicated writes после `502`, `504` или lost response.
- **Причина:** proxy сообщил о проблеме доставки ответа, но upstream уже мог зафиксировать операцию.
- **Исправление:** классифицировать failure point и ambiguous outcome; требовать idempotent contract, key или reconciliation.

### Идемпотентность считают одинаковым ответом

- **Неверное предположение:** повтор idempotent request обязан вернуть тот же status и body.
- **Симптом:** корректный `DELETE` с последующим `404` объявляют нарушением идемпотентности.
- **Причина:** RFC определяет одинаковый intended effect, а не byte-identical responses.
- **Исправление:** проверять итоговое состояние и отдельно проектировать replay результата, если клиенту нужен стабильный response.

### Idempotency key меняют при каждом attempt

- **Неверное предположение:** ключ идентифицирует сетевой request, а не логическую операцию.
- **Симптом:** server честно создаёт несколько эффектов для нескольких уникальных keys.
- **Причина:** retry выглядит для dedup store как новая команда.
- **Исправление:** сохранять один key и fingerprint на весь lifecycle логической операции; новый key выдавать только новой операции.

### Replayability проверяют после failure

- **Неверное предположение:** любой body можно прочитать второй раз.
- **Симптом:** retry уходит с пустым/частичным payload или вообще не стартует после upload reset.
- **Причина:** one-shot stream уже потреблён, а buffering/regeneration не были частью контракта.
- **Исправление:** выбрать стратегию replay до первой отправки и ограничить размер буфера.

### Retry включён на каждом hop

- **Неверное предположение:** несколько локальных политик независимо повышают надёжность.
- **Симптом:** один request создаёт десятки downstream attempts и продлевает outage.
- **Причина:** attempt limits перемножаются, а каждый слой видит лишь локальную ошибку.
- **Исправление:** назначить одного владельца retries, передавать attempt metadata и применять общий time/retry budget.

### `Retry-After` трактуют как приказ

- **Неверное предположение:** наличие header автоматически делает operation retryable.
- **Симптом:** client повторяет non-idempotent request либо ждёт дольше пользовательского deadline.
- **Причина:** server hint о времени смешали с семантическим разрешением.
- **Исправление:** сначала пройти semantics/outcome gates, затем проверить, помещается ли suggested delay в remaining budget.

## Когда применять

Gate нужен в HTTP/RPC clients, SDK, reverse proxies и service mesh перед любой автоматической политикой повтора. Для каждого retry rule должны быть явно записаны operation class, replay strategy, retriable outcomes, ambiguous-outcome handling, maximum attempts, owner layer и общий deadline.

На review полезен один вопрос: «Каким доказательством мы располагаем после failure?» Если ответ сводится к названию exception или к `5xx`, информации недостаточно. Нужна связь с точкой обработки request и бизнес-инвариантом эффекта.

## Источники

- [RFC 9110 — HTTP Semantics: safe and idempotent methods, retries, Retry-After](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RFC 9113 — HTTP/2: GOAWAY and REFUSED_STREAM](https://www.rfc-editor.org/rfc/rfc9113.html) — IETF, RFC 9113, июнь 2022, проверено 2026-07-18.
- [RFC 9114 — HTTP/3: request cancellation and rejection](https://www.rfc-editor.org/rfc/rfc9114.html) — IETF, RFC 9114, июнь 2022, проверено 2026-07-18.
- [RFC 6585 — Additional HTTP Status Codes: 429](https://www.rfc-editor.org/rfc/rfc6585.html) — IETF, RFC 6585, апрель 2012, проверено 2026-07-18.
- [Retry](https://grpc.io/docs/guides/retry/) — gRPC Authors, официальное руководство, обновлено 2025-11-26, проверено 2026-07-18.
- [Route components: retry policy](https://www.envoyproxy.io/docs/envoy/v1.38.3/api-v3/config/route/v3/route_components.proto.html) — Envoy Project, API Envoy 1.38.3, проверено 2026-07-18.
- [Timeouts, retries, and backoff with jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/) — Amazon Web Services, Builders' Library, онлайн-публикация, проверено 2026-07-18.
