---
aliases:
  - Стили API
  - REST vs RPC vs gRPC vs GraphQL
tags:
  - область/бэкенд
  - тема/api
статус: проверено
---

# REST, RPC, gRPC и GraphQL

## TL;DR

REST, RPC, gRPC и GraphQL размещают семантику API в разных местах. REST опирается на resources и uniform HTTP interface. RPC называет удалённые procedures. gRPC добавляет к RPC schema-first IDL, code generation, HTTP/2 и четыре формы streaming. GraphQL публикует typed graph, а клиент выбирает response shape через selection set.

Универсального победителя нет. Для public HTTP API часто важны reach, links, cache и понятная wire-диагностика. Для внутренних typed calls и streaming сильнее gRPC. Для UI с быстро меняющимися выборками полей полезен GraphQL. Action-heavy интеграция может быть честнее как RPC. Выбор проверяют по latency, payload, server cost, evolution и failure semantics конкретного workflow.

## Область применимости

- REST рассматривается как архитектурный стиль из диссертации Fielding 2000 года, а resource-oriented HTTP API — как его практическое приближение.
- RPC-пример соответствует JSON-RPC 2.0; gRPC — официальному core protocol и документации, проверенным 2026-07-18.
- GraphQL соответствует спецификации September 2025 Edition. GraphQL over HTTP на дату проверки остаётся Stage 2 draft, поэтому transport details нужно версионировать отдельно.
- Вне scope: SOAP, WebSocket protocol design, event streaming brokers и сравнение конкретных API gateway.

## Ментальная модель

Стиль API отвечает на вопрос: «какой язык видит клиент?»

- В REST клиент видит ресурсы, representations, ссылки и стандартные HTTP operations.
- В RPC он видит каталог команд и функций.
- В gRPC этот каталог описан IDL и превращён в generated stubs; вызов может быть unary или stream.
- В GraphQL клиент видит graph типов и сам составляет projection и traversal.

Это меняет не внешний вид URL, а место coupling. REST связывает стороны с resource model и HTTP semantics. RPC — с procedure names и messages. GraphQL — со schema fields и execution cost query. Инфраструктура тоже видит разные сигналы: HTTP cache понимает GET URI и `Vary`, но не знает смысл `ChargeCard`; GraphQL gateway понимает operation AST, а обычный CDN видит множество запросов к одному endpoint.

## Как устроено

### REST и resource-oriented HTTP

REST задаёт constraints: client-server, stateless interaction, cache, uniform interface, layered system и необязательный code-on-demand. Uniform interface включает identification of resources, manipulation through representations, self-descriptive messages и hypermedia as the engine of application state.

Практический HTTP API часто применяет только часть стиля: стабильные resource URI, GET/POST/PUT/PATCH/DELETE, status codes, validators и links. Это всё равно полезно, но один JSON endpoint ещё не становится REST только из-за HTTP.

Сильная сторона resource model: общие участники понимают безопасное чтение, caching, conditional update и location нового ресурса. Сложность появляется, когда домен состоит из команд с жизненным циклом, которые плохо выглядят как CRUD. Тогда `POST /orders/{id}:cancel` или отдельный resource операции честнее искусственного `PUT`.

### RPC и JSON-RPC

RPC публикует operations напрямую: `CreateOrder`, `CalculateQuote`, `CancelReservation`. JSON-RPC 2.0 передаёт `jsonrpc`, `method`, `params` и client-generated `id`; success содержит `result`, failure — `error`. Notification не содержит `id`, поэтому server не отправляет response, включая сообщение об ошибке.

Плюс RPC в том, что domain verb остаётся verb. Минус: локальный-looking call скрывает network boundary. Он может завершиться timeout после server commit, частично выполнить fan-out или быть повторён middleware. Каждый method всё равно требует deadline, retry classification и idempotency contract.

HTTP intermediaries обычно не знают, cacheable ли `GetQuote` внутри POST envelope. Такая оптимизация становится частью RPC framework или прикладного протокола, а не стандартной HTTP-семантики.

### gRPC

В обычном gRPC service и messages описаны в Protocol Buffers IDL, а compiler генерирует client/server interfaces. Core model поддерживает четыре формы:

| Форма | Request | Response | Пример |
| --- | --- | --- | --- |
| Unary | одно message | одно message | `GetOrder` |
| Server streaming | одно message | stream messages | `WatchOrderUpdates` |
| Client streaming | stream messages | одно message | загрузка chunks с итогом |
| Bidirectional streaming | stream messages | stream messages | интерактивная сессия |

gRPC transport поверх HTTP/2 использует streams, headers, length-prefixed messages и trailers с `grpc-status`. Messages внутри отдельного stream сохраняют порядок; разные streams выполняются независимо. Metadata, deadlines, cancellation и flow control входят в framework model.

Schema и code generation дают раннюю type checking и удобную multi-language интеграцию. Цена: protobuf evolution rules становятся частью контракта, binary wire хуже читается вручную, а browser и некоторые HTTP intermediaries требуют gRPC-Web или transcoding. Long-lived streams также привязываются к выбранному connection/backend и меняют load balancing.

### GraphQL

GraphQL schema задаёт object, scalar, enum, interface, union и input types. Query выбирает поля, aliases и arguments; server выполняет selection set и возвращает response той же формы. Mutation выражает изменения, subscription — поток событий по правилам реализации transport.

Client-selected projection сокращает over-fetching и позволяет одному UI получить связанные поля без выпуска нового endpoint. Introspection и schema дают tooling. Но query теперь одновременно контракт и план работы. Один небольшой HTTP request может породить тысячи resolver calls, дорогой fan-out или N+1 DB queries.

Authorization нужно применять к каждому resource и field, а не только к корневому endpoint. Execution error допускает partial data: успешные поля остаются в `data`, ошибка содержит path; non-null field может распространить `null` вверх. Клиент, который проверяет только HTTP `200`, пропустит частичный отказ.

GraphQL specification не фиксирует HTTP transport. На 2026-07-18 GraphQL over HTTP остаётся Stage 2 draft; media type, GET для query, status mapping и caching нужно привязывать к выбранной редакции transport contract.

### Оси выбора

| Ось | REST/HTTP | RPC/JSON-RPC | gRPC | GraphQL |
| --- | --- | --- | --- | --- |
| Публичный reach и ручная диагностика | Сильная сторона | Простая JSON-диагностика, но custom envelope | Нужны compatible clients/tooling | Хороший browser reach через HTTP, нужен GraphQL tooling |
| Схема и codegen | OpenAPI возможен, но не обязателен | Зависит от отдельной IDL | Встроенный schema-first путь | Встроенная typed schema и client tooling |
| Generic HTTP cache | Естественен для GET/validators | Обычно слабый | Не понимает методы как HTTP resources | Требует operation-aware policy или persisted queries |
| Streaming | Дополнительный protocol/pattern | Зависит от transport | Все четыре формы встроены | Subscription требует отдельного transport contract |
| Гибкость response shape | Задаёт server; возможны fields/include | Задаёт method | Задаёт response message | Задаёт client selection set |
| Cost control | Endpoint известен заранее | Method известен заранее | Method и message известны | Нужны depth/width/cardinality/cost limits |
| Evolution | HTTP+schema compatibility | Method/message compatibility | Protobuf source/wire/semantic rules | Additive fields и deprecation, field removal ломает query |

Гибрид допустим, если есть один canonical contract. Например, gRPC service можно транскодировать в resource-oriented HTTP по AIP-127, а GraphQL BFF — строить поверх внутренних gRPC services. Ручное дублирование моделей без ownership и compatibility tests почти неизбежно приводит к drift; границы описаны в [[20 Бэкенд/Контракты API и обратная совместимость|заметке о контрактах]].

## Пример или трассировка

Workflow должен получить заказ, создать заказ и наблюдать изменения статуса.

REST-поверхность:

```text
GET  /orders/42              -> 200 Order
POST /orders                 -> 201 Order, Location: /orders/43
GET  /orders/43/events       -> SSE stream или отдельный polling contract
```

gRPC-поверхность:

```text
rpc GetOrder(GetOrderRequest) returns (Order);
rpc CreateOrder(CreateOrderRequest) returns (Order);
rpc WatchOrderUpdates(WatchOrderUpdatesRequest) returns (stream OrderUpdate);
```

GraphQL-поверхность:

```graphql
query OrderScreen($id: ID!) {
  order(id: $id) {
    id
    status
    customer { id name }
    lines { sku quantity }
  }
}
```

Наблюдаемый contract result различается. REST cache может независимо валидировать `GET /orders/42`; gRPC client получает compile-time method/messages и ordered update stream; GraphQL UI получает выбранный nested shape одним query. Если `customer` resolver падает, GraphQL может вернуть `order` и `lines`, `customer: null` и запись в `errors` с path `order.customer`. Это partial success, а не полный успех экрана.

Проверка выбора использует один workload: 100 orders на экране, изменение одного поля и один streaming session. Измеряются request count, bytes, p95, число DB queries, cache hit rate и CPU на query validation. Без этих чисел спор о стиле остаётся спором о синтаксисе.

## Trade-offs

- REST выигрывает, когда uniform resource semantics, browser reach и caching важнее прямого отображения domain commands. RPC выигрывает у него в action-heavy API, где попытка свести каждое действие к CRUD скрывает смысл.
- JSON-RPC легко внедрить поверх обычного JSON transport. gRPC добавляет сильную IDL, codegen и streaming, но требует более строгого toolchain и network path.
- GraphQL уменьшает число заранее выпущенных UI-specific endpoints и over-fetching. Server принимает на себя сложность batching, authorization и cost control. REST/RPC endpoint с фиксированной shape легче прогнозировать и кешировать.
- Один универсальный GraphQL graph упрощает клиентам discovery, но создаёт центральную schema governance. Несколько bounded APIs сохраняют ownership сервисов, зато клиенту нужен composition layer.
- Transcoding даёт несколько transports из одного schema. Оно не устраняет semantic mismatch: HTTP method, status, cache и long-running operation всё равно нужно спроектировать явно.

## Типичные ошибки

- Неверное предположение: REST означает «JSON по HTTP». Симптом: все действия идут POST-запросами на verb URI, status всегда `200`, cache и conditional requests не работают. Причина: uniform interface не используется. Исправление: либо принять resource/HTTP semantics, либо честно назвать surface RPC.
- Неверное предположение: generated RPC выглядит как локальный вызов и так же надёжен. Симптом: mutation повторяется после timeout и создаёт duplicate. Причина: client не различает unprocessed request и lost response after commit. Исправление: задать deadline, retry policy и operation identity.
- Неверное предположение: один gRPC channel на вызов изолирует запросы. Симптом: TLS handshakes, socket churn и высокая latency. Причина: channel владеет connection pool и рассчитан на reuse. Исправление: переиспользовать channels/stubs и отдельно управлять stream saturation.
- Неверное предположение: один GraphQL HTTP request означает одну дешёвую server operation. Симптом: p99 и DB load растут нелинейно от nested query. Причина: N+1, aliases и list cardinality умножают resolver work. Исправление: batching/DataLoader, query cost limits, persisted operations и tracing по field path.
- Неверное предположение: endpoint-level authorization достаточно для GraphQL. Симптом: пользователь читает скрытое field или фильтрует по нему. Причина: graph пересекает несколько resource boundaries. Исправление: проверять object/field access до resolver side effect и учитывать indirect leaks.
- Неверное предположение: две вручную реализованные поверхности останутся эквивалентны. Симптом: REST и gRPC по-разному валидируют default, errors или idempotency. Причина: нет canonical schema и cross-surface contract tests. Исправление: один source of truth и golden scenarios для каждой projection.

## Когда применять

Выбирайте REST/resource-oriented HTTP для public и partner APIs, где важны стандартные methods, cache, links и широкая совместимость. Выбирайте gRPC для контролируемых service-to-service calls, typed clients, high-throughput binary messages и streaming. JSON-RPC подходит для компактного command API, когда full gRPC stack не оправдан. GraphQL полезен на BFF/API aggregation границе с разными UI projections и командой, готовой эксплуатировать query engine.

Не выбирайте стиль по моде или одному benchmark. Сначала запишите workflows, consumers, transport path, mutation safety, streaming и evolution horizon. После выбора зафиксируйте schema и [[20 Бэкенд/Версионирование API|versioning policy]] до появления второго несовместимого клиента.

## Источники

- [Architectural Styles and the Design of Network-based Software Architectures](https://ics.uci.edu/~fielding/pubs/dissertation/fielding_dissertation.pdf) — Roy T. Fielding, University of California, Irvine, 2000, глава 5, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, STD 97, июнь 2022, проверено 2026-07-18.
- [JSON-RPC 2.0 Specification](https://www.jsonrpc.org/specification) — JSON-RPC Working Group, версия 2.0, редакция 2013-01-04, проверено 2026-07-18.
- [Introduction to gRPC](https://grpc.io/docs/what-is-grpc/introduction/) — gRPC project, официальная документация, проверено 2026-07-18.
- [Core concepts](https://grpc.io/docs/what-is-grpc/core-concepts/) — gRPC project, официальная документация, проверено 2026-07-18.
- [gRPC over HTTP/2](https://grpc.github.io/grpc/core/md_doc__p_r_o_t_o_c_o_l-_h_t_t_p2.html) — gRPC project, core protocol specification, проверено 2026-07-18.
- [GraphQL Specification, September 2025 Edition](https://spec.graphql.org/September2025/) — GraphQL Foundation, сентябрь 2025, проверено 2026-07-18.
- [AIP-121: Resource-oriented design](https://google.aip.dev/121) — Google, Approved, проверено 2026-07-18.
- [AIP-127: HTTP and gRPC Transcoding](https://google.aip.dev/127) — Google, Approved, проверено 2026-07-18.
- [GraphQL over HTTP](https://graphql.github.io/graphql-over-http/draft/) — GraphQL Foundation, Stage 2 draft, не финальная спецификация, проверено 2026-07-18.
