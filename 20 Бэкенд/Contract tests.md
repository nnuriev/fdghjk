---
aliases:
  - Contract testing
  - Контрактные тесты
tags:
  - область/бэкенд
  - тема/тестирование
статус: проверено
---

# Contract tests

## TL;DR

Contract test проверяет совместимость двух независимо изменяемых участников на их observable boundary: может ли consumer отправить сообщение в понятной provider форме и получить минимально необходимый результат. Он быстрее и точнее локализует несовместимость, чем полный end-to-end test, потому что стороны не обязаны одновременно работать в одной среде.

Контракт — это не только JSON schema. Для HTTP в него входят method, path, значимые headers и query parameters, request/response body, status и error semantics. Для сообщений — channel, payload, headers, key/correlation metadata и поддерживаемые interaction patterns. Delivery, ordering и бизнес-эффект всей цепочки остаются за пределами одного contract test.

## Область применимости

Заметка охватывает HTTP/RPC и message-driven границы между сервисами, SDK и внешними clients. В качестве фиксированных спецификаций используются OpenAPI 3.2.0, AsyncAPI 3.1.0 и Pact Specification v4, проверенные 2026-07-18.

Семантика совместимости API и rollout подробнее разобрана в [[20 Бэкенд/Контракты API и обратная совместимость|заметке о backward compatibility]]. Здесь главный вопрос другой: как превратить этот контракт в автоматическое доказательство для конкретных consumer/provider versions.

## Ментальная модель

Contract test — это двусторонний compatibility check, а не тест одной копии ожиданий:

```text
consumer test -> versioned contract -> provider verification
          \             |                  /
           request need | actual behavior /
```

Consumer доказывает, что его production serializer/parser работает с записанным interaction. Provider затем воспроизводит тот же request против своей production boundary и доказывает, что выдаёт совместимый response. Только обе половины связывают ожидание consumer с реальным поведением provider.

У contract test есть более общий provider-driven вариант: versioned OpenAPI/AsyncAPI document служит source of truth, а реализация и clients проверяются на соответствие ему. Consumer-driven contract (CDC) отличается тем, что фиксирует только реально используемое конкретным consumer подмножество поведения. Эти подходы дополняют друг друга.

## Как устроено

### Зафиксировать границу и владельцев

Для каждой пары указывают:

- стабильные имена consumer и provider;
- version/revision обоих artifacts;
- transport и direction взаимодействия;
- provider states, необходимые для воспроизведения;
- matching rules и значимую семантику;
- место публикации contract и verification results;
- policy, какие комбинации версий разрешено deploy.

Contract artifact без результатов provider verification — только заявление consumer. Verification без привязки к версиям не отвечает, можно ли безопасно выпустить конкретную сборку.

### Проверить consumer production path

Consumer test вызывает production client/serializer против controllable contract server, а не вручную формирует JSON рядом с assertion. Он задаёт минимальный response, который действительно нужен application behavior, и затем проверяет, что production parser приводит его к ожидаемому результату.

Необязательные значения сопоставляют по типу или допустимому диапазону, dynamic IDs — matcher, а не случайной exact строкой. Exact значение оставляют, когда оно само несёт семантику: enum, error code, version header или idempotency result.

### Воспроизвести contract на provider

Verifier поднимает production provider boundary, переводит его в объявленный provider state и повторяет interactions. Downstream dependencies provider можно заменить, если они не входят в проверяемый контракт: цель — отделить несовместимость boundary от чужой доступности.

Provider state должен описывать бизнес-предусловие (`user 42 has plan pro`), а не SQL implementation. Setup выполняется отдельно для interaction, чтобы порядок tests и остаточные данные не влияли на результат.

### Проверять обе стороны совместимости

Для request consumer обязан быть достаточно строг: provider не должен угадывать потерянные required fields. Для response consumer обычно должен игнорировать неизвестные дополнительные поля, если его protocol это допускает. Но универсального правила «additive всегда безопасно» нет: strict parser, enum expansion, changed default или новая обязательная ветка могут сломать consumer.

Schema проверяет форму, но не всю семантику. OpenAPI 3.2.0 позволяет описать операции и data shapes, однако application semantics всё равно должна быть выражена prose/constraints и executable examples. Поэтому `amount: number` не доказывает currency units, sign rule или rounding.

Для asynchronous API contract включает producer и consumer view сообщения. AsyncAPI описывает applications, channels, operations, messages и protocol bindings, но сам документ не доказывает, что broker доставил событие, consumer применил его ровно в допустимой semantics или workflow завершился. Это проверяют integration/end-to-end scenarios.

### Принять release decision по matrix

Перед deploy provider `P2` проверяют contracts всех ещё поддерживаемых consumers, а перед deploy consumer `C2` — наличие успешной verification на provider version, которая реально будет доступна. Pact broker-подобный workflow хранит contract и verification results по версиям; gate отвечает на конкретный вопрос `C2 + P2 compatible?`, а не на абстрактное «последний build зелёный».

## Пример или трассировка

Consumer `billing-ui@17` использует provider `accounts-api`. Ему нужен сценарий:

```text
GET /users/42
-> 200 application/json
-> {"id":"42","plan":"pro"}
```

1. Consumer test вызывает production API client. Contract server возвращает два нужных поля, parser создаёт `UserPlan{id: 42, plan: pro}`, а interaction публикуется как contract `billing-ui@17 -> accounts-api`.
2. Provider verifier создаёт state `user 42 has plan pro`, отправляет `GET /users/42` в production handler `accounts-api@31` и сравнивает actual response с matchers contract.
3. Provider добавляет `"timezone":"UTC"`. Verification проходит, потому что consumer не объявлял отсутствие дополнительных response fields своим требованием.
4. Provider переименовывает `plan` в `tier`. Verification падает до deploy: `billing-ui@17` не получает обязательное для него поле.
5. Отдельный interaction `user 404 does not exist` фиксирует status и machine-readable error code. Он защищает [[20 Бэкенд/Валидация и модель ошибок API|error model]], а не только happy response.

Тест не утверждает, что база `accounts-api` доступна в production, login работает или UI показывает правильный текст. Он доказывает ровно compatibility этой пары versions на объявленных interactions.

## Trade-offs

Consumer-driven contracts защищают реально используемые interactions и не блокируют изменение неиспользуемой части provider API. Цена — инфраструктура публикации, version matrix и риск пропустить consumer, который не публикует contract. Provider/spec-driven suite охватывает весь объявленный API, но может закрепить endpoints, которыми никто не пользуется, и не доказывает, что production consumer формирует корректный request.

Schema compatibility дешёвая и хорошо работает как ранний gate. Executable contract by example проверяет production serialization и provider behavior, но покрывает только заданные states. Для rich state machine оба подхода дополняют model/property tests.

Contract tests уменьшают потребность собирать все сервисы одновременно, однако не видят emergent behavior: retries, auth configuration, routing, broker delivery, transaction boundaries и общий latency budget. Небольшое число end-to-end journeys остаётся необходимым.

## Типичные ошибки

- **Неверное предположение:** consumer mock сам по себе является contract test. **Симптом:** consumer suite зелёный, provider не принимает request. **Причина:** ожидание ни разу не проверялось на production provider boundary. **Исправление:** публиковать versioned artifact и запускать provider verification.
- **Неверное предположение:** валидный OpenAPI document доказывает implementation. **Симптом:** документация обещает поле или error, которого handler не выдаёт. **Причина:** проверена schema документа, а не conformance runtime. **Исправление:** проверять actual requests/responses against fixed specification и добавлять semantic interactions.
- **Неверное предположение:** exact example повышает строгость. **Симптом:** timestamp или generated ID ломает test без incompatibility. **Причина:** случайное значение принято за контракт. **Исправление:** использовать type/regex/range matcher, exact оставлять для semantic constants.
- **Неверное предположение:** additive response change всегда совместима. **Симптом:** strict consumer перестаёт декодировать ответ. **Причина:** compatibility оценена только с точки зрения provider schema. **Исправление:** проверять реальные поддерживаемые consumers и их parser policy.
- **Неверное предположение:** только успешные interactions важны. **Симптом:** clients по-разному обрабатывают `404`, validation и throttling. **Причина:** error shape остался неявным. **Исправление:** contract cases для значимых error classes, headers и retry semantics.
- **Неверное предположение:** «latest against latest» достаточно. **Симптом:** rolling deploy ломает старый consumer. **Причина:** не проверена coexistence matrix. **Исправление:** gate по конкретным deployed/supported versions и [[20 Бэкенд/Версионирование API|version policy]].

## Когда применять

Contract tests особенно полезны, когда consumer и provider выпускаются независимо, принадлежат разным командам или взаимодействуют через сеть/broker. Они также нужны для SDK, public API и webhook contracts, хотя внешний provider может не запускать ваш verifier: тогда source-of-truth specification и sandbox становятся доступной формой provider-driven проверки.

Внутри одного process и одного release unit shared typed API плюс unit/integration tests часто дают достаточно сигнала; отдельный broker contracts добавит ceremony без независимой compatibility problem.

## Источники

- [OpenAPI Specification 3.2.0](https://spec.openapis.org/oas/v3.2.0.html) — OpenAPI Initiative, OAS 3.2.0, проверено 2026-07-18.
- [AsyncAPI Specification 3.1.0](https://www.asyncapi.com/docs/reference/specification/v3.1.0) — AsyncAPI Initiative, specification 3.1.0, проверено 2026-07-18.
- [Pact Specification](https://docs.pact.io/getting_started/specification) — Pact Foundation, Pact Specification v4, проверено 2026-07-18.
- [How Pact works](https://docs.pact.io/getting_started/how_pact_works) — Pact Foundation, workflow consumer test и provider verification для Pact Specification v4, проверено 2026-07-18.
- [Verifying Pacts](https://docs.pact.io/getting_started/verifying_pacts) — Pact Foundation, provider verification и публикация результатов, Pact Specification v4, проверено 2026-07-18.
