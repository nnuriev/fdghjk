---
aliases:
  - Reverse proxy
  - HTTP gateway
  - Обратный прокси
tags:
  - область/основы-cs
  - тема/сети
  - тема/http
  - механизм/proxy
статус: проверено
---

# Reverse proxy

## TL;DR

Reverse proxy принимает HTTP-запрос так, будто он origin server, а затем сам выбирает upstream и выполняет отдельный обмен с ним. Поэтому это не прозрачная труба: downstream- и upstream-соединения имеют независимые TLS-сессии, версии HTTP, пулы, flow control и сроки жизни. Один downstream request может породить несколько upstream attempts, а одно upstream-соединение может обслуживать запросы из разных downstream-соединений.

Главный инвариант: proxy обязан сохранить HTTP-семантику через границу двух обменов. Он корректно определяет framing, удаляет hop-by-hop fields, не доверяет присланным клиентом forwarding headers, ограничивает buffering и передаёт отмену. TLS termination, retry или преобразование протокола расширяют полномочия proxy и одновременно его failure surface.

## Область применимости

Термины gateway и reverse proxy используются по RFC 9110 от июня 2022 года. Механика относится к HTTP reverse proxy; L4 forwarding и TLS passthrough сравниваются только как ближайшая альтернатива. Выбор endpoint и алгоритма распределения раскрыт в [[10 Основы CS/Балансировка сетевой нагрузки|заметке о L4/L7-балансировке]], API policy — в [[20 Бэкенд/API gateway|заметке об API gateway]], а межсервисная топология — в [[10 Основы CS/Proxy и service-to-service networking|заметке о service-to-service networking]].

## Ментальная модель

У reverse proxy две независимые protocol state machines, соединённые причинной связью:

```text
client
  -- downstream connection / request --> [ reverse proxy ]
  <-- downstream response ------------  [ route, policy, bounded buffers ]
                                         |
                                         +-- upstream attempt / connection --> backend
                                         <-- upstream response --------------+
```

Proxy завершает входящий обмен и начинает исходящий. Он может принять HTTP/2 от клиента, отправить HTTP/1.1 upstream, завершить клиентский TLS и открыть другой TLS-сеанс к backend. Равенства `downstream connection = upstream connection` нет. Связь существует на уровне request/stream и его attempts.

Отсюда следуют четыре инварианта:

1. Route и authority вычисляются из нормализованного request, а не из противоречивых заголовков.
2. Connection-specific state одной стороны не переносится как end-to-end metadata на другую.
3. Buffers, connections, streams, retries и время ограничены; иначе proxy становится отдельным источником перегрузки.
4. Сбой upstream transport не сообщает, выполнил ли backend бизнес-эффект.

## Как устроено

### Reverse proxy, forward proxy и tunnel

Forward proxy выбирает клиент или его сеть; посредник действует на пути к произвольным origins. Reverse proxy публикуется как адрес origin и скрывает от клиента внутренние servers. RFC 9110 называет его gateway: на внешней стороне к нему применимы требования origin server, а на внутренней стороне он выступает клиентом выбранного upstream.

Tunnel после установления просто пересылает байты, не интерпретируя последующие HTTP messages. Так работает, например, HTTPS через forward proxy после успешного `CONNECT`. HTTP reverse proxy, напротив, видит messages и способен route, логировать, фильтровать и преобразовывать их. L4 load balancer с TLS passthrough ближе к tunnel: он может распределить connection, но не может принять решение по path или status code.

### Route, endpoint и upstream pool

Сначала proxy сопоставляет authority, path, method и другие разрешённые признаки с route. Route указывает logical upstream cluster; discovery и health policy дают eligible endpoints; алгоритм балансировки выбирает один host. Затем proxy берёт подходящее соединение из [[20 Бэкенд/Пулы соединений и keep-alive|upstream pool]] или открывает новое.

Эти стадии нельзя склеивать в «proxy отправил на сервис». Ошибка route даёт локальный отказ до попытки соединения. Пустой healthy set, pool wait, DNS failure, connect timeout и upstream reset происходят на разных границах и требуют разных метрик. Один downstream request учитывается отдельно от числа upstream attempts.

Долгоживущий pool закрепляет трафик за старым endpoint даже после изменения DNS или discovery. При rollout proxy перестаёт назначать новые requests удаляемому host, но уже открытые streams нужно drain-ить по протоколу. Само обновление route table не закрывает существующие соединения.

### Сохранение HTTP-семантики

Proxy заново сериализует message для следующего hop. Он обязан удалить fields, перечисленные входящим `Connection`, и другие hop-by-hop fields. `Host` или `:authority` участвует в выборе target и не должен расходиться с route. Неизвестные end-to-end fields обычно пересылаются: иначе intermediary ломает расширяемость HTTP.

На HTTP/1.1 граница body определяется правилами `Content-Length`, `Transfer-Encoding` и status/method. Разные трактовки framing на соседних узлах открывают request smuggling: один parser считает хвост частью body, другой — следующим request. Поэтому неоднозначный request нужно отвергнуть, а не «починить» по-своему. Перевод между HTTP/1.1 и HTTP/2/3 также требует одной канонической интерпретации message.

Proxy способен менять content coding, кешировать или переписывать headers только в рамках HTTP-контракта. `Cache-Control: no-transform` запрещает content transformation. Любой фильтр, который переписывает method, authority, body или status, становится частью прикладной семантики и должен тестироваться как protocol participant.

### Forwarding metadata и граница доверия

После termination backend видит адрес proxy, а не исходного клиента. Стандартный `Forwarded` может передать `for`, `by`, `host` и `proto`; `X-Forwarded-*` остаются распространёнными, но не стандартизованными полями.

Значение, пришедшее из недоверенной сети, нельзя использовать для authentication, allowlist или rate limit. Клиент способен сам прислать `Forwarded: for=127.0.0.1`. Edge proxy должен удалить или отделить недоверенный prefix и добавить сведения о непосредственно наблюдаемом peer. Следующий hop доверяет только известной цепочке proxies и защищённому каналу до неё. Даже тогда элементы, существовавшие до первого доверенного proxy, не становятся доказанными.

Forwarding metadata раскрывает IP-адреса и внутреннюю топологию. Передавать нужно только поля, которые действительно нужны downstream. Ответ не должен случайно возвращать клиенту всю внутреннюю цепочку.

### TLS termination и повторное шифрование

При TLS termination клиент устанавливает защищённое соединение с proxy и проверяет сертификат proxy. После расшифрования посредник видит HTTP и может применить L7 policy. Upstream leg — отдельная граница: plaintext внутри доверенной сети или новый TLS handshake с собственной проверкой имени и trust roots. «Включить TLS» без проверки upstream identity означает шифровать данные неизвестному peer.

TLS passthrough сохраняет шифрование между клиентом и backend, но лишает proxy HTTP path, headers и response status. Выбор между termination и passthrough — выбор trust boundary, а не только производительности. Полный handshake и certificate validation разобраны в [[10 Основы CS/TLS handshake и проверка сертификатов|заметке о TLS]].

### Streaming, buffering и backpressure

Request или response body можно передавать по мере получения. Streaming уменьшает latency до первого байта и удерживаемую память. Если upstream читает медленнее клиента, proxy приостанавливает чтение downstream или уменьшает protocol window: давление должно вернуться к отправителю, а не накопиться в безразмерном buffer.

Некоторым фильтрам нужен полный body: проверка подписи целого payload, преобразование формата или policy по содержимому. Тогда proxy буферизует до явного лимита и отказывает до передачи upstream, если предел превышен. Буферизация позволяет дождаться полного request и делает body replayable, но не делает саму операцию идемпотентной. За это платят memory cost и latency, а большие uploads превращаются в удобный DoS-вектор.

После отправки downstream response headers новый status code уже не вставить. Если upstream оборвался посреди streaming response, proxy может завершить stream/reset connection и, где протокол позволяет, добавить trailer. Клиент получит неполный response, а не аккуратный новый `502` поверх уже начатого `200`.

### Deadline, отмена и retry

Proxy расходует остаток общего [[20 Бэкенд/Дедлайны запросов и распространение отмены|deadline]] на pool wait, connect, TLS и upstream response. Per-try timeout ограничивает одну попытку, но не заменяет общий срок. Disconnect клиента должен отменить ещё полезную только этому request работу; отмена остаётся кооперативной и не откатывает уже совершённый backend effect.

Retry создаёт новый upstream attempt. Разрыв до response headers ещё не доказывает, что backend не обработал request. Решение зависит от семантики операции, replayability body, точки отказа, оставшегося бюджета и [[10 Основы CS/Retry safety|retry contract]]. Для неидемпотентной команды безопасный повтор требует operation identity и дедупликации, а не одной настройки proxy.

### Ошибки и наблюдаемость

HTTP status не всегда говорит, кто создал response. `502` может сгенерировать proxy после protocol error или закрытия upstream; `504` — после connect/read timeout; `503` — при локальном лимите. RFC 9209 задаёт `Proxy-Status`, где intermediary способен указать стандартизованный error type, например `connection_terminated`. Поле полезно для диагностики, но способно раскрыть topology, поэтому его содержимое и аудитория ограничиваются.

Минимальная telemetry связывает downstream request ID с route, выбранным endpoint, pool wait, upstream protocol, числом attempts, per-attempt latency, bytes streamed, локальным response flag и причиной reset. Отдельно измеряются downstream latency и upstream service time: между ними находятся routing, queueing, TLS, filters и retries.

## Пример или трассировка

Клиент создаёт заказ через edge reverse proxy:

```http
:method: POST
:scheme: https
:authority: api.example.com
:path: /orders
forwarded: for=127.0.0.1
idempotency-key: 8b6f2d8a-8f95-4ac4-b51d-c5aa228f8111
content-type: application/json

{"sku":"A-7","count":1}
```

1. Клиентский TLS завершается на proxy; сертификат подтверждает `api.example.com`. Поддельный `forwarded` удаляется, proxy добавляет наблюдаемый client address и `proto=https`.
2. Route `api.example.com + /orders` указывает на cluster `orders`. Proxy выбирает healthy endpoint и открывает HTTP/2 stream в уже существующем upstream TLS connection.
3. Body передаётся с bounded buffering. Backend фиксирует заказ, но upstream connection закрывается до получения proxy полного response.
4. Поскольку downstream headers ещё не отправлены, proxy возвращает `502 Bad Gateway` и при разрешённой policy добавляет `Proxy-Status: edge.example; error=connection_terminated`. Автоматического retry POST нет.
5. Для клиента outcome неоднозначен: `502` описывает путь ответа, а не отсутствие заказа. Он повторяет ту же logical operation с прежним idempotency key; backend возвращает сохранённый результат без второго заказа.

Наблюдаемый результат: spoofed address не стал доверенным, HTTP/2 connections по обе стороны остались независимыми, а transport failure не превратился в ложное утверждение о business outcome.

## Trade-offs

Reverse proxy скрывает topology, централизует TLS, routing и наблюдаемость, а разнородным clients оставляет один стабильный origin. Цена — дополнительный hop, общая failure domain, queueing и перенос доверия к компоненту, который видит plaintext и способен менять messages. Client-side discovery убирает центральный data-plane hop, но размножает protocol policy по client libraries.

TLS termination даёт L7-routing и фильтрацию. Passthrough сохраняет end-to-end TLS до backend и сужает доступ proxy к данным, зато ограничивает решения transport metadata. Повторное TLS к upstream создаёт две аутентифицированные границы и требует управлять двумя наборами identities.

Streaming ограничивает память и быстрее передаёт первый байт. Full buffering позволяет inspect и иногда replay, но добавляет latency, disk/RAM pressure и предел размера. Практичный default — streaming с bounded buffers; полный body собирается только для конкретной policy.

Один общий proxy упрощает конфигурацию и аудит. Несколько уровней — CDN, ingress, service proxy — локализуют функции, но каждый уровень добавляет timeout, retry, headers и собственную интерпретацию ошибки. Без единого end-to-end бюджета и attempt telemetry цепочка становится непрозрачной.

## Типичные ошибки

### Доверять адресу из `X-Forwarded-For`

- **Неверное предположение:** наличие field доказывает исходный IP клиента.
- **Симптом:** обход allowlist или rate limit подстановкой внутреннего адреса.
- **Причина:** HTTP field может прислать сам клиент, а недоверенная часть proxy chain не аутентифицирована.
- **Исправление:** очищать входящие forwarding fields на trust boundary, добавлять наблюдаемого peer и разбирать цепочку только относительно известных proxies.

### Буферизовать body без предела

- **Неверное предположение:** proxy всегда может сначала прочитать request целиком.
- **Симптом:** memory/disk exhaustion и высокая latency на uploads.
- **Причина:** размер и скорость body контролирует клиент, а full buffering разрывает backpressure.
- **Исправление:** streaming по умолчанию, явные per-request и aggregate limits; фильтр с full body получает собственный небольшой предел.

### Повторять любой upstream reset

- **Неверное предположение:** отсутствие response означает отсутствие эффекта.
- **Симптом:** duplicate orders или платежи во время сетевой деградации.
- **Причина:** backend мог commit-нуть операцию до разрыва ответа.
- **Исправление:** retry gate по семантике и оставшемуся deadline; для команд — стабильный idempotency key и дедупликация.

### Шифровать upstream без проверки identity

- **Неверное предположение:** любой успешный TLS handshake доказывает нужный backend.
- **Симптом:** proxy устанавливает защищённый канал с ошибочно выбранным или подменённым server.
- **Причина:** certificate/hostname validation отключена либо trust roots слишком широки.
- **Исправление:** проверять ожидаемую service identity и цепочку доверия на каждом отдельном TLS leg.

### Терпимо разбирать неоднозначный HTTP/1.1

- **Неверное предположение:** proxy и backend одинаково «догадаются» о границе body.
- **Симптом:** request smuggling, cache poisoning или попадание скрытого request мимо policy.
- **Причина:** два parser по-разному выбирают между `Transfer-Encoding`, `Content-Length` и malformed syntax.
- **Исправление:** одна строгая framing policy, отклонение неоднозначных messages и одинаковые conformance tests всей цепочки.

## Когда применять

Reverse proxy нужен перед группой HTTP-services, когда clients не должны знать topology, требуется единая TLS/routing boundary, protocol translation, bounded upstream pools или общая observability. До внедрения зафиксируйте trust boundary, правила authority и forwarding headers, limits, streaming policy, общий deadline, retry contract, draining и способ отличить proxy-generated response от upstream response.

Если нужно только переслать зашифрованный connection без анализа HTTP, L4 balancing или TLS passthrough проще и сужает полномочия посредника. Если задача — выполнять user-facing API policy, поверх reverse-proxy mechanism нужен явно описанный API gateway contract; название продукта само по себе такого контракта не создаёт.

## Источники

- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, STD 97, июнь 2022, проверено 2026-07-18.
- [RFC 9112: HTTP/1.1](https://www.rfc-editor.org/rfc/rfc9112.html) — IETF, Standards Track, июнь 2022, проверено 2026-07-18.
- [RFC 7239: Forwarded HTTP Extension](https://www.rfc-editor.org/rfc/rfc7239.html) — IETF, Standards Track, июнь 2014, проверено 2026-07-18.
- [RFC 9209: The Proxy-Status HTTP Response Header Field](https://www.rfc-editor.org/rfc/rfc9209.html) — IETF, Standards Track, июнь 2022, проверено 2026-07-18.
- [HTTP connection management](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/http/http_connection_management.html) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Connection pooling](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/upstream/connection_pooling.html) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [How do I configure flow control?](https://www.envoyproxy.io/docs/envoy/v1.38.3/faq/configuration/flow_control.html) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
