---
aliases:
  - Семантика HTTP
  - HTTP API
tags:
  - область/бэкенд
  - тема/http
статус: проверено
---

# HTTP-методы, статус-коды, заголовки и семантика кэширования

## TL;DR

HTTP-метод сообщает, какое действие запрашивает клиент и какие свойства у него есть: safety, idempotency и cacheability. Статус-код описывает общий результат обмена, заголовки передают метаданные и управляющие условия, а cache directives определяют, разрешено ли сохранить ответ, когда его можно повторно использовать и как проверить актуальность.

Эти части образуют один контракт. Если endpoint меняет состояние через GET, возвращает `200 OK` для любого исхода или забывает `Vary`, ложную модель получает не один SDK. На тех же сигналах строят решения proxy, cache, crawler, retry middleware и средства наблюдаемости.

## Область применимости

- Базовая семантика HTTP соответствует RFC 9110 и RFC 9111, опубликованным в июне 2022 года. Метод QUERY учитывается по RFC 10008 от июня 2026 года; источники проверены 2026-07-18.
- Правила общие для HTTP/1.1, HTTP/2 и HTTP/3. Framing, multiplexing и управление конкретным соединением остаются вне scope.
- Основной контекст: JSON API поверх HTTP, private browser/client caches и shared reverse-proxy/CDN caches.
- Вне scope: authentication schemes, cookie policy, CORS и настройка конкретного CDN.

## Ментальная модель

HTTP-запрос похож на типизированное сообщение для цепочки независимых участников. URI называет target resource, method задаёт намерение, fields уточняют условия, а content несёт representation или параметры операции. Ответ сообщает status, metadata и representation результата.

Intermediary не знает бизнес-логику сервиса. Он рассуждает только по этому сообщению. Увидев safe GET и свежий cacheable response, cache вправе не обращаться к origin. Увидев `Vary: Accept-Language`, он разделяет варианты. Увидев условие `If-Match`, origin применяет изменение только к ожидаемой версии ресурса. Поэтому корректная HTTP-семантика даёт системе свойства без знания домена.

## Как устроено

### Методы: намерение и свойства

Safety означает, что клиент не просит изменить состояние origin server. В базовом наборе RFC 9110 к safe methods относятся GET, HEAD, OPTIONS и TRACE. RFC 10008 добавил QUERY: content задаёт server-side query, но клиент по-прежнему не просит изменить target resource. Сервер всё равно может записать access log, увеличить метрику или начислить стоимость запроса: эти побочные эффекты не были целью клиента.

Idempotency означает, что несколько одинаковых запросов должны иметь тот же intended effect, что один. Все safe methods идемпотентны; PUT и DELETE тоже определены как idempotent. Ответы повторов не обязаны совпадать: первый DELETE может вернуть `204 No Content`, второй `404 Not Found`. Для автоматических повторов этого свойства недостаточно: клиент ещё должен уметь повторить body и уложиться в общий deadline. Прикладную сторону подробно разбирает [[20 Бэкенд/Идемпотентные и неидемпотентные операции|заметка об идемпотентных операциях]].

Cacheability — отдельное свойство. Оно зависит от определения метода, status code и явных cache directives. Нельзя вывести разрешение на кеширование только из того, что метод safe или idempotent.

Обычно методы выбирают так:

| Намерение | Обычный метод | Существенный инвариант |
| --- | --- | --- |
| Получить representation | GET | Не прятать запрошенное изменение состояния в чтении |
| Получить те же metadata без content | HEAD | Fields должны соответствовать GET настолько, насколько это возможно без отправки content |
| Выполнить сложный safe query с content | QUERY | Метод safe и idempotent; `Content-Type` обязателен, cache key учитывает content и связанные metadata |
| Создать подчинённый ресурс или выполнить ресурс-специфичную обработку | POST | Повтор небезопасен без дополнительного знания или idempotency key |
| Полностью создать или заменить состояние по известному URI | PUT | Повтор одного representation имеет тот же intended effect |
| Частично изменить ресурс | PATCH | Idempotency зависит от формата patch и операции |
| Удалить отображение ресурса | DELETE | Повтор не должен создавать дополнительный intended effect |

### Статус-код: транспортная категория результата

Первая цифра задаёт класс: `1xx` сообщает промежуточное состояние, `2xx` — успешную обработку, `3xx` — redirect или работу с сохранённым representation, `4xx` — проблему в запросе или состоянии со стороны клиента, `5xx` — неспособность сервера выполнить корректный запрос.

Status code не заменяет доменную [[20 Бэкенд/Валидация и модель ошибок API|модель ошибок]], но задаёт поведение общих компонентов:

| Код | Смысл, который меняет решение клиента |
| --- | --- |
| `200 OK` | Запрос успешно обработан, content описывает результат |
| `201 Created` | Создан ресурс; `Location` может указать его URI |
| `202 Accepted` | Запрос принят, но обработка ещё не завершена |
| `204 No Content` | Обработка завершена, response content отсутствует |
| `304 Not Modified` | Conditional GET/HEAD может использовать сохранённый representation |
| `400 Bad Request` | Сервер не может или не будет обрабатывать запрос из-за клиентской ошибки |
| `401 Unauthorized` | Запрос не содержит valid authentication credentials; ответ включает `WWW-Authenticate` challenge |
| `403 Forbidden` | Сервер понял запрос, но отказывается его выполнять |
| `409 Conflict` | Запрос конфликтует с текущим состоянием target resource |
| `412 Precondition Failed` | Условие `If-Match`, `If-Unmodified-Since` или другое precondition ложно |
| `415 Unsupported Media Type` | Representation имеет неподдерживаемый media type или encoding |
| `422 Unprocessable Content` | Content синтаксически распознан, но инструкции обработать нельзя |
| `429 Too Many Requests` | Клиент превысил ограничение; сервер может вернуть `Retry-After` |
| `503 Service Unavailable` | Сервис временно недоступен; `Retry-After` может задать срок повторной попытки |

`202` требует отдельного способа узнать итог: operation resource, callback, event или polling endpoint. Иначе клиент не отличит «ещё выполняется» от «навсегда потеряно».

### Заголовки: метаданные, условия и переговоры

Field names регистронезависимы. Синтаксис значения и возможность объединить несколько field lines через запятую определяет спецификация конкретного поля; универсальный `split(",")` ломается на кавычках и полях, которые не являются list-valued. Для новых полей с повторно используемым синтаксисом RFC 9651 задаёт Structured Fields как Item, List или Dictionary.

Основные группы полей:

- content negotiation: `Accept`, `Accept-Language`, `Accept-Encoding`;
- описание representation: `Content-Type`, `Content-Encoding`, `Content-Length`;
- validators и preconditions: `ETag`, `Last-Modified`, `If-None-Match`, `If-Match`;
- caching: `Cache-Control`, `Age`, `Vary`, `Expires`;
- location и retry: `Location`, `Retry-After`;
- tracing и domain metadata: стандартные или явно определённые extension fields.

Connection-specific field нельзя бездумно пересылать следующему hop. HTTP/1.1 использует `Connection` для объявления таких полей; proxy обязан удалить их перед forwarding. Прикладной header, напротив, должен иметь end-to-end semantics, если спецификация не говорит обратного.

### Cache pipeline

Cache принимает решение в пять шагов.

1. **Разрешено ли хранение.** `no-store` запрещает cache сохранять response. `private` запрещает хранение shared cache, но допускает private cache. Ответ на запрос с `Authorization` обычно не переиспользуется shared cache без явного разрешения.
2. **Как найти вариант.** Базовый cache key включает method и target URI. `Vary` добавляет request fields, которые origin использовал при выборе representation. `Vary: *` означает, что reuse без обращения к origin невозможен. Для QUERY RFC 10008 дополнительно требует включить request content и связанные metadata: один URI не идентифицирует разные queries.
3. **Свеж ли ответ.** `max-age` ограничивает freshness lifetime; `s-maxage` переопределяет его для shared cache. `Age` оценивает время с генерации или последней успешной validation ответа у origin, включая transit и пребывание в cache chain.
4. **Можно ли переиспользовать stale response.** `no-cache` не запрещает хранение: он требует успешной validation перед reuse. `must-revalidate` запрещает обычное использование stale response без validation. Extensions `stale-while-revalidate` и `stale-if-error` разрешают контролируемые исключения в своих временных окнах.
5. **Как проверить актуальность.** Cache посылает `If-None-Match` со strong или weak ETag. Если выбранный representation не изменился, origin возвращает `304`, и cache обновляет metadata без повторной передачи body. `Last-Modified` и `If-Modified-Since` служат менее точным запасным validator.

`no-store` не удаляет копии, сохранённые до появления directive, и не даёт полной privacy guarantee. Чувствительные данные требуют корректной authentication, transport security и контроля storage на всех слоях.

Strong ETag обозначает byte-for-byte эквивалентность выбранного representation. Weak ETag с префиксом `W/` подтверждает semantic equivalence, но не подходит для `If-Match` и range reconstruction. Если compression создаёт byte-разные representations, validators и `Vary: Accept-Encoding` должны сохранять эту границу.

Получив на unsafe request non-error response класса `2xx` или `3xx`, cache инвалидирует сохранённый response для target URI. Он может также инвалидировать URI из `Location` и `Content-Location`, если они относятся к тому же origin. Это не гарантирует инвалидацию прочих связанных collection URI: такую зависимость проектирует приложение или CDN policy.

## Пример или трассировка

Клиент читает профиль и затем меняет его с optimistic concurrency:

```http
GET /profiles/42 HTTP/1.1
Accept-Language: ru

HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: private, max-age=0, must-revalidate
Vary: Accept-Language
ETag: "v7-ru"

{"id":"42","name":"Анна"}
```

Private cache сохраняет ответ, но `max-age=0` сразу делает его stale. Повторное чтение валидирует копию:

```http
GET /profiles/42 HTTP/1.1
Accept-Language: ru
If-None-Match: "v7-ru"

HTTP/1.1 304 Not Modified
Cache-Control: private, max-age=0, must-revalidate
ETag: "v7-ru"
Vary: Accept-Language
```

Body не передаётся; наблюдаемый профиль остаётся `{"id":"42","name":"Анна"}` из cache. Для изменения клиент использует текущую версию:

```http
PATCH /profiles/42 HTTP/1.1
Content-Type: application/merge-patch+json
Accept-Language: ru
If-Match: "v7-ru"

{"name":"Анна Н."}

HTTP/1.1 200 OK
ETag: "v8-ru"
Content-Type: application/json
Vary: Accept-Language

{"id":"42","name":"Анна Н."}
```

Здесь API определяет validator для языкового representation, поэтому PATCH повторяет `Accept-Language: ru` и проверяет именно `"v7-ru"`. Другой допустимый контракт — отдельная strong write-version, не зависящая от представления; связь validators с write precondition всё равно должна быть явной. Повтор старого PATCH с `If-Match: "v7-ru"` получает `412 Precondition Failed`. Наблюдаемый результат: более позднее изменение не затирается, а варианты `ru` и другого языка не смешиваются из-за `Vary: Accept-Language`.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| До июня 2026 года → RFC 10008, июнь 2026 | Сложный safe query обычно кодировали в URI GET либо отправляли POST с прикладным обещанием safety/idempotency | Стандартизирован QUERY с request content; метод зарегистрирован как safe и idempotent, response cacheable | QUERY разрешает автоматический retry и caching по стандартной семантике, но cache обязан учитывать content/metadata; browser CORS выполняет preflight, а поддержку clients/proxies нужно проверить | [RFC 10008](https://www.rfc-editor.org/rfc/rfc10008.html) |

## Trade-offs

- Полная HTTP-семантика требует дисциплины контракта, зато generic clients, caches и observability понимают обмен. Универсальный POST с `200` проще сначала, но переносит routing, retry, caching и errors в собственный протокол.
- Public caching резко снижает origin load и latency для общих representations. Цена ошибки высока: неверный key или `Vary` способен раскрыть персональные данные. Для пользовательских ответов безопасный исходный выбор — `private` или `no-store`, затем осознанное расширение.
- ETag validation экономит body и даёт optimistic concurrency. Нужно стабильно вычислять validator для representation; при частых изменениях и дешёвом body выигрыш может быть мал.
- `Last-Modified` проще получить из storage, но его точности и связи с representation может не хватить для нескольких изменений за одну секунду. ETag гибче, но требует явной версии или hash policy.

## Типичные ошибки

- Неверное предположение: GET можно использовать для команды, если так удобнее router. Симптом: crawler, prefetch или cache неожиданно запускает действие. Причина: инфраструктура считает GET safe. Исправление: перенести изменение на POST, PUT, PATCH или DELETE и вернуть подходящий status.
- Неверное предположение: `no-cache` запрещает хранение. Симптом: команда либо теряет полезную validation, ставя `no-store`, либо удивляется наличию копии. Причина: directive требует revalidation, а не отказа от storage. Исправление: выбирать directive по нужной фазе cache pipeline.
- Неверное предположение: URI полностью определяет representation. Симптом: один пользователь получает язык, encoding или вариант другого запроса. Причина: origin выбирал content по field, которого нет в `Vary`. Исправление: добавить минимальный полный `Vary` или запретить shared caching.
- Неверное предположение: любой ETag подходит для lost-update protection. Симптом: `If-Match` не даёт нужной гарантии или сервер отвергает weak validator. Причина: weak ETag описывает semantic, а не strong equivalence. Исправление: выдавать strong version validator для изменяемого ресурса.
- Неверное предположение: `202 Accepted` означает успешный бизнес-результат. Симптом: клиент показывает завершение, хотя job позже падает. Причина: status подтверждает только принятие. Исправление: вернуть operation URI и конечные состояния либо выбрать synchronous status.
- Неверное предположение: error body достаточно, status всегда может быть `200`. Симптом: retry middleware и alerts считают отказ успехом. Причина: transport category скрыта внутри domain envelope. Исправление: сочетать точный HTTP status со стабильной machine-readable error model.

## Когда применять

Используйте стандартную семантику методов и статусов на каждой HTTP-границе, даже если единственный текущий клиент внутренний. Для cacheable чтений сначала определите identity representation, authorization boundary и validators, затем directives. На Go-стороне wire-поведение дополняют [[60 Go/HTTP-сервер на net-http|HTTP-сервер]] и [[60 Go/HTTP-клиент и Transport|HTTP-клиент с Transport]].

Не включайте shared caching персональных ответов, пока cache key и правила invalidation не проверены тестом через реальный proxy/CDN. Если доменная операция не укладывается в resource semantics, POST с явным operation resource честнее, чем маскировка команды под GET или PUT.

## Источники

- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, STD 97, июнь 2022, проверено 2026-07-18.
- [RFC 9111: HTTP Caching](https://www.rfc-editor.org/rfc/rfc9111.html) — IETF, STD 98, июнь 2022, проверено 2026-07-18.
- [RFC 10008: The HTTP QUERY Method](https://www.rfc-editor.org/rfc/rfc10008.html) — IETF, Standards Track, июнь 2026, проверено 2026-07-18.
- [RFC 5789: PATCH Method for HTTP](https://www.rfc-editor.org/rfc/rfc5789.html) — IETF, март 2010, проверено 2026-07-18.
- [RFC 7396: JSON Merge Patch](https://www.rfc-editor.org/rfc/rfc7396.html) — IETF, октябрь 2014, проверено 2026-07-18.
- [RFC 9651: Structured Field Values for HTTP](https://www.rfc-editor.org/rfc/rfc9651.html) — IETF, сентябрь 2024, заменяет RFC 8941, проверено 2026-07-18.
- [RFC 5861: HTTP Cache-Control Extensions for Stale Content](https://www.rfc-editor.org/rfc/rfc5861.html) — IETF, май 2010, проверено 2026-07-18.
- [RFC 6585: Additional HTTP Status Codes](https://www.rfc-editor.org/rfc/rfc6585.html) — IETF, апрель 2012, проверено 2026-07-18.
