---
aliases:
  - API versioning
  - Версии API
tags:
  - область/бэкенд
  - тема/api
статус: проверено
---

# Версионирование API

## TL;DR

Версия API выбирает набор несовместимых контрактных решений, который должен оставаться стабильным для клиента. Compatible additions развиваются внутри версии; новая version boundary нужна для изменения, которое нельзя безопасно дать существующим consumers.

Версия не заменяет migration. Provider должен одновременно обслуживать старый и новый контракты, публиковать deprecation и sunset, измерять реальное использование и проверять преобразование данных. Без этого `/v2` лишь переносит breaking change в новый URL.

## Область применимости

- Общие HTTP-механизмы deprecation соответствуют RFC 9745 от марта 2025 года и RFC 8594 от мая 2019 года.
- Major-version guidance опирается на AIP-185 от 2024-10-22. Это конкретная практичная policy, а не обязательное правило для всех API.
- GitHub REST `2026-03-10` и Stripe `2026-06-24.dahlia` используются как официальные примеры date-based и account/request-pinned versioning, проверенные 2026-07-18.
- Вне scope: версия implementation binary, package semantic versioning и миграция database schema сама по себе.

## Ментальная модель

Версия — имя compatibility lane. Клиент входит в lane явно и ожидает, что старые успешные requests сохранят смысл, а responses останутся понятны. Provider может менять код каждый день, но lane продолжает выполнять прежний контракт.

Новая версия создаёт параллельную lane. Некоторое время один resource доступен через обе, а adapters переводят внешние representations в общую внутреннюю модель. Затем traffic старой lane падает, provider завершает её по объявленной policy. Если version выбирается неявно как `latest`, lane движется под клиентом и теряет смысл.

## Как устроено

### Что именно получает версию

Нужно различать пять независимых чисел или имён:

- HTTP protocol version (`HTTP/1.1`, HTTP/2, HTTP/3);
- API contract version (`v1`, `2026-03-10`);
- OpenAPI/GraphQL/protobuf schema artifact version;
- server release/build;
- SDK/package version.

Один server release может одновременно обслуживать `v1` и `v2`. Новый SDK может по-прежнему вызывать `v1`. Поле OpenAPI `openapi: 3.2.0` сообщает диалект спецификации, а не версию описанного API.

Внутри stable version разрешены [[20 Бэкенд/Контракты API и обратная совместимость|совместимые изменения]]: новый optional output field, новый endpoint или расширение принимаемого input при оговорённых reader rules. Removal, rename, новый required input, изменение type/default/unit или иное semantic break требуют новой lane либо длительного совместимого перехода.

В policy AIP-185 наружу выставляется только major version: `v1`, а не `v1.1` или `v1.4.2`. Minor/patch-equivalent additions приходят в `v1` in place. Это удерживает число одновременно поддерживаемых surfaces. Date-based policy решает ту же задачу иначе: breaking changes собираются в именованный release date, как в GitHub REST API.

### Где передавать версию

| Механизм | Сильная сторона | Эксплуатационная цена |
| --- | --- | --- |
| Path: `/v1/orders/42` | Версия видна в URI, routing/log/cache просты | URI меняется между версиями; links и docs нужно мигрировать |
| Header: `X-Api-Version: 2026-03-10` или versioned media type | Resource URI остаётся стабильным | Gateway, SDK и cache обязаны учитывать header; нужен `Vary`/явный cache key |
| Query: `/orders/42?api-version=2` | Явно и легко попробовать вручную | Proxy может нормализовать/удалить query; version смешивается с resource parameters |
| Account/default pin | Старые integrations не обязаны менять каждый request | Webhooks и фоновые callbacks зависят от account state; upgrade требует координации |

Ни один механизм не исправляет breaking semantics. Выбор определяет routing, cache key, observability и ergonomics. Если version header меняет representation, shared cache не должен смешивать варианты. Path version естественно разделяет cache entries, но identity доменного resource всё равно должна оставаться общей там, где версии описывают один объект.

### Сосуществование версий

Новая версия обычно не дублирует всю бизнес-логику. Edge adapter разбирает versioned request, переводит его в canonical command/model, а response проецирует обратно. Такой слой обязан сохранять:

- один resource identity и authorization boundary;
- данные, которые обе версии умеют выразить;
- idempotency identity при retry через ту же lane;
- version-specific defaults, units и error representation;
- round-trip invariants, заявленные migration guide.

Если v2 не может представить состояние v1 без потерь, это должно быть явным ограничением migration, а не silent truncation. Новая major version не должна зависеть от вызова старой public version как от implementation API: иначе shutdown v1 ломает v2.

### Deprecation и sunset

Lifecycle выглядит так:

1. Публикуется новая версия и migration guide с mapping полей и behavior changes.
2. Обе версии работают одновременно; client pin остаётся стабильным.
3. Provider объявляет deprecation и дату прекращения поддержки, связывает ответ с документацией.
4. Метрики показывают traffic по version, consumer и endpoint; owners получают уведомления.
5. После migration window и exit criteria старая версия переходит в sunset, затем отвечает по объявленному post-sunset contract, часто `410 Gone`.

RFC 9745 задаёт `Deprecation` как Structured Field Date и link relation `deprecation`. RFC 8594 задаёт `Sunset` как HTTP-date. Sunset не должен быть раньше deprecation. Сам header `Deprecation` не меняет semantics ресурса: до отключения старый контракт продолжает работать.

Preview channel и stable version решают разные задачи. `alpha` допускает более быстрые breaking changes по опубликованной stability policy; stable lane обязана следовать compatibility promise. Нельзя делать production consumer неявным участником preview.

## Пример или трассировка

В v1 деньги представлены целым числом minor units:

```json
{"id":"p-9","amount_cents":1050,"currency":"USD"}
```

В v2 representation меняется:

```json
{"id":"p-9","money":{"currency":"USD","units":10,"nanos":500000000}}
```

Обе lane читают один payment `p-9`. Adapter проверяется golden cases: `1050 USD` преобразуется в `10 units + 500000000 nanos` и обратно без потери. Для currency или precision, которые v1 не выражает, migration rule обязан вернуть явную ошибку или запретить v1 write, а не округлить молча.

Ответ v1 после объявления deprecation:

```http
HTTP/1.1 200 OK
Deprecation: @1798761600
Sunset: Fri, 31 Dec 2027 23:59:59 GMT
Link: <https://api.example.com/migrations/payments-v2>; rel="deprecation"; type="text/html"
Content-Type: application/json

{"id":"p-9","amount_cents":1050,"currency":"USD"}
```

Наблюдаемый результат до sunset не меняется: клиент всё ещё получает v1 body. Отдельная telemetry series `api_requests{version="v1",consumer=...}` показывает оставшихся consumers. Shutdown разрешён только после migration window и согласованного traffic threshold; cache test подтверждает, что v1 и v2 representations не пересекаются.

## Trade-offs

- Path versioning проще routing и caching, header versioning сохраняет stable resource URI. Header требует строгой cache/config discipline; path размножает links и surface.
- Major-only policy ограничивает version explosion и доставляет additions всем consumers. Date-based releases удобны для пакетирования breaking changes и точного pin, но увеличивают число поддерживаемых snapshots.
- Долгое параллельное обслуживание уменьшает migration risk, но умножает test matrix, security backports и observability cardinality. Короткая window дешевле provider, но переносит риск на consumers.
- Canonical internal model снижает дублирование. Слишком общий model может накопить version-specific flags; иногда отдельный adapter или даже реализация безопаснее, если semantics действительно разошлись.
- Автоматическое переключение unversioned traffic на следующую supported version сокращает legacy support, но создаёт скрытый breaking change. Явный pin надёжнее, хотя требует действий клиента.

## Типичные ошибки

- Неверное предположение: любая новая feature требует `v1.1`. Симптом: clients комбинируют несовместимые endpoint versions, а provider поддерживает десятки surfaces. Причина: compatible evolution перепутана с release numbering. Исправление: добавлять совместимые элементы in place, версию менять только для подтверждённого break.
- Неверное предположение: запрос без version можно всегда направлять в latest. Симптом: старый integration ломается без deploy. Причина: default движется независимо от client. Исправление: стабильный documented default с deprecation либо обязательный explicit pin.
- Неверное предположение: version header не влияет на cache. Симптом: v1 consumer получает v2 body. Причина: intermediary key не учитывает representation-selecting field. Исправление: включить version в cache key/`Vary` или использовать path separation.
- Неверное предположение: publication v2 позволяет выключить v1. Симптом: webhooks, mobile clients или batch jobs перестают работать. Причина: distribution и upgrade lag не измерены. Исправление: concurrent support, per-consumer telemetry и exit criteria.
- Неверное предположение: deprecation означает, что поведение уже можно менять. Симптом: client ломается до sunset. Причина: signal перепутан с новой semantics. Исправление: сохранять старый контракт, а migration вести через docs, headers и новую lane.
- Неверное предположение: adapter всегда может без потерь перевести модели. Симптом: сумма округляется или unknown enum превращается в другой state. Причина: новая модель выразительнее старой. Исправление: проверять round-trip, документировать non-representable states и блокировать опасный write.

## Когда применять

Определите versioning policy до первого external consumer: где передаётся версия, что считается breaking, сколько версий поддерживается, как выглядит preview, deprecation и post-sunset response. Пиновать нужно также webhook/event payloads, потому что их consumer не управляет исходящим request header.

Не создавайте новую версию, если change можно сделать совместимо и проверить consumer tests. Не делайте скрытый breaking change ради «чистоты» модели: новая lane с конечной migration дороже сегодня, но оставляет consumer управлять моментом перехода.

## Источники

- [AIP-185: API Versioning](https://google.aip.dev/185) — Google, Approved, версия от 2024-10-22, проверено 2026-07-18.
- [AIP-180: Backwards compatibility](https://google.aip.dev/180) — Google, Approved, changelog до 2025-10-21, проверено 2026-07-18.
- [RFC 9745: The Deprecation HTTP Response Header Field](https://www.rfc-editor.org/rfc/rfc9745.html) — IETF, март 2025, проверено 2026-07-18.
- [RFC 8594: The Sunset HTTP Header Field](https://www.rfc-editor.org/rfc/rfc8594.html) — IETF, май 2019, проверено 2026-07-18.
- [GitHub REST API versions](https://docs.github.com/en/rest/about-the-rest-api/api-versions) — GitHub, актуальная версия `2026-03-10`, проверено 2026-07-18.
- [Stripe API versioning](https://docs.stripe.com/api/versioning) — Stripe, актуальная версия `2026-06-24.dahlia`, проверено 2026-07-18.
- [Kubernetes API deprecation policy](https://kubernetes.io/docs/reference/using-api/deprecation-policy/) — Kubernetes project, online policy, проверено 2026-07-18.
