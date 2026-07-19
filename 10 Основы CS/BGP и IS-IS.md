---
aliases:
  - BGP
  - Border Gateway Protocol
  - IS-IS
  - Intermediate System to Intermediate System
tags:
  - область/основы-cs
  - тема/сети
  - протокол/bgp
  - протокол/is-is
статус: проверено
---

# BGP и IS-IS

## TL;DR

Эта заметка нужна только для networking/infrastructure JD. Backend engineer достаточно понимать границу: routing protocols распространяют reachability и наполняют RIB/FIB, а application traffic затем пересылается по выбранному next hop. Конфигурация peerings, route policies, redistribution и failure-domain design требует отдельной операторской подготовки и здесь не рассматривается.

Intermediate System to Intermediate System (IS-IS) — link-state Interior Gateway Protocol (IGP) внутри routing domain. Routers формируют adjacencies, flood-ят Link State PDUs, получают согласованную Link State Database (LSDB), запускают Shortest Path First (SPF) и вычисляют внутренние next hops. Level 1 ограничивает flooding областью, Level 2 связывает области.

Border Gateway Protocol (BGP) — policy-driven path-vector protocol между Autonomous Systems и внутри крупного AS. Peer сообщает prefixes (NLRI) и path attributes; import policy выбирает допустимые routes, decision process — preferred route, export policy — что разрешено объявить дальше. BGP отвечает не «какой path имеет минимальную latency», а «какая reachability согласуется с local policy и доступным next hop».

Протоколы соседствуют: BGP выбирает внешний prefix и BGP next hop, а IGP, например IS-IS, делает этот next hop достижимым внутри AS. Ошибка IGP может обрушить трафик по формально существующей BGP route; ошибка export policy может увести Internet traffic через исправный внутренний path.

## Область применимости

Base BGP semantics описана RFC 4271 с существенными updates: four-octet AS numbers RFC 6793, revised error handling RFC 7606 и default reject RFC 8212. Base IS-IS задан ISO/IEC 10589:2002 edition 2; Integrated IS-IS для IPv4 — RFC 1195, IPv6 — RFC 5308. Материал остаётся concept-level: без vendor CLI, timer recipes, route-reflector/area topology cookbook и production change procedure.

## Ментальная модель

Оба protocol строят вход для forwarding, но обмениваются разными доказательствами пути:

```text
IS-IS: «вот карта links и их metrics внутри domain»
       LSDB -> SPF -> внутренний next hop

BGP:   «вот prefix и attributes пути, который я разрешаю тебе видеть»
       Adj-RIB-In -> import policy -> decision -> Loc-RIB -> export policy
```

IS-IS пытается дать routers одной области согласованную карту topology. BGP не раздаёт полную физическую карту Internet; каждый AS публикует policy-filtered reachability и AS_PATH. Поэтому «shortest» у них означает разное. IS-IS минимизирует configured link metric в своём topology level. BGP сначала применяет local policy и path attributes; число AS в AS_PATH — лишь один сигнал, а latency и capacity из него не следуют.

Control plane и data plane разделены:

```text
routing messages -> protocol databases/RIB -> best route -> FIB
application packet ---------------------------------------> FIB lookup
```

Established adjacency/session означает только работоспособность control channel. Она не доказывает корректность policy, свежесть всех routes и успешную установку FIB.

## Как устроено

### Сравнение границ

| Свойство | BGP | IS-IS |
| --- | --- | --- |
| Основная область | Между AS (eBGP) и распространение BGP routes внутри AS (iBGP) | Внутри одного routing domain/AS как IGP |
| Модель | Path vector + local policy | Link state + SPF |
| Что распространяется | Prefix/NLRI и path attributes; withdrawals | Adjacencies, link metrics и reachable prefixes в LSP/TLV |
| Transport | TCP port 179 между configured peers | Собственные IS-IS PDUs между соседями; IP reachability для adjacency не требуется |
| Loop control | AS_PATH и iBGP dissemination rules | Общая LSDB, sequence/lifetime и SPF graph |
| Иерархия | eBGP/iBGP; scaling extensions вроде route reflection | Level 1 areas и Level 2 backbone |
| Основной риск | Неверная import/export policy, leak/hijack, slow convergence | Неверная adjacency/metric/flooding, area partition, SPF/FIB churn |

### BGP session и incremental exchange

BGP peers устанавливают TCP connection на port 179 и проходят BGP finite state machine. `OPEN` согласует version, AS number, hold time, identifier и capabilities. `KEEPALIVE` поддерживает session, `UPDATE` объявляет/заменяет/withdraw-ит routes, `NOTIFICATION` сообщает fatal protocol condition и закрывает session.

После establishment peer отправляет разрешённую export policy часть routing table, затем передаёт incremental updates. BGP не требует периодически пересылать полную table. Закрытие session неявно withdraw-ит все routes, полученные через неё, если extension вроде graceful restart не меняет временную обработку stale state.

TCP снимает с BGP retransmission, sequencing и fragmentation control messages. Это не делает reachability мгновенно согласованной: UPDATE должен пройти policy, decision process, RIB/FIB installation и дальнейшее propagation.

### BGP route pipeline

Route — prefix (NLRI) плюс path attributes. Удобный pipeline:

```text
peer UPDATE
  -> Adj-RIB-In
  -> import policy / validation
  -> candidates
  -> decision process
  -> Loc-RIB и, если resolvable/eligible, FIB
  -> export policy
  -> Adj-RIB-Out других peers
```

`AS_PATH` перечисляет AS path segments и позволяет обнаруживать собственный AS в route, предотвращая простой inter-AS loop. `NEXT_HOP` указывает адрес, через который достигается prefix; он сам обязан разрешаться local routing table. `LOCAL_PREF` выражает внутреннее предпочтение AS, `MULTI_EXIT_DISC` передаёт соседнему AS hint о preferred ingress. Реальный decision order дополняют local policy и implementation-specific tie breakers, поэтому «меньше AS_PATH всегда выигрывает» неверно.

eBGP соединяет разные AS. iBGP распространяет внешние/policy routes между routers одного AS, но не заменяет IGP: BGP next hop и адреса peers обычно достижимы через IS-IS/OSPF/static underlay. Base RFC 4271 для consistent internal BGP view предполагает full mesh iBGP; route reflectors RFC 4456 уменьшают число sessions ценой дополнительной path-visibility topology.

Import и export — разные security boundaries. RFC 8212 изменил default: без явной import policy eBGP route не участвует в decision process, без export policy не попадает в Adj-RIB-Out. Это fail-closed default, но неверная явно заданная policy всё ещё создаёт route leak.

Malformed UPDATE historically мог сбросить session и убрать много корректных routes. RFC 7606 ввёл более локальные outcomes, включая `treat-as-withdraw` для ряда malformed attributes. Протокол пытается ограничить blast radius плохой route, но не способен исправить семантически неверное, хорошо сформированное объявление.

### IS-IS adjacency, flooding и SPF

IS-IS работает между directly connected routers и не зависит от уже работающего IP route к neighbor. IS-IS Hello (IIH) обнаруживает и поддерживает adjacency. Link State PDU (LSP) публикует router identity, neighbors, metrics и reachability в extensible Type-Length-Value fields. Sequence Number PDUs (CSNP/PSNP) сравнивают версии LSP, подтверждают их и запрашивают недостающие, чтобы соседние LSDB сошлись.

Каждый router flood-ит свежий LSP по соответствующему level. Sequence number отличает новую версию, remaining lifetime удаляет stale information. После изменения LSDB router запускает SPF/Dijkstra и получает shortest paths по configured metric, затем устанавливает prefixes/next hops в RIB/FIB. Flooding сообщает topology; SPF локально выводит routes. Один router не раздаёт соседям готовую полную FIB.

TLV model позволила сохранить core protocol и добавлять reachability. RFC 1195 добавил IPv4 information, RFC 5308 — IPv6 Reachability и IPv6 Interface Address TLVs, RFC 5305 — extended metrics и traffic-engineering attributes. Поддержка TLV не означает, что attribute автоматически участвует в обычном SPF: extension задаёт собственную semantics.

### Level 1 и Level 2

Level 1 routers строят topology внутри area и образуют adjacency только с совместимой area membership. Destination вне area направляется к attached Level 2 router. Level 2 связывает areas и хранит межобластную reachability; Level 1-2 router участвует в обеих LSDB и служит границей.

Иерархия ограничивает размер flooding domain и SPF input. Цена summarization/default routing — Level 1 router видит меньше detail и способен выбрать attached L2, у которого за границей нет рабочего specific path. Неверная redistribution между levels создаёт loops или black holes даже при синхронных LSDB.

### Convergence и failure modes

При отказе link IS-IS должен обнаружить adjacency failure, выпустить новый LSP, flood-ить его, запустить SPF и обновить FIB. До завершения routers могут иметь разные topology versions. Быстрые timers сокращают detection, но увеличивают sensitivity к transient CPU/packet loss; массовый SPF/FIB churn сам способен задержать convergence.

BGP failure проходит другую цепочку: TCP/BGP session или route validation обнаруживает изменение, routes withdraw-ятся, каждый AS заново применяет policy и распространяет best path. Path exploration может последовательно перебрать альтернативы. BGP convergence обычно медленнее внутреннего IGP и зависит от policy, Minimum Route Advertisement Interval (MRAI), других timers и числа administrative domains.

Сессия может оставаться up, пока data path сломан: TCP keepalive идёт по одному path, prefix next hop резолвится в stale FIB, interface drops traffic или remote AS blackhole-ит destination. Проверка control plane дополняется data-plane probe и counters.

### Как BGP и IS-IS зависят друг от друга

В типичной provider/datacenter underlay IS-IS публикует loopbacks и infrastructure prefixes. iBGP sessions используют эти addresses; eBGP routes несут `NEXT_HOP`, который должен разрешиться через IGP. BGP route может быть лучшей по policy, но не установится или станет unusable при недостижимом next hop.

Обратная зависимость тоже опасна: без фильтра redistribution BGP Internet table, попавшая в IS-IS, раздует LSDB/SPF и failure domain. Обычно IGP держит infrastructure reachability, а BGP — service/external/tenant prefixes; точная граница зависит от architecture, но случайная двусторонняя redistribution почти всегда требует доказательства loop prevention.

[[40 Распределённые системы/Service discovery|Service discovery]] решает другую задачу: сопоставляет application service с живущими endpoints. BGP/IS-IS доставляют packets к prefixes и next hops, но не знают readiness конкретного request handler. BGP advertising service VIP/anycast prefix не превращает routing protocol в registry.

## Пример или трассировка

AS `65010` имеет edge routers `R1` и `R2`, core `C` и резервный внутренний link между edge routers. Внутри работает IS-IS. `R1` получает по eBGP от AS `64496` prefix `203.0.113.0/24`; iBGP распространяет route на `R2`. Loopback `R1`, выбранный BGP next hop, доступен через IS-IS.

```text
external AS64496
      |
   eBGP
      |
     R1 ===== C ===== R2
       \_____backup_____/
          IS-IS underlay
```

1. `R1` принимает UPDATE, import policy разрешает prefix и сохраняет route в Adj-RIB-In. Decision process выбирает её; `R1` устанавливает forwarding и публикует разрешённую route по iBGP.
2. `R2` получает BGP route. `NEXT_HOP=loopback R1` разрешается через IS-IS path `R2 → C → R1`, поэтому prefix попадает в FIB.
3. Link `C–R1` падает, но у IS-IS есть alternate internal path. Новый LSP flood-ится, SPF меняет next hop до loopback `R1`. BGP route `203.0.113.0/24` не менялась и BGP UPDATE для этого внутреннего события не нужен.
4. Позже AS `64496` withdraw-ит prefix. `R1` удаляет BGP route и передаёт withdrawal iBGP; исправный IS-IS path до `R1` уже не даёт reachability `203.0.113.0/24`.

Наблюдаемый вывод: IGP convergence может сохранить BGP reachability при внутреннем link failure, но не заменяет BGP withdrawal. И наоборот, стабильная BGP session бесполезна, если IGP не разрешает next hop.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| ISO/IEC 10589:1992 / edition 2 (2002) | Base IS-IS был опубликован первой edition и amendments/corrigenda | ISO/IEC 10589:2002 edition 2 заменил прежнюю edition и остаётся Published/Confirmed | Base protocol сверяют с edition 2, IP extensions — с RFC | [ISO/IEC 10589:2002](https://www.iso.org/standard/30932.html) |
| RFC 1195 (1990) / RFC 5308 (2008) | Integrated IS-IS переносил OSI и IPv4 reachability | Добавлены IPv6 Reachability/Interface Address TLVs | Один IS-IS control plane может рассчитывать IPv4 и IPv6 topologies с protocol-specific reachability | [RFC 1195](https://www.rfc-editor.org/rfc/rfc1195.html), [RFC 5308](https://www.rfc-editor.org/rfc/rfc5308.html) |
| RFC 1771 / RFC 4271 (2006) | BGP-4 base specification жила в RFC 1771 | RFC 4271 сделала RFC 1771 obsolete и уточнила base behavior | Текущая base reference — RFC 4271 плюс updates/extensions | [RFC 4271](https://www.rfc-editor.org/rfc/rfc4271.html) |
| 2-octet ASN / RFC 6793 (2012) | Base OPEN/AS_PATH предполагали 2-octet AS number space | Capability и AS4 attributes обеспечили 4-octet ASNs и переход через old speakers | Современный design не ограничивает значение ASN 16-bit границей 65 535 | [RFC 6793](https://www.rfc-editor.org/rfc/rfc6793.html) |
| RFC 4271 error handling / RFC 7606 (2015) | Многие malformed UPDATE приводили к session reset | Для ряда errors введены attribute discard или `treat-as-withdraw` | Один bad route реже уничтожает все routes peer session | [RFC 7606](https://www.rfc-editor.org/rfc/rfc7606.html) |
| Permissive implementations / RFC 8212 (2017) | Без policy implementations часто принимали и экспортировали всё | eBGP без explicit import/export policy default-rejects routes | Новая session без policy fail-closed, снижая риск случайного leak | [RFC 8212](https://www.rfc-editor.org/rfc/rfc8212.html) |

## Trade-offs

BGP масштабирует administrative policy и скрывает внутреннюю topology AS. Он сходится сложнее и не оптимизирует latency автоматически. IS-IS быстро распространяет topology внутри controlled domain и вычисляет metric-shortest paths, но flooding/LSDB/SPF плохо подходят для Internet-wide policy.

Один flat IS-IS level упрощает routing и даёт всем одинаковую detail. L1/L2 уменьшает flooding и SPF scope, но добавляет area boundaries, default routing и риск suboptimal path. Иерархия оправдана failure-domain/scale измерениями, а не числом routers само по себе.

Полный iBGP mesh прост для path visibility, но число sessions растёт квадратично. Route reflection уменьшает sessions, зато выбранные paths и visibility зависят от reflector topology; troubleshooting требует видеть, какой Adj-RIB-In/Out доступен в конкретной точке.

Более быстрые failure-detection timers уменьшают black-hole window. Они повышают вероятность false failure при CPU pause, control-plane congestion или transient loss. Bidirectional Forwarding Detection (BFD) и graceful mechanisms добавляют ещё одну state machine; их нельзя включать как универсальный «ускоритель» без capacity/failure анализа.

Route summarization сокращает table и churn. Она способна объявлять aggregate, когда specific destination за ним недоступен. Aggregate owner обязан иметь discard route/детальную reachability policy, иначе packets зациклятся или уйдут в случайный default.

## Типичные ошибки

### Выбирать BGP path по длине AS_PATH как по latency

- **Неверное предположение:** меньше AS numbers означает быстрее и надёжнее.
- **Симптом:** traffic идёт на congested/дорогой link при наличии лучшего operational path.
- **Причина:** AS_PATH не кодирует physical hops, bandwidth или RTT; local policy может приоритетнее его длины.
- **Исправление:** сформулировать business/traffic-engineering policy, измерять data plane и понимать полный decision process implementation.

### Считать session/adjacency доказательством forwarding

- **Неверное предположение:** `Established` BGP или `Up` IS-IS гарантирует доставку application packets.
- **Симптом:** control-plane dashboard зелёный, а prefix blackhole-ится.
- **Причина:** route могла быть отфильтрована, next hop неразрешим, FIB не установлена или egress data plane drops traffic.
- **Исправление:** пройти pipeline Adj-RIB/LSDB → selected RIB → FIB → neighbor/interface counters → end-to-end probe.

### Оставить eBGP без явной policy

- **Неверное предположение:** peer сам объявит только безопасные routes.
- **Симптом:** route leak, unexpected transit или при RFC 8212-compliant default полное отсутствие routes.
- **Причина:** trust boundary import/export не определена.
- **Исправление:** explicit prefix/attribute policy в обе стороны, limits и out-of-band validation; default reject считать страховкой, не policy design.

### Перенести service discovery в IGP

- **Неверное предположение:** advertisement prefix означает, что application endpoint ready.
- **Симптом:** route существует, но requests идут в terminating/unhealthy process.
- **Причина:** routing reachability не содержит request-level readiness и lifecycle semantics.
- **Исправление:** разделить service membership/health и network reachability; связывать их через контролируемый VIP/anycast advertisement lifecycle.

### Redistribute всё между BGP и IS-IS

- **Неверное предположение:** больше routes в обоих protocols повышает resilience.
- **Симптом:** LSDB/FIB churn, loops, feedback и большой blast radius одного external update.
- **Причина:** потеряна ownership boundary prefixes и loop-prevention metadata.
- **Исправление:** минимальная направленная redistribution, explicit tags/policy, aggregation и проверенный failure scenario.

## Когда применять

Глубокое знание BGP/IS-IS требуется для networking engineer, SRE/network infrastructure, datacenter fabric, ISP, cloud underlay, anycast/global routing и infrastructure JD. Там нужно отдельно изучать implementation, policy language, authentication, RPKI/origin validation, route reflection, BFD, graceful restart, telemetry и безопасный change process.

Backend/System Design interview обычно требует только концептуальной границы: BGP/IGP строят reachability, L4/L7 balancing выбирает connection/request destination, service discovery сообщает endpoints. При incident backend engineer должен уметь сформулировать prefix/tuple/source location и отличить DNS/service health от route/next-hop failure, но не импровизировать operator changes.

## Источники

- [RFC 4271: A Border Gateway Protocol 4 (BGP-4)](https://www.rfc-editor.org/rfc/rfc4271.html) — IETF, RFC 4271, январь 2006, проверено 2026-07-18.
- [RFC 6793: BGP Support for Four-Octet Autonomous System Number Space](https://www.rfc-editor.org/rfc/rfc6793.html) — IETF, RFC 6793, декабрь 2012, проверено 2026-07-18.
- [RFC 7606: Revised Error Handling for BGP UPDATE Messages](https://www.rfc-editor.org/rfc/rfc7606.html) — IETF, RFC 7606, август 2015, проверено 2026-07-18.
- [RFC 8212: Default External BGP (EBGP) Route Propagation Behavior without Policies](https://www.rfc-editor.org/rfc/rfc8212.html) — IETF, Proposed Standard / RFC 8212, июль 2017, проверено 2026-07-18.
- [RFC 4456: BGP Route Reflection](https://www.rfc-editor.org/rfc/rfc4456.html) — IETF, RFC 4456, апрель 2006, проверено 2026-07-18.
- [ISO/IEC 10589:2002](https://www.iso.org/standard/30932.html) — ISO/IEC, edition 2, ноябрь 2002, статус Published/Confirmed, проверено 2026-07-18.
- [RFC 1195: Use of OSI IS-IS for Routing in TCP/IP and Dual Environments](https://www.rfc-editor.org/rfc/rfc1195.html) — IETF, RFC 1195, декабрь 1990, проверено 2026-07-18.
- [RFC 5308: Routing IPv6 with IS-IS](https://www.rfc-editor.org/rfc/rfc5308.html) — IETF, RFC 5308, октябрь 2008, проверено 2026-07-18.
- [RFC 5305: IS-IS Extensions for Traffic Engineering](https://www.rfc-editor.org/rfc/rfc5305.html) — IETF, RFC 5305, октябрь 2008, проверено 2026-07-18.
