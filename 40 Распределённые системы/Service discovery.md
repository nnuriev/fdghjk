---
aliases:
  - Service discovery
  - Обнаружение сервисов
  - Registry-based discovery
tags:
  - область/распределённые-системы
  - тема/сети
  - механизм/discovery
статус: проверено
---

# Service discovery

## TL;DR

Service discovery сопоставляет логическое имя сервиса с меняющимся набором endpoints и metadata: address, port, zone, weight, protocol, version. Оно сообщает topology, но не доказывает способность endpoint выполнить конкретный request. Membership, readiness и наблюдаемое health — разные сигналы с разной задержкой.

Discovery почти всегда eventually consistent. Client или proxy принимает решение по локальному snapshot, который может содержать уже удалённый endpoint или ещё не видеть новый. Корректный data plane переживает эту неопределённость: проверяет health, ограничивает connection timeout, умеет обновить snapshot и не очищает last-known-good набор только потому, что control plane временно недоступен.

## Область применимости

DNS-модель и TTL опираются на RFC 1034, SRV records — на RFC 2782. Registry/watch и health semantics показаны на Kubernetes 1.36 EndpointSlice и Envoy 1.38.3. Заметка описывает endpoint discovery внутри системы; глобальный выбор региона раскрыт в [[40 Распределённые системы/Multi-region architecture|multi-region architecture]].

## Ментальная модель

У caller есть две независимо стареющие картины:

```text
topology snapshot: service -> endpoint identities + metadata, version V
health snapshot:   endpoint -> ready/degraded/unhealthy, observed at T
```

Topology отвечает «кто считается членом сервиса». Health отвечает «кому стоит послать новый attempt». Endpoint, исчезнувший из свежего registry snapshot, ещё может обслуживать in-flight traffic. Endpoint, который registry по-прежнему перечисляет, уже может быть недоступен.

Полезные инварианты:

1. Endpoint identity включает service и generation, а не только IP:port. Адрес может быть быстро переиспользован другим workload.
2. Snapshot имеет версию. Если watch пропустил delta, consumer запрашивает полное состояние, а не применяет изменения к неизвестной базе.
3. Ошибка обновления отличается от успешного ответа с пустым набором. Первая сохраняет last-known-good; второй может означать реальное отсутствие endpoints.
4. Removal прекращает новые назначения, но не обязан немедленно обрывать установленные connections. Для этого есть draining.

## Как устроено

### От регистрации к snapshot

Endpoint попадает в topology тремя основными путями:

- platform controller выводит endpoints из desired/observed state workloads;
- instance self-registers и периодически продлевает lease;
- оператор или deployment system публикует статическую configuration.

Third-party registration через controller лучше связывает membership с lifecycle workload: умерший process не обязан успеть удалить себя. Self-registration работает вне оркестратора, но требует authenticated identity, lease renewal и защиты от зависшего instance. Lease expiration убирает запись из registry, однако не останавливает старый process; если side effect требует exclusive authority, применяют [[40 Распределённые системы/Leases, distributed locks и fencing tokens|fencing]], а не доверяют discovery.

Registry публикует full snapshots или ordered deltas. Consumer хранит version/nonce и применяет новый набор атомарно. Watch уменьшает update latency, polling проще восстанавливается после разрыва. В обоих случаях reconnect должен уметь получить полное состояние, иначе пропущенное удаление живёт бесконечно.

### DNS и registry API

DNS A/AAAA records дают addresses. SRV добавляет service port, priority и relative weight. TTL ограничивает срок повторного использования ответа resolver, но не обещает мгновенное удаление endpoint: caches обновляются независимо, а уже открытые connections способны жить дольше TTL.

Обычный Kubernetes Service возвращает stable virtual IP, за которым platform выполняет server-side balancing. Headless Service возвращает адреса отдельных Pods; client сам выбирает endpoint. Именованные ports публикуются также через SRV. Этот пример показывает важное различие: DNS name может указывать на один proxy/VIP либо на полный endpoint set, и client behavior будет разным.

Registry API или xDS-подобный protocol передаёт больше metadata: zone, weight, canary flag, health hint, protocol. Цена — отдельный control plane, client implementation и versioned schema. DNS проще и универсальнее, но ограничен record model и caching behavior resolver.

### Client-side и server-side discovery

При client-side discovery library получает endpoint set и выполняет [[10 Основы CS/Балансировка сетевой нагрузки|балансировку]] локально. Нет дополнительного proxy hop, доступны per-endpoint latency и zone-aware selection. Зато каждый language/runtime должен корректно реализовать watch, pools, health, retries и draining.

При server-side discovery client обращается к stable VIP или общему proxy. Тот сам получает topology и выбирает backend. Clients проще, rollout policy централизована, но proxy становится общей capacity и failure boundary. Mesh sidecar скрывает discovery от application code, однако выбор endpoint остаётся распределён по локальным proxies; по data-plane topology это ближе к client-side balancing, чем к одному центральному router.

### Membership, readiness и health

Registry membership не следует вычислять только из периодического `200 /healthz`. Membership — control-plane факт о service identity; readiness — локальное разрешение на новый traffic; active/passive health — наблюдение конкретного caller или proxy.

Envoy сочетает eventually consistent discovery с active health checks. Endpoint, пропавший из discovery, но продолжающий проходить health check, можно временно сохранить: registry outage не удалит рабочий data plane. Когда endpoint одновременно отсутствует и проваливает health, его безопаснее убрать. Это policy конкретной системы, но сама развязка сигналов универсальна.

Readiness должна измениться раньше termination. Kubernetes EndpointSlice хранит `ready`, `serving` и `terminating`; `ready` в обычном случае соответствует `serving && !terminating`. Consumer может прекратить новые назначения, пока уже начатые requests завершаются по [[20 Бэкенд/Graceful shutdown backend-сервиса|graceful shutdown]].

### Stale endpoints и отказ control plane

Stale endpoint обнаруживается connect error, reset, timeout или active health failure. Caller исключает его на ограниченный срок и обновляет topology. Мгновенное глобальное удаление по одному локальному timeout опасно: проблема может находиться в path конкретного caller. Passive ejection остаётся локальным и имеет recovery hysteresis.

При недоступности registry data plane продолжает работать по last-known-good snapshot, если endpoints всё ещё проходят health. Он не увидит scale-out и рискует дольше слать traffic удалённым hosts, поэтому измеряет config age и ограничивает максимальную stale-ness согласно risk. Fail-closed нужен, если старый membership нарушает security boundary; для обычного internal routing он часто создаёт больший outage, чем stale snapshot.

Registration и discovery channel аутентифицируют. Иначе attacker добавит свой endpoint к платёжному сервису или подменит metadata zone/version. Network identity backend проверяется отдельно через TLS certificate или workload identity: присутствие адреса в registry не доказывает, кто ответил на этом IP.

## Пример или трассировка

Сервис `catalog` обновляется с instance `E1` на `E2`. Два callers держат snapshot `v41 = {E1}`.

1. Controller создаёт `E2`, но не публикует его как ready до успешной readiness check. После этого registry выпускает `v42 = {E1, E2}`.
2. Caller `A` получает `v42`; caller `B` временно остаётся на `v41`. Оба состояния допустимы.
3. `E1` начинает termination и снимает readiness. Snapshot `v43` помечает его terminating. `A` прекращает новые назначения сразу; `B` ещё видит `E1`, но его local active check получает failure и также исключает endpoint.
4. Уже открытый stream на `E1` завершается в drain window. Новые requests идут `E2`.
5. Watch у `B` восстанавливается и сообщает `v43`. Если бы он увидел delta после неизвестной версии, то запросил бы full snapshot вместо слепого применения.

Наблюдаемый результат: rollout не требует мгновенной согласованности registry. Безопасность дают readiness перед removal, local health для stale snapshot и protocol-aware draining существующих connections.

## Trade-offs

DNS универсален, кэшируется стандартной инфраструктурой и не требует специальной library. Registry/watch быстрее передаёт изменения и metadata, но добавляет control plane и schema lifecycle. Низкий DNS TTL уменьшает stale window ценой query load; он всё равно не закрывает долгоживущие connections.

Client-side discovery убирает общий proxy hop и даёт богатый local choice. Server-side скрывает topology и концентрирует policy. Цена концентрации — proxy capacity и blast radius; цена client-side — одинаково зрелые libraries во всех runtimes.

Strongly consistent registry упорядочивает membership changes, но caller всё равно видит snapshot с сетевой задержкой, а health меняется независимо. Eventual discovery с last-known-good и local health часто доступнее. Сильная coordination нужна там, где membership само выдаёт authority; обычный routing лучше не смешивать с leader election.

## Типичные ошибки

### DNS TTL считают моментом отключения

- **Неверное предположение:** после истечения TTL все callers перестали использовать адрес.
- **Симптом:** удалённый instance получает traffic после rollout или connection остаётся открытой часами.
- **Причина:** resolver caches и connection pools имеют разные lifetimes.
- **Исправление:** readiness и draining, bounded connection age, наблюдаемая propagation window.

### Registry entry принимают за health

- **Неверное предположение:** зарегистрированный endpoint способен выполнить request.
- **Симптом:** traffic идёт в process с зависшей dependency.
- **Причина:** membership и readiness склеены в один бит.
- **Исправление:** separate readiness, active/passive checks и route-specific degradation.

### Ошибка discovery очищает endpoint set

- **Неверное предположение:** отсутствие свежего ответа означает отсутствие backends.
- **Симптом:** outage registry мгновенно выключает рабочий data plane.
- **Причина:** transport error не отличён от authoritative empty snapshot.
- **Исправление:** last-known-good, version/config-age metrics и явный stale policy.

### Endpoint идентифицируют только IP

- **Неверное предположение:** прежний IP означает прежний service instance.
- **Симптом:** reused address проходит старый cached route или health result.
- **Причина:** identity и generation потеряны при адресации.
- **Исправление:** service identity в certificate/metadata, generation-aware snapshot и health check identity.

### Readiness flaps на каждом transient error

- **Неверное предположение:** один timeout доказывает длительную непригодность instance.
- **Симптом:** весь fleet синхронно входит и выходит из rotation, capacity осциллирует.
- **Причина:** нет thresholds, hysteresis и разделения local/path-wide failure.
- **Исправление:** несколько наблюдений, bounded ejection, медленное восстановление и отдельная диагностика dependency.

## Когда применять

Discovery нужен, когда instances меняются быстрее, чем можно безопасно обновлять clients вручную, или когда routing учитывает zone, version и health. DNS достаточно для устойчивого имени, простого endpoint set или stable VIP. Registry/watch оправдан, когда нужны быстрые updates, metadata и явные topology versions.

Перед реализацией определите authority регистрации, endpoint identity, snapshot/delta protocol, health source, maximum stale age, behavior при registry outage, draining sequence и security регистрации. Если выбранный endpoint получает эксклюзивное право менять общий ресурс, routing discovery уже недостаточно: нужен coordination protocol с fencing.

## Источники

- [RFC 1034: Domain Names — Concepts and Facilities](https://www.rfc-editor.org/rfc/rfc1034.html) — IETF, STD 13 / RFC 1034, ноябрь 1987, проверено 2026-07-18.
- [RFC 2782: A DNS RR for specifying the location of services](https://www.rfc-editor.org/rfc/rfc2782.html) — IETF, RFC 2782, февраль 2000, проверено 2026-07-18.
- [Service discovery](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/upstream/service_discovery) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Health checking](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/upstream/health_checking.html) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Service](https://kubernetes.io/docs/concepts/services-networking/service/) — Kubernetes, документация v1.36, проверено 2026-07-18.
- [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/) — Kubernetes, документация v1.36, проверено 2026-07-18.
