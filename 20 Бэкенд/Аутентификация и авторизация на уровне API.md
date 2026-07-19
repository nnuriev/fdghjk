---
aliases:
  - API authentication and authorization
  - Authentication vs authorization
  - AuthN and AuthZ
  - Контроль доступа API
tags:
  - область/бэкенд
  - тема/безопасность
статус: проверено
---

# Аутентификация и авторизация на уровне API

## TL;DR

Аутентификация (authentication, AuthN) устанавливает principal и свойства credential. Авторизация (authorization, AuthZ) решает, может ли этот principal выполнить конкретное действие над конкретным ресурсом в данном контексте. Валидный JWT или scope ещё не дают доступ к произвольному объекту: resource server обязан проверить issuer, audience, срок и профиль токена, а затем применить policy к tenant, owner, состоянию ресурса и операции.

Gateway может отсеять отсутствующие и явно невалидные credentials, но окончательное решение должно находиться у владельца данных и инварианта. Политика работает deny-by-default, а запросы к хранилищу с самого начала ограничиваются разрешённой областью. `401` означает отсутствие валидных authentication credentials и требует challenge; `403` — credentials поняты, но доступа недостаточно. Для сокрытия существования ресурса сервер вправе ответить `404`.

## Область применимости

Заметка рассматривает HTTP API/resource server, bearer access tokens и прикладную авторизацию в multi-tenant backend. OAuth authorization flow, выдача токенов, browser sessions, MFA и управление пользовательскими паролями остаются вне scope. JWT описан как один формат access token; OAuth access token не обязан быть JWT.

## Ментальная модель

Проверка доступа — pipeline с разными доказательствами:

```text
request
  -> transport/credential extraction
  -> token validation or introspection
  -> immutable principal
  -> load/scoped lookup of resource
  -> policy(subject, action, resource, environment)
  -> business effect
  -> audit decision
```

AuthN отвечает «кто или что предъявило credential?». AuthZ отвечает «разрешено ли `invoice:read` для invoice `i7` tenant `t1` в момент запроса?». Разделение важно: подпись токена доказывает происхождение набора claims, но не истинность client-supplied path parameter и не актуальность всех прав.

Policy Enforcement Point (PEP) перехватывает действие и исполняет решение. Policy Decision Point (PDP) вычисляет permit/deny. Они могут быть библиотекой в одном процессе или отдельным сервисом; сетевое размещение не меняет обязанности владельца ресурса передать корректные атрибуты и применить ответ без обходного пути.

## Как это устроено

### 1. Извлечение и проверка credential

Bearer token передают в `Authorization: Bearer ...` по защищённому transport. Bearer означает, что владение токеном достаточно для использования, поэтому его защищают в хранилище и логах. Передача в query string опасна: URL попадает в history, access logs и referrer, поэтому RFC 6750 не рекомендует этот способ.

Для self-contained JWT resource server как минимум:

- разрешает только ожидаемый набор algorithms, не принимает алгоритм из токена как policy;
- проверяет подпись подходящим ключом;
- проверяет `iss`, что `aud` содержит этот API, и временные ограничения;
- различает access token и другой JWT по явному профилю/`typ`, если профиль это предусматривает;
- не смешивает токены разных issuers с несовместимыми validation rules.

RFC 9068 задаёт профиль JWT access token с `typ=at+jwt`, обязательными claims и правилами audience, но API применяет его только если issuer и resource server договорились об этом профиле. Для opaque token проверка обычно выполняется introspection или lookup; кэш снижает latency, но продлевает действие отозванного права на срок TTL.

Результат validation преобразуют в внутренний immutable principal: subject, tenant, client, scopes, authentication strength и token metadata. Handler не должен снова парсить raw token или доверять одноимённым заголовкам, которые мог прислать внешний клиент. Gateway обязан удалить/перезаписать internal identity headers и аутентифицировать связь с backend.

### 2. Решение авторизации

Минимальный вход policy — `(subject, action, resource, environment)`. NIST ABAC описывает решение через атрибуты subject, object, requested operation и окружения. На практике методы можно сочетать:

- **RBAC** сопоставляет роли с разрешениями и удобен для устойчивых должностных функций;
- **ABAC** учитывает tenant, классификацию данных, регион, время и состояние ресурса;
- **ReBAC** выводит доступ из отношений, например owner, member или parent folder.

Scope в access token обычно даёт coarse-grained разрешение вроде `invoices:read`. Он не доказывает, что invoice принадлежит тому же tenant или доступен этому пользователю. Object-level check выполняется после получения доверенного resource identity, но запрос в БД лучше сразу ограничить `tenant_id`/доступным набором. Схема «найти по глобальному ID, затем проверить» повышает риск утечки через side channel и случайный ранний return.

Policy должна применяться на каждом entry point: HTTP, consumer, scheduled job и административный tool. Проверка только в UI или gateway обходится внутренним вызовом. Внутри сервиса полезно авторизовать command у владельца данных, а не размазывать условие по controllers.

### 3. Время решения и изменение прав

JWT фиксирует claims на момент выдачи и действует до expiry, даже если роль уже удалена, если нет отдельного revocation/lookup. Короткий lifetime уменьшает окно stale authorization, но увеличивает refresh traffic. Live policy lookup даёт более свежий ответ, но добавляет latency и availability dependency.

Для критичного действия проверку выполняют максимально близко к commit и включают состояние ресурса в атомарное условие изменения. Иначе между `authorize` и `UPDATE` другой процесс способен сменить owner или состояние — классический time-of-check/time-of-use (TOCTOU). Например, `UPDATE invoices ... WHERE id=? AND tenant_id=? AND status='draft'` одновременно подтверждает часть policy и бизнес-предусловие.

### 4. HTTP-ответы и challenge

По RFC 9110:

- `401 Unauthorized` означает, что запрос не содержит валидных authentication credentials; ответ содержит `WWW-Authenticate` с применимым challenge;
- `403 Forbidden` означает, что сервер понял запрос, но отказывается его выполнять; новые credentials могут не помочь;
- сервер может использовать `404 Not Found`, чтобы не раскрывать существование запрещённого ресурса.

RFC 6750 уточняет bearer errors: истёкший или невалидный token обычно приводит к `401` и `error="invalid_token"`, а недостаточный scope — к `403` и `error="insufficient_scope"`. Подробность error body ограничивают, чтобы не превращать API в oracle о пользователях, ресурсах и policy.

### 5. Аудит без утечки credential

Audit event связывает request ID, principal ID, action, resource type/ID, decision, policy version и reason code. Raw bearer token, secret claims и полный чувствительный ресурс туда не пишут. Разрешённые и запрещённые решения наблюдают отдельно: всплеск deny может означать атаку, поломку rollout policy или ошибочный audience.

## Сквозной пример: чтение invoice в tenant

Запрос:

```http
GET /tenants/t1/invoices/i7
Authorization: Bearer <access-token>
```

1. Resource server проверяет TLS boundary, подпись/issuer, что `aud` предназначен этому API, срок действия и ожидаемый token profile. Из claims получается principal `subject=u9`, `tenant=t1`, scope `invoices:read`.
2. Repository выполняет scoped lookup `WHERE tenant_id=t1 AND invoice_id=i7`, а не глобальный lookup только по `i7`.
3. Policy проверяет action `invoice:read`, membership `u9` в tenant, scope и classification invoice. Role `viewer` разрешает чтение, но не изменение.
4. Для invoice другого tenant scoped lookup ничего не возвращает. API по выбранной concealment policy отвечает одинаковым `404`, не подтверждая существование объекта.
5. Если token истёк, lookup не выполняется: API отвечает `401` с Bearer challenge. Если token валиден, ресурс видим, но scope недостаточен, ответ — `403`.

Наблюдаемый результат: подмена `t1` или `i7` в URL не расширяет область доступа. Gateway validation экономит работу, но tenant invariant остаётся у сервиса, который владеет invoice — в соответствии с [[50 Проектирование систем/Границы сервисов|границей данных]].

## Trade-offs и альтернативы

### Self-contained JWT или opaque token

JWT проверяется локально и не делает authorization server runtime dependency, но claims устаревают до expiry, а ошибка audience/algorithm создаёт широкую уязвимость. Opaque token с introspection проще отозвать и централизованно трактовать, зато каждый lookup или cache зависит от control plane. Формат выбирают по требуемой свежести и blast radius, а не по экономии одного запроса вообще.

### RBAC, ABAC или ReBAC

RBAC легче объяснить и аудитировать при небольшом числе устойчивых ролей, но role explosion начинается, когда роли кодируют tenant, регион и состояние объекта. ABAC выражает такие условия напрямую, зато сложнее тестируется и объясняет решение. ReBAC естественен для графов совместного доступа, но требует корректного хранения и обхода отношений. Часто coarse RBAC/scope сочетают с resource-level attributes.

### Policy library или удалённый PDP

Локальная библиотека даёт низкую latency и работает при сетевых сбоях, но policy rollout связан с приложением или snapshot delivery. Удалённый PDP централизует policy и аудит, однако добавляет request dependency. Кэширование требует версии, TTL и явного fail-open/fail-closed; для чувствительной операции deny при неопределённости обычно безопаснее доступности.

### Проверка в gateway или сервисе

Gateway полезен для общей token validation, rate limits и грубых scopes. Только сервис знает актуальный resource state и tenant ownership. Поэтому defense in depth не означает две разные политики: gateway выполняет дешёвый общий фильтр, owner — окончательный object-level decision.

## Типичные ошибки

### «JWT подписан — доступ разрешён»

- **Неверное предположение:** подпись равна авторизации.
- **Симптом:** token другого audience или пользователь другого tenant читает ресурс.
- **Причина:** не проверены `iss`/`aud` и object-level policy.
- **Исправление:** строгий validation profile, затем отдельное решение `(subject, action, resource, environment)`.

### Доверие tenant из URL

- **Неверное предположение:** аутентифицированный клиент честно указывает scope данных.
- **Симптом:** IDOR/BOLA — перебор ID открывает чужие объекты.
- **Причина:** path parameter использован как доверенный authorization context.
- **Исправление:** связать tenant с principal/membership и ограничить lookup разрешённой областью.

### Авторизация только в gateway

- **Неверное предположение:** все вызовы всегда проходят один ingress.
- **Симптом:** internal endpoint, job или consumer обходит resource policy.
- **Причина:** решение отделено от владельца данных.
- **Исправление:** общий ingress filter плюс обязательная проверка в application/service boundary.

### Логирование bearer token

- **Неверное предположение:** token нужен для расследования.
- **Симптом:** обладатель доступа к логам может вызвать API от имени пользователя.
- **Причина:** bearer credential скопирован в access/error logs.
- **Исправление:** redact Authorization, логировать token ID/hash только при обоснованной необходимости и ограниченном доступе.

### Невыбранный fail-open

- **Неверное предположение:** timeout PDP — обычная техническая ошибка.
- **Симптом:** либо outage всего API, либо несанкционированный доступ при сбое policy service.
- **Причина:** availability/security trade-off оставлен случайной обработке exception.
- **Исправление:** выбрать поведение по классу действия, ограничить cache и проверить его chaos-сценарием.

## Когда применять

AuthN нужна на каждой недоверенной границе, где запрос должен быть связан с человеком, workload или client. AuthZ нужна для каждого защищённого действия, включая чтение, фоновые consumers и administrative paths. Чем чувствительнее ресурс, тем ближе к data commit должна находиться проверка и тем короче допустимо окно stale policy.

Перед выпуском API моделируют matrix principal × action × resource state, тестируют cross-tenant negative cases и отдельно проверяют expired token, wrong audience, отозванную роль, недоступный PDP и TOCTOU. Happy path не доказывает изоляцию.

## Источники

- [RFC 9110: HTTP Semantics](https://datatracker.ietf.org/doc/html/rfc9110) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RFC 6750: The OAuth 2.0 Authorization Framework: Bearer Token Usage](https://datatracker.ietf.org/doc/html/rfc6750) — IETF, RFC 6750, октябрь 2012, обновлён RFC 8996 и RFC 9700, проверено 2026-07-18.
- [RFC 8725: JSON Web Token Best Current Practices](https://datatracker.ietf.org/doc/html/rfc8725) — IETF, BCP 225 / RFC 8725, февраль 2020, проверено 2026-07-18.
- [RFC 9068: JWT Profile for OAuth 2.0 Access Tokens](https://datatracker.ietf.org/doc/html/rfc9068) — IETF, RFC 9068, октябрь 2021, проверено 2026-07-18.
- [RFC 7662: OAuth 2.0 Token Introspection](https://datatracker.ietf.org/doc/html/rfc7662) — IETF, RFC 7662, октябрь 2015, проверено 2026-07-18.
- [RFC 9700: Best Current Practice for OAuth 2.0 Security](https://datatracker.ietf.org/doc/html/rfc9700) — IETF, BCP 240 / RFC 9700, январь 2025, проверено 2026-07-18.
- [NIST SP 800-162: Guide to Attribute Based Access Control Definition and Considerations](https://csrc.nist.gov/pubs/sp/800/162/upd2/final) — NIST, SP 800-162 от января 2014 года, обновление 2 от 2019-08-02, проверено 2026-07-18.
