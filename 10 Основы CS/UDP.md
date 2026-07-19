---
aliases:
  - User Datagram Protocol
  - UDP datagrams
  - Connected UDP
tags:
  - область/основы-cs
  - тема/сети
  - протокол/udp
статус: проверено
---

# UDP

## TL;DR

UDP передаёт независимые datagrams между ports. Один успешный receive возвращает не более одной datagram и сохраняет её boundary; слишком маленький buffer обрезает datagram, а остаток нельзя дочитать следующим вызовом. Сам UDP не гарантирует delivery, ordering, duplicate suppression, retransmission, flow control или congestion control.

`connect()` на UDP socket не выполняет handshake и не создаёт transport connection. Он назначает default peer, фильтрует входящие datagrams по peer address/port и упрощает сопоставление некоторых asynchronous errors. Peer по-прежнему ничего не узнаёт до отправки первой datagram.

Приложение обязано явно решить, что делать с loss, duplicates, reordering, overload, Path MTU (PMTU), authentication и повтором операции. Если эти решения нужны «как в TCP», готовый transport protocol обычно безопаснее самодельного набора timers и ACK.

## Область применимости

Wire format задан RFC 768. Практические требования для Internet applications взяты из BCP 145 / RFC 8085, DPLPMTUD — из RFC 8899. Socket behavior ниже описывает Linux man-pages 6.18; другие kernels могут иначе доставлять asynchronous ICMP errors.

## Ментальная модель

UDP socket — почтовый ящик для отдельных конвертов:

```text
send datagram A -> [IP packet(s)] -> receive datagram A целиком или ничего
send datagram B -> [IP packet(s)] -> B может прийти раньше A
send datagram A retry           -> receiver может увидеть вторую A
```

Между двумя конвертами нет общего sequence space. Kernel не знает, что `A retry` повторяет логическое сообщение, а `B` зависит от `A`. Даже connected UDP хранит только local association с peer, не общую state machine двух hosts.

Полезный инвариант: одна UDP datagram атомарна только на границе socket API. Ниже неё IP может фрагментировать packet, а выше неё application message может состоять из нескольких datagrams. Потеря одного IP fragment уничтожает всю datagram; потеря одной application fragment не должна заставлять повторять всё сообщение, если protocol умеет адресовать fragments отдельно.

## Как устроено

### Header и datagram semantics

UDP header содержит четыре 16-bit поля: source port, destination port, length и checksum. Length включает 8-byte header и payload. Обычное поле ограничивает UDP unit 65 535 bytes; реальный безопасный payload намного меньше из-за IP headers, path MTU, tunnels и policy. IPv6 jumbograms — отдельное редкое расширение, не основание отправлять огромные datagrams в обычной сети.

Destination host демультиплексирует datagram по address, protocol и destination port в подходящий socket. Source port указывает порт для ответа; RFC 768 допускает ноль, когда он не используется. Даже ненулевой source port не доказывает identity sender. Без криптографической защиты source IP/port и payload нельзя считать authenticated.

Message boundary сохраняется: два `sendto()` дают две datagrams. Они не склеиваются в одну UDP datagram на receiver. Если receive buffer меньше datagram, Linux возвращает помещающуюся часть; `recvmsg()` сообщает об обрезании через `MSG_TRUNC`, а отброшенный tail уже не доступен. Это отличается от [[10 Основы CS/Сокеты|stream socket]], где partial read продолжает тот же поток.

UDP не присваивает sequence numbers. Сеть и receive path могут потерять, reorder или продублировать packets. Kernel receive queue также конечна: когда process читает медленно, новые datagrams отбрасываются без backpressure к удалённому sender.

### Checksum: corruption detection, не authentication

Checksum считается по UDP header/data и pseudo-header с source/destination IP, protocol и length. Она ловит многие повреждения и ошибочную доставку не тому IP tuple, но не защищает от намеренной подделки: attacker пересчитает checksum.

Для IPv4 transmitted zero означает отсутствие UDP checksum. Если результат вычисления checksum сам равен нулю, RFC 768 требует передать все единицы, чтобы не спутать корректную checksum с её отключением. RFC 1122 требует host уметь генерировать и проверять checksum и включать её по умолчанию; отключение historically допустимо, но привело к undetected errors. Для IPv6 checksum по умолчанию обязательна: receiver отбрасывает zero checksum. Узкое исключение существует для специальных UDP tunnel protocols при выполнении RFC 6936, а не для обычного application traffic.

Hardware checksum offload способен показать в capture на sending host ещё не заполненное поле. Проверять corruption нужно с учётом capture point.

### Размер, fragmentation и Path MTU

UDP создаёт одну transport datagram. Если получившийся IP packet больше MTU, возможны четыре исхода:

- source получает локальную ошибку размера (`EMSGSIZE`) из известной PMTU;
- IPv4 packet фрагментируется, если это разрешено;
- IPv6 source заранее создаёт Fragment header, но routers по пути не фрагментируют;
- packet отбрасывается, а source получает ICMP `Fragmentation Needed` / `Packet Too Big` либо ничего при фильтрации ICMP.

IP fragmentation особенно хрупка: все fragments нужны для reassembly, один loss уничтожает всю datagram, а receiver хранит временное state. Fragments хуже проходят NAT/firewalls, потому что transport ports есть только в первом fragment. RFC 8085 рекомендует не отправлять UDP datagrams, создающие packets больше path MTU.

Classical PMTUD полагается на ICMP feedback. Если middlebox его фильтрует, большие datagrams попадают в PMTU black hole: маленькие работают, большие молча исчезают. Datagram Packetization Layer PMTU Discovery (DPLPMTUD) из RFC 8899 посылает probes разных размеров и подтверждает их средствами application/transport, поэтому умеет снижать размер без доверия к ICMP.

Если application message больше выбранного datagram payload, application-layer fragmentation должна дать fragments идентификатор сообщения, offset/index и предел общего размера, а при необходимости recovery — независимое подтверждение. Иначе один потерянный fragment заставляет повторять всё, а attacker может удерживать неограниченное reassembly state.

### Connected UDP

На Linux `connect()` для `SOCK_DGRAM`:

- задаёт default destination для `send()`/`write()`;
- связывает socket с выбранным peer tuple и при необходимости выбирает local port;
- принимает через этот socket только datagrams от указанного peer;
- позволяет kernel сопоставлять route/cache и некоторые errors с одним peer.

Никаких SYN/ACK нет. Успешный `connect()` не проверяет, слушает ли peer port, жив ли process и существует ли обратный route. Первая отправка всё ещё может завершиться локально успешно, а ICMP error прийти позже.

Connected socket удобен для одного peer и уменьшает риск принять packet от неожиданного address. Unconnected socket естественнее для server, который отвечает многим sources через `recvfrom()`/`sendto()`. Один unconnected socket усложняет attribution asynchronous errors: error способен относиться к более ранней datagram, отправленной другому destination.

### ICMP и асинхронность ошибок

Router или destination host может вернуть ICMP error: network/host unreachable, port unreachable, packet too big. Error идёт отдельным IP packet и приходит после исходного `send()`. Он может потеряться, быть отфильтрован или задержаться до повторного использования того же port.

RFC 1122 требует предоставить UDP application возможность получать asynchronous ICMP errors, но API и delivery policy различаются. Linux передаёт fatal errors даже unconnected sockets и через `IP_RECVERR` умеет складывать расширенную информацию в error queue. Приложение обязано проверить, что quoted tuple/payload действительно соответствует отправленной datagram, и не должно полагаться на ICMP для correctness: отсутствие error не подтверждает delivery.

Transient ICMP unreachable — soft signal. Route мог меняться, поэтому без protocol-specific основания единичный ICMP не должен навсегда объявлять peer мёртвым.

### Что переносится в application protocol

UDP application само выбирает:

- идентификаторы messages/requests и duplicate suppression;
- ordering policy: ждать gap, пропускать late data или обрабатывать независимо;
- ACK, retransmission timer, retry limit и expiry старых данных;
- rate/pacing и congestion response по aggregate traffic ко всем sockets;
- receiver flow control, queue limits и load shedding;
- PMTU probing и maximum datagram payload;
- authentication, replay protection и anti-amplification.

Congestion control обязателен и для UDP. RFC 8085 требует bulk transfer использовать подходящий congestion-control mechanism; небольшой request/response traffic также ограничивает rate и применяет backoff. «UDP не тормозит» без feedback означает, что sender переложил loss и queue collapse на сеть и соседние flows.

Retry создаёт новую datagram, которую server способен обработать после первой. Transport не дедуплицирует её. Без request ID и сохранённого outcome timeout превращается в ambiguous business result так же, как при разрыве TCP.

## Пример или трассировка

Client отправляет server команду `charge(order=42)` с application request ID `r7`. Retransmission timeout установлен protocol designer, не UDP.

```text
t0  client -> server: {id:r7, charge:42}       packet задержан
t1  client timeout
t2  client -> server: {id:r7, charge:42}       retry приходит первым
t3  server выполняет charge и отвечает r7
t4  исходная datagram с t0 приходит поздно
```

Без duplicate table server выполнит command дважды: обе datagrams корректны для UDP. С таблицей `id -> final outcome` server на шаге `t4` узнаёт `r7`, не повторяет side effect и возвращает прежний result. Если response на `t3` потеряется, client всё равно не может вывести outcome из timeout; он повторяет `r7` в пределах исходного [[20 Бэкенд/Дедлайны запросов и распространение отмены|deadline]] или запрашивает состояние операции.

Sequence number внутри media stream дал бы другой выбор: поздний frame можно отбросить, потому что его playback deadline уже прошёл. Надёжно доставлять его после `t4` было бы хуже, чем потерять. Именно возможность задать такую policy делает UDP полезным.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| RFC 8085 (2017) | RFC 5405 давал прежние UDP usage guidelines | RFC 8085 сделал RFC 5405 obsolete и собрал congestion, message size, reliability и security requirements | UDP application оценивают как transport design, а не только как 8-byte header | [RFC 8085](https://www.rfc-editor.org/rfc/rfc8085.html) |
| PLPMTUD RFC 4821 / DPLPMTUD RFC 8899 (2020) | Общий PLPMTUD требовал adaptation под datagram protocols | RFC 8899 задал state machine и probes для datagram transports | Protocol может обнаруживать PMTU black hole без обязательной доставки ICMP | [RFC 8899](https://www.rfc-editor.org/rfc/rfc8899.html) |

## Trade-offs

UDP даёт message boundaries, отсутствие connection handshake и свободу не ждать потерянные данные. Это подходит коротким queries, real-time media, multicast и substrate для transport protocols. Цена — почти вся end-to-end policy находится выше UDP.

[[10 Основы CS/TCP - handshake, надёжность и управление перегрузкой|TCP]] лучше, когда нужен ordered reliable stream и retransmission полезна для всех bytes. UDP выигрывает, когда messages независимы, late data бесполезны или protocol уже имеет собственные ACK/congestion/crypto, как QUIC. «Меньше header» редко компенсирует ошибочную самодельную reliability.

Одна крупная datagram уменьшает число syscalls и headers, но повышает вероятность fragmentation и цену одного loss. Несколько малых datagrams легче вписываются в PMTU и независимо повторяются, зато увеличивают packet rate, overhead и reassembly logic application.

Connected UDP упрощает single-peer code и фильтрует receive path. Unconnected socket обслуживает много peers одним FD и сохраняет per-message destination. Цена multiplexing — application state keyed by peer/request и осторожная обработка errors.

## Типичные ошибки

### Считать успешный `sendto()` доставкой

- **Неверное предположение:** syscall проверил доступность peer.
- **Симптом:** command теряется без error либо error приходит на следующий unrelated call.
- **Причина:** local kernel принял datagram; network/ICMP feedback асинхронен и ненадёжен.
- **Исправление:** application acknowledgment, request identity, deadline и явная retry/reconciliation policy.

### Посылать maximum-size datagram

- **Неверное предположение:** 16-bit UDP length означает безопасные 65 KB на любом path.
- **Симптом:** маленькие messages проходят, большие исчезают за tunnel/VPN или при смене route.
- **Причина:** path MTU намного меньше theoretical UDP limit; fragmentation или ICMP black hole уничтожает datagram.
- **Исправление:** ограничить payload проверенным размером, использовать PMTUD/DPLPMTUD и application fragmentation с bounded reassembly.

### Принимать checksum за защиту от подделки

- **Неверное предположение:** valid UDP checksum подтверждает sender.
- **Симптом:** spoofed request вызывает side effect или reflection/amplification response жертве.
- **Причина:** checksum не использует secret и пересчитывается attacker.
- **Исправление:** authenticated protocol, replay protection, response amplification limit и validation source reachability.

### Добавить retries без congestion control

- **Неверное предположение:** больше повторов повышает delivery probability без побочного эффекта.
- **Симптом:** loss вызывает burst retries, queue растёт и полезный throughput падает.
- **Причина:** UDP не уменьшает rate; каждый retry усиливает overload.
- **Исправление:** exponential backoff/jitter, retry budget, pacing и congestion response по aggregate destination traffic.

### Считать `connect()` handshake

- **Неверное предположение:** connected UDP peer подтвердил готовность.
- **Симптом:** первая datagram теряется, хотя `connect()` вернул success.
- **Причина:** `connect()` лишь меняет local socket association.
- **Исправление:** readiness подтверждать application exchange; transport association использовать только как local API constraint.

## Когда применять

UDP подходит, когда protocol сохраняет ценность независимых datagrams и явно реализует недостающие свойства: DNS-like short exchange, telemetry с допустимой потерей, time-sensitive media, multicast, tunneling и substrate для QUIC. Для каждого случая зафиксируйте maximum payload, rate/congestion policy, request identity, replay window, timeout/retry, overload behavior и authentication.

Если каждое сообщение нужно доставить по порядку, повторять до успеха и защищать receive buffers, сначала выбирайте готовый reliable transport. UDP оправдан не отсутствием требований, а тем, что application осознанно выбирает другую семантику loss и времени.

## Источники

- [RFC 768: User Datagram Protocol](https://www.rfc-editor.org/rfc/rfc768.html) — IETF, STD 6 / RFC 768, август 1980, проверено 2026-07-18.
- [RFC 1122: Requirements for Internet Hosts — Communication Layers](https://www.rfc-editor.org/rfc/rfc1122.html) — IETF, STD 3 / RFC 1122, октябрь 1989, проверено 2026-07-18.
- [RFC 8085: UDP Usage Guidelines](https://www.rfc-editor.org/rfc/rfc8085.html) — IETF, BCP 145 / RFC 8085, март 2017, проверено 2026-07-18.
- [RFC 8899: Packetization Layer Path MTU Discovery for Datagram Transports](https://www.rfc-editor.org/rfc/rfc8899.html) — IETF, RFC 8899, сентябрь 2020, проверено 2026-07-18.
- [RFC 8200: Internet Protocol, Version 6 (IPv6) Specification](https://www.rfc-editor.org/rfc/rfc8200.html) — IETF, Internet Standard / RFC 8200, июль 2017, проверено 2026-07-18.
- [RFC 6936: Applicability Statement for the Use of IPv6 UDP Datagrams with Zero Checksums](https://www.rfc-editor.org/rfc/rfc6936.html) — IETF, RFC 6936, апрель 2013, проверено 2026-07-18.
- [udp(7)](https://git.kernel.org/pub/scm/docs/man-pages/man-pages.git/tree/man/man7/udp.7?h=man-pages-6.18) — Linux man-pages, tag `man-pages-6.18`, апрель 2026, проверено 2026-07-18.
- [connect(2)](https://git.kernel.org/pub/scm/docs/man-pages/man-pages.git/tree/man/man2/connect.2?h=man-pages-6.18) — Linux man-pages, tag `man-pages-6.18`, апрель 2026, проверено 2026-07-18.
