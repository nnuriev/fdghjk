---
aliases:
  - Контракт API
  - Backward compatibility API
tags:
  - область/бэкенд
  - тема/api
статус: проверено
---

# Контракты API и обратная совместимость

## TL;DR

API-контракт включает больше, чем schema. Клиент зависит от wire encoding, required/optional полей, значений enum, defaults, ordering, pagination, error codes, idempotency и временных гарантий. OpenAPI, Protocol Buffers, GraphQL schema или JSON Schema фиксируют часть контракта, но не доказывают semantic compatibility.

У совместимости всегда есть направление и несколько измерений: старый клиент с новым сервером, новый клиент со старым сервером, старые сохранённые payloads с новым reader; отдельно проверяются source, wire и semantic compatibility. Даже additive change может сломать потребителя, если тот считает enum закрытым, отвергает unknown fields или полагается на прежний default.

## Область применимости

- OpenAPI соответствует версии 3.2.0 от 2025-09-19.
- Protocol Buffers рассматривается по актуальному Proto3 language guide, проверенному 2026-07-18.
- GraphQL соответствует September 2025 Edition, JSON Schema — Draft 2020-12.
- Организационные правила изменений опираются на AIP-180 и Kubernetes API deprecation policy.
- Вне scope: binary ABI, database schema migration и package-level semantic versioning.

## Ментальная модель

Контракт — множество предположений, на которых уже работает consumer. Provider не видит их все: часть записана в schema, часть появилась из примеров, тестов и наблюдаемого поведения.

Поэтому вопрос «change backward compatible?» неполон. Нужна матрица:

```text
old client  -> new server
new client  -> old server
old payload -> new reader
new payload -> old reader
```

И для каждой стрелки три уровня:

- source compatibility: старый или новый client code компилируется;
- wire compatibility: обе стороны разбирают bytes/messages;
- semantic compatibility: разобранные данные означают то же и приводят к допустимому поведению.

Изменение может быть wire-safe и semantic-breaking. Например, новый enum value корректно декодируется числом, но старый exhaustive switch падает или выбирает опасный default.

## Как устроено

### Слои контракта

**Transport и representation.** Method, path, media type, HTTP status, headers, protobuf field numbers, JSON names и GraphQL operation shape определяют wire interaction.

**Schema.** Types, requiredness/presence, ranges, formats, enum и relationships задают множество допустимых messages. OpenAPI 3.2.0 описывает HTTP operations и schemas; JSON Schema Draft 2020-12 задаёт validation vocabulary; `.proto` и GraphQL SDL выполняют аналогичную роль в своих экосистемах.

**Semantics.** Значение поля, unit, timezone, default, округление, sort order, duplicate handling и error reason редко полностью выражаются типом. Смена `amount` с cents на major currency units остаётся breaking, даже если тип `integer` не изменился.

**Temporal и operational behavior.** Deadline, retryability, idempotency window, eventual-consistency lag, pagination snapshot и rate limits тоже наблюдаемы клиентом. Если list раньше всегда был полным, а теперь молча возвращает первую страницу, schema может выглядеть additive, но consumer теряет данные.

### Что обычно совместимо, а что нет

| Изменение provider | Old client -> new server | New client -> old server | Риск |
| --- | --- | --- | --- |
| Добавить optional output field | Обычно совместимо, если client игнорирует unknown fields | Не применимо | Strict decoder может отклонить response |
| Добавить optional input field | Старый client не использует его | Старый server может отклонить unknown input | Нужна capability/version boundary |
| Добавить required input field | Breaking | Новый client отправляет его, но old server может не знать | Старый client не способен выполнить request |
| Удалить или переименовать field | Breaking для использующих clients | Breaking | Rename равен remove + add |
| Расширить множество принимаемых input | Совместимо для old client | Не гарантировано | Обычно безопаснее с provider side |
| Сузить validation input | Breaking | Не применимо | Ранее успешный request отклоняется |
| Добавить enum output value | Условно | Не применимо | Exhaustive switch и generated enum behavior |
| Изменить default, unit или sort | Wire может сохраниться | Wire может сохраниться | Semantic break без schema diff |
| Добавить pagination к полному list | Старый client может увидеть только page 1 | Не применимо | Потеря данных без parse error |

Robustness должна быть явной. Response readers обычно игнорируют unknown output fields и имеют unknown enum fallback. Request readers часто строже: typo в input лучше отклонить, чем молча проигнорировать. Единое правило «всегда tolerant» либо скрывает ошибки клиента, либо ломает forward compatibility.

### Protocol Buffers

Field number участвует в wire encoding и не меняется после публикации. Удалённые numbers и names нужно помечать `reserved`, чтобы их случайно не использовали для другого смысла. Некоторые изменения field type wire-compatible, но generated source type и прикладная семантика всё равно могут сломаться.

Переезд message между packages, изменение oneof/presence, JSON field name или enum handling требуют отдельной проверки по каждому языку. «Protobuf bytes читаются» не означает, что старый generated client безопасно обработает значение.

### OpenAPI, JSON Schema и GraphQL

В OpenAPI поле `openapi` обозначает версию самой OpenAPI Specification, а `info.version` — версию OpenAPI-документа. Обе строки отделены от версии описываемого API и не создают routing автоматически. Contract diff должен сравнивать operations, parameters, schemas и responses, но semantic fixtures дополняют его.

JSON Schema описывает assertions и annotations. Draft 2020-12 разделяет `format-annotation` и `format-assertion`; наличие `format: email` не гарантирует одинаковую runtime validation во всех validators без выбранного vocabulary и policy.

GraphQL позволяет пометить field или enum value директивой `@deprecated`, пока старые queries продолжают его выбирать. Удаление field ломает validation query. Добавление required non-null argument тоже ломает старый query; required non-null arguments и required input fields нельзя использовать как обычную deprecated точку миграции без нового совместимого пути.

### Процесс изменения

1. Contract artifact хранится рядом с кодом и проходит lint/diff.
2. Policy классифицирует schema changes по каждой стрелке compatibility matrix.
3. Frozen consumer tests запускают старые generated clients и payload fixtures против новой реализации.
4. Semantic golden tests проверяют defaults, ordering, errors, pagination и idempotency, которых schema не выражает.
5. Breaking migration идёт через expand-and-contract: добавить новый путь, поддержать оба, перевести traffic, объявить deprecation, удалить старый путь только в разрешённой [[20 Бэкенд/Версионирование API|версии API]].
6. Usage telemetry показывает, остались ли consumers старого элемента. Наличие нового SDK не доказывает миграцию deployed clients.

## Пример или трассировка

Исходный response:

```json
{"id":"o-7","status":"OPEN"}
```

Новый server добавляет optional `note` и enum value `SUSPENDED`:

```json
{"id":"o-7","status":"SUSPENDED","note":"manual review"}
```

Старый client игнорирует unknown `note`, поэтому field addition проходит. Но его логика закрыта:

```text
switch status:
  OPEN    -> allowEdit
  CLOSED  -> readonly
  default -> panic("unreachable")
```

Compatibility test `old client -> new server` наблюдает panic на `SUSPENDED`. Wire parsing прошёл, semantic compatibility нарушена. Исправленный contract требует unknown fallback, например `readonly + surface unknown state`; только после распространения такого client новый output enum становится безопаснее.

Полная проверка запускает четыре сценария: old client/new server, new client/old server, stored old payload/new reader и new payload/old reader. Schema diff ловит required field и removal. Golden fixture отдельно ловит изменение default sort или появление pagination, потому что эти breaks могут не вызвать parse error.

## Trade-offs

- Строгая input validation быстро обнаруживает typo и drift. Игнорирование unknown input повышает forward compatibility, но способно принять запрос, не выполнив ожидаемое клиентом поле. Для commands безопаснее отклонить неизвестное и версионировать расширение.
- Tolerant output readers переживают additive fields. Цена: client не узнаёт новое значение автоматически; для security-sensitive enum нужен conservative unknown fallback.
- Generated clients дают source-level types и удобство, но добавляют language-specific compatibility surface. Динамический JSON client меньше ломается при компиляции, зато ошибки переходят в runtime.
- Один schema registry и обязательный diff снижают случайные breaks. Он не заменяет semantic tests и review: default, ordering и side effects часто невидимы schema.
- Длинная deprecation window уменьшает риск для consumers, но увеличивает test matrix и стоимость security support. Telemetry позволяет завершать её по фактам, а не по календарю в одиночку.

## Типичные ошибки

- Неверное предположение: additive означает compatible. Симптом: старый client падает на новом enum или strict unknown field. Причина: consumer assumptions не отражены в provider schema. Исправление: frozen-client tests и documented unknown-value policy.
- Неверное предположение: wire compatibility protobuf достаточна. Симптом: generated code не компилируется или меняет смысл значения. Причина: source и semantic layers не проверены. Исправление: language-specific generated-client tests; не переиспользовать field numbers, reserve удалённые.
- Неверное предположение: rename сохраняет смысл, значит безопасен. Симптом: старый client перестаёт видеть field. Причина: на wire rename обычно выглядит как removal старого имени и addition нового. Исправление: добавить новое поле, синхронно поддерживать оба, deprecated старое и удалить в новой major version.
- Неверное предположение: OpenAPI diff покрывает контракт. Симптом: корректно сгенерированный client получает другой порядок, unit или error reason. Причина: semantic behavior отсутствует в machine-readable schema. Исправление: examples как tests, golden traces и consumer-driven scenarios.
- Неверное предположение: новый server может сразу требовать новое поле. Симптом: все старые clients получают validation error. Причина: rollout provider опередил consumers. Исправление: сначала optional/default, затем миграция и только потом новая incompatible boundary.
- Неверное предположение: deprecation annotation сама мигрирует клиентов. Симптом: старый field нельзя удалить спустя годы. Причина: deployed usage не измеряется. Исправление: per-field/version telemetry, owner communication и проверяемый exit criterion.

## Когда применять

Compatibility policy нужна до публикации первого внешнего или межкомандного API. Зафиксируйте accepted input, emitted output и error codes; добавьте contract diff и хотя бы одну предыдущую client/schema version в CI. Для payloads, которые сохраняются надолго, treating storage reader as ещё одного consumer обязательно.

Не присваивайте `compatible` по одному schema diff. Изменение defaults, ordering, permissions, retryability или side effects требует semantic review. Если поддержку старого поведения доказать нельзя, используйте новую version boundary и migration plan вместо скрытого break.

## Источники

- [OpenAPI Specification 3.2.0](https://spec.openapis.org/oas/v3.2.0.html) — OpenAPI Initiative, версия 3.2.0 от 2025-09-19, проверено 2026-07-18.
- [AIP-180: Backwards compatibility](https://google.aip.dev/180) — Google, Approved, changelog до 2025-10-21, проверено 2026-07-18.
- [Protocol Buffers Proto3 Language Guide: Updating a Message Type](https://protobuf.dev/programming-guides/proto3/#updating) — Google, Proto3, проверено 2026-07-18.
- [GraphQL Specification, September 2025 Edition](https://spec.graphql.org/September2025/) — GraphQL Foundation, сентябрь 2025, проверено 2026-07-18.
- [JSON Schema Draft 2020-12](https://json-schema.org/draft/2020-12) — JSON Schema, Draft 2020-12 от 2022-06-16, проверено 2026-07-18.
- [JSON Schema Validation Vocabulary](https://json-schema.org/draft/2020-12/json-schema-validation) — JSON Schema, Draft 2020-12 от 2022-06-16, проверено 2026-07-18.
- [Kubernetes API deprecation policy](https://kubernetes.io/docs/reference/using-api/deprecation-policy/) — Kubernetes project, online policy, проверено 2026-07-18.
