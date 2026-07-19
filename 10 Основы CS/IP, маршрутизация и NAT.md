---
aliases:
  - IP forwarding
  - IP routing
  - Network Address Translation
  - NAT и NAPT
tags:
  - область/основы-cs
  - тема/сети
  - механизм/маршрутизация
  - механизм/nat
статус: проверено
---

# IP, маршрутизация и NAT

## TL;DR

IP forwarding применяет к destination address уже построенную Forwarding Information Base (FIB): выбирает наиболее специфичный prefix, next hop и egress interface, уменьшает TTL/Hop Limit и передаёт packet на следующий link. Routing/control plane наполняет FIB статическими routes, BGP, IS-IS или другим механизмом; он не пересылает каждый application packet сам.

NAT добавляет rewrite на границе address realms. SNAT меняет source, DNAT — destination, NAPT/PAT ещё меняет TCP/UDP port и позволяет множеству internal endpoints разделять external address. Stateful translation хранит mapping и reverse tuple, поэтому return traffic должен попасть в совместимое state.

NAT не равен firewall, proxy или service discovery. Он ограничен конечными ports/state, ломает буквальную end-to-end адресацию и создаёт failure modes: port exhaustion, stale mappings, hairpinning, asymmetric path и потерю state при failover. В IPv6 обычная routed connectivity не требует address conservation через NAPT; для связи IPv6-only clients с IPv4-only servers существует NAT64/DNS64 с отдельными границами.

## Область применимости

IPv4 forwarding описан по RFC 1812, IPv6 — по RFC 8200. NAT terminology и traditional NAT взяты из RFC 2663/RFC 3022; актуализированные behavioral requirements — из RFC 4787, RFC 5382, RFC 7857 и RFC 6888. `conntrack` ниже означает типичную state table Linux Netfilter на tag `v7.1`; другие products называют и реализуют её иначе.

## Ментальная модель

Обычный router применяет таблицу назначения, stateful NAT — таблицу преобразования:

```text
FIB (destination-driven)
203.0.113.0/24 -> next-hop R2, interface eth1
0.0.0.0/0      -> next-hop R1, interface eth0

NAT/conntrack (flow-driven)
inside 10.0.0.7:51514 -> outside 203.0.113.5:40001, TCP
reverse 203.0.113.5:40001 -> 10.0.0.7:51514
```

Router может забыть один packet сразу после forwarding. NAT не может: следующий reverse packet должен найти прежний mapping. Отсюда главный operational trade-off — адресная экономия и policy boundary оплачиваются shared mutable state на пути.

Routing отвечает «какой next hop ведёт к prefix». NAT отвечает «под каким tuple этот flow виден в другом realm». Firewall отвечает «разрешён ли packet/flow». Эти решения часто совмещены в одном appliance и pipeline, но причинно различны.

## Как устроено

### Routing plane, RIB и FIB

Connected prefixes, static routes и routing protocols создают кандидаты в Routing Information Base (RIB). Control plane сравнивает source/protocol preference, metric, policy и reachability next hop, затем устанавливает выбранные entries в FIB. [[10 Основы CS/BGP и IS-IS|BGP и IS-IS]] решают разные задачи control plane; fast path получает их результат, а не «спрашивает BGP» на каждый packet.

FIB entry обычно содержит prefix, next hop, egress interface и metadata policy/encapsulation. Несколько equal-cost next hops могут дать ECMP. Реализация обычно hash-ит flow tuple, чтобы packets одного transport flow не reorderились при каждом lookup, но изменение membership или seed способно перевести flow на другой path.

Longest Prefix Match — data-plane инвариант destination routing. Route `203.0.113.0/24` выигрывает у default `0.0.0.0/0` для address `203.0.113.42`, даже если default route получен из более «предпочтительного» source. Administrative preference сначала помогает выбрать кандидатов того же охвата; менее специфичный prefix не должен затмить более специфичный только из-за origin.

### Forwarding одного packet

Упрощённый IPv4/IPv6 fast path проходит такие границы:

1. Проверить link frame и IP header; определить, предназначен ли destination локальному node.
2. Применить ingress policy, firewall/VRF и другие configured stages. Точный порядок NAT, filtering и routing зависит от implementation.
3. Найти лучший FIB prefix и next hop. Если route нет, отбросить packet и при допустимых условиях вернуть ICMP unreachable.
4. Уменьшить IPv4 TTL или IPv6 Hop Limit. При нуле отбросить packet и обычно вернуть ICMP Time Exceeded.
5. Проверить egress MTU. IPv4 router может fragment при разрешённой fragmentation; IPv6 router не фрагментирует и возвращает ICMPv6 Packet Too Big.
6. Разрешить link-layer address next hop через ARP/ND, поставить packet в egress queue и создать frame для нового link.

IPv4 router также проверяет и пересчитывает IPv4 header checksum после изменения TTL. У IPv6 base header checksum нет; transport checksum и link integrity остаются отдельными проверками.

Forwarding и convergence расходятся во времени. Routing process может уже выбрать новый route, пока часть line cards/replicas ещё применяет прежнюю FIB. В этот промежуток возможны microloops и black holes. Поэтому «route видна в control plane» не доказывает прохождение traffic.

### SNAT, DNAT и NAPT

Source NAT (SNAT) переписывает source address перед выходом в другой realm. Return packet приходит на translated address, NAT находит mapping и восстанавливает original destination. Частый вариант — private IPv4 client выходит в Internet под public IPv4 gateway.

Destination NAT (DNAT) переписывает destination address, а иногда и port. Static port forwarding направляет public `203.0.113.5:443` на internal `10.0.0.20:8443`. Некоторые [[10 Основы CS/Балансировка сетевой нагрузки|L4-балансировщики]] используют DNAT-подобный data path, но балансировка добавляет endpoint selection, health и lifecycle; один rewrite сам этих свойств не даёт.

Basic NAT меняет address one-to-one или из pool. Network Address Port Translation (NAPT, часто PAT) меняет transport identifier вместе с address. Несколько internal tuples получают разные external ports одного public address. Для TCP/UDP NAT пересчитывает IP/transport checksums либо использует корректное incremental update; ICMP errors требуют перевода quoted original header, иначе source не сопоставит ошибку со своим flow.

SNAT и DNAT могут применяться к одному packet. Названия описывают изменяемое поле относительно направления наблюдения, а не два разных wire protocols. Reverse translation обязана быть согласована с первым mapping.

### Mapping, conntrack и timeout

Первый подходящий packet создаёт mapping, например:

```text
original: TCP 10.0.0.7:51514 -> 198.51.100.20:443
reply:    TCP 198.51.100.20:443 -> 203.0.113.5:40001
```

State table хранит original/reply tuples, protocol, timestamps и protocol-specific progress. Linux conntrack классифицирует packets относительно уже наблюдаемого flow и предоставляет NAT повторяемый binding. Это не application session: один HTTP/2 connection содержит много requests, а UDP не имеет handshake, поэтому его «session end» определяется idle timeout heuristic.

TCP flags помогают NAT приблизительно увидеть SYN, FIN и RST, но middlebox не знает, дошёл ли segment дальше и что прочитало приложение. Он сохраняет state после FIN/RST на время возможных retransmissions и garbage-collects idle entries. UDP mapping refresh/timeout зависит от traffic и behavior RFC 4787; слишком короткий timeout ломает quiet bidirectional application, слишком длинный удерживает ports и memory.

Connection tracking полезен и без address rewrite для stateful firewall. Обратное тоже концептуально возможно для static stateless prefix translation. Поэтому `conntrack`, NAT и firewall нельзя использовать как синонимы.

### Port и state exhaustion

NAPT multiplexing конечен. Для каждого external address доступен ограниченный набор ports, а mapping/filtering behavior определяет, можно ли один mapping использовать с несколькими destinations. Большой connection churn, долгие TCP states, UDP keep-alives и слишком длинные idle timeouts удерживают ports. Carrier-Grade NAT (CGN) дополнительно делит их между subscribers; RFC 6888 требует configurable per-subscriber external-port limits.

При exhaustion новые flows получают отказ allocation или молча теряют packets. Изнутри это выглядит как intermittent connect timeout к произвольным destinations, хотя CPU backend и route здоровы. Метрики нужны по protocol, public IP/pool, allocated mappings, allocation failures и age distribution.

Меры следуют из ресурса: уменьшать бессмысленный churn, использовать bounded [[20 Бэкенд/Пулы соединений и keep-alive|connection pooling]], настраивать timeout по protocol, добавлять external addresses/ports, распределять subscribers и переходить на native IPv6 там, где обе стороны его поддерживают. Преждевременное reuse tuple опасно: late packets старого flow способны попасть в новый incarnation.

### Hairpinning и asymmetric routing

Hairpin NAT нужен, когда два internal hosts обращаются друг к другу по external address/port. Packet от `X1` приходит на outside mapping `X2'`, NAT разворачивает его назад к `X2` и обычно переводит source так, чтобы reverse traffic снова прошёл через NAT. Без hairpin support internal client видит timeout только для public name своего же service; split-horizon DNS может скрыть проблему, но не заменяет определённую policy.

Stateful NAT требует, чтобы packets обоих направлений нашли одну translation state или синхронизированную replica. RFC 3022 прямо требует проводить requests и responses session через тот же NAT. ECMP/asymmetric routing через два независимых gateways приводит к reverse packet без mapping. Active/standby failover без state replication обрывает существующие flows; replication сама добавляет ordering, capacity и consistency cost.

### Граница IPv4 и IPv6

IPv4 NAPT широко используется из-за дефицита public IPv4 addresses и private realms RFC 1918. IPv6 предоставляет значительно больше адресов и рассчитан на routed end-to-end addressing; security policy всё равно задаёт firewall, потому что global address не означает public permission.

Dual-stack host ведёт независимые IPv4 и IPv6 routes, PMTU и failures. Успешный DNS `AAAA` не гарантирует рабочий IPv6 path, а fallback способен скрыть деградацию одной family.

Stateful NAT64 переводит IPv6 packets IPv6-only client в IPv4 packets к IPv4-only server и создаёт NAPT-like bindings. DNS64 может синтезировать `AAAA` из `A`, чтобы client выбрал NAT64 prefix. Это transition boundary, а не доказательство, что IPv6 «требует NAT»: native IPv6-to-IPv6 traffic в NAT64 не нуждается. Protocols, встраивающие IP literals или проверяющие address family, требуют отдельной совместимости.

## Пример или трассировка

Client `10.0.0.7:51514` открывает TCP connection к `198.51.100.20:443` через NAPT gateway с public address `203.0.113.5`.

| Шаг | Packet на этой границе | State/action NAT |
| --- | --- | --- |
| 1. Inside ingress | `10.0.0.7:51514 → 198.51.100.20:443`, SYN | Mapping отсутствует; выделить external port `40001` |
| 2. Outside egress | `203.0.113.5:40001 → 198.51.100.20:443`, SYN | Сохранить original/reply tuples, обновить checksums |
| 3. Outside ingress | `198.51.100.20:443 → 203.0.113.5:40001`, SYN-ACK | Найти reverse mapping |
| 4. Inside egress | `198.51.100.20:443 → 10.0.0.7:51514`, SYN-ACK | Восстановить internal destination/checksums |

Server никогда не видит `10.0.0.7`; client не видит port `40001`. Если reply шага 3 придёт на второй gateway без state, route до `10.0.0.7` сам по себе не поможет: тот не знает translation. Если все usable external ports заняты, шаг 1 не создаст mapping, и новый connection не начнётся.

Для DNAT направление зеркально: public destination `203.0.113.5:443` заранее сопоставлен `10.0.0.20:8443`, NAT переписывает destination inbound и source/return tuple outbound. Server route должен вернуть response через совместимый NAT state; прямой asymmetric return раскроет client другой source tuple и сломает flow.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| RFC 2663 (1999) / RFC 3022 (2001) | Разные products использовали NAT terms неодинаково | Зафиксированы Basic NAT, NAPT и traditional NAT behavior | При дизайне различают address translation и port multiplexing | [RFC 2663](https://www.rfc-editor.org/rfc/rfc2663.html), [RFC 3022](https://www.rfc-editor.org/rfc/rfc3022.html) |
| RFC 4787 (2007), RFC 5382 (2008), RFC 7857 (2016) | NAT traversal зависел от несовместимых mapping/filter/timer behaviors | Опубликованы и уточнены behavioral requirements для UDP/TCP | Endpoint-independent mapping, hairpin и timers стали проверяемыми expectations, но legacy devices всё ещё различаются | [RFC 4787](https://www.rfc-editor.org/rfc/rfc4787.html), [RFC 5382](https://www.rfc-editor.org/rfc/rfc5382.html), [RFC 7857](https://www.rfc-editor.org/rfc/rfc7857.html) |
| RFC 6146 / RFC 6147 (2011) | IPv6-only client не мог напрямую обратиться к IPv4-only server | Стандартизованы stateful NAT64 и DNS64 | Появилась явная translation boundary между address families | [RFC 6146](https://www.rfc-editor.org/rfc/rfc6146.html), [RFC 6147](https://www.rfc-editor.org/rfc/rfc6147.html) |
| RFC 6888 (2013) | Enterprise NAT assumptions переносили на provider-scale sharing | Зафиксированы CGN logging, port/resource limits и behavior requirements | Ports/state рассматриваются как shared per-subscriber resource | [RFC 6888](https://www.rfc-editor.org/rfc/rfc6888.html) |

## Trade-offs

Pure routing сохраняет end-to-end addresses, упрощает attribution и не требует per-flow translation state. NAPT экономит IPv4 addresses и скрывает internal addressing от внешнего routing. Цена — ports, state, traversal protocols и зависимость от return path. Сокрытие address topology не заменяет access control.

SNAT упрощает outbound reachability и aggregate egress policy, но backend видит gateway address. Для audit, rate limit и abuse response приходится переносить client identity на доверенный application layer либо вести NAT logs с точным временем/port.

DNAT даёт дешёвое L3/L4 перенаправление. L7 reverse proxy понимает HTTP/TLS policy, retries и request metrics, зато завершает connection, расходует больше CPU/memory и становится application trust boundary.

Долгие NAT timeouts сохраняют idle sessions и уменьшают keep-alive traffic. Короткие освобождают ports/state, но silently ломают connections, которые endpoints считают живыми. Правило выбирают по protocol и измеренному idle behavior, не одним global числом.

State replication позволяет failover сохранять flows. Она повышает write rate control plane/state plane и может отстать ровно перед аварией. Иногда дешевле принять reconnect с application recovery, чем обещать безразрывный NAT failover.

## Типичные ошибки

### Принимать NAT за firewall

- **Неверное предположение:** отсутствие static inbound mapping делает internal host защищённым при любом traffic.
- **Симптом:** разрешённый/established mapping или hairpin открывает неожиданный path.
- **Причина:** translation отвечает за tuple rewrite, policy фильтрации — отдельный механизм.
- **Исправление:** задавать explicit ingress/egress firewall policy и проверять её до/после translation согласно pipeline implementation.

### Игнорировать port exhaustion

- **Неверное предположение:** пока есть свободная память, NAT создаст сколько угодно connections.
- **Симптом:** новые outbound connections случайно timeout, старые продолжают работать.
- **Причина:** исчерпан external address/port pool или per-subscriber mapping limit.
- **Исправление:** метрики allocation failures/utilization, bounded churn/pools, корректные timeouts и расширение public pool/native IPv6.

### Разнести направления по независимым gateways

- **Неверное предположение:** одинаковая routing configuration делает NAT nodes взаимозаменяемыми для established flow.
- **Симптом:** SYN уходит, SYN-ACK отбрасывается на другом gateway.
- **Причина:** reverse node не имеет translation/conntrack state.
- **Исправление:** symmetric steering, deterministic state ownership или проверенная state replication; failover semantics сделать явной.

### Считать conntrack application state

- **Неверное предположение:** `ESTABLISHED` означает authenticated session и успешный request.
- **Симптом:** firewall разрешает нежелательный application traffic или monitoring рапортует ложный success.
- **Причина:** conntrack классифицирует packet flow по tuple/protocol, не понимает business protocol.
- **Исправление:** application authentication/authorization и request health проверять выше L4.

### Лечить hairpin только DNS

- **Неверное предположение:** internal DNS answer навсегда устраняет необходимость hairpin behavior.
- **Симптом:** доступ ломается по literal public address, cached answer или при переходе между сетями.
- **Причина:** split-horizon меняет name resolution, но public tuple остаётся реальным API path.
- **Исправление:** определить поддержку hairpin и source translation либо официально запретить/тестировать этот path; DNS считать отдельной policy.

## Когда применять

IP forwarding model нужна при любом network incident: проверьте destination prefix, VRF/policy, выбранный next hop, neighbor state, TTL/Hop Limit, MTU и фактическую FIB на data plane. Routing protocols исследуют после подтверждения, что FIB entry неверна или unstable.

NAT применяют осознанно на границе address realms: IPv4 egress sharing, inbound publication, tenant isolation, provider CGN или IPv4/IPv6 transition. До rollout зафиксируйте mapping/filter behavior, port capacity, timers, hairpin, fragment/ICMP handling, asymmetric routing, logging и failover state.

Если обе стороны имеют native IPv6 reachability, обычная routing + firewall policy сохраняет больше end-to-end semantics. NAT64 нужен именно для несовпадающих address families, а не как обязательный слой IPv6.

## Источники

- [RFC 1812: Requirements for IP Version 4 Routers](https://www.rfc-editor.org/rfc/rfc1812.html) — IETF, RFC 1812, июнь 1995, проверено 2026-07-18.
- [RFC 8200: Internet Protocol, Version 6 (IPv6) Specification](https://www.rfc-editor.org/rfc/rfc8200.html) — IETF, Internet Standard / RFC 8200, июль 2017, проверено 2026-07-18.
- [RFC 8201: Path MTU Discovery for IP version 6](https://www.rfc-editor.org/rfc/rfc8201.html) — IETF, Internet Standard / RFC 8201, июль 2017, проверено 2026-07-18.
- [RFC 2663: IP Network Address Translator Terminology and Considerations](https://www.rfc-editor.org/rfc/rfc2663.html) — IETF, RFC 2663, август 1999, проверено 2026-07-18.
- [RFC 3022: Traditional IP Network Address Translator](https://www.rfc-editor.org/rfc/rfc3022.html) — IETF, RFC 3022, январь 2001, проверено 2026-07-18.
- [RFC 4787: Network Address Translation Behavioral Requirements for Unicast UDP](https://www.rfc-editor.org/rfc/rfc4787.html) — IETF, BCP 127 / RFC 4787, январь 2007, проверено 2026-07-18.
- [RFC 5382: NAT Behavioral Requirements for TCP](https://www.rfc-editor.org/rfc/rfc5382.html) — IETF, BCP 142 / RFC 5382, октябрь 2008, проверено 2026-07-18.
- [RFC 7857: Updates to Network Address Translation Best Current Practices](https://www.rfc-editor.org/rfc/rfc7857.html) — IETF, BCP 127 / RFC 7857, апрель 2016, проверено 2026-07-18.
- [RFC 6888: Common Requirements for Carrier-Grade NATs](https://www.rfc-editor.org/rfc/rfc6888.html) — IETF, BCP 127 / RFC 6888, апрель 2013, проверено 2026-07-18.
- [RFC 6146: Stateful NAT64](https://www.rfc-editor.org/rfc/rfc6146.html) — IETF, RFC 6146, апрель 2011, проверено 2026-07-18.
- [RFC 6147: DNS64 — DNS Extensions for Network Address Translation from IPv6 Clients to IPv4 Servers](https://www.rfc-editor.org/rfc/rfc6147.html) — IETF, RFC 6147, апрель 2011, проверено 2026-07-18.
- [nf_conntrack_core.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/net/netfilter/nf_conntrack_core.c?h=v7.1) — Linux kernel, tag `v7.1`, файл `net/netfilter/nf_conntrack_core.c`, символы `nf_conntrack_in`, `resolve_normal_ct`, `__nf_conntrack_confirm`, проверено 2026-07-18.
