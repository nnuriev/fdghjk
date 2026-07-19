---
aliases:
  - API Gateway
  - Шлюз API
  - Edge API gateway
tags:
  - область/бэкенд
  - тема/api
  - архитектура/gateway
статус: проверено
---

# API gateway

## TL;DR

API gateway — policy boundary перед набором backend APIs. Он принимает внешний protocol contract, выбирает route и применяет общие проверки: TLS, authentication, ограничения размера, rate limits, deadlines, безопасные retries и telemetry. Физически data plane часто построен как [[10 Основы CS/Балансировка сетевой нагрузки|L7 reverse proxy]], но смысл gateway шире: к нему добавляются API-aware policies и versioned control plane.

Gateway не должен владеть бизнес-процессом. Проверить подпись token, общий scope и tenant format на входе разумно; решить, имеет ли пользователь право изменить конкретный invoice, может только владелец ресурса. Когда gateway начинает собирать заказ, резервировать склад и проводить платёж, он превращается в центральный orchestration service с чужими инвариантами и большим blast radius.

## Область применимости

Заметка описывает north-south gateway для HTTP/gRPC API. HTTP gateway и reverse proxy определены по RFC 9110 от июня 2022 года. Маршрутизация и attachment model сверены с Kubernetes Gateway API 1.4.0; external authorization и rate limiting — с Envoy 1.38.3. Внутренний service mesh и полноценный Backend for Frontend (BFF) вне scope.

## Ментальная модель

Gateway — исполняемый пограничный контракт:

```text
untrusted client
  -> normalize and bound
  -> authenticate
  -> apply coarse policy and quota
  -> choose API route/version
  -> forward one bounded attempt
  -> preserve outcome and telemetry
  -> owner service enforces business authorization
```

У него две части. **Data plane** обрабатывает каждый request по уже принятому snapshot. **Control plane** собирает routes, certificates и policies, валидирует их и выпускает versioned configuration. Control plane может быть временно недоступен, а data plane должен продолжать обслуживать traffic по last-known-good snapshot.

Главные инварианты:

1. Внешний caller не может сам назначить trusted identity, route или internal forwarding headers.
2. Gateway применяет только policy, одинаковую для всего route или API class. Object-level решение остаётся у owner service.
3. Один downstream request имеет общий deadline и ограниченное число upstream attempts.
4. Изменение configuration публикуется атомарным snapshot либо с явно совместимыми фазами. Половина новой route table опаснее старой целиком.

## Как устроено

### Data plane и control plane

Data plane держит listeners, routing table, upstream pools и filters. Он не должен синхронно обращаться к control plane на каждом request: outage управления иначе становится outage пользовательского API. Snapshot содержит monotonically identifiable version; после проверки ссылок, certificates и conflicts gateway применяет его целиком. При ошибке остаётся предыдущая версия, а не частично разобранная конфигурация.

Ownership конфигурации тоже часть безопасности. Gateway API 1.4.0 разделяет infrastructure (`GatewayClass`, `Gateway`) и прикрепляемые routes. Ссылка route на backend или другой resource в чужом namespace требует `ReferenceGrant`; cross-namespace attachment route к самому Gateway регулирует `AllowedRoutes`. Общий принцип переносим за пределы Kubernetes: владелец API может объявить route, но не должен молча направить traffic в чужой backend или trust domain.

### Порядок policy

Порядок filters влияет на стоимость и безопасность. Типичный path выглядит так:

1. завершить TLS, проверить допустимый protocol и нормализовать authority/path;
2. удалить недоверенные `X-Forwarded-*`, identity и internal routing headers, затем записать собственные значения;
3. ограничить header/body size, parsing time и concurrency до дорогих внешних проверок;
4. проверить credential, issuer, audience, expiry и общий API scope;
5. применить [[20 Бэкенд/Rate limiting и quotas|rate limit или quota]] по серверной identity;
6. выбрать route/version, установить upstream deadline и передать trace context;
7. после response записать outcome без token, secret и чувствительного body.

Authentication на gateway снижает дублирование криптографической проверки и отсекает явно неверные requests. Но [[20 Бэкенд/Аутентификация и авторизация на уровне API|авторизация на уровне API]] остаётся двухступенчатой: gateway выполняет дешёвую общую проверку, owner сверяет resource state, tenant ownership и business policy.

External authorization или global limiter добавляют сетевую dependency. Для каждой policy заранее выбирают fail-open или fail-closed. Чувствительный write обычно закрывается при неопределённости; telemetry endpoint иногда можно пропустить с локальным ограничением. Один общий default для всех routes маскирует security/availability trade-off.

### Routing, versions и преобразования

HTTP route сопоставляет hostname, path, headers или query parameters с backend и весами. Weighted backends удобны для canary, но rollout безопасен лишь при совместимых API и schema. Правила backward compatibility раскрыты в [[20 Бэкенд/Контракты API и обратная совместимость|контрактах API]], а lifecycle нескольких public versions — в [[20 Бэкенд/Версионирование API|версионировании API]].

Gateway может удалить hop-by-hop fields, преобразовать transport envelope или закончить TLS. Глубокое преобразование business payload создаёт второй contract owner. Если gateway переводит поля v1 в v2, он обязан определять lossless mapping, ошибки и срок жизни adapter; иначе клиенты получают тихое semantic corruption.

Streaming меняет resource model. Нельзя читать весь body для проверки, если contract допускает большой upload или бесконечный stream. Limits задают отдельно для bytes, времени чтения, concurrent streams и idle period. Cancellation и deadline должны пройти к backend, иначе client уже ушёл, а gateway продолжает дорогую работу.

### Gateway и business orchestration

Gateway aggregation допустима для transport-oriented read fan-out, если она имеет собственный контракт, deadline и partial-result semantics. Но workflow с изменением нескольких доменных состояний лучше размещать в отдельном application service, который владеет state machine и recovery. Граница определяется ownership, а не тем, что оба процесса принимают HTTP.

Если gateway знает внутренние таблицы, последовательность compensations и статус каждого payment attempt, он уже не edge policy component. Такой код сложно выпускать независимо, он связывает все команды общим rollout и переносит domain failure modes в точку входа.

### Отказы и наблюдаемость

Gateway ограничивает pools, per-route concurrency и retries. При собственной перегрузке он применяет [[40 Распределённые системы/Load shedding|load shedding]] до чтения большого body и внешнего auth call. Retry учитывает method semantics, оставшийся deadline и idempotency contract. Ответ `504` означает, что gateway не получил своевременный upstream response, но не доказывает отсутствие эффекта.

Минимальная telemetry: route/config version, authentication result без credential, authorization/limiter dependency outcome, local queue time, upstream attempts, response source, body rejection, per-route latency и status class. W3C Trace Context задаёт перенос `traceparent` и `tracestate`, но входной trace context остаётся недоверенным: gateway валидирует формат, ограничивает размер и не помещает туда PII.

## Пример или трассировка

Клиент отправляет `POST /v1/orders` с bearer token и `Idempotency-Key: k-42`.

1. Gateway принимает TLS, удаляет входные `X-User-ID` и `X-Tenant-ID`, проверяет body limit и создаёт trusted request context.
2. Token проходит issuer, audience, expiry и scope `orders:write`. Limiter списывает cost unit для authenticated tenant.
3. Config snapshot `g-81` направляет route в `OrderService v2`. Gateway передаёт оставшийся deadline, idempotency key и новый trace parent.
4. `OrderService` сам проверяет, что caller вправе создавать заказ для указанного account, затем атомарно сохраняет business outcome по `k-42`.
5. Upstream response теряется после commit, и gateway достигает deadline. Он возвращает `504`, не повторяя unsafe request вслепую. Клиент повторяет команду с `k-42`; owner возвращает прежний outcome.

Наблюдаемый результат: gateway отсеял недоверенную identity и применил общую policy, но business authorization и дедупликация остались у владельца заказа. Неизвестный transport outcome не превратился в двойной заказ.

## Trade-offs

Тонкий gateway проще масштабировать и обновлять: routing, coarse authentication, limits, deadlines, telemetry. Богатый gateway уменьшает повтор middleware в сервисах, но быстро становится общей runtime и release dependency. Business-specific transformations и orchestration лучше выносить в BFF или application service с явным owner.

Централизованные policies дают единый enforcement и audit. Library в каждом сервисе убирает сетевой hop к внешнему policy service и лучше знает локальный resource, зато версии library и policy расходятся. Практичный разрез: общая проверка на gateway, окончательное решение у resource owner.

Один глобальный gateway упрощает public endpoint, но увеличивает blast radius и WAN path. Regional gateways уменьшают latency и изолируют capacity; им нужны совместимые config snapshots, region-aware routing и заранее выбранное поведение при потере control plane.

## Типичные ошибки

### Gateway становится владельцем workflow

- **Неверное предположение:** центральная точка входа — естественное место любой orchestration.
- **Симптом:** изменение checkout требует rollout gateway, а его outage ломает все домены.
- **Причина:** edge policy смешана с business state machine.
- **Исправление:** оставить gateway transport/policy boundary, workflow передать application service с собственным state и recovery.

### Авторизация выполняется только на gateway

- **Неверное предположение:** валидный token и общий scope разрешают доступ к любому resource.
- **Симптом:** пользователь читает чужой invoice, подменив ID в path.
- **Причина:** gateway не знает актуальный owner и tenant state.
- **Исправление:** coarse filter на входе, object-level authorization в сервисе-владельце.

### Любой `5xx` автоматически повторяется

- **Неверное предположение:** gateway видит, был ли side effect committed.
- **Симптом:** один POST создаёт два эффекта или retry storm добивает backend.
- **Причина:** response failure смешан с operation failure.
- **Исправление:** retry matrix по method/outcome, общий budget и idempotency contract.

### Ошибка control plane очищает routes

- **Неверное предположение:** пустая новая configuration безопаснее устаревшей.
- **Симптом:** ошибка генератора мгновенно отключает весь API.
- **Причина:** нет atomic validation и last-known-good snapshot.
- **Исправление:** versioned snapshots, reject-on-invalid, staged rollout и отдельная сигнализация config age.

### Недоверенные forwarding headers проходят внутрь

- **Неверное предположение:** `X-User-ID` уже добавил доверенный proxy.
- **Симптом:** внешний caller назначает себе tenant или internal role.
- **Причина:** trust boundary не очищает входные метаданные.
- **Исправление:** удалить внешние copies и записать trusted headers после authentication; ограничить, кто может обращаться к backend напрямую.

## Когда применять

API gateway оправдан, когда несколько APIs разделяют внешний trust boundary, routing, authentication, quotas, certificates и наблюдаемость. Он особенно полезен для публичных clients, которым нельзя раскрывать topology, и для независимой эволюции backend deployments.

Не добавляйте gateway как обязательный hop только ради термина. Для одного сервиса reverse proxy или platform ingress может закрыть transport-задачу дешевле. Перед внедрением перечислите policies, их scope и owner, fail-open/fail-closed, пределы resources, правила retry, control-plane rollout и проверки, которые всё равно остаются в сервисах.

## Источники

- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [Gateway API reference](https://gateway-api.sigs.k8s.io/reference/api-spec/1.4/spec/) — Kubernetes SIG Network, Gateway API 1.4.0, проверено 2026-07-18.
- [External authorization](https://www.envoyproxy.io/docs/envoy/v1.38.3/configuration/http/http_filters/ext_authz_filter) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Rate limit](https://www.envoyproxy.io/docs/envoy/v1.38.3/configuration/http/http_filters/rate_limit_filter) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [RFC 9700: Best Current Practice for OAuth 2.0 Security](https://www.rfc-editor.org/rfc/rfc9700.html) — IETF, BCP 240 / RFC 9700, январь 2025, проверено 2026-07-18.
- [Trace Context](https://www.w3.org/TR/trace-context/) — W3C, Recommendation от 2021-11-23, проверено 2026-07-18.
