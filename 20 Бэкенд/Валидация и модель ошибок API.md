---
aliases:
  - Error model API
  - Валидация API
  - Problem Details
tags:
  - область/бэкенд
  - тема/api
статус: проверено
---

# Валидация и модель ошибок API

## TL;DR

Валидация идёт слоями: framing и media type, syntax, schema/types, cross-field domain invariants, authorization и current-state preconditions. Каждый слой отвечает на другой вопрос и должен завершиться до необратимого side effect. Предварительная проверка в application не заменяет database constraint, потому что между check и write остаётся race.

Error response разделяет machine contract и human explanation. HTTP/gRPC status задаёт общую категорию, стабильный `type` или domain code управляет логикой клиента, structured details указывают поля и retry context, а `detail/message` можно менять и локализовать. Клиент не должен разбирать текст ошибки.

## Область применимости

- HTTP Problem Details соответствует RFC 9457 от июля 2023 года, заменившему RFC 7807.
- HTTP status semantics соответствует RFC 9110 от июня 2022 года.
- Schema validation опирается на JSON Schema Draft 2020-12.
- gRPC model соответствует official status/error guides и AIP-193, проверенным 2026-07-18.
- GraphQL errors соответствует September 2025 Edition.
- Вне scope: UI-form validation, log aggregation и exception hierarchy конкретного языка.

## Ментальная модель

Request проходит несколько ворот. Первые отвечают «могу ли я разобрать bytes?», следующие — «соответствует ли message schema?», затем «разрешена ли такая команда в домене и текущем state?». Смешивать ворота в один `400 invalid request` удобно server, но client теряет способ исправить запрос или решить, нужен ли retry/read-refresh.

Error response — discriminated union на wire. Status выбирает широкую ветку, stable type/code — конкретный вариант, details несут typed parameters. Human-readable message остаётся для человека. Если branch строится по строке `"user already exists"`, любое исправление текста становится breaking change.

## Как устроено

### Слои validation

| Слой | Что проверяется | Типичный HTTP outcome |
| --- | --- | --- |
| Framing и limits | request line/headers/body size, content encoding | protocol error, `400`, `413` |
| Media type | поддерживается ли `Content-Type` | `415 Unsupported Media Type` |
| Syntax | один ли корректный JSON value, допустимы ли protobuf bytes | `400 Bad Request` |
| Schema/types | required fields, type, enum, shape, format policy | `400` или `422` по контракту |
| Domain invariant | range, cross-field relation, currency/state rule | обычно `422 Unprocessable Content` |
| Authentication/authorization | кто вызывает и что ему разрешено | `401`, `403` или concealment policy |
| Current state/precondition | version, uniqueness, transition, conflict | `409 Conflict`, `412 Precondition Failed` |
| Dependency/availability | временно ли server может выполнить корректный request | `500`, `502`, `503`, `504` |

`400` остаётся общей ошибкой запроса. `422` точнее сообщает: server понял media type и syntax, но не может обработать содержащиеся инструкции. Разделять их полезно, если client действительно меняет поведение; иначе единый документированный `400` лучше случайной классификации.

Validation должна происходить до side effect, но state-dependent invariant всё равно фиксирует authority хранения. Два concurrent requests могут оба пройти `SELECT ... WHERE key=?`, а затем вставить duplicate. Unique constraint или conditional write решает race; application преобразует constraint violation в стабильный domain error.

Точный порядок authentication, schema и domain checks зависит от transport и concealment policy. Principal стоит установить рано, а сведения о существовании resource и domain state нельзя возвращать до нужной authorization check; иначе различия error или timing становятся oracle.

На JSON-границе успешный parser ещё не доказывает valid request. Например, стандартный [[60 Go/Пакет encoding-json|`encoding/json`]] по умолчанию игнорирует unknown fields и может разобрать первый JSON value, оставив trailing data. Size limit, unknown-field policy, presence и domain validation задаются отдельно.

JSON Schema Draft 2020-12 также требует выбранной vocabulary policy. `format` разделён на annotation и assertion vocabularies, поэтому два validators могут по-разному относиться к `format: email`, если API не закрепил режим.

### Problem Details для HTTP

RFC 9457 задаёт media types `application/problem+json` и `application/problem+xml`. Основные members:

- `type`: URI identifier problem type; по нему ветвится client;
- `title`: краткое стабильное описание класса;
- `status`: HTTP status для удобства, согласованный с фактическим response status;
- `detail`: объяснение этого occurrence для человека;
- `instance`: URI конкретного occurrence, если policy позволяет;
- extension members: domain code, violations, retry metadata, correlation ID.

`type` должен оставаться стабильным и документированным. Он не обязан вести на HTML при каждом request, но dereferenceable documentation полезна. `detail` не используют как ключ, потому что текст меняется, локализуется и может скрываться по security policy.

Field violations удобно передавать массивом с JSON Pointer:

```json
{
  "type": "https://api.example.com/problems/validation",
  "title": "Request validation failed",
  "status": 422,
  "code": "VALIDATION_FAILED",
  "violations": [
    {"pointer": "/amount", "code": "required", "message": "amount is required"}
  ]
}
```

Extension names и semantics входят в API contract. Pointer ссылается на client-visible request representation, а не на Go struct или database column.

### gRPC и GraphQL

gRPC завершает RPC status code и description; richer model использует `google.rpc.Status` с `code`, `message` и typed `details`. AIP-193 рекомендует `google.rpc.ErrorInfo`: stable `reason`, `domain` и metadata. Client ветвится по code/reason, а не по message. Retry policy отдельно перечисляет retryable codes; `UNKNOWN` не означает «повторять всё».

GraphQL различает request errors и execution errors. При parse/validation request error execution не начинается и `data` отсутствует. Execution error записывается в `errors` с path; успешные sibling fields могут остаться в `data`. Ошибка non-null field распространяет `null` к ближайшему nullable parent. Core specification transport-agnostic и не выбирает HTTP status. В API, где HTTP mapping возвращает `200` для выполненной операции с field errors, этот код не доказывает полный GraphQL success: client разбирает `errors` и presence нужных fields. GraphQL-over-HTTP остаётся Stage 2 draft, поэтому конкретное transport behavior фиксируют в контракте сервиса.

Batch endpoint требует такой же явности. Atomic batch возвращает один failure и не применяет элементы. Partial batch возвращает outcome каждого item с устойчивой correlation identity. Скрывать несколько failures за общим `200 {success:true}` нельзя.

### Совместимость и безопасность error model

Error code/type и shape details подчиняются тем же правилам, что успешный response. Удаление code, смена retryability или обязательного metadata — [[20 Бэкенд/Контракты API и обратная совместимость|изменение контракта]]. Новые optional details безопасны только для readers, которые игнорируют unknown fields.

Error не должен раскрывать stack trace, SQL, filesystem path, secret, credential и existence ресурса вопреки authorization policy. Correlation ID связывает response с server logs, но сам не должен содержать внутренние данные. Для authentication/authorization порядок checks выбирают так, чтобы error и timing не превращались в oracle.

Retry hint обязан согласовываться с category. `Retry-After` у `503` или `429` помогает scheduling, но не делает non-idempotent operation безопасной для повтора. Ambiguous mutations требуют [[20 Бэкенд/Идемпотентные и неидемпотентные операции|operation identity]].

## Пример или трассировка

Client создаёт order без `amount`:

```http
POST /orders HTTP/1.1
Content-Type: application/json

{"currency":"RUB"}
```

JSON синтаксически корректен и media type поддерживается. Schema/domain validation не запускает write и отвечает:

```http
HTTP/1.1 422 Unprocessable Content
Content-Type: application/problem+json
X-Request-ID: req-91

{
  "type":"https://api.example.com/problems/validation",
  "title":"Request validation failed",
  "status":422,
  "code":"VALIDATION_FAILED",
  "violations":[
    {"pointer":"/amount","code":"required","message":"amount is required"}
  ]
}
```

Наблюдаемый результат: orders table не изменилась; client выбирает field по `pointer` и локализует UI по `code`, не разбирая английский `message`.

Тот же endpoint проходит contract table:

```text
malformed JSON                         -> 400 malformed-json
supported JSON, invalid domain field   -> 422 validation
stale If-Match                         -> 412 precondition-failed
duplicate current-state business key   -> 409 conflict
temporary unavailable dependency       -> 503 + Retry-After
```

Tests проверяют фактический HTTP status, `application/problem+json`, stable type/code/pointers, отсутствие stack/secret и нулевое число writes для всех pre-execution failures.

## Trade-offs

- Разделение `400`, `415`, `422`, `409` и `412` даёт client точную реакцию. Слишком тонкая недокументированная taxonomy создаёт споры и inconsistent endpoints. Нужен небольшой общий decision table.
- Aggregating все field violations сокращает циклы form correction, но validator тратит больше работы и может показывать cascade errors. Fail-fast проще для дорогих checks; structural ошибки обычно можно собрать bounded списком.
- Strict unknown-input policy ловит typo и неподдержанную feature. Tolerant input облегчает forward compatibility, но способен молча проигнорировать намерение клиента. Output и input требуют разных defaults.
- Один RFC 9457 type с domain `code` упрощает documentation; отдельный type URI на каждый problem делает semantics discoverable. В обоих случаях machine discriminator должен быть стабильным.
- Partial success полезен для independent GraphQL fields и bulk processing. Для транзакционного command он усложняет retry и reconciliation; atomic failure безопаснее, если items образуют один invariant.

## Типичные ошибки

- Неверное предположение: parse success означает valid business request. Симптом: zero/default values доходят до write. Причина: syntax, schema и domain layers смешаны. Исправление: typed DTO, presence/schema checks и отдельные invariants до side effect.
- Неверное предположение: application pre-check гарантирует uniqueness. Симптом: concurrent requests создают duplicate или один падает внутренним `500`. Причина: TOCTOU race. Исправление: database constraint/conditional write и mapping violation в `409` или другой documented error.
- Неверное предположение: human message можно использовать как code. Симптом: client ломается после локализации или редакторской правки. Причина: display text стал protocol field. Исправление: stable type/code/reason и typed details.
- Неверное предположение: любой failure можно вернуть как `200 {"success":false}`. Симптом: proxy, monitoring и retry layer считают обмен успехом. Причина: transport category скрыта. Исправление: корректный status плюс structured body.
- Неверное предположение: schema `format` одинаково валидируется везде. Симптом: один service принимает значение, другой отклоняет. Причина: JSON Schema vocabulary/assertion policy не закреплена. Исправление: выбрать dialect, vocabulary и validator conformance tests.
- Неверное предположение: подробный error всегда помогает. Симптом: response раскрывает SQL, stack, существование чужого account или secret. Причина: internal diagnostics смешаны с public contract. Исправление: безопасный public detail и correlation ID; полные diagnostics только в защищённых logs.
- Неверное предположение: в выбранном GraphQL-over-HTTP контракте `200` означает полный успех. Симптом: UI использует partial object как полный. Причина: execution errors живут в `errors`, а nullable fields остаются в `data`. Исправление: проверять `errors[].path`, required client fields и null propagation.

## Когда применять

Определите единый error envelope и decision table до размножения endpoints. Contract tests должны посылать malformed, schema-invalid, state-conflicting и transient-failure requests, а затем проверять status, machine code, side effects и disclosure.

На внутренней RPC-границе structured errors нужны не меньше, чем во внешнем HTTP API: generated client не спасает от парсинга message, если provider не публикует reason/details. Для редкой неожиданной server bug возвращайте общий internal type клиенту, сохраняйте correlation ID и не превращайте каждое исключение в новый публичный code.

## Источники

- [RFC 9457: Problem Details for HTTP APIs](https://www.rfc-editor.org/rfc/rfc9457.html) — IETF, июль 2023, заменяет RFC 7807, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, STD 97, июнь 2022, проверено 2026-07-18.
- [JSON Schema Draft 2020-12: Validation Vocabulary](https://json-schema.org/draft/2020-12/json-schema-validation) — JSON Schema, Draft 2020-12 от 2022-06-16, проверено 2026-07-18.
- [RFC 6901: JavaScript Object Notation (JSON) Pointer](https://www.rfc-editor.org/rfc/rfc6901.html) — IETF, апрель 2013, проверено 2026-07-18.
- [AIP-193: Errors](https://google.aip.dev/193) — Google, Approved, online edition, проверено 2026-07-18.
- [gRPC Status Codes](https://grpc.io/docs/guides/status-codes/) — gRPC project, официальная документация, проверено 2026-07-18.
- [gRPC Error handling](https://grpc.io/docs/guides/error/) — gRPC project, официальная документация, проверено 2026-07-18.
- [GraphQL Specification, September 2025 Edition: Errors](https://spec.graphql.org/September2025/#sec-Errors) — GraphQL Foundation, сентябрь 2025, проверено 2026-07-18.
- [GraphQL over HTTP](https://graphql.github.io/graphql-over-http/draft/) — GraphQL Foundation, Stage 2 draft, transport status mapping не финален, проверено 2026-07-18.
