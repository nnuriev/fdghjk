---
aliases:
  - Service-to-service networking
  - Service mesh data plane
  - Межсервисная сеть через proxy
tags:
  - область/основы-cs
  - тема/сети
  - архитектура/service-to-service
статус: проверено
---

# Proxy и service-to-service networking

## TL;DR

Proxy разрывает один сетевой path на downstream и upstream: принимает соединение или request с одной стороны и создаёт отдельное обращение с другой. Forward proxy выбирает клиент и использует его для доступа к origin servers; [[10 Основы CS/Reverse proxy|reverse proxy]] выглядит для клиента как origin и направляет запрос к контролируемым backends.

В service-to-service networking proxy — только data plane. Control plane распространяет service endpoints, routes, workload identities и policy; data plane применяет последний принятый snapshot к каждому connection/request. Полный путь выглядит так: logical service → discovered endpoints → readiness/policy → load balancing → connection pool → один или несколько attempts. Ни DNS, ни mTLS, ни retry по отдельности не заменяют этот конвейер.

## Область применимости

- Термины proxy и gateway/reverse proxy соответствуют RFC 9110 от июня 2022 года; forwarding metadata — RFC 7239.
- Versioned discovery и control-plane behavior показаны на Envoy 1.38.3; readiness — на Kubernetes 1.36.2; ambient-style L4/L7 placement — на Istio 1.30.3; workload identity — на стабильных SPIFFE specifications из documentation bundle v1.15.1. Состояние проверено 2026-07-18.
- Продукты служат примерами общих механизмов. Заметка не является руководством по настройке Envoy, Kubernetes, SPIRE или конкретного service mesh.
- Вне scope: ingress API management, глобальная маршрутизация регионов, BGP/ISIS и CNI datapath конкретного оркестратора.

## Ментальная модель

У межсервисной сети есть два разных контура:

```text
control plane
  discovery + desired routes + policy + identity material
                 |
                 v  versioned snapshot / stream
data plane
  downstream -> authenticate/route/filter -> choose endpoint
             -> get pooled connection -> upstream attempt
```

**Control plane** наблюдает desired и observed state, вычисляет конфигурацию и доставляет её proxies. **Data plane** находится на горячем пути: принимает bytes, проверяет локальную policy, выбирает endpoint и пересылает трафик. Запрос не должен синхронно ждать control plane. При его outage data plane обычно продолжает работу с last-known-good snapshot, но этот snapshot стареет.

Полезные инварианты:

1. Discovery сообщает topology, readiness — eligibility, load balancer выбирает endpoint, connection pool доставляет attempt. Это четыре разных решения.
2. mTLS аутентифицирует peer и защищает transport; authorization отдельно отвечает, разрешён ли этому identity конкретный service/method.
3. Один logical request может породить несколько upstream attempts. Proxy не делает non-idempotent operation безопасной своим присутствием.
4. Доверять forwarding metadata можно только внутри явно очерченной proxy chain. Внешний клиент способен прислать такой же header.
5. Control-plane version, endpoint snapshot и identity bundle являются частью наблюдаемого состояния data plane, а не скрытой «настройкой».

## Как устроено

### Forward и reverse proxy

Forward proxy выбирает client: он знает адрес proxy и просит обратиться к произвольному или policy-разрешённому origin. Такой посредник используют для egress control, caching и аудита клиентского доступа. RFC 9110 определяет proxy именно как message-forwarding agent, выбранный client, обычно по локальной configuration.

Gateway, или reverse proxy, выбран архитектурой сервиса. Для downstream client он выглядит authoritative origin, но пересылает request одному или нескольким upstream servers. TLS termination, routing, header normalization и balancing становятся его ответственностью. Разница задаётся ролью в конкретном exchange: один и тот же binary способен быть forward proxy для одного path и reverse proxy для другого.

HTTP proxy обязан удалить hop-by-hop fields, перечисленные в `Connection`, и корректно вести protocol version/`Via`. L7-посредник видит method, path и headers, поэтому может менять семантику и расширяет security surface; L4 proxy работает с connections/flows и не может применять HTTP method-level policy.

### Client-side и server-side networking

При **client-side discovery** библиотека внутри caller получает endpoint snapshot, выполняет [[10 Основы CS/Балансировка сетевой нагрузки|балансировку]] и управляет [[20 Бэкенд/Пулы соединений и keep-alive|пулами соединений]]. Это убирает отдельный proxy process/hop и даёт приложению полный контекст. Цена — одинаковую сложную policy приходится поддерживать во всех языках и версиях clients.

При **server-side discovery** client обращается к stable VIP/proxy, а тот выбирает backend. Clients проще, rollout routing policy централизован, но proxy становится capacity и failure boundary. Sidecar — распределённый вариант: приложение обращается к локальному proxy, а endpoint выбирает data plane рядом с workload, не один центральный router.

Независимо от размещения discovery pipeline остаётся тем же. [[40 Распределённые системы/Service discovery|Service discovery]] публикует множество кандидатов и version; readiness и local health строят eligible set; балансировщик выбирает host; pool либо переиспользует connection, либо ставит request в ограниченную очередь. DNS name может указывать на stable proxy/VIP или сразу на instances — эти случаи дают разное ownership выбора.

### Endpoints и readiness

Kubernetes EndpointSlice иллюстрирует более подробную модель discovery. Один Service может иметь несколько slices, и consumer обязан собрать их, а не считать первый полным snapshot. Conditions `ready`, `serving` и `terminating` разделяют готовность к новому traffic и graceful termination. В обычном случае `ready` соответствует `serving && !terminating`; `publishNotReadyAddresses` сознательно меняет эту семантику.

Readiness probe failure убирает Pod из обычного Service traffic, но propagation не мгновенна. Старый proxy snapshot и открытые connections ещё могут обращаться к endpoint. Поэтому removal сочетают с draining и passive health, а не считают registry update принудительным закрытием всех streams.

xDS-подобный protocol доставляет versioned resources. Data plane ACK подтверждает принятую конфигурацию; invalid update получает NACK, а proxy продолжает использовать предыдущую valid configuration. Разрыв management stream не обязан останавливать forwarding: last-known-good сохраняет availability, но proxy перестаёт видеть scale-out, removal и новую security policy. Возраст snapshot и NACK должны быть SLO-visible.

### Workload identity, mTLS и policy

IP-адрес плохо подходит для service identity: он переиспользуется, скрывается NAT/proxy и не выражает workload generation. SPIFFE ID задаёт URI вида `spiffe://trust-domain/path`; X.509-SVID помещает один SPIFFE ID в URI SAN. Workload получает rotating SVID и trust bundles через локальный Workload API, после чего peers валидируют certificate chain и expected identity.

mTLS доказывает, каким key владеет peer из доверенного domain, и шифрует канал. Затем authorization policy сопоставляет authenticated identity с destination, method/port и другими проверенными атрибутами. «Certificate valid» не означает «доступ разрешён», а service name из обычного header не заменяет cryptographic peer identity.

Rotation создаёт отдельную failure boundary. Если data plane перестал получать SVID/bundle updates, текущие connections могут продолжить работу, но новые handshakes после истечения или смены trust material начнут отказывать. Поэтому наблюдают срок действия local identity, возраст bundle и причину TLS validation failure.

### Deadlines, retries и overload

Proxy вычитает уже потраченное время и передаёт upstream остаток [[20 Бэкенд/Дедлайны запросов и распространение отмены|end-to-end deadline]], а downstream disconnect преобразует в cancellation, если protocol позволяет. Локальный timeout proxy не должен оставлять backend работать до независимого более длинного предела.

Retry proxy допустим только по правилам [[10 Основы CS/Retry safety|Retry safety]]. Timeout или reset после передачи request имеет ambiguous outcome; для write нужны [[20 Бэкенд/Идемпотентные и неидемпотентные операции|идемпотентный контракт]] либо [[20 Бэкенд/Ключи идемпотентности и дедупликация запросов|дедупликация]]. Повторы на client, sidecar и upstream SDK одновременно создают [[40 Распределённые системы/Retry storms и cascading failures|retry storm]].

При saturation proxy ограничивает pool queue и concurrency. [[40 Распределённые системы/Circuit breaker|Circuit breaker]] прекращает обращения к явно деградировавшей зависимости, а [[40 Распределённые системы/Load shedding|load shedding]] отвергает лишнюю работу до дорогих filters/upstream calls. Ни один алгоритм балансировки не создаёт capacity, если весь eligible set насыщен.

### Trusted forwarding metadata

`Forwarded`, `X-Forwarded-For`, internal identity, original-protocol, deadline и attempt headers — данные, а не доказательство. RFC 7239 прямо учитывает, что header может быть добавлен или изменён любой стороной path и раскрывать чувствительную topology information.

На входе trust boundary proxy удаляет внешние значения внутренних headers и создаёт их заново из authenticated connection и собственного наблюдения. Следующий hop принимает metadata только от известного peer по защищённому transport; при нескольких proxies нужна фиксированная trusted-hop policy. Client IP, service identity и authorization context нельзя брать из «левого» элемента XFF или из произвольного `X-Service-Name`.

Разные классы metadata требуют разной политики. Trace ID допустимо сохранить после проверки формата/размера, но identity нужно получить из mTLS context. Remaining deadline можно только уменьшать. Attempt count proxy увеличивает сам. Hop-by-hop fields не пересылают как end-to-end headers.

### Размещение data plane

**Library в client process** не создаёт дополнительный локальный hop и использует domain context приложения. Зато языки расходятся по TLS, retries, draining и telemetry; обновление policy требует rollout clients.

**Sidecar на workload** даёт единообразный L4/L7 stack и маленькую failure boundary: падение proxy обычно ломает сеть одного workload. Цена — process на каждый workload, CPU/memory overhead, два локальных crossings и сложность согласованного lifecycle приложения и sidecar.

**Node proxy** делит ресурсы между workloads и уменьшает число процессов. Он расширяет blast radius до узла, усложняет per-workload attribution/identity и требует защищённого способа связать traffic с исходным workload.

**Ambient-style data plane** выносит общий L4 tunnel на node, а L7 policy выполняет только через отдельные waypoints. Это уменьшает число sidecars, но разделяет enforcement между уровнями: без L7 waypoint общий tunnel не способен авторизовать HTTP method/path, а shared components получают более широкую failure boundary.

**Центральный reverse proxy** проще для ingress или небольшого числа heterogeneous clients, но добавляет сетевой hop и концентрирует capacity, certificates и configuration в одной failure boundary. Размещение выбирают по требуемой L7 policy, blast radius, стоимости обновления и тому, где доступна достоверная workload identity.

### Наблюдаемость и failure boundaries

Trace должен разделять downstream logical request и upstream attempts. Для каждого hop полезны: proxy instance/placement, route и config version, snapshot age, выбранный endpoint и readiness state, pool wait, connection reuse, authenticated peer identity, policy decision, remaining deadline, attempt number, retry reason, local reply flag, upstream status/reset и cancellation initiator.

Отказ control plane отличается от отказа data plane. В первом случае configuration стареет, но existing traffic может идти; во втором конкретный path перестаёт пересылать bytes. Отдельно видны discovery-empty, discovery-update-failed, no-healthy-upstream, TLS identity failure, policy deny, pool overflow и upstream timeout. Сведение их к одному `503` лишает систему причинной диагностики.

## Пример или трассировка

Service `orders` вызывает logical service `inventory` через локальный data plane. Control plane доставил snapshot `v42`:

```text
E1: ready=true,  serving=true,  terminating=false
E2: ready=false, serving=true,  terminating=true
E3: ready=false, serving=false, terminating=false
```

1. Proxy подтвердил `v42` через ACK и строит eligible set `{E1}`. `E2` drain-ится, `E3` ещё не готов; наличие всех трёх в topology не делает их равноправными.
2. Workload `orders` имеет X.509-SVID `spiffe://prod.example/ns/shop/sa/orders`. mTLS peer валидирует SVID по trust bundle, затем policy разрешает этому identity метод `CheckStock` у `inventory`.
3. Proxy удаляет присланные client значения внутренних identity/attempt headers, сохраняет проверенный trace ID, записывает authenticated identity и передаёт остаток deadline. Из bounded HTTP/2 pool он получает stream к `E1`; load balancing не открывает connection автоматически на каждый request.
4. `E1` отвечает успешно. Trace содержит logical request ID и upstream attempt `1`, route/config `v42`, endpoint `E1`, pool wait и обе latency.
5. Затем management stream обрывается. Data plane продолжает использовать `v42`: control-plane outage сам по себе не рвёт request path. Однако новый snapshot `v43` с `E4` не приходит.
6. `E1` завершается. Passive connect failures локально исключают его; eligible set пуст. Proxy быстро возвращает `no_healthy_upstream` вместо безразмерной очереди. Метрики `config_age` и control-plane disconnect объясняют, почему proxy не увидел `E4`.

Наблюдаемый результат: last-known-good пережил краткий outage control plane, но не превратился в вечную истину. Readiness, local health и bounded failure сохранили data-plane capacity; config version связала пользовательский отказ со stale control state.

## Trade-offs

Централизация policy в proxy ускоряет единообразные security и reliability fixes, но создаёт opaque behavior для приложения и общую ошибку конфигурации. Client library прозрачнее для domain logic, зато увеличивает число реализаций и версий одного механизма.

Last-known-good предпочитает availability: control-plane outage не останавливает трафик. Цена — stale endpoints и policy. Fail-closed нужен, когда устаревшая authorization policy опаснее outage; для обычного routing мгновенное очищение snapshot часто превращает отказ management plane в полный data-plane outage.

mTLS даёт сильную workload authentication и защищает канал, но требует rotation, trust-domain design и наблюдаемой validation. Network ACL/IP проще, однако хуже переносит autoscaling, NAT и переиспользование адресов. Во многих системах эти уровни дополняют, а не заменяют друг друга.

## Типичные ошибки

### Control plane включают в синхронный request path

- **Неверное предположение:** proxy должен подтверждать route у management server для каждого request.
- **Симптом:** outage control plane немедленно останавливает весь service traffic.
- **Причина:** data plane не имеет локального versioned snapshot.
- **Исправление:** применять последнюю валидную конфигурацию локально, отдельно ограничить допустимый config age и выбрать fail-open/fail-closed по риску.

### Discovery считают готовым routing decision

- **Неверное предположение:** любой зарегистрированный endpoint можно сразу выбрать.
- **Симптом:** traffic идёт в starting или terminating workloads.
- **Причина:** topology смешана с readiness, local health и draining.
- **Исправление:** строить eligible set из versioned discovery и условий готовности; отдельно управлять existing connections.

### mTLS считают authorization

- **Неверное предположение:** любой valid certificate внутри trust domain разрешает любой RPC.
- **Симптом:** скомпрометированный workload обращается к несвязанным внутренним сервисам.
- **Причина:** authentication identity не сопоставлена с destination/action policy.
- **Исправление:** авторизовать verified workload identity на конкретном route/method и логировать решение policy.

### Доверяют forwarding headers от внешнего клиента

- **Неверное предположение:** `X-Forwarded-For` или `X-Service-Identity` правдивы по названию.
- **Симптом:** обход IP/identity policy и подмена audit trail.
- **Причина:** trust boundary не очищает client-controlled metadata.
- **Исправление:** strip/overwrite на ingress, принимать внутренние headers только от authenticated trusted hop и ограничивать глубину цепочки.

### Proxy незаметно повторяет writes

- **Неверное предположение:** retry `5xx` — чисто сетевая оптимизация.
- **Симптом:** duplicate side effects, хотя приложение отправило один request.
- **Причина:** logical request превратился в несколько attempts без знания idempotency и failure point.
- **Исправление:** отключить generic retries для writes; разрешать их только по явному operation contract, с общим budget и attempt telemetry.

### Все proxy deployments считают эквивалентными

- **Неверное предположение:** sidecar, node proxy и shared waypoint различаются только стоимостью CPU.
- **Симптом:** один node failure ломает много workloads или L7 policy ожидают от L4 tunnel.
- **Причина:** проигнорированы placement-specific blast radius, visibility и enforcement layer.
- **Исправление:** явно нарисовать data path, owner identity, policy layer и failure boundary каждого компонента.

## Когда применять

Модель нужна при выборе между client library, sidecar, node/ambient data plane и central proxy; при проектировании internal mTLS, discovery, policy propagation и retries; при расследовании ситуации, где приложение видит один status, а реальный отказ произошёл в другом hop.

Для design review достаточно проследить один request: откуда взялся endpoint set, кто исключил unready hosts, кто выбрал endpoint, где ждал pool, кто аутентифицировал обе стороны, какой deadline и attempt count прошли дальше, что случится при потере control plane и какие telemetry поля это докажут.

## Источники

- [RFC 9110 — HTTP Semantics: intermediaries, proxy and gateway](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RFC 7239 — Forwarded HTTP Extension](https://www.rfc-editor.org/rfc/rfc7239.html) — IETF, RFC 7239, июнь 2014, проверено 2026-07-18.
- [Kubernetes Services](https://kubernetes.io/docs/concepts/services-networking/service/) — Kubernetes Documentation, версия 1.36.2, проверено 2026-07-18.
- [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/) — Kubernetes Documentation, версия 1.36.2, проверено 2026-07-18.
- [Pod lifecycle: container probes and readiness](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-probes) — Kubernetes Documentation, версия 1.36.2, проверено 2026-07-18.
- [Service discovery](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/upstream/service_discovery) — Envoy Project, документация Envoy 1.38.3, проверено 2026-07-18.
- [xDS REST and gRPC protocol](https://www.envoyproxy.io/docs/envoy/v1.38.3/api-docs/xds_protocol) — Envoy Project, документация Envoy 1.38.3, проверено 2026-07-18.
- [Deployment types](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/deployment_types/deployment_types) — Envoy Project, документация Envoy 1.38.3, проверено 2026-07-18.
- [HTTP header sanitizing](https://www.envoyproxy.io/docs/envoy/v1.38.3/configuration/http/http_conn_man/header_sanitizing.html) — Envoy Project, документация Envoy 1.38.3, проверено 2026-07-18.
- [Ambient mode overview](https://istio.io/latest/docs/ambient/overview/) — Istio Project, документация Istio 1.30.3, проверено 2026-07-18.
- [SPIFFE Identity and Verifiable Identity Document](https://spiffe.io/docs/latest/spiffe-specs/spiffe-id/) — SPIFFE Project, stable specification, documentation bundle v1.15.1, проверено 2026-07-18.
- [X509-SVID](https://spiffe.io/docs/latest/spiffe-specs/x509-svid/) — SPIFFE Project, stable specification, documentation bundle v1.15.1, проверено 2026-07-18.
- [SPIFFE Workload API](https://spiffe.io/docs/latest/spiffe-specs/spiffe_workload_api/) — SPIFFE Project, stable specification, documentation bundle v1.15.1, проверено 2026-07-18.
