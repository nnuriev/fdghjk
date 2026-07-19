---
aliases:
  - CSRF for cookie-based APIs
  - Cross-Site Request Forgery
  - XSRF
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/http
статус: проверено
---

# CSRF для cookie-based API

## TL;DR

Cross-Site Request Forgery (CSRF) использует ambient credential: браузер сам прикладывает session cookie к запросу, который инициировал другой site. Same-Origin Policy часто не даёт атакующей странице прочитать ответ, но не запрещает все способы **отправить** запрос. Если сервер видит только валидную cookie, он не отличает действие UI от подставленной form/navigation.

Для unsafe methods cookie-based API проверяет доказательство, которое чужой origin не может автоматически добавить: session-bound synchronizer token либо корректно подписанный double-submit token. `SameSite`, exact `Origin`, Fetch Metadata (`Sec-Fetch-Site`) и запрет simple content types дают независимые слои. State-changing `GET` остаётся ошибкой независимо от этих защит.

`HttpOnly` защищает cookie от чтения JavaScript, но не от CSRF: браузер всё равно отправляет её. CORS тоже не универсальная CSRF-защита; HTML form умеет послать simple request без preflight.

## Область применимости

Заметка покрывает browser clients и API, где authentication/session state передаётся cookie. Модель соответствует CWE-352 в CWE 4.20 от 2026-04-30, OWASP CSRF Prevention Cheat Sheet, Fetch Metadata Working Draft от 2025-04-01 и RFC 10025 от июля 2026, который заменил RFC 6265.

Bearer token в `Authorization`, который application code добавляет явно и браузер не прикладывает ambiently, меняет threat model: произвольная cross-origin form не способна выставить этот header. Но XSS, неверный CORS, token в cookie или browser-managed Basic/client-certificate credentials возвращают риск. Нельзя объявлять весь API «не подверженным CSRF» только по слову REST.

Вне scope остаются защита от XSS и полная [[20 Бэкенд/Сессии, API-ключи, OAuth 2.0, OIDC и JWT|session lifecycle]]. XSS часто обходит CSRF controls из доверенного origin, поэтому они нужны совместно, а не вместо друг друга.

## Ментальная модель

В CSRF участвуют три стороны:

```text
attacker site
    -> instructs victim browser to send request
victim browser
    -> automatically attaches target-site cookie
target API
    -> sees authenticated request but not user's intent
```

Session cookie доказывает наличие browser session. CSRF token или origin signal доказывает, что request прошёл через разрешённый interaction channel.

CSRF существует при сочетании трёх условий:

1. browser автоматически предъявляет credential;
2. внешний site способен инициировать request нужной формы;
3. endpoint выполняет эффект без независимой проверки origin/intent.

Уберите любое условие, и конкретная атака перестаёт работать. Defense in depth убирает несколько сразу.

## Как устроено

### Safe и unsafe HTTP methods

RFC 9110 называет `GET`, `HEAD`, `OPTIONS` и `TRACE` safe methods: клиент не запрашивает изменение состояния. Backend не должен выполнять business mutation через `GET`, включая «удобные» delete links и tracking endpoint с критичным side effect. `GET` легко инициируют navigation, image и prefetch, а SameSite=Lax допускает cookie для части top-level safe navigations.

CSRF middleware обычно безусловно пропускает safe methods и проверяет `POST`, `PUT`, `PATCH`, `DELETE` и любой custom mutation. Это корректно лишь при соблюдении HTTP semantics внутри handlers. Method override также проверяют после определения effective method, иначе `POST` способен превратиться в unchecked `DELETE` ниже middleware.

Login, password change, email binding и logout тоже требуют осознанной policy. Login CSRF связывает браузер жертвы с account атакующего; последующие данные пользователь может добавить уже в чужую учётную запись.

### Synchronizer token pattern

Сервер создаёт непредсказуемый token и связывает его с session. UI получает token внутри same-origin response и отправляет в request body или, предпочтительно для API, custom header. Cookie одна не годится: её browser приложит ambiently.

На unsafe request сервер проверяет:

```text
session cookie is valid
AND request CSRF token exists
AND token belongs to this session/purpose
AND comparison succeeds
```

Token не кладут в URL: query попадает в history, referrer и access logs. Token не записывают в обычный request log. Per-session token проще для multi-tab/back navigation. Per-request token сужает окно повторного использования, но создаёт concurrency и usability issues; для high-value confirmation чаще нужен отдельный transaction authorization, а не глобально одноразовый CSRF token.

Проверку делают до business effect и по возможности до чтения большого body. Ошибка возвращает `403` с общим reason code, а audit отделяет missing, malformed и mismatch без логирования значения.

### Signed double-submit cookie

Stateless API может выдать отдельную readable CSRF cookie и потребовать то же значение в custom header. Наивное сравнение уязвимо, если атакующий способен внедрить cookie для target domain или создать ambiguity нескольких cookies с одним именем.

Signed double-submit token содержит random value и MAC, привязанный к текущей session identity и purpose. Сервер проверяет MAC и совпадение request token с cookie. Секрет остаётся на сервере; session identifier не нужно раскрывать в token. Rotation session должна инвалидировать старую привязку.

Этот pattern экономит server-side CSRF state, но key rotation, token format, cookie injection и duplicate-cookie parsing становятся частью security contract. Если session store уже есть, synchronizer token часто проще доказать.

### SameSite и cookie scope

`SameSite=Strict` максимально ограничивает cross-site отправку cookie, но ломает часть входов по внешним ссылкам и federated flows. `Lax` допускает больше top-level navigation и удобнее для обычных web sessions. `None` нужен cross-site embedding/SSO-сценариям и используется вместе с `Secure`.

SameSite — понятие site, а не origin. Sibling subdomains могут быть same-site при разных origins; компрометация или takeover соседнего subdomain снижает защиту. Redirect chains и browser compatibility тоже усложняют модель. Поэтому OWASP рекомендует SameSite как defense in depth, а не единственную проверку.

Session cookie дополнительно получает `Secure` и `HttpOnly`. Чем уже `Domain` и `Path`, тем меньше accidental exposure, но `Path` не служит строгой security boundary. Для host-only session удобно имя с prefix `__Host-` при соблюдении его требований. Ни один cookie attribute не исправляет mutation через `GET`.

### Origin и Fetch Metadata

Для unsafe request сервер сравнивает `Origin` с точным allowlist `scheme://host:port`. Suffix и substring comparisons опасны. За reverse proxy authoritative external origin собирают только из доверенной proxy configuration; произвольный `X-Forwarded-Host` клиента не становится источником истины. `Origin: null` отвергают, кроме отдельно спроектированного flow.

Fetch Metadata добавляет browser-generated headers. `Sec-Fetch-Site: cross-site` позволяет рано отклонить unsafe request; `same-origin`, `same-site` и `none` имеют разную семантику. Headers с prefix `Sec-` web JavaScript не может произвольно выставить. Однако старые/non-browser clients могут не прислать metadata, а `same-site` не равно `same-origin`.

В Go `net/http.CrossOriginProtection`, добавленный в Go 1.25.0 и проверенный по документации Go 1.26.5, всегда пропускает `GET`, `HEAD` и `OPTIONS`, а для остальных methods определяет cross-origin browser requests по `Sec-Fetch-Site` или сравнению hostname из `Origin` с `Host`. Запросы без обоих headers он допускает. Поэтому wrapper удобен как внешний слой, но session-bound token остаётся нужен там, где отсутствие headers, same-site sibling или особая proxy topology входят в threat model.

### Custom header, CORS и simple requests

Чужая HTML form способна отправить `application/x-www-form-urlencoded`, `multipart/form-data` или `text/plain` без custom header. Если API принимает только JSON и требует, например, `X-CSRF-Token`, browser JavaScript с другого origin сначала проходит CORS preflight.

Сервер при этом обязан:

- отклонять simple content types на JSON-only endpoint, а не молча парсить их как JSON/form fallback;
- разрешать credentials только точным trusted origins;
- не отражать произвольный `Origin` в `Access-Control-Allow-Origin`;
- ограничить allowed methods/headers;
- всё равно проверять CSRF token или origin policy для cookie-authenticated mutation.

CORS управляет доступом cross-origin script к response и разрешением non-simple request. Он не запрещает обычную form submission и не подтверждает намерение пользователя.

### XSS как смена границы

Скрипт, исполняемый в target origin, способен читать token из DOM, выставлять custom header и отправлять same-origin request. `HttpOnly` сохранит session cookie от прямого чтения, но браузер приложит её к запросу XSS. CSRF token не заменяет output encoding, CSP и устранение XSS.

## Сквозной пример: cookie нужна cross-site SSO

Приложение вынуждено использовать session cookie:

```http
Set-Cookie: __Host-session=s7; Path=/; Secure; HttpOnly; SameSite=None
```

Unsafe endpoint `POST /api/profile/email` требует `X-CSRF-Token`, связанный с session `s7`, и обёрнут Fetch Metadata/Origin policy.

1. Страница `https://outside.example.test` инициирует simple form POST к API. Из-за `SameSite=None` browser прикладывает session cookie.
2. Современный browser добавляет `Sec-Fetch-Site: cross-site`. Внешний middleware отклоняет request с `403` до body parser.
3. Если metadata отсутствует, form всё равно не может добавить `X-CSRF-Token`. Application check отклоняет request. При наличии `Origin` его exact mismatch даёт ещё один независимый deny.
4. Same-origin UI читает CSRF token из bootstrap response и отправляет cookie плюс header. Token совпадает с session binding, mutation проходит.
5. Non-browser integration с отдельным API credential использует другой endpoint/auth scheme и не получает исключение в cookie middleware по одному `User-Agent`.

Наблюдаемый результат: ambient cookie одна не авторизует изменение email. Cross-site request блокируется двумя разными сигналами; legitimate UI предъявляет session и proof interaction channel.

## Trade-offs и альтернативы

### Synchronizer token или signed double-submit

Synchronizer token использует server session state и проще связывается с logout/rotation. Signed double-submit масштабируется без отдельного lookup, но требует безошибочного MAC format, cookie parsing и key rotation. Stateful session уже устраняет главный аргумент против synchronizer pattern.

### Per-session или per-request token

Per-session token дружит с несколькими tabs, retry и back button; XSS/утечка сохраняет его до rotation. Per-request token сужает reuse, но гонки и потерянные responses вызывают false rejects. High-value action лучше связывать отдельным short-lived transaction challenge с точными данными операции.

### SameSite=Strict или Lax/None

Strict даёт сильнее browser-level boundary, но ухудшает external navigation и SSO. Lax — практичный default для многих first-party sessions. None нужен только при реальной cross-site функции и повышает ценность explicit token/origin checks.

### Token или Origin/Fetch Metadata

Origin/Fetch Metadata дешёвы и блокируют request до parsing, но имеют compatibility/fallback и same-site нюансы. Token точнее связывается с session, зато требует доставки и хранения. Для browser session обычно используют оба: metadata как ранний фильтр, token как устойчивый application invariant.

### Cookie session или explicit Authorization header

Cookie удобна для browser и защищается `HttpOnly`, но ambient sending создаёт CSRF. Explicit bearer header не отправляется form автоматически, зато token доступен application code/storage и сильнее зависит от XSS-защиты. Выбор меняет угрозы, а не отменяет authentication design.

## Типичные ошибки

### Проверяют только наличие session cookie

- **Неверное предположение:** authenticated request отражает действие пользователя.
- **Симптом:** mutation выполняется после посещения внешней страницы.
- **Причина:** browser сам приложил ambient credential.
- **Исправление:** session-bound CSRF proof плюс origin/metadata policy для unsafe methods.

### Полагаются только на CORS

- **Неверное предположение:** без `Access-Control-Allow-Origin` чужой site не отправит request.
- **Симптом:** form POST меняет state, хотя response атакующей странице недоступен.
- **Причина:** SOP/CORS ограничивают чтение и non-simple JavaScript requests, а не все cross-origin sends.
- **Исправление:** explicit CSRF check; JSON-only endpoint отвергает simple content types и требует custom header.

### Ставят только `HttpOnly`

- **Неверное предположение:** нечитаемая cookie не участвует в атаке.
- **Симптом:** server получает валидную session cookie на forged request.
- **Причина:** `HttpOnly` запрещает JavaScript читать cookie, но не мешает browser отправлять её.
- **Исправление:** `HttpOnly` сохранить против token theft, добавить SameSite и CSRF proof.

### Считают SameSite полной защитой

- **Неверное предположение:** любой недоверенный origin cross-site.
- **Симптом:** request с sibling subdomain проходит browser cookie policy.
- **Причина:** site шире origin; кроме того, flows могут требовать `None`, а browser behavior эволюционирует.
- **Исправление:** exact Origin/token check и минимальный domain scope cookie.

### State меняется через GET

- **Неверное предположение:** secret URL или UI confirmation защищают handler.
- **Симптом:** navigation, image, crawler или prefetch запускает effect.
- **Причина:** endpoint нарушает safe-method semantics и обходит middleware policy.
- **Исправление:** mutation через unsafe method, CSRF check и явное подтверждение там, где цена ошибки высока.

### Наивный double-submit

- **Неверное предположение:** равенство cookie и header всегда доказывает session origin.
- **Симптом:** внедрённая/двусмысленная cookie создаёт принимаемую пару.
- **Причина:** token не подписан и не связан с текущей session.
- **Исправление:** HMAC-bound double-submit с строгим parsing либо synchronizer token.

## Когда применять

CSRF controls нужны на каждом browser-reachable state-changing endpoint, который принимает ambient credentials. Проверяют обычные handlers, GraphQL mutations, uploads, logout/login, admin actions, method override и legacy form endpoints. Mobile/CLI clients лучше отделять явным auth scheme и route contract, а не массовым bypass в browser middleware.

Практическое правило: для unsafe request сервер требует два независимых доказательства — действующую session и сигнал, который другой origin не получает автоматически. Cookie подтверждает первое. Token/origin policy подтверждает второе.

## Источники

- [CWE-352: Cross-Site Request Forgery](https://cwe.mitre.org/data/definitions/352.html) — MITRE, CWE 4.20 от 2026-04-30, проверено 2026-07-18.
- [Cross-Site Request Forgery Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html) — OWASP Cheat Sheet Series, актуальная веб-версия, проверено 2026-07-18.
- [Fetch Metadata Request Headers](https://www.w3.org/TR/2025/WD-fetch-metadata-20250401/) — W3C Web Application Security Working Group, Working Draft от 2025-04-01, work in progress, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://datatracker.ietf.org/doc/html/rfc9110) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RFC 10025: Cookies: HTTP State Management Mechanism](https://www.rfc-editor.org/info/rfc10025) — IETF, RFC 10025 от июля 2026; obsoletes RFC 6265, проверено 2026-07-18.
- [Package net/http](https://pkg.go.dev/net/http@go1.26.5#CrossOriginProtection) — Go Project, Go 1.26.5; `CrossOriginProtection` добавлен в Go 1.25.0, проверено 2026-07-18.
