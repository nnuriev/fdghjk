---
aliases:
  - HTTP/2
  - HTTP 2
  - HTTP/2 multiplexing
  - HPACK
tags:
  - область/основы-cs
  - тема/сети
  - тема/http
  - механизм/мультиплексирование
статус: проверено
---

# HTTP/2 и multiplexing

## TL;DR

HTTP/2 сохраняет семантику HTTP, но заменяет текстовый wire format бинарными frames и разбивает одно TCP connection на независимые streams. Frames разных streams можно чередовать, поэтому готовый короткий response не обязан ждать медленный response, как при HTTP/1.1 pipelining. Это и есть multiplexing на уровне HTTP.

Независимость неполная. Все frames всё ещё лежат в одном упорядоченном TCP byte stream: потерянный TCP-сегмент задерживает доставку последующих байтов всех HTTP/2 streams до retransmission. Кроме того, streams делят connection-level flow-control window, HPACK state, congestion state и судьбу самого connection. Поэтому «один connection устраняет все очереди» — неверная модель.

## Область применимости

- Базовая версия — HTTP/2 по RFC 9113, июнь 2022 года; он заменил RFC 7540.
- Header compression рассматривается по HPACK RFC 7541, а современная схема priority signals — по RFC 9218.
- Семантика методов, status codes и полей остаётся общей для версий HTTP и раскрыта в [[20 Бэкенд/HTTP-методы, статус-коды, заголовки и семантика кэширования|заметке о семантике HTTP]].
- Вне scope: API конкретной HTTP-библиотеки, TLS handshake и детальная настройка connection pool.

## Ментальная модель

TCP connection — одна железная дорога с обязательным порядком вагонов. HTTP/2 stream — отдельная логическая партия груза, а frame — подписанный контейнер с `stream identifier`. Scheduler может чередовать контейнеры разных streams и собирать каждый response независимо, но повреждённый участок общей дороги останавливает доставку всех контейнеров за ним.

Полезно держать четыре уровня state:

1. **frame** — минимальная wire-единица с length, type, flags и stream ID;
2. **stream** — двунаправленная последовательность frames одного request/response;
3. **connection** — SETTINGS, общее flow control, HPACK context и TCP transport;
4. **HTTP message** — HEADERS и DATA, чья прикладная семантика не зависит от версии wire protocol.

Stream isolation работает только там, где состояние действительно per-stream. Любой исчерпанный connection-level ресурс снова связывает latency запросов.

## Как устроено

### Binary framing и streams

Каждый frame начинается с фиксированного 9-октетного header: payload length, type, flags и 31-bit stream identifier. Первый `HEADERS` открывает request stream и начинает field block; если block не помещается, его продолжают frames `CONTINUATION`. `DATA` переносит body, а флаг `END_STREAM` закрывает направление отправителя. Trailers начинаются финальным `HEADERS`; `Transfer-Encoding: chunked` в HTTP/2 не применяется.

Frames разных streams могут чередоваться:

```text
HEADERS(stream=1), HEADERS(stream=3), DATA(stream=3), DATA(stream=1)
```

Исключение — незавершённый field block: `HEADERS` без `END_HEADERS` должен сопровождаться только `CONTINUATION` того же stream до `END_HEADERS`. Frames других streams внутри этой последовательности запрещены.

При этом state machine каждого stream сохраняет собственный порядок и half-closed/closed states. Stream identifier внутри connection не переиспользуется. Peer сообщает верхнюю границу одновременно открытых streams через `SETTINGS_MAX_CONCURRENT_STREAMS`; это advertised maximum, а не обещание бесконечной capacity.

Так HTTP/2 устраняет требование HTTP/1.1 возвращать responses в порядке requests. Если stream 3 завершился раньше stream 1, его `HEADERS` и `DATA` можно отправить раньше. Но server scheduler всё равно решает, кому выделить CPU, socket buffer и bandwidth; протокол разрешает multiplexing, а не гарантирует fairness.

### Flow control: два окна

HTTP/2 применяет credit-based flow control только к `DATA` frames. У отправителя есть:

- отдельное окно каждого stream;
- общее окно connection.

Оба окна изначально равны 65 535 октетам, хотя peer может изменить initial stream window через SETTINGS. Получатель увеличивает credit с помощью `WINDOW_UPDATE`. Отправитель может послать DATA только если хватает обоих окон.

Следствия различаются:

- исчерпано stream window — останавливается DATA этого stream;
- исчерпано connection window — останавливается DATA всех streams;
- control frames не расходуют flow-control credit, но endpoint должен продолжать читать connection и обрабатывать их, иначе не увидит `WINDOW_UPDATE`, `RST_STREAM` или `GOAWAY`.

Flow control защищает receiver memory, а не задаёт business concurrency и не заменяет backpressure приложения. Если приложение не читает response body, библиотека может не возвращать credit; достаточно одного большого потока, чтобы при неудачной политике исчерпать общее окно и задержать соседей.

### HPACK и общее compression state

HPACK кодирует header fields через static table, ограниченную dynamic table и необязательное Huffman coding. Повторяющееся имя или пара name/value может передаваться индексом вместо полного текста. Dynamic table начинается пустой и обновляется в порядке field blocks одного connection; её максимальный размер ограничивает `SETTINGS_HEADER_TABLE_SIZE`.

Экономия создаёт shared state: encoder и decoder должны видеть согласованную последовательность обновлений. Ошибка decompression context — connection error типа `COMPRESSION_ERROR`, поэтому может оборвать не один request, а все streams. Это отличается от обычной ошибки прикладного stream.

HPACK не следует путать с кэшированием HTTP. Он уменьшает wire representation полей внутри connection, но не меняет их смысл, freshness или cache key.

### Отмена, drain и граница повторной попытки

`RST_STREAM` немедленно завершает конкретный stream и освобождает связанные протокольные ресурсы. Он не откатывает уже выполненный side effect: отменённый клиентом `POST` мог успеть изменить состояние до прихода reset. [[10 Основы CS/Retry safety|Безопасность повтора]] определяется HTTP- и business-семантикой, а не фактом stream reset.

`GOAWAY` сообщает, что connection прекращает принимать новые streams, и указывает последний stream ID, который отправитель мог обработать. Клиент открывает replacement connection; streams с идентификаторами выше объявленной границы можно считать не обработанными данным peer, а streams до границы требуют знания результата или правил retry. Для graceful shutdown endpoint может сначала послать `GOAWAY` с максимально допустимым ID, дать in-flight работе завершиться, затем сузить границу.

Lifecycle общего connection дополняет [[20 Бэкенд/Пулы соединений и keep-alive|модель connection pool]]: одно HTTP/2 connection несёт много concurrent streams, но stream limit, draining и общий blast radius остаются конечными.

### Priority — сигнал, а не гарантия

Dependency tree и `PRIORITY` из RFC 7540 объявлены deprecated в RFC 9113. RFC 9218 определяет более простые extensible priorities: поле `Priority` и frame `PRIORITY_UPDATE` передают urgency `u=0..7`, где меньшее число означает более срочную работу, и incremental flag `i`.

Эти значения advisory. Сервер может учитывать их вместе со своей политикой, доступными ресурсами и защитой от starvation, а intermediary — преобразовать или не переслать сигнал. Нельзя выводить точный wire order только из значения urgency.

### TCP head-of-line blocking

HTTP/2 видит не TCP-сегменты, а строго упорядоченный byte stream. Если сегмент с ранними байтами потерян, ядро может уже получить более поздние сегменты, но не отдаст их HTTP/2 parser до восстановления пропуска. Parser не может перескочить к frame другого stream, потому что frame boundary тоже находится в недоставленных по порядку байтах.

HTTP/2 убирает application-layer ordering responses из HTTP/1.1, но сохраняет transport-layer head-of-line blocking TCP. Именно эту границу меняет QUIC в HTTP/3.

### Connection coalescing

Одно HTTP/2 TLS connection иногда можно использовать для нескольких origins. Совпадения IP недостаточно: сервер должен быть authoritative для нового origin, а certificate обязан пройти все проверки, которые прошёл бы при новом соединении к этому host. SNI-based routing или middlebox может всё же направить coalesced request не тому backend; `421 Misdirected Request` позволяет серверу это отклонить.

Coalescing сокращает handshakes и connections, но расширяет blast radius и усложняет attribution latency. Это оптимизация после корректной проверки identity, а не разрешение обходить её.

## Пример или трассировка

Клиент открывает два request streams в одном HTTP/2 connection:

```text
C -> S  HEADERS stream=1  :method=GET :path=/slow
C -> S  HEADERS stream=3  :method=GET :path=/fast
S -> C  HEADERS stream=3  :status=200
S -> C  DATA    stream=3  "fast" END_STREAM
S -> C  HEADERS stream=1  :status=200
S -> C  DATA    stream=1  "slow" END_STREAM
```

Наблюдаемый результат без потерь: `/fast` завершается раньше `/slow`; response order больше не привязан к request order.

Во втором прогоне scheduler помещает начало `HEADERS stream=1` в TCP-сегмент `N`, а следующие байты `DATA stream=3` — в сегмент `N+1`. Сегмент `N` теряется, `N+1` приходит. TCP сохраняет более поздние байты в receive buffer, но не отдаёт их HTTP/2 до retransmission `N`. Наблюдаемый результат: stream 3 временно блокируется из-за потери байтов stream 1, хотя HTTP/2 state streams независим. Это transport head-of-line blocking, а не требование порядка HTTP responses.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| RFC 7540, май 2015 → RFC 9113, июнь 2022 | Dependency-tree priorities и frame `PRIORITY` были основной схемой | Схема RFC 7540 deprecated; wire elements оставлены для совместимости | Нельзя проектировать scheduler с предположением, что все peers реализуют старое дерево одинаково | [RFC 9113, раздел 5.3](https://www.rfc-editor.org/rfc/rfc9113.html#section-5.3) |
| RFC 9218, июнь 2022 | Старый priority model плохо расширялся и часто реализовывался неодинаково | Добавлены extensible priority signals `Priority`/`PRIORITY_UPDATE`, urgency и incremental | Клиент может передать намерение проще, но server policy остаётся решающей | [RFC 9218](https://www.rfc-editor.org/rfc/rfc9218.html) |

## Trade-offs

| Выбор | Выигрыш | Цена и ближайшая альтернатива |
| --- | --- | --- |
| Один HTTP/2 connection вместо нескольких HTTP/1.1 connections | Меньше handshakes и sockets, multiplexing, header compression | Общий TCP HOL, flow-control window, HPACK state и connection failure; несколько connections уменьшают blast radius ценой ресурсов |
| Большие flow-control windows | Лучше throughput на больших bandwidth-delay product и меньше ожиданий `WINDOW_UPDATE` | Больше потенциально буферизованных данных и влияние медленного consumer |
| Малые окна | Строже memory bound и backpressure | Больше control traffic и риск недоиспользовать канал при большом RTT |
| Dynamic HPACK table | Хорошее сжатие повторяющихся headers | Shared mutable state, memory и connection-level failure при desynchronization; literal encoding проще, но крупнее |
| Coalescing origins | Меньше connections и TLS handshakes | Общая судьба unrelated traffic, сложнее routing; отдельные connections дают изоляцию |
| [[10 Основы CS/HTTP-3 и QUIC]] | Нет TCP HOL между независимыми streams, поддерживается migration | QUIC сложнее наблюдать и реализовывать, работает поверх UDP и имеет собственные shared congestion/flow limits |

## Типичные ошибки

### Считать multiplexing бесконечной параллельностью

Неверное предположение: одно connection примет любое число requests без очереди. Симптом: новые requests ждут, хотя TCP connection открыт. Причина: `SETTINGS_MAX_CONCURRENT_STREAMS`, application concurrency, connection window или server scheduler исчерпали capacity. Исправление: измерять stream wait и limits, ограничивать concurrency клиента и только затем решать, нужен ли дополнительный connection.

### Увеличивать только stream window

Неверное предположение: большое окно stream гарантирует его продвижение. Симптом: DATA всех streams остановлены. Причина: исчерпано общее connection window. Исправление: наблюдать оба уровня credit и обеспечивать чтение/`WINDOW_UPDATE` на уровне connection.

### Приравнивать `RST_STREAM` к отсутствию side effect

Неверное предположение: reset доказывает, что server ничего не сделал. Симптом: retry дублирует запись или платёж. Причина: транспортная отмена могла прийти после commit приложения. Исправление: повторять только безопасную операцию либо использовать idempotency key и проверку результата.

### Игнорировать общий TCP HOL

Неверное предположение: разные stream IDs полностью изолируют latency. Симптом: одна packet loss коррелирует с паузой многих streams. Причина: TCP выдаёт единый ordered byte stream. Исправление: различать server queue, HTTP/2 flow-control stall и TCP retransmission; для критичного loss isolation рассмотреть HTTP/3.

### Закрывать connection вместо draining

Неверное предположение: deploy может немедленно оборвать HTTP/2 socket без дополнительного протокольного шага. Симптом: одновременно падают десятки in-flight requests и начинается retry storm. Причина: все streams разделяют connection. Исправление: послать `GOAWAY`, прекратить новые streams, дождаться разрешённой in-flight работы и ограничить retry budget с учётом [[20 Бэкенд/Дедлайны запросов и распространение отмены|оставшегося deadline]].

## Когда применять

HTTP/2 особенно полезен при множестве concurrent requests к одному origin, повторяющихся headers и заметной стоимости новых TCP/TLS connections. Он не гарантирует меньшую latency сам по себе: результат зависит от loss, scheduler, flow-control windows, размера ответов и server capacity.

При диагностике полезно последовательно спросить: свободен ли stream slot, хватает ли stream и connection credit, читает ли consumer, не пришёл ли `GOAWAY`/`RST_STREAM`, есть ли TCP retransmission. Эта последовательность отделяет логическую очередь HTTP/2 от transport stall и от перегрузки приложения.

## Источники

- [RFC 9113: HTTP/2](https://www.rfc-editor.org/rfc/rfc9113.html) — IETF, RFC 9113, июнь 2022, проверено 2026-07-18.
- [RFC 7541: HPACK — Header Compression for HTTP/2](https://www.rfc-editor.org/rfc/rfc7541.html) — IETF, RFC 7541, май 2015, проверено 2026-07-18.
- [RFC 9218: Extensible Prioritization Scheme for HTTP](https://www.rfc-editor.org/rfc/rfc9218.html) — IETF, RFC 9218, июнь 2022, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, STD 97 / RFC 9110, июнь 2022, проверено 2026-07-18.
