---
aliases:
  - Модель TCP/IP
  - TCP/IP stack
  - Путь пакета
  - Packet path
tags:
  - область/основы-cs
  - тема/сети
  - механизм/инкапсуляция
статус: проверено
---

# Модель TCP-IP и путь пакета

## TL;DR

Стек TCP/IP удобнее представлять четырьмя слоями: приложение, транспорт, Internet layer и link layer. Приложение передаёт данные через [[10 Основы CS/Сокеты|сокет]], транспорт добавляет end-to-end семантику, IP доставляет datagram между адресами через цепочку routers, а link layer переносит IP packet только до соседнего узла. При отправке headers добавляются снаружи, при приёме снимаются в обратном порядке.

IP packet обычно сохраняет source и destination IP на всём пути, но каждый router создаёт для следующего link новый frame с новыми link-layer addresses и уменьшает Time to Live (TTL) или Hop Limit. NAT, tunnels и proxies нарушают отдельные части этой упрощённой картины, поэтому при диагностике сначала фиксируют границу наблюдения и слой.

Успех на одном слое не подтверждает следующий: успешный `send()` говорит о принятии данных локальным kernel, ACK TCP — о приёме байтов peer TCP, а HTTP response — о результате application protocol. Эти границы нельзя склеивать в одну «сетевую операцию».

## Область применимости

Заметка описывает архитектурную модель RFC 1122, IPv4 router behavior RFC 1812 и IPv6 RFC 8200. Это карта пути данных, а не разбор конкретного NIC driver, firewall или cloud network. Надёжность TCP, UDP semantics, NAT и балансировка раскрыты отдельно.

## Ментальная модель

Данные едут во вложенных конвертах. Каждый слой читает свой внешний конверт и не обязан понимать содержимое:

```text
application data
└─ TCP segment / UDP datagram       ports, transport state/checksum
   └─ IPv4 / IPv6 packet           source/destination IP, TTL/Hop Limit
      └─ link-layer frame          адреса только текущего link
         └─ bits/signals
```

У этой модели три полезных инварианта:

1. Transport state находится у endpoints. Обычный IP router пересылает каждый packet независимо и не обеспечивает ordering, delivery или application success.
2. IP destination выбирает маршрут до конечного адреса, а link-layer destination указывает лишь следующий hop. Для удалённого destination host отправитель адресует первый frame своему gateway, а не удалённому NIC.
3. Один end-to-end exchange состоит из нескольких локальных передач. На каждом routed hop входной frame заканчивается, IP packet обрабатывается, затем помещается в новый frame.

## Как устроено

### Четыре слоя и их контракты

Application layer задаёт формат и смысл сообщения: HTTP request, DNS query, database protocol. Он выбирает имя или адрес peer, framing, authentication, deadline и семантику результата.

Transport layer демультиплексирует traffic по ports и даёт приложению выбранный контракт. TCP представляет упорядоченный поток байтов с retransmission, flow control и congestion control. UDP сохраняет границу одной datagram, но сам не гарантирует доставку, порядок и защиту от дублей. TCP checksum и включённая UDP checksum покрывают pseudo-header с IP addresses, поэтому ошибочно доставленный packet обычно не будет принят как корректный transport unit. В IPv4 нулевое поле UDP checksum означает, что проверка отключена; в IPv6 checksum обычно обязательна, а узкие tunnel exceptions разобраны в [[10 Основы CS/UDP|заметке об UDP]].

Internet layer помещает transport unit в IPv4 или IPv6 packet. Source и destination IP описывают endpoints текущего IP exchange; Protocol в IPv4 или Next Header в IPv6 указывает следующий header. IP — connectionless service без end-to-end delivery guarantee. TTL в IPv4 и Hop Limit в IPv6 ограничивают число forwarding hops и обрывают routing loop.

Link layer переносит packet по одному directly connected link: Ethernet, Wi-Fi, point-to-point tunnel и другим средам. Ethernet frame содержит local source/destination MAC и проверочную сумму frame. Router не пересылает этот frame «как есть» на другой interface: link header и trailer относятся только к входному segment сети.

### Исходящий путь на host

После вызова socket API kernel проходит несколько независимых решений:

1. Transport формирует segment или datagram. Для TCP это может быть часть stream, не совпадающая с размером `send()`; для UDP сохраняется одна message boundary.
2. IP выбирает route по destination. Forwarding Information Base (FIB) сопоставляет prefix с egress interface и next hop; среди совпавших prefixes выигрывает наиболее длинный.
3. Если destination on-link, next hop равен destination. Иначе next hop — router. IPv4 разрешает его link-layer address через Address Resolution Protocol (ARP); IPv6 использует Neighbor Discovery (ND).
4. Kernel проверяет, помещается ли packet в допустимый MTU path/interface, ставит его в egress queue и передаёт driver. Queue discipline, shaping и congestion способны задержать или отбросить packet ещё до wire.
5. NIC создаёт или завершает link framing и передаёт bits. Offload может отложить checksum или segmentation до NIC, поэтому host capture иногда показывает «packet» крупнее фактических frames на wire.

`send()` способен завершиться до шагов 4–5. Он подтверждает только локальное принятие данных согласно socket contract.

### Что делает router на каждом hop

Router принимает frame, проверяет link-level validity и извлекает IP packet. Затем он проверяет IP header, решает, предназначен ли packet самому router или должен быть forwarded, уменьшает TTL/Hop Limit и выполняет FIB lookup. Если route отсутствует, policy запрещает traffic или hop limit исчерпан, router отбрасывает packet и при подходящих условиях отправляет ICMP error. При превышении egress MTU IPv4 router ещё может фрагментировать packet, если fragmentation разрешена; иначе он отбрасывает packet и возвращает ICMP. IPv6 router не фрагментирует и сообщает source через ICMPv6 `Packet Too Big`.

Для успешной пересылки router выбирает next hop, разрешает его link-layer address, ставит packet в egress queue и создаёт новый frame. Поэтому capture по разные стороны router увидит разные MAC addresses и TTL/Hop Limit, но без NAT или tunnel те же transport ports и конечные IP addresses.

Routing protocol и forwarding — разные процессы. BGP, IS-IS, static configuration или controller наполняют routing state; fast path применяет уже выбранную FIB entry к каждому packet. Изменение control plane не мгновенно меняет все data-plane copies, поэтому во время convergence возможны transient loss, loop или разные paths на соседних routers.

### Входящий путь на destination

Последний router узнаёт, что destination on-link, разрешает MAC/neighbor address самого host и отправляет frame. NIC host принимает frame, IP проверяет destination и передаёт payload transport protocol. Transport сверяет checksum и состояние, демультиплексирует unit в socket receive queue; application получает данные только после `recv()`/`read()`.

Receive queue и application consumption разделены. TCP ACK способен уйти, пока application ещё не прочитало байты. Точно так же UDP packet может быть корректно доставлен kernel, но отброшен из-за переполнения socket buffer до чтения процессом.

### Path не обязан быть симметричным

Forward и return traffic выбираются независимо. ECMP, policy routing, NAT, anycast и несколько providers дают разные последовательности hops. `traceroute` наблюдает ответы на истечение TTL/Hop Limit и не доказывает, что application response пойдёт тем же путём. Stateful middlebox при асимметрии может стать отдельной точкой отказа.

[[10 Основы CS/Балансировка сетевой нагрузки|L4/L7-балансировщик]] также меняет границу рассуждения: L4 устройство может сохранить transport connection и переписать addresses, а L7 proxy завершает одно соединение и создаёт другое. За L7 proxy уже нет одного end-to-end TCP connection.

## Пример или трассировка

Host `192.0.2.10` отправляет TCP packet на server `203.0.113.20:443`. Его default gateway — `192.0.2.1`; между ними и server два routers. NAT отсутствует.

```text
application -> socket -> TCP -> IPv4 -> Ethernet -> R1 -> R2 -> server
```

| Точка | Link-layer source → destination | IP source → destination | TTL | Что произошло |
| --- | --- | --- | ---: | --- |
| Host → R1 | `MAC-host → MAC-R1` | `192.0.2.10 → 203.0.113.20` | 64 | Route выбрал default gateway; ARP разрешил `192.0.2.1` |
| R1 → R2 | `MAC-R1-out → MAC-R2` | те же IP | 63 | R1 снял входной frame, сделал FIB lookup и новый frame |
| R2 → server | `MAC-R2-out → MAC-server` | те же IP | 62 | Destination стал on-link; ARP разрешил server |
| Server kernel | frame снят | packet доставлен TCP | 62 | TCP проверил tuple/sequence/checksum и положил bytes в socket queue |

Если server process не читает socket, первые три hops всё равно могут работать, а TCP временно подтверждать уже buffered bytes. Наблюдаемый network success ещё не равен успешному request.

## Trade-offs

Четырёхслойная TCP/IP model ближе к реальным Internet protocols и быстрее помогает локализовать сбой. Семислойная OSI model точнее разделяет presentation/session concerns и полезна как общий словарь. Нельзя требовать от реализации буквального соответствия обеим схемам: TLS можно описать как часть application stack, а tunnels добавляют повторную инкапсуляцию тех же layers.

Packet switching позволяет routers не хранить end-to-end connection state и перенаправлять traffic после изменения routes. Цена — endpoints получают loss, reordering, duplication и variable delay, а надёжность приходится строить выше IP.

Кэш ARP/ND и FIB ускоряет fast path. Устаревшая entry временно отправляет packets неверному neighbor или старому next hop. Полный lookup/solicitation на каждый packet был бы свежее, но неприемлемо дорог.

Большие MTU уменьшают долю headers и packet-processing overhead. Они требуют поддержки всего path; одна более узкая link или tunnel создаёт fragmentation, `Packet Too Big` либо black hole при потерянном ICMP.

## Типичные ошибки

### Искать MAC удалённого server

- **Неверное предположение:** Ethernet destination должен совпадать с MAC конечного IP host.
- **Симптом:** engineer считает frame на gateway неверно адресованным.
- **Причина:** link-layer address обозначает следующий hop на текущем link.
- **Исправление:** сначала определить on-link/off-link и next hop по FIB, затем проверять ARP/ND именно для next hop.

### Считать `send()` доказательством доставки

- **Неверное предположение:** успешный syscall подтверждает, что peer получил или обработал данные.
- **Симптом:** потерянный response трактуют как доказательство, что request не выполнялся.
- **Причина:** syscall, network delivery, transport acknowledgment и application commit — разные границы.
- **Исправление:** определить нужный acknowledgment на application layer, задать [[20 Бэкенд/Дедлайны запросов и распространение отмены|end-to-end deadline]] и безопасную retry semantics.

### Диагностировать только по `ping`

- **Неверное предположение:** ICMP Echo success доказывает доступность TCP port и service.
- **Симптом:** `ping` проходит, а request стабильно падает.
- **Причина:** ICMP, transport port, TLS/application policy и backend health проходят разные paths и checks.
- **Исправление:** проверять последовательно route/neighbor, transport handshake и application exchange с той же точки клиента.

### Считать packet capture буквальным wire image

- **Неверное предположение:** крупный TCP segment в host capture нарушает MTU.
- **Симптом:** ищут fragmentation, которой на wire нет.
- **Причина:** TSO/GSO/GRO и checksum offload меняют точку, где segmentation и checksum становятся физическими.
- **Исправление:** учитывать capture point и offloads; при необходимости сравнить capture на egress/peer или временно отключить конкретный offload в контролируемой среде.

## Когда применять

Эта модель нужна для разбора latency и loss по границам: application queue, socket buffer, transport recovery, route/neighbor lookup, interface queue, отдельный hop. Начинайте с tuple, address family, source host и времени события; затем двигайтесь по пути сверху вниз на отправителе, hop за hop и снизу вверх на получателе.

Для backend design она задаёт вопросы, которые нельзя оставить «сети»: где заканчивается connection, кто владеет timeout, какой слой подтверждает результат и какой state потеряется при смене route или proxy.

## Источники

- [RFC 1122: Requirements for Internet Hosts — Communication Layers](https://www.rfc-editor.org/rfc/rfc1122.html) — IETF, STD 3 / RFC 1122, октябрь 1989, проверено 2026-07-18.
- [RFC 1812: Requirements for IP Version 4 Routers](https://www.rfc-editor.org/rfc/rfc1812.html) — IETF, RFC 1812, июнь 1995, проверено 2026-07-18.
- [RFC 8200: Internet Protocol, Version 6 (IPv6) Specification](https://www.rfc-editor.org/rfc/rfc8200.html) — IETF, Internet Standard / RFC 8200, июль 2017, проверено 2026-07-18.
- [RFC 826: An Ethernet Address Resolution Protocol](https://www.rfc-editor.org/rfc/rfc826.html) — IETF, STD 37 / RFC 826, ноябрь 1982, проверено 2026-07-18.
- [RFC 4861: Neighbor Discovery for IP version 6](https://www.rfc-editor.org/rfc/rfc4861.html) — IETF, RFC 4861, сентябрь 2007, проверено 2026-07-18.
- [RFC 768: User Datagram Protocol](https://www.rfc-editor.org/rfc/rfc768.html) — IETF, STD 6 / RFC 768, август 1980, проверено 2026-07-18.
- [RFC 6936: Applicability Statement for the Use of IPv6 UDP Datagrams with Zero Checksums](https://www.rfc-editor.org/rfc/rfc6936.html) — IETF, RFC 6936, апрель 2013, проверено 2026-07-18.
- [Segmentation Offloads](https://github.com/torvalds/linux/blob/v7.1/Documentation/networking/segmentation-offloads.rst) — Linux kernel, tag `v7.1`, файл `Documentation/networking/segmentation-offloads.rst`, проверено 2026-07-18.
