---
aliases:
  - TCP
  - TCP handshake
  - TCP reliability
  - TCP congestion control
tags:
  - область/основы-cs
  - тема/сети
  - протокол/tcp
статус: проверено
---

# TCP - handshake, надёжность и управление перегрузкой

## TL;DR

TCP создаёт между двумя sockets полнодуплексный упорядоченный поток байтов. Three-way handshake синхронизирует два независимых sequence spaces и параметры соединения. После этого sender хранит неподтверждённые bytes, receiver подтверждает следующий ожидаемый sequence number, дубли отбрасываются, а gaps закрываются retransmission.

Скорость ограничивают две разные обратные связи. Advertised receive window (`rwnd`) защищает buffer получателя, congestion window (`cwnd`) — общий network path. Грубо, sender держит в полёте не больше `min(rwnd, cwnd)`. Loss, retransmission timeout и Explicit Congestion Notification (ECN) относятся к congestion control; медленно читающее приложение меняет `rwnd`, но не доказывает congestion.

TCP гарантирует доставку байтов в socket stream либо сообщает transport failure. Он не знает, выполнил ли peer business operation. После timeout, FIN/RST или потерянного response результат request способен остаться неоднозначным.

## Область применимости

Базовая TCP semantics сверена с Internet Standard RFC 9293 от августа 2022 года. Baseline congestion control описан RFC 5681, retransmission timer — RFC 6298, ECN — RFC 3168. Конкретные operating systems применяют дополнительные loss-recovery и congestion-control algorithms, но сохраняют wire contract TCP. Socket API и границы `send`/`recv` разобраны в [[10 Основы CS/Сокеты|отдельной заметке]].

## Ментальная модель

TCP — две независимые бухгалтерские книги байтов, по одной на каждое направление:

```text
A send sequence space                           B receive sequence space

SND.UNA -------- SND.NXT ------------------>
  ACKed bytes      sent, not yet ACKed

             FlightSize <= min(rwnd, cwnd)

                         <------------------ RCV.NXT
                              следующий byte, который B ждёт без gap
```

Sequence number привязывает каждый byte к позиции потока. `ACK=n` сообщает: «все bytes до `n-1` включительно уже приняты; следующим жду byte `n`». Receiver может временно держать более поздние bytes за gap, но application получает непрерывный prefix. Повтор того же диапазона не создаёт второй copy в stream.

`rwnd` и `cwnd` отвечают разным владельцам:

- `rwnd` публикует receiver: сколько места осталось в его receive path;
- `cwnd` ведёт sender: сколько неподтверждённых данных path, по его оценке, выдерживает без перегрузки.

## Как устроено

### Three-way handshake

Connection идентифицируется transport protocol и парой endpoint addresses/ports. Active opener отправляет `SYN` со своим initial sequence number (ISN) `x`. Passive opener отвечает `SYN, ACK`: выбирает ISN `y` и подтверждает `x+1`. Active side завершает handshake `ACK y+1`.

```text
client                                      server
SYN, seq=x                     -----------> SYN-RECEIVED
SYN, seq=y, ack=x+1            <-----------
ACK, seq=x+1, ack=y+1          -----------> ESTABLISHED
```

`SYN` занимает один sequence number, как и `FIN`. Три шага нужны, чтобы каждая сторона получила ISN peer и доказательство, что её собственный ISN увидели; заодно handshake отсекает старый duplicate SYN от прежнего incarnation соединения. Simultaneous open допустим, хотя редко встречается в обычном client/server flow.

TCP options с negotiation semantics передают в `SYN`/`SYN-ACK`: Maximum Segment Size (MSS), Window Scale, разрешение Selective Acknowledgment (SACK), timestamps. MSS ограничивает TCP payload segment, а не IP packet целиком. Если option не согласован при handshake, его нельзя считать доступным позже только потому, что обе реализации в принципе умеют его.

Успешный client `connect()` означает, что локальный TCP завершил transport establishment. Server application всё ещё может не вызвать `accept()`, не прочитать request или закрыться сразу после handshake.

### Sequence numbers, ACK, ordering и duplicates

TCP нумерует bytes, а не packets и не вызовы `send()`. Один application write может стать несколькими segments; несколько writes могут быть coalesced. ACK обычно cumulative: `ACK=n` подтверждает непрерывный prefix до `n-1`. Если segment `1001..1500` потерян, а `1501..2500` пришли, receiver продолжает отвечать `ACK=1001`, сохраняя gap.

Receiver проверяет, пересекается ли segment с допустимым receive window. Уже принятый диапазон распознаётся по sequence numbers и не выдаётся application повторно. Out-of-order bytes могут храниться в reassembly queue; application увидит их только после заполнения gap. Если buffer или policy не позволяют хранить, receiver вправе отбросить segment, и sender восстановит его позже.

SACK, если его разрешили в handshake, дополняет cumulative ACK блоками уже полученных ranges. Sender точнее видит несколько gaps и не обязан повторять весь tail. SACK не меняет основной контракт stream и не превращает ACK в подтверждение application processing.

### Retransmission: RTO и fast retransmit

У каждого sender есть retransmission timeout (RTO) для старейших неподтверждённых данных. RFC 6298 оценивает smoothed RTT (`SRTT`) и variation (`RTTVAR`), затем вычисляет:

```text
RTO = SRTT + max(clock_granularity, 4 * RTTVAR)
```

До RTT sample initial RTO равен 1 секунде по RFC 6298. Тот же RFC рекомендует округлять вычисленный RTO меньше 1 секунды вверх до 1 секунды. После timeout sender повторяет старейший неподтверждённый segment и экспоненциально увеличивает RTO. RTT нельзя надёжно измерить по ACK retransmitted segment: неизвестно, подтвердил ACK исходную или повторную copy. Karn's algorithm не берёт такой ambiguous sample без timestamp-based disambiguation.

Timer — медленный, но универсальный detector: он работает даже когда после loss не пришло достаточно следующих segments. При потере внутри активного потока receiver немедленно шлёт duplicate ACK для каждого out-of-order segment. Baseline fast retransmit из RFC 5681 трактует три duplicate ACK без продвижения `SND.UNA` как сигнал loss и повторяет предполагаемый missing segment до RTO. Reordering тоже создаёт duplicate ACK, поэтому слишком агрессивный threshold давал бы spurious retransmissions.

ACK сам способен потеряться. Это не обязательно вызывает retransmission: более поздний cumulative ACK подтвердит тот же prefix. Retransmission не означает, что первый copy не дошёл; duplicate suppression на receiver — обязательная часть надёжности.

### Flow control: receive window

Receiver помещает bytes в kernel receive buffer и публикует свободный диапазон в TCP Window field. По мере поступления данных `RCV.NXT` движется, а пока application не читает, свободное место сокращается. Sender не должен передавать новые bytes за правую границу advertised window.

Базовое поле window имеет 16 bits. Window Scale из RFC 7323, согласованный только в SYN, позволяет интерпретировать его с масштабом для paths с большим bandwidth-delay product. Если receiver объявил zero window, sender прекращает новые data и периодически посылает window probes, чтобы не зависнуть навсегда при потерянном window update.

Flow control ограничивает одного sender ради одного receiver. Он не защищает промежуточный router и не ограничивает число concurrent connections к application. Медленный consumer проявляется уменьшением `rwnd`, заполненным sender buffer и блокировкой/`EAGAIN`; увеличение buffers лишь откладывает эту обратную связь.

### Congestion control: congestion window

Sender поддерживает `cwnd`, которого нет в TCP header. Это локальная оценка допустимого объёма unacknowledged data в network. Реальный предел отправки учитывает и `rwnd`, и `cwnd`; также важны уже находящийся в полёте объём и pacing.

RFC 5681 задаёт baseline из slow start, congestion avoidance, fast retransmit и fast recovery. В slow start `cwnd` растёт на подтверждённые bytes так, что при непрерывных ACK примерно удваивается за RTT до `ssthresh` или congestion signal. В congestion avoidance рост становится примерно additive. После loss sender уменьшает доступное окно; timeout считается более сильным признаком отсутствия progress, чем fast retransmit, и возвращает отправку к малому loss window.

Loss не всегда вызван congestion: packet мог повредиться, route мог поменяться, segments могли сильно reorder. Но обычный TCP не имеет достоверного способа различить причины и реагирует консервативно, иначе competing flows способны вызвать congestion collapse.

Explicit Congestion Notification (ECN) позволяет ECN-capable endpoint пометить IP packets, а queue — выставить Congestion Experienced вместо раннего drop. Receiver возвращает сигнал sender, и тот уменьшает congestion window примерно как при loss. ECN экономит retransmission, но не отменяет снижение rate и не помогает, если endpoint или path не согласовали/не сохранили маркировку.

`rwnd` и `cwnd` легко различить по эксперименту: если receiver перестал читать, advertised window падает при здоровом path; если bottleneck теряет/маркирует packets, sender уменьшает `cwnd`, даже когда receiver buffer пуст.

### FIN, half-close, RST и TIME-WAIT

Поскольку направления независимы, TCP закрывается по половинам. `FIN` означает: sender больше не передаст bytes после указанной позиции. Peer подтверждает FIN, но ещё может отправлять данные в обратном направлении. Это соответствует `shutdown(SHUT_WR)` и EOF у peer после всех предшествующих bytes.

Orderly close требует FIN и ACK для обоих направлений. Сторона, которая активно закрылась и отправила финальный ACK на FIN peer, обычно проходит TIME-WAIT. Она временно хранит state, чтобы повторить последний ACK при retransmitted FIN и не спутать старые segments с новым incarnation того же tuple.

`RST` аварийно сбрасывает state. Peer получает reset/error вместо orderly EOF; buffered или in-flight data могут не дойти до application. RST не является «ускоренным FIN» и не подтверждает, что предыдущие bytes обработаны. Abortive `close` через некоторые `SO_LINGER` настройки способен породить именно такой outcome.

### Почему transport outcome остаётся неоднозначным

Допустим, client полностью отправил `POST`, server TCP подтвердил bytes, server application committed изменение, но response потерялся и connection reset. Client знает только, что не получил response. Даже отсутствие ACK не доказывает отсутствие эффекта: request мог попасть в application, а ACK/response — потеряться.

Поэтому network retry — новый application attempt. Он обязан укладываться в исходный [[20 Бэкенд/Дедлайны запросов и распространение отмены|deadline]], а небезопасная операция требует protocol-level idempotency или дедупликации. TCP sequence numbers удаляют transport duplicates внутри одного connection, но не объединяют два заново открытых requests.

## Пример или трассировка

После handshake client начинает поток с `seq=1001`, server — с `seq=7001`. Server рекламирует `rwnd=8000`; client в этот момент имеет `cwnd=4000`. MSS равен 1000 bytes.

```text
client                                               server

seq=1001, len=1000  ------------------------------>  ACK=2001
seq=2001, len=1000  --------X                         packet lost
seq=3001, len=1000  ------------------------------>  ACK=2001 (dup #1)
seq=4001, len=1000  ------------------------------>  ACK=2001 (dup #2)
seq=5001, len=1000  ------------------------------>  ACK=2001 (dup #3)

fast retransmit:
seq=2001, len=1000  ------------------------------>  ACK=6001
```

До loss sender мог держать не более `min(8000, 4000) = 4000` bytes in flight; ACK clock освобождал место для следующего segment. Server временно сохранил ranges `3001..6000`, но application не получил их за gap. Третий duplicate ACK запустил baseline fast retransmit. После получения missing range cumulative ACK сразу продвинулся до `6001`; повторно переданные или уже buffered bytes не задублировались в stream. Одновременно congestion control уменьшил sending window, потому что loss трактуется как congestion signal.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| RFC 793 (1981) / RFC 9293 (2022) | TCP specification была распределена по RFC 793 и множеству updates | RFC 9293 обобщил основной protocol и сделал RFC 793 obsolete | Для базовой wire semantics точкой отсчёта служит RFC 9293 с перечисленными updates | [RFC 9293](https://www.rfc-editor.org/rfc/rfc9293.html) |
| До RFC 6298 / RFC 6298 (2011) | Рекомендованный initial RTO составлял 3 секунды | Initial RTO снижен до 1 секунды с fallback для spurious SYN retransmission case | Потеря при handshake восстанавливается быстрее, но paths с RTT > 1 s могут получить лишний SYN | [RFC 6298](https://www.rfc-editor.org/rfc/rfc6298.html) |
| Без SACK / RFC 2018 (1996) | Cumulative ACK сообщает только начало первого gap | Receiver может сообщить дополнительные принятые blocks | Sender точнее восстанавливает несколько losses в одном window | [RFC 2018](https://www.rfc-editor.org/rfc/rfc2018.html) |
| Drop-only / ECN RFC 3168 (2001) | Congestion обычно сигнализировался packet loss | ECN-capable queue может поставить CE mark вместо drop | Sender снижает rate без обязательной retransmission этого packet | [RFC 3168](https://www.rfc-editor.org/rfc/rfc3168.html) |

## Trade-offs

TCP скрывает loss, reordering и duplicates от application и даёт byte-stream backpressure. Цена — handshake, per-connection state и head-of-line blocking: потерянный byte задерживает выдачу всех последующих bytes этого stream, даже если они уже на receiver.

[[10 Основы CS/UDP|UDP]] сохраняет datagram boundaries и позволяет application выбирать, какие данные стоит повторять или пропустить. Но reliability, congestion control, ordering, PMTU и retry ambiguity переходят в application protocol. QUIC решает часть TCP transport limitations поверх UDP, однако это полноценный transport protocol, а не «UDP с парой ACK».

Большие receive windows и buffers помогают заполнить path с большим bandwidth-delay product. Они же увеличивают memory per connection и позволяют накопить больше устаревших данных. Увеличивать buffer без измерения `rwnd`, `cwnd`, RTT и application queue бессмысленно.

Долгоживущие connections амортизируют handshake и накопленную path state. [[20 Бэкенд/Пулы соединений и keep-alive|Пул соединений]] сохраняет эти выгоды, но добавляет очереди, lifetime policy и риск повторно использовать connection, закрытую peer или middlebox.

FIN даёт проверяемый EOF и half-close. RST быстро освобождает state, но превращает завершение в error и способен уничтожить ещё не прочитанные данные. Выбор зависит от application framing и допустимости ambiguous outcome.

## Типичные ошибки

### Путать flow control с congestion control

- **Неверное предположение:** большое `rwnd` разрешает sender отправлять с любой скоростью.
- **Симптом:** throughput не растёт после увеличения receive buffer либо path получает bursts/loss.
- **Причина:** sender одновременно ограничен `cwnd`; receiver capacity не доказывает network capacity.
- **Исправление:** измерять `rwnd`, `cwnd`, bytes in flight, RTT и loss/ECN раздельно.

### Читать TCP по границам packets

- **Неверное предположение:** один `send()` соответствует одному segment и одному `recv()`.
- **Симптом:** parser принимает partial message или склеивает соседние messages.
- **Причина:** TCP сохраняет порядок bytes, но не application boundaries.
- **Исправление:** ввести length prefix/delimiter, incremental parsing и maximum frame size.

### Считать retransmission доказательством потери первого copy

- **Неверное предположение:** повторный segment означает, что receiver не видел исходный.
- **Симптом:** transport retransmission ошибочно считают duplicate business request.
- **Причина:** ACK мог потеряться, RTO мог быть spurious, а duplicate подавляется sequence space.
- **Исправление:** различать transport segment и application attempt; business dedup строить по request identity.

### Трактовать FIN и RST одинаково

- **Неверное предположение:** оба флага означают корректно прочитанный peer response.
- **Симптом:** truncated payload принимается за полное сообщение либо reset ошибочно считается graceful shutdown.
- **Причина:** FIN упорядочен в sequence space и сообщает EOF после предшествующих bytes; RST сбрасывает state.
- **Исправление:** проверять application framing до EOF, а reset обрабатывать как ambiguous transport failure.

### Повторять mutation после timeout

- **Неверное предположение:** timeout доказывает, что server не выполнил request.
- **Симптом:** двойное списание или повторное создание объекта.
- **Причина:** request мог быть delivered и committed, а response потерян.
- **Исправление:** использовать safe/idempotent operation или idempotency key, ограниченный retry budget и reconciliation по operation ID.

## Когда применять

TCP подходит для protocols, которым нужен надёжный ordered byte stream и допустима задержка последующих bytes при loss: HTTP/1.1, HTTP/2 transport, database connections, replication streams. Перед production использованием определите connect, request, idle и total deadlines; framing; maximum buffers; keep-alive/lifetime; retry semantics; graceful/abortive close.

При диагностике handshake проверяйте SYN, SYN-ACK, финальный ACK и negotiated options. Для throughput разделяйте receiver limit (`rwnd`), sender congestion state (`cwnd`), application-limited periods и path loss/ECN. Для correctness всегда поднимайтесь выше transport: TCP ACK не заменяет application acknowledgment.

## Источники

- [RFC 9293: Transmission Control Protocol (TCP)](https://www.rfc-editor.org/rfc/rfc9293.html) — IETF, Internet Standard / RFC 9293, август 2022, проверено 2026-07-18.
- [RFC 5681: TCP Congestion Control](https://www.rfc-editor.org/rfc/rfc5681.html) — IETF, RFC 5681, сентябрь 2009, проверено 2026-07-18.
- [RFC 6298: Computing TCP's Retransmission Timer](https://www.rfc-editor.org/rfc/rfc6298.html) — IETF, RFC 6298, июнь 2011, проверено 2026-07-18.
- [RFC 7323: TCP Extensions for High Performance](https://www.rfc-editor.org/rfc/rfc7323.html) — IETF, RFC 7323, сентябрь 2014, проверено 2026-07-18.
- [RFC 2018: TCP Selective Acknowledgment Options](https://www.rfc-editor.org/rfc/rfc2018.html) — IETF, RFC 2018, октябрь 1996, проверено 2026-07-18.
- [RFC 3168: The Addition of Explicit Congestion Notification (ECN) to IP](https://www.rfc-editor.org/rfc/rfc3168.html) — IETF, RFC 3168, сентябрь 2001, проверено 2026-07-18.
