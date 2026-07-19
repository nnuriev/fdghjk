---
aliases:
  - Connection pooling
  - HTTP keep-alive
tags:
  - область/бэкенд
  - тема/http
  - тема/производительность
статус: проверено
---

# Пулы соединений и keep-alive

## TL;DR

Connection pool повторно использует уже установленные соединения и при явной настройке ограничивает число создаваемых и активных transport resources. Это убирает лишние DNS, TCP и TLS handshakes, но добавляет очередь за соединением, idle lifecycle и риск держать связь с уже нежелательным backend. Сам факт наличия пула не задаёт bound: например, в Go `MaxConnsPerHost=0` означает отсутствие предела.

В HTTP/1.1 persistent connection обычно обслуживает один активный обмен за раз, поэтому concurrency требует несколько соединений. HTTP/2 мультиплексирует streams поверх одного соединения, но не отменяет лимиты streams, flow control и общую судьбу TCP connection. HTTP keep-alive при этом не следует путать с TCP keepalive probes: первое означает повторное использование HTTP-соединения, второе обнаруживает мёртвого peer на транспортном уровне.

## Область применимости

- Семантика HTTP/1.1 соответствует RFC 9112, HTTP/2 — RFC 9113; оба стандарта опубликованы в июне 2022 года.
- Пример реализации привязан к `net/http` и `net` из Go 1.26.5 и дополняет [[60 Go/HTTP-клиент и Transport|заметку о Go Transport]].
- Модель относится к клиентским пулам HTTP и, по аналогии, к пулам соединений с БД. У `database/sql` своя семантика, описанная в [[60 Go/Пакет database-sql и пулы соединений|отдельной заметке]].
- Вне scope: HTTP/3 поверх QUIC, TLS session resumption, connection coalescing между origins и настройки конкретного load balancer.

## Ментальная модель

Пул — это ограниченный набор дорогих транспортных каналов плюс очередь желающих ими воспользоваться. У каждого канала есть состояния: dialling, active, idle, draining и closed. Запрос считается быстрым не потому, что pool «включён», а когда он получил подходящее соединение без ожидания и это соединение действительно можно безопасно переиспользовать.

Два инварианта удерживают модель:

1. незавершённый протокольный обмен нельзя выдать следующему запросу как чистое соединение;
2. число соединений и streams должно быть ограничено относительно capacity клиента, сети и сервера, иначе pool превращается в генератор перегрузки.

## Как устроено

### Ключ пула и жизненный цикл

Клиент ищет idle connection, совместимое с target origin, proxy, transport protocol и TLS-параметрами. Если его нет и предел не достигнут, начинается dial. Иначе запрос ждёт освобождения capacity или истечения собственного deadline.

После ответа соединение возвращается в idle set только когда протокол знает границу сообщения и обе стороны сохранили его пригодным. RFC 9112 требует для HTTP/1.1 полностью прочитать сообщения, если соединение собираются использовать дальше. В Go caller должен прочитать `Response.Body` до EOF и закрыть его; иначе `Transport` может не переиспользовать HTTP/1.x connection.

Idle connection не бесплатна: она занимает file descriptor, память, NAT и load-balancer state. `MaxIdleConns`, `MaxIdleConnsPerHost` и `IdleConnTimeout` ограничивают этот хвост. `MaxConnsPerHost` ограничивает dialling, active и idle connections вместе; когда предел достигнут, новые dials блокируются.

### HTTP/1.1 и HTTP/2 по-разному связывают concurrency с соединениями

HTTP/1.1 по умолчанию использует persistent connections. Pipelining стандарт допускает, но ответы обязаны идти в порядке запросов, поэтому медленный ответ создаёт application-layer head-of-line blocking. Практические клиенты обычно достигают параллелизма несколькими соединениями.

HTTP/2 создаёт несколько независимых streams внутри одного connection. Это снижает число handshakes и устраняет порядок ответов HTTP/1.1, но capacity всё равно конечна:

- peer ограничивает concurrent streams;
- DATA подчиняются stream-level и connection-level flow-control windows;
- потеря или закрытие общего TCP connection затрагивает все его streams;
- один крупный или плохо читаемый поток способен исчерпать общее окно и ухудшить остальные.

Потому «одно HTTP/2-соединение на origin» не универсальный оптимум. Реализация может открыть дополнительные connections при stream limit или держать строгий общий предел и ставить новые запросы в очередь. Это выбор между handshake cost, fairness и blast radius.

### HTTP keep-alive и TCP keepalive

HTTP keep-alive, или persistence, позволяет передать следующий HTTP request по существующему соединению. В HTTP/1.1 это поведение по умолчанию; `Connection: keep-alive` не нужно посылать как обязательный сигнал.

TCP keepalive отправляет probes после периода бездействия, чтобы обнаружить peer, который исчез без корректного FIN/RST. Он не создаёт HTTP-pooling, не ограничивает idle lifetime приложения и обычно срабатывает гораздо позже request deadline. В Go `Transport.DisableKeepAlives` относится к HTTP reuse и прямо не связан с одноимённым механизмом TCP.

### Bounds, deadline и stale connections

Предел активных соединений выполняет роль bulkhead для одного origin. Малый предел защищает downstream, но увеличивает pool wait; большой уменьшает очередь до тех пор, пока сервер или сеть не насыщаются. Поэтому вместе с request latency измеряют:

- долю reuse и число новых dials;
- pool wait и timeout в очереди;
- active/idle connections и streams;
- TLS handshake latency;
- закрытия idle/stale connections и ошибки первого запроса после reuse.

Долгоживущие connections закрепляют клиента за адресом, выбранным ранее. После DNS или load-balancer изменений новый backend не получит трафик, пока старые connections не закроются. Ограничение lifetime и управляемое draining решают эту задачу ценой дополнительных handshakes.

## Пример или трассировка

Клиент отправляет 200 одновременных запросов одному origin.

**HTTP/1.1, `MaxConnsPerHost=32`:** первые 32 запроса занимают connections, остальные 168 ждут. Если service time равен 100 ms, очередь проходит волнами. Увеличение предела до 200 уберёт pool wait, но создаст 200 TCP/TLS handshakes при холодном старте и столько же конкурентных запросов к серверу.

**HTTP/2, один connection и peer limit 100 streams:** первые 100 запросов открывают streams, остальные ждут stream capacity либо второго connection, в зависимости от политики клиента. Один TCP handshake обслуживает много вызовов, но закрытие connection одновременно прерывает до 100 запросов.

Один HTTP/1.1 handler возвращает ошибку, а клиент закрывает body, не дочитав её. Этот connection может не попасть в пригодный idle set; доля reuse падает, dials и TLS latency растут. Симптом выглядит как «сеть стала медленной», хотя причина находится в lifecycle response body.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| HTTP/1.0 | Соединение обычно закрывалось после одного ответа; persistence согласовывалась расширением `Keep-Alive` | HTTP/1.1 сделал persistent connection поведением по умолчанию | Reuse перестал требовать отдельного opt-in, но message framing стало обязательным для безопасной границы обменов | RFC 9112, приложение C.2.2 и раздел 9.3 |
| HTTP/1.1 → HTTP/2 | Concurrency требовала нескольких connections или pipelining с ordered responses | Несколько concurrent streams идут по одному connection | Меньше handshakes и application-layer HOL, но появились stream limits и connection-level flow control | RFC 9113, разделы 5 и 6 |

## Trade-offs

Большой idle pool уменьшает cold-start latency после паузы, но удерживает descriptors и старые маршруты. Малый быстрее обновляет topology и экономит ресурсы, зато вызывает handshake bursts.

Жёсткий `MaxConnsPerHost` ограничивает давление на сервер. Цена — локальная очередь, которая тоже должна иметь deadline и bounded size. Без метрики pool wait оператор ошибочно обвинит downstream latency.

HTTP/2 multiplexing эффективнее при множестве коротких запросов. Несколько HTTP/2 connections полезны при строгом stream limit, большом bandwidth-delay product или необходимости уменьшить общий blast radius, но повышают handshake и server state.

## Типичные ошибки

### Отдельный Transport создаётся на каждый запрос

- **Неверное предположение:** новый Client с новым Transport ничего не меняет в lifecycle соединений.
- **Симптом:** много TCP/TLS handshakes, TIME_WAIT и file descriptors.
- **Причина:** отдельный Transport создаёт отдельный connection pool. Несколько `http.Client` с `Transport=nil`, напротив, используют общий `http.DefaultTransport`.
- **Исправление:** переиспользовать Client/Transport; они рассчитаны на concurrent use.

### Response body не дочитывается и не закрывается

- **Неверное предположение:** после получения status code соединение уже свободно.
- **Симптом:** reuse падает, число dials растёт, pool быстро упирается в предел.
- **Причина:** HTTP/1.x transport не может надёжно найти начало следующего ответа.
- **Исправление:** закрывать body на всех путях; когда нужен reuse, читать его до EOF с разумным ограничением размера.

### HTTP keep-alive заменяют TCP keepalive

- **Неверное предположение:** probes гарантируют быстрый request timeout и reuse.
- **Симптом:** запрос долго висит на формально живом connection либо каждый запрос всё равно делает dial.
- **Причина:** смешаны разные уровни протокола.
- **Исправление:** отдельно настроить request deadlines, HTTP idle lifecycle и TCP failure detection.

### Pool считают бесконечной пропускной способностью

- **Неверное предположение:** больше connections всегда уменьшает latency.
- **Симптом:** downstream насыщается, растут ошибки и tail latency.
- **Причина:** клиент убрал собственную очередь, переложив неограниченную concurrency на сервер.
- **Исправление:** связать размеры pool и очереди с capacity, применять [[60 Go/Backpressure|backpressure]] и измерять goodput.

## Когда применять

Пул нужен почти любому многократно используемому сетевому клиенту. Настройку начинают с протокола и требуемой concurrency, затем подбирают active limit, idle reserve и lifetime по нагрузочному тесту.

Reuse особенно выгоден при TLS и коротких частых запросах. Для редких вызовов к множеству hosts агрессивный idle cache способен стоить больше, чем экономит; тогда важнее ограничить общий idle set и своевременно закрывать connections.

## Источники

- [RFC 9112: HTTP/1.1](https://datatracker.ietf.org/doc/html/rfc9112) — IETF, RFC 9112, июнь 2022, проверено 2026-07-18.
- [RFC 9113: HTTP/2](https://datatracker.ietf.org/doc/html/rfc9113) — IETF, RFC 9113, июнь 2022, проверено 2026-07-18.
- [Package net/http](https://pkg.go.dev/net/http@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-18.
- [Package net](https://pkg.go.dev/net@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-18.
