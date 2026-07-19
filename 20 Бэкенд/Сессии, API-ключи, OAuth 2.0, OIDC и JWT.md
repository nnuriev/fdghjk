---
aliases:
  - Sessions, API keys, OAuth 2.0, OIDC and JWT
  - Сессии и токены
  - OAuth и OpenID Connect
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/идентификация-и-доступ
статус: проверено
---

# Сессии, API-ключи, OAuth 2.0, OIDC и JWT

## TL;DR

Эти механизмы отвечают на разные вопросы. Сессия продолжает уже состоявшуюся аутентификацию. API key обычно подтверждает владение секретом приложения или интеграции. OAuth 2.0 выдаёт клиенту ограниченный доступ к resource server. OpenID Connect (OIDC) добавляет поверх OAuth протокол аутентификации пользователя и ID Token. JSON Web Token (JWT) — формат claims, а не протокол login, authorization или revocation.

Выбирать нужно по субъекту, получателю и lifecycle credential: user или workload, browser или machine client, один backend или несколько resource servers, bearer или sender-constrained, server-side state или self-contained claims. Подпись JWT подтверждает происхождение и целостность claims, но не скрывает payload, не делает права актуальными и не заменяет object-level authorization из [[20 Бэкенд/Аутентификация и авторизация на уровне API|прикладной проверки доступа]].

## Ментальная модель

Credential — переносимое доказательство с ограниченной областью применимости. Для него надо уметь ответить:

```text
кто выдал -> кому -> о каком субъекте -> для какого получателя
-> с какими правами -> до какого времени -> как проверить и отозвать
```

Две независимые оси часто смешивают:

- **reference или self-contained**: сервер ищет состояние по случайному идентификатору либо читает подписанные claims локально;
- **bearer или proof-of-possession**: достаточно предъявить строку либо нужно ещё доказать владение привязанным ключом.

Opaque session ID обычно reference и bearer. JWT access token обычно self-contained и bearer, но DPoP или mTLS способны sender-constrain OAuth token. Формат ничего не предрешает сам по себе.

| Артефакт | Основная задача | Типичный субъект | Кто принимает | Где актуальное состояние |
| --- | --- | --- | --- | --- |
| Session cookie | продолжить login в одном приложении | user + browser session | session host | server-side store или защищённый session artifact |
| API key | аутентифицировать integration/client | application, project, workload | конкретный API | key registry, scopes, status, expiry |
| OAuth access token | дать клиенту доступ к resource server | user delegation или client | resource server | token claims либо introspection/state |
| Refresh token | получить новый access token | client + authorization grant | authorization server | grant и revocation state |
| OIDC ID Token | сообщить client о результате user authentication | end-user | OIDC relying party | signed claims об authentication event |
| JWT | упаковать claims в JWS/JWE | зависит от профиля | зависит от профиля | зависит от протокола, не от JWT |

## Как устроено

### Сессия

После authentication session host выдаёт session secret и связывает его с principal, временем и assurance level. В stateful-варианте browser хранит только случайный opaque ID, а backend — запись с user ID, auth time, expiry, revocation и security context. Logout и административное завершение инвалидируют запись немедленно; смена privilege или повторная аутентификация может потребовать rotation session ID, чтобы старое значение не наследовало новую силу.

NIST SP 800-63B-4 задаёт нормативные требования к session management для digital identity: session secret создаётся при authentication с approved random bit generator, имеет не менее 64 bits, передаётся по authenticated protected channel, инвалидируется при logout и ограничивается timeout. Browser cookie для сессии должна быть `Secure`, иметь минимальную практическую область host/path и не содержать cleartext PII. Ей также следует иметь `HttpOnly`, срок не позже окончания session, prefix `__Host-` с `Path=/`, `SameSite=Lax` или `Strict` и opaque value. Cookie expiry при этом не заменяет server-side timeout.

Пример заголовка:

```http
Set-Cookie: __Host-session=<opaque-random-id>; Path=/; Secure; HttpOnly; SameSite=Lax
```

Cookie browser отправляет автоматически, поэтому сессия подвержена CSRF. `SameSite` снижает часть cross-site surface, но не заменяет проверку origin и CSRF token там, где cross-site state-changing request остаётся возможным. `HttpOnly` мешает обычному JavaScript прочитать cookie, однако XSS всё ещё способен выполнять запросы от имени session внутри origin.

Нужны два времени: inactivity timeout и overall timeout. Reauthentication обновляет уверенность в присутствии пользователя и требуется перед чувствительным действием, если исходный authentication слишком стар или слаб. Access token сам по себе не доказывает, что пользователь всё ещё присутствует: NIST SP 800-63B-4 прямо отделяет token lifetime от authenticated session.

### API key

API key — shared bearer secret, если протокол не добавляет подпись запроса или другой proof-of-possession. Практичная запись состоит из несекретного key ID/prefix и случайной secret part. Backend по ID находит запись, сравнивает secret с защищённым verifier, затем проверяет status, environment, tenant, allowed APIs/actions, expiry и quotas. Полный ключ не логируют и после создания обычно не показывают повторно.

API key хорошо подходит контролируемой server-to-server интеграции с одним issuer/API, когда delegation и user login не нужны. Он не должен молча становиться user identity: общий ключ CI job или партнёра не объясняет, какой человек инициировал действие. Для audit нужен отдельный actor context либо индивидуальный credential.

Ограничения API key должны быть явными: один environment, небольшой набор actions/resources, срок, owner, rotation и revoke. Ключ в мобильном приложении или browser bundle нельзя считать секретом: клиентское устройство позволяет извлечь значение. Для public client используют протокол, который не полагается на постоянный встроенный secret.

### OAuth 2.0

OAuth разделяет четыре роли: resource owner, client, authorization server (AS) и resource server (RS). Client получает access token, чтобы обращаться к RS в пределах grant. OAuth не определяет стандартный способ сообщить client, кто вошёл; попытка использовать произвольный OAuth access token как login создаёт token substitution и mix-up риски.

Для redirect-based user flow актуальная BCP RFC 9700 рекомендует authorization code flow. Упрощённая последовательность:

1. Client создаёт одноразовые `state` и PKCE `code_verifier`, отправляет `code_challenge` в authorization request и регистрирует точный redirect URI.
2. AS аутентифицирует user и получает authorization.
3. Browser возвращает короткоживущий authorization code.
4. Client проверяет `state` и меняет code вместе с `code_verifier` на tokens через token endpoint.
5. RS принимает access token только для своего audience и разрешённых scopes.

`state` связывает browser response с начатой client transaction и используется против CSRF. PKCE связывает authorization code с client instance и мешает code injection или обмену перехваченного code. Для client, работающего с несколькими authorization servers, mix-up закрывают отдельно: transaction связывают с ожидаемым issuer и проверяют параметр `iss` по RFC 9207 либо используют разные redirect URI. В OIDC `nonce` связывает ID Token с authentication request; это другой объект, его нельзя механически заменить `state`.

Access token делают короткоживущим и audience-restricted. Refresh token хранится строже, потому что продлевает grant. RFC 9700 требует для public clients либо sender-constrained refresh token, либо refresh token rotation с обнаружением повторного использования старого значения. Для access tokens BCP рекомендует sender constraint через OAuth mTLS (RFC 8705) или DPoP (RFC 9449), когда риск и платформа оправдывают сложность.

### OpenID Connect

OIDC Core 1.0 — identity layer поверх OAuth 2.0. Client запрашивает scope `openid`; OpenID Provider (OP) аутентифицирует end-user и возвращает ID Token, то есть JWT с claims об authentication event. ID Token предназначен relying party, а access token — resource server. По OIDC ID Token нельзя передавать в API вместо access token: даже похожие JWT должны иметь разные типы, audiences и взаимоисключающие validation rules.

Relying party валидирует ID Token по правилам OIDC-профиля: signature и разрешённый algorithm, точный `iss`, наличие своего `client_id` в `aud`, `azp` при применимости, `exp`, `iat` по policy и `nonce`, если он был отправлен. Subject идентифицируют парой `(iss, sub)`, а не email: email способен измениться и не обязан быть глобально уникальным.

OIDC login не создаёт автоматически локальную application session. После validation RP обычно связывает `(iss, sub)` с локальным account и выдаёт собственный session secret. Logout у RP, logout у OP и revocation OAuth grant — разные state transitions; их надо проектировать отдельно.

### JWT

RFC 7519 определяет JWT как compact, URL-safe representation claims в JWS или JWE. Частый signed JWT состоит из `header.payload.signature`; header и payload base64url-encoded, но не зашифрованы. Любой обладатель token видит claims. Confidentiality появляется только у JWE либо у защищённого транспортного/хранилищного контура.

Безопасная validation строится не из того, что попросил token. RFC 8725 требует заранее разрешить algorithms, проверить все криптографические операции, `iss`/`aud`, использовать explicit typing и взаимоисключающие правила для разных видов JWT. Иначе ID Token, access token, email-verification token и session artifact могут быть приняты не тем consumer — cross-JWT confusion.

`exp` ограничивает приём после времени, но не отзывает token раньше. Удалённая у пользователя роль останется в self-contained claims до expiry, если consumer не делает lookup/introspection или не проверяет revocation state. Поэтому lifetime выбирают по допустимому stale window, а не только по производительности.

OAuth access token не обязан быть JWT. Если deployment использует профиль RFC 9068, JWT access token имеет `typ=at+jwt` и профильные claims; без такого соглашения нельзя угадывать semantics по трём сегментам строки.

## Пример или трассировка

Browser обращается к backend-for-frontend (BFF), а BFF вызывает invoice API:

```text
browser <-> BFF/RP <-> OpenID Provider / Authorization Server
                  |
                  +-> invoice resource server
```

1. BFF создаёт `state=s1`, `nonce=n1` и PKCE pair, сохраняет transaction server-side и перенаправляет browser к OP.
2. Callback содержит `code=c1&state=s1&iss=https%3A%2F%2Fid.example`. BFF отклонит ответ при несовпадении `state` или ожидаемого issuer, затем отправит `c1` и verifier только на token endpoint этого issuer.
3. BFF проверяет ID Token: `iss=https://id.example`, `aud=bff-client`, `nonce=n1`, signature и times. По `(iss, sub)` находит user `u9`.
4. BFF создаёт opaque session `sid7`, хранит OAuth tokens server-side и отвечает cookie `__Host-session=sid7; Secure; HttpOnly; SameSite=Lax; Path=/`.
5. При `GET /invoices/i7` browser отправляет cookie. BFF находит активную session и вызывает invoice API с access token, у которого `aud=invoice-api` и scope `invoices:read`.
6. Invoice API проверяет token, затем object-level policy. ID Token с `aud=bff-client`, отправленный вместо access token, получает `401`; access token другого API тоже получает `401` из-за wrong audience.
7. Logout удаляет `sid7`. Повтор старого cookie после этого даёт `401`, даже если OAuth access token ещё существует в server-side storage; BFF его больше не выдаёт browser.

Наблюдаемый результат: ID Token устанавливает identity только для BFF, access token ограничен invoice API, а browser session можно завершить немедленно server-side. Компрометация одного артефакта не обязана давать силу двух остальных.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| OAuth 2.0, RFC 6749, 2012 → BCP RFC 9700, 2025 | Original framework описывал implicit grant и resource owner password credentials grant | RFC 9700 не рекомендует implicit без специальных mitigations, запрещает использовать password grant и усиливает требования к PKCE, redirect URI, audience и replay protection | Новый deployment проектируют по RFC 9700, а не копируют все grants из RFC 6749 | RFC 6749, RFC 9700 |
| OIDC Core 1.0, 2014 → errata set 2, 2023 | Final specification 2014 года | Одобренная редакция включает второй набор errata без смены major version | Ссылаться следует на Core 1.0 incorporating errata set 2 от 2023-12-15 | OIDC Core errata 2 |
| NIST SP 800-63B, 2017/2020 → SP 800-63B-4, 2025 | Предыдущая редакция Digital Identity Guidelines | Revision 4 заменила её и содержит актуальные normative session requirements | Session policy и cookie guidance сверяют с SP 800-63B-4 | NIST SP 800-63B-4 |
| RFC 6265, 2011 → RFC 10025, 2026 | RFC 6265 описывал HTTP cookies до появления стандартизованных `SameSite` и cookie prefixes | RFC 10025 заменил RFC 6265 в июле 2026 года и включил актуальную модель cookies, `SameSite` и prefixes | Новый cookie contract сверяют с RFC 10025; RFC 6265 нужен для истории и старых реализаций | RFC 6265, RFC 10025 |
| На 2026-07-18 | OAuth 2.1 ещё не опубликован как RFC | `draft-ietf-oauth-v2-1-15` остаётся work in progress | Draft полезен как направление развития, но production contract нельзя приписывать несуществующему RFC | IETF Datatracker |

## Trade-offs

### Stateful session или self-contained session JWT

Server-side session требует shared/replicated store и lookup, зато даёт немедленный revoke, небольшой cookie и централизованный state. Self-contained artifact уменьшает lookup dependency, но увеличивает cookie, переносит sensitive claims к client и оставляет stale state до expiry. Для browser login stateful opaque session часто проще и безопаснее; signed artifact оправдан при контролируемом коротком lifetime и чётком key/rotation/revocation design.

### API key или OAuth client credentials/workload identity

API key дёшев в интеграции и понятен одному API, но обычно долгоживущий bearer secret с ручным distribution. OAuth client credentials централизует выдачу коротких access tokens и audience/scope, однако добавляет AS dependency и не решает bootstrap client credential автоматически. Platform workload identity убирает pre-shared application secret, но привязывает доверие к attestation и control plane.

### Bearer или sender-constrained token

Bearer token работает везде и легко проксируется; утечка равна временному захвату полномочий. DPoP/mTLS снижает replay украденного token за счёт ключа и дополнительной validation, но усложняет key custody, proxies, retries, nonce/clock handling и debugging. Сначала всё равно ограничивают audience, scope и lifetime.

### Browser с access token или BFF session

Прямой browser client убирает backend session и удобен для независимого SPA, но token оказывается в среде XSS и сложнее защищается/обновляется. BFF держит OAuth tokens server-side и даёт browser `HttpOnly` session cookie; цена — state, CSRF controls и дополнительный hop. Выбор зависит от trust model, а не от моды на JWT.

## Типичные ошибки

### «OAuth означает login»

- **Неверное предположение:** любой access token сообщает client подтверждённую user identity.
- **Симптом:** client принимает token другого flow/provider и связывает не того пользователя.
- **Причина:** OAuth authorization подменил authentication protocol.
- **Исправление:** использовать OIDC, валидировать ID Token и связывать account по `(iss, sub)`.

### ID Token отправляется в API

- **Неверное предположение:** все JWT взаимозаменяемы.
- **Симптом:** API принимает token с audience client и неподходящими claims.
- **Причина:** нет explicit token type и взаимоисключающих validation rules.
- **Исправление:** API принимает access-token profile для собственного audience; RP принимает ID Token по OIDC rules.

### JWT только декодируется

- **Неверное предположение:** base64url payload уже доверенный.
- **Симптом:** attacker меняет `sub`, role или `alg` и получает доступ.
- **Причина:** пропущены signature, algorithm, issuer, audience, time и type validation.
- **Исправление:** фиксированный validation profile по RFC 8725 и профильной спецификации.

### Долгоживущий token считается отзываемым

- **Неверное предположение:** удаление role немедленно меняет self-contained claims.
- **Симптом:** отозванное право действует до `exp`.
- **Причина:** consumer не обращается к актуальному state.
- **Исправление:** короткий lifetime, introspection/reference token или отдельная revocation/version check по цене риска.

### Cookie flags считаются полной защитой

- **Неверное предположение:** `HttpOnly` устраняет XSS, а `SameSite` — весь CSRF.
- **Симптом:** injected script выполняет authorized request либо разрешённый cross-site flow меняет state.
- **Причина:** flags ограничивают отдельные browser behaviors, а не исправляют injection и origin policy.
- **Исправление:** output/input safety, CSP по threat model, CSRF token/origin check и минимальные cookie scope/lifetime.

### Один API key у всего fleet

- **Неверное предположение:** общий secret проще обслуживать без потери контроля.
- **Симптом:** утечку нельзя привязать к workload, а rotation ломает весь fleet.
- **Причина:** identity, blast radius и lifecycle объединены.
- **Исправление:** отдельные scoped keys или short-lived workload credentials, owner, expiry и tested rotation.

## Когда применять

Server-side session подходит first-party web application, где нужен немедленный logout/revoke и browser не должен видеть upstream tokens. API key уместен для ограниченной интеграции, если ключ можно держать вне public client, инвентаризировать и регулярно менять. OAuth нужен, когда client получает ограниченный доступ к resource server, особенно от имени пользователя или через централизованный AS. OIDC добавляют, когда client должен знать результат user authentication.

JWT выбирают только после протокола и validation profile. Если нужны мгновенный revoke, маленький payload и централизованная актуальность, opaque reference часто лучше. Если resource servers должны проверять token локально без runtime lookup и допустимо окно stale claims, профильный короткоживущий JWT даёт такой trade-off.

## Источники

- [NIST SP 800-63B-4: Authentication and Authenticator Management](https://csrc.nist.gov/pubs/sp/800/63/b/4/final) — NIST, SP 800-63B-4, июль 2025, финальная версия от 2025-07-31, проверено 2026-07-18.
- [RFC 6265: HTTP State Management Mechanism](https://www.rfc-editor.org/rfc/rfc6265.html) — IETF, RFC 6265, апрель 2011, проверено 2026-07-18.
- [RFC 10025: Cookies: HTTP State Management Mechanism](https://www.rfc-editor.org/info/rfc10025) — IETF, RFC 10025, июль 2026; заменил RFC 6265, проверено 2026-07-18.
- [RFC 6749: The OAuth 2.0 Authorization Framework](https://www.rfc-editor.org/rfc/rfc6749.html) — IETF, RFC 6749, октябрь 2012, проверено 2026-07-18.
- [RFC 9700: Best Current Practice for OAuth 2.0 Security](https://www.rfc-editor.org/rfc/rfc9700.html) — IETF, BCP 240 / RFC 9700, январь 2025, проверено 2026-07-18.
- [RFC 8705: OAuth 2.0 Mutual-TLS Client Authentication and Certificate-Bound Access Tokens](https://www.rfc-editor.org/rfc/rfc8705.html) — IETF, RFC 8705, февраль 2020, проверено 2026-07-18.
- [OpenID Connect Core 1.0 incorporating errata set 2](https://openid.net/specs/openid-connect-core-1_0-errata2.html) — OpenID Foundation, Final Specification incorporating errata set 2 от 2023-12-15, проверено 2026-07-18.
- [RFC 7519: JSON Web Token](https://www.rfc-editor.org/rfc/rfc7519.html) — IETF, RFC 7519, май 2015, проверено 2026-07-18.
- [RFC 8725: JSON Web Token Best Current Practices](https://www.rfc-editor.org/rfc/rfc8725.html) — IETF, BCP 225 / RFC 8725, февраль 2020, проверено 2026-07-18.
- [RFC 9068: JWT Profile for OAuth 2.0 Access Tokens](https://www.rfc-editor.org/rfc/rfc9068.html) — IETF, RFC 9068, октябрь 2021, проверено 2026-07-18.
- [RFC 9207: OAuth 2.0 Authorization Server Issuer Identification](https://www.rfc-editor.org/rfc/rfc9207.html) — IETF, RFC 9207, март 2022; параметр `iss` для предотвращения authorization server mix-up, проверено 2026-07-18.
- [RFC 9449: OAuth 2.0 Demonstrating Proof of Possession](https://www.rfc-editor.org/rfc/rfc9449.html) — IETF, RFC 9449, сентябрь 2023, проверено 2026-07-18.
- [OAuth 2.1 Authorization Framework draft history](https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/history/) — IETF OAuth WG, `draft-ietf-oauth-v2-1-15` от 2026-03-02, work in progress, проверено 2026-07-18.
- [NIST SP 800-228: Guidelines for API Protection for Cloud-Native Systems](https://csrc.nist.gov/pubs/sp/800/228/upd1/final) — NIST, SP 800-228 update 1, финальная версия от 2026-03-13, проверено 2026-07-18.
