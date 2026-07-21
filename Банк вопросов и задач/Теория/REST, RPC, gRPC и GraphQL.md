---
aliases:
  - "Теоретический вопрос: REST, RPC, gRPC и GraphQL"
tags:
  - область/бэкенд
  - тема/api
  - тип/вопрос
статус: проверено
---

# REST, RPC, gRPC и GraphQL

## Вопрос

Как работает «REST, RPC, gRPC и GraphQL» и какие ограничения, failure modes и trade-offs нужно учитывать в backend-системе?

## Короткий ориентир

REST, RPC, gRPC и GraphQL размещают семантику API в разных местах. REST опирается на resources и uniform HTTP interface. RPC называет удалённые procedures. gRPC добавляет к RPC schema-first IDL, code generation, HTTP/2 и четыре формы streaming. GraphQL публикует typed graph, а клиент выбирает response shape через selection set.

Универсального победителя нет. Для public HTTP API часто важны reach, links, cache и понятная wire-диагностика. Для внутренних typed calls и streaming сильнее gRPC. Для UI с быстро меняющимися выборками полей полезен GraphQL. Action-heavy интеграция может быть честнее как RPC. Выбор проверяют по latency, payload, server cost, evolution и failure semantics конкретного workflow.

Полный разбор: [[20 Бэкенд/REST, RPC, gRPC и GraphQL|REST, RPC, gRPC и GraphQL]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/02 Кэш, API и observability#API|API]] — исходный блок вопросов о transport и публичном контракте.
- [[CurseHunter/5785/02 Кэш, API и observability#REST, RPC/gRPC, GraphQL, polling, streaming — как выбирать?|REST, RPC/gRPC, GraphQL, polling, streaming — как выбирать?]] — точная сравнительная формулировка.
- «Точный ориентир: удалённое поле перестают использовать, но его number резервируют; желательно зарезервировать и name для JSON/TextFormat. Старый номер нельзя выдавать новому полю, иначе старые bytes могут декодироваться в новый смысл. Отдельный contract repository уменьшает локальное дублирование, но создаёт release coordination и dependency fan-out; colocated contract упрощает atomic change producer’а, но consumers требуют отдельной доставки артефакта. Выбор определяется ownership и rollout protocol, а не универсальным правилом. Базовое сравнение transport и schema подходов связано с REST, RPC, gRPC и GraphQL.» — [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Микросервисы, gRPC и Protobuf|Telegram Собесы/M.Tech — 2026-07-17 — 350к, раздел «Микросервисы, gRPC и Protobuf»]].
- «REST, RPC и gRPC → синхронная и асинхронная обработка.» — [[Telegram Собесы/VK Tech — 2025-09-12 — 350к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/VK Tech — 2025-09-12 — 350к, раздел «Минимальный маршрут по vault»]].

- [[Telegram Собесы/АМТЕХ — 2026-04-06 — 350к/Бланк вопросов и заданий#REST, gRPC, RPC и SQL — `00:20:12–00:28:38`|REST, gRPC, RPC и SQL — `00:20:12–00:28:38`]] — точная проверенная формулировка технического блока интервью АМТЕХ.

- [[Telegram Собесы/VK Tech — 2025-09-12 — 350к/Бланк вопросов и заданий#Синхронные взаимодействия, REST и gRPC — `00:59:54–01:05:45`|Синхронные взаимодействия, REST и gRPC — `00:59:54–01:05:45`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Авито — 2026-04-20 — 470к/Бланк вопросов и заданий#Межсервисное взаимодействие — `00:00:00–00:16:13`|Межсервисное взаимодействие — `00:00:00–00:16:13`]] — точная проверенная формулировка самостоятельного технического блока интервью.

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
