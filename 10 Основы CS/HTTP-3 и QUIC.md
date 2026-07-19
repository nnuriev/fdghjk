---
aliases:
  - HTTP/3
  - HTTP 3
  - QUIC
  - QPACK
tags:
  - область/основы-cs
  - тема/сети
  - тема/http
  - механизм/quic
статус: проверено
---

# HTTP/3 и QUIC

## TL;DR

HTTP/3 переносит HTTP поверх QUIC, а QUIC реализует поверх UDP защищённые connections, надёжные streams, loss recovery, flow control и congestion control. UDP здесь лишь datagram substrate: прикладной код получает не «ненадёжный HTTP», а упорядоченные байты внутри каждого QUIC stream.

Ключевое отличие от HTTP/2 — отсутствие общего транспортного порядка между streams. Потеря данных одного stream не мешает доставить уже полученные данные другого stream. При этом loss не исчезает: streams делят congestion budget, connection-level flow control, stream limits и судьбу connection. QPACK тоже может временно заблокировать header block, если тот ссылается на ещё не доставленное состояние dynamic table.

## Область применимости

- HTTP/3 рассматривается по RFC 9114, QUIC version 1 — по RFC 9000, TLS integration — по RFC 9001, recovery — по RFC 9002, QPACK — по RFC 9204.
- QUIC version 2 по RFC 9369 меняет wire image для проверки version negotiation и борьбы с ossification, но не меняет рассматриваемую транспортную модель.
- Семантика request остаётся общей с HTTP/1.1 и HTTP/2; методы, statuses, headers и caching разобраны в [[20 Бэкенд/HTTP-методы, статус-коды, заголовки и семантика кэширования|отдельной заметке]].
- Вне scope: конкретный congestion-control algorithm, kernel bypass, QUIC DATAGRAM и реализация load balancer routing по Connection ID.

## Ментальная модель

UDP доставляет отдельные конверты, а QUIC строит поверх них несколько независимых нумерованных лент. У каждой ленты — собственные offsets и порядок. Потерянный конверт нужно восстановить, но готовый кусок другой ленты можно отдать приложению, не заполняя пропуск первой.

Для рассуждения полезно разделить пять сущностей:

1. **UDP datagram** переносит один или несколько QUIC packets;
2. **QUIC packet** задаёт protection level и переносит frames; packets с transport frames нумеруются внутри своего packet number space;
3. **QUIC frame** управляет transport state или переносит диапазон байтов stream;
4. **QUIC stream** даёт надёжный ordered byte stream независимо от соседних streams;
5. **HTTP/3 frame** живёт внутри QUIC stream и несёт HEADERS, DATA или control information.

Packet number сообщает, что было получено или потеряно на transport; stream offset сообщает, куда относятся данные приложения. Поэтому QUIC повторно передаёт потерянную информацию в новом packet с новым номером, а не воспроизводит старый packet целиком.

## Как устроено

### QUIC connection поверх UDP

QUIC version 1 определяет надёжную доставку stream data, ACK, loss detection, congestion control, flow control и криптографическую защиту в user space поверх UDP. Это не отменяет ограничений сети: datagram может потеряться, измениться MTU, а некоторые сети блокируют UDP. Тогда клиенту нужен управляемый fallback, обычно к HTTP/2, а не бесконечные попытки QUIC.

Connection не тождественен сетевому 4-tuple. Connection IDs позволяют peer и load balancer узнавать логическое соединение после смены клиентского адреса или порта. При обнаружении нового peer address endpoint проверяет path с `PATH_CHALLENGE`/`PATH_RESPONSE`, прежде чем доверять ему полностью. Так переживается NAT rebinding; в QUIC v1 active migration инициирует client, а server может предложить preferred address. Это capability, а не гарантия: zero-length Connection ID, endpoint policy или сеть могут migration ограничить.

### Streams и HTTP/3 mapping

Каждый HTTP request/response занимает client-initiated bidirectional QUIC stream. Клиент передаёт HEADERS и необязательные DATA; сервер отвечает HEADERS и DATA в обратном направлении того же stream. Кроме request streams, обе стороны создают critical unidirectional streams:

- control stream для SETTINGS и управления HTTP/3 connection;
- QPACK encoder stream для обновлений dynamic table;
- QPACK decoder stream для подтверждений и управления блокировкой.

У QUIC есть ограничения числа streams и два уровня flow control. `MAX_STREAM_DATA` выдаёт credit конкретному stream, `MAX_DATA` — connection целиком. `MAX_STREAMS` задаёт cumulative число bidirectional или unidirectional streams, которое peer вправе открыть за жизнь connection. Закрытие stream само не уменьшает счётчик; receiver может выдать новый credit следующим `MAX_STREAMS` с большим значением. Поэтому медленный consumer способен остановить свой stream, а исчерпание общего credit — весь sender, даже без inter-stream ordering.

Закрытие тоже имеет уровни. `RESET_STREAM` прекращает отправку в одном направлении, `STOP_SENDING` просит peer её остановить, а `CONNECTION_CLOSE` завершает всё connection. HTTP/3 `GOAWAY` прекращает приём новых requests и позволяет корректно drain существующие. Ни один reset сам по себе не доказывает отсутствие прикладного side effect.

### Packet numbers, ACK и loss recovery

QUIC использует три packet number spaces: Initial, Handshake и Application Data; 0-RTT и 1-RTT разделяют последний space. Номера монотонно растут внутри space и не переиспользуются. ACK несёт ranges полученных packet numbers из того же space.

Если packet признан потерянным, sender помещает нужные данные и control information в новые frames новых packets. Stream offsets остаются прежними, поэтому receiver собирает правильный диапазон независимо от номера повторной передачи. Раздельные number spaces не позволяют ACK одного encryption level ошибочно подтвердить packet другого; congestion и RTT estimation при этом относятся к connection/path, а не дают каждому stream отдельную сеть.

RFC 9002 задаёт обязательные механизмы loss detection и пример NewReno congestion controller, но разрешает другие algorithms. Какой бы algorithm ни использовался, loss обычно уменьшает доступный congestion window или тормозит его рост. Поэтому потеря stream A не блокирует уже прибывшие байты stream B, но может замедлить будущую отправку обоих через общий path budget.

### TLS внутри QUIC

QUIC интегрирует TLS 1.3 handshake: сообщения handshake переносятся в `CRYPTO` frames. Ключи Initial protection выводятся из version-specific salt и client Destination Connection ID, поэтому эта защита не аутентифицирует peer; TLS key schedule даёт ключи для Handshake, 0-RTT и 1-RTT. QUIC не использует TLS record layer — packet framing и protection определяет сам QUIC. Через ALPN стороны выбирают `h3`, а certificate и service identity проверяются по тем же принципам, что описаны в [[10 Основы CS/TLS handshake и проверка сертификатов|заметке о TLS handshake]].

Объединение transport и cryptographic handshake сокращает число последовательных round trips по сравнению с отдельными TCP и TLS handshakes. Это не означает «всегда 0 RTT»: новый клиент без сохранённого PSK выполняет handshake, а server может потребовать retry или дополнительный key share.

### 0-RTT и resumption

После предыдущего соединения клиент может иметь TLS PSK/session ticket и отправить early data вместе с первым flight. Server вправе 0-RTT отвергнуть, после чего запрос может понадобиться повторить уже в 1-RTT keys.

0-RTT data не имеет forward secrecy и межсоединительной защиты от replay, которую имеет обычный 1-RTT traffic. Поэтому transport acceptance не равна business safety. В early data помещают только запросы, проходящие правила [[10 Основы CS/Retry safety|retry safety]], либо применяют дополнительный replay/idempotency protocol. HTTP status `425 Too Early` позволяет server сообщить, что request следует повторить после handshake.

### QPACK без общего порядка streams

HPACK из HTTP/2 опирается на общий TCP order: decoder получает изменения compression state раньше header blocks, которые ими пользуются. В QUIC разные streams могут прийти в другом порядке, поэтому HTTP/3 использует QPACK.

QPACK передаёт изменения dynamic table по отдельному encoder stream. Field section request stream может сослаться на entry, которая ещё не пришла; тогда decoding этой секции ждёт нужного insert count, а секции без такой зависимости продолжают обрабатываться. Настройка `SETTINGS_QPACK_BLOCKED_STREAMS` ограничивает, сколько streams peer готов держать заблокированными. Encoder выбирает trade-off: агрессивные dynamic references дают лучшее сжатие, literal или уже подтверждённые entries — меньше риск latency из-за reordering.

### Connection lifecycle и routing

QUIC connection может нести много requests и пережить смену path, поэтому его reuse особенно выгоден. Но connection-level failure затрагивает все streams, а долгоживущий Connection ID создаёт state у load balancer и endpoint. Ограничения, очереди и draining следует рассматривать вместе с [[20 Бэкенд/Пулы соединений и keep-alive|общей моделью connection pooling]].

Для L4 load balancer обычного hash по сетевому 4-tuple недостаточно, если QUIC должен переживать migration: routing часто использует server-chosen Connection ID. L7 proxy, напротив, завершает QUIC/HTTP/3 и создаёт новый upstream transport; граница TLS identity и congestion state проходит через proxy, как и в других вариантах [[10 Основы CS/Балансировка сетевой нагрузки|сетевой балансировки]].

## Пример или трассировка

После handshake клиент отправляет два request в client-initiated bidirectional streams 0 и 4; все показанные packets относятся к Application Data packet number space:

```text
packet 20: STREAM id=0 offset=0  HEADERS+DATA for /slow   -- потерян
packet 21: STREAM id=4 offset=0  HEADERS+DATA for /fast   -- доставлен
```

Receiver подтверждает packet 21 и сразу отдаёт полные байты stream 4 HTTP/3 parser. Stream 0 ждёт повторной передачи диапазона с offset 0:

```text
packet 24: STREAM id=0 offset=0  тот же диапазон /slow    -- доставлен
```

Наблюдаемый результат: `/fast` может завершиться до восстановления `/slow`; packet 24 имеет новый packet number, хотя несёт прежний диапазон stream data. Если бы оба stream ranges находились только в потерянном packet 20, оба ждали бы recovery. А уменьшенный после loss congestion window способен задержать будущие packets всех streams — исчез общий порядок доставки, но не общий congestion budget.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| QUIC v1 / HTTP/3, май–июнь 2021–2022 | Стандартизованы transport QUIC v1, TLS integration, recovery, QPACK и mapping HTTP/3 | Набор RFC 9000–9002, 9114 и 9204 зафиксировал совместимую базовую модель | При анализе поведения нужно проверять несколько слоёв, а не ссылаться на один «RFC QUIC» | [RFC 9000](https://www.rfc-editor.org/rfc/rfc9000.html), [RFC 9114](https://www.rfc-editor.org/rfc/rfc9114.html) |
| QUIC v2, май 2023 | QUIC v1 задал первый стандартизованный wire image, вокруг которого могли закрепиться предположения middleboxes | RFC 9369 изменил version number, salts, labels и часть header encoding, сохранив transport semantics v1 | V2 проверяет, что endpoints и middleboxes действительно поддерживают version negotiation; новых HTTP-возможностей само по себе не добавляет | [RFC 9369](https://www.rfc-editor.org/rfc/rfc9369.html) |

## Trade-offs

| Выбор | Выигрыш | Цена и ближайшая альтернатива |
| --- | --- | --- |
| HTTP/3 вместо HTTP/2 | Нет TCP HOL между независимыми streams, совместный transport+TLS handshake, migration | Более сложный user-space transport, UDP может блокироваться, наблюдаемость и LB routing требуют QUIC-aware tooling |
| Один QUIC connection | Меньше handshakes, reuse congestion knowledge, много streams | Общий congestion/flow-control budget и blast radius; несколько connections дают изоляцию ценой state и fairness |
| Агрессивный QPACK dynamic table | Меньше header bytes | Header block может ждать encoder stream; literal encoding больше, но предсказуемее по latency |
| Большие flow-control windows | Высокий throughput при большом bandwidth-delay product | Больше receiver memory и потенциальный общий stall от медленного consumer |
| Connection migration | Запросы переживают NAT rebinding и смену path | Нужны Connection IDs, path validation, routing state и защита privacy; reconnect проще, но обрывает in-flight streams |
| 0-RTT | Request может уйти в первом flight повторного connection | Replay risk, weaker forward secrecy и возможность rejection; обычный 1-RTT безопаснее как default для операций с эффектом |

## Типичные ошибки

### Считать QUIC ненадёжным из-за UDP

Неверное предположение: приложение само должно повторять потерянные HTTP chunks. Симптом: дублированные requests и разрушенный порядок body. Причина: QUIC уже обеспечивает reliable ordered delivery внутри stream. Исправление: оставить transport recovery реализации QUIC, а application retry выполнять только после определения исхода всего request и его семантической безопасности.

### Утверждать, что QUIC устранил head-of-line blocking полностью

Неверное предположение: один stalled stream никак не влияет на остальные. Симптом: после loss или медленного consumer растёт latency сразу нескольких requests. Причина: connection congestion window, `MAX_DATA`, stream limits, QPACK dependencies и CPU остаются общими. Исправление: различать inter-stream ordering, который устранён, и shared resource contention, который остался.

### Повторять 0-RTT request как обычную сетевую потерю

Неверное предположение: TLS/QUIC гарантирует exactly-once для early data. Симптом: дублированный side effect после replay или server rejection. Причина: 0-RTT допускает межсоединительный replay и может быть обработан до завершения handshake. Исправление: не отправлять небезопасную операцию в early data либо использовать application-level idempotency и учитывать `425 Too Early`.

### Диагностировать только по packet number

Неверное предположение: retransmission обязана иметь тот же номер, поэтому новый номер означает новые данные. Симптом: неверно посчитанные retries и потеря связи между trace и stream. Причина: QUIC никогда не переиспользует packet number внутри одного packet number space; повторяется information range с тем же stream offset. Исправление: сопоставлять ACK/loss по packet numbers и их spaces, а данные приложения — по stream ID и offsets.

### Не ограничивать QUIC handshake и fallback

Неверное предположение: клиент может ждать UDP сколько угодно, потому что HTTP/3 быстрее. Симптом: запрос зависает в сети, где UDP фильтруется, и не успевает перейти на HTTP/2. Причина: handshake, path validation и fallback конкурируют за общий budget. Исправление: выделить им фазы по модели [[10 Основы CS/Тайм-ауты на сетевых уровнях|сетевых тайм-аутов]] внутри [[20 Бэкенд/Дедлайны запросов и распространение отмены|end-to-end deadline]] и измерять причину fallback.

## Когда применять

HTTP/3 особенно полезен на paths с заметной loss/reordering, при мобильной смене адреса и при большом числе concurrent requests, где TCP HOL HTTP/2 виден в tail latency. На стабильной низколатентной сети выигрыш может быть небольшим, а операционная стоимость QUIC-aware observability и load balancing — заметной.

При диагностике разделяйте: UDP reachability, QUIC/TLS handshake, path validation, stream/connection flow control, QPACK blocking, congestion loss и application queue. У этих пауз разные wire-сигналы и разные исправления; «QUIC медленный» не является достаточной причиной.

## Источники

- [RFC 9000: QUIC — A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000.html) — IETF, RFC 9000 / QUIC version 1, май 2021, проверено 2026-07-18.
- [RFC 9001: Using TLS to Secure QUIC](https://www.rfc-editor.org/rfc/rfc9001.html) — IETF, RFC 9001 / QUIC version 1, май 2021, проверено 2026-07-18.
- [RFC 9002: QUIC Loss Detection and Congestion Control](https://www.rfc-editor.org/rfc/rfc9002.html) — IETF, RFC 9002 / QUIC version 1, май 2021, проверено 2026-07-18.
- [RFC 9114: HTTP/3](https://www.rfc-editor.org/rfc/rfc9114.html) — IETF, RFC 9114, июнь 2022, проверено 2026-07-18.
- [RFC 9204: QPACK — Field Compression for HTTP/3](https://www.rfc-editor.org/rfc/rfc9204.html) — IETF, RFC 9204, июнь 2022, проверено 2026-07-18.
- [RFC 8470: Using Early Data in HTTP](https://www.rfc-editor.org/rfc/rfc8470.html) — IETF, RFC 8470, сентябрь 2018, проверено 2026-07-18.
- [RFC 9369: QUIC Version 2](https://www.rfc-editor.org/rfc/rfc9369.html) — IETF, RFC 9369 / QUIC version 2, май 2023, проверено 2026-07-18.
- [RFC 9308: Applicability of the QUIC Transport Protocol](https://www.rfc-editor.org/rfc/rfc9308.html) — IETF, RFC 9308, сентябрь 2022, проверено 2026-07-18.
