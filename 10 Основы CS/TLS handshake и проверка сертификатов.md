---
aliases:
  - TLS 1.3
  - TLS handshake
  - mTLS
  - Mutual TLS
  - Certificate validation
  - PKIX validation
tags:
  - область/основы-cs
  - тема/сети
  - тема/безопасность
  - механизм/tls
статус: проверено
---

# TLS handshake и проверка сертификатов

## TL;DR

TLS 1.3 handshake решает две разные задачи: согласует ключи защищённого канала и аутентифицирует peer. В обычном HTTPS server доказывает владение private key сертификата, а client отдельно строит PKIX certification path до локального trust anchor и проверяет, что certificate разрешён именно для исходного service identity. Успешная криптографическая подпись без проверки имени подтверждает неизвестный ключ, а не нужный host.

TLS даёт confidentiality, integrity и peer authentication в рамках выбранного credential. Он не выполняет application authorization и не гарантирует exactly-once. mTLS certificate может доказать identity клиента, но решение «этому identity разрешена операция» остаётся за приложением.

По состоянию на 2026-07-18 действующая спецификация TLS 1.3 — RFC 9846, опубликованный в июле 2026 года и заменивший RFC 8446. Это обратно совместимое уточнение той же версии TLS 1.3, а не новый wire protocol.

## Область применимости

- Основной сценарий — TLS 1.3 с X.509 server certificate и DNS service identity.
- TLS handshake описан по RFC 9846; исходная редакция RFC 8446 нужна только для версионной границы.
- Certification path validation опирается на PKIX profile RFC 5280, а сопоставление service identity — на RFC 9525, который заменил RFC 6125.
- Вне scope: устройство конкретного public CA, Certificate Transparency, детальный OCSP protocol, cipher implementation и TLS 1.2 handshake.

## Ментальная модель

Handshake можно представить как четыре последовательно проверяемых утверждения:

1. **Совместимость:** стороны выбрали общую версию, algorithms и application protocol.
2. **Свежие ключи:** key exchange создал общий secret для этого connection.
3. **Identity:** certificate path связывает public key с допустимым service identity, а `CertificateVerify` доказывает владение соответствующим private key.
4. **Целостность negotiation:** `Finished` подтверждает transcript и derived keys, поэтому attacker не может незаметно заменить параметры.

Каждый слой нужен отдельно. Сертификат с корректной цепочкой, но чужим DNS-ID, аутентифицирует другой service. Совпавшее имя в просроченном или недоверенном certificate не создаёт trust. Зашифрованный канал без проверенного identity защищает от пассивного наблюдателя, но не от active MITM, который установит два разных канала.

## Как устроено

### Full TLS 1.3 handshake

В типичном новом соединении без PSK и `HelloRetryRequest` поток выглядит так:

```text
Client                                                Server
ClientHello
  supported_versions, cipher suites
  key_share, signature_algorithms
  SNI, ALPN                    ---------------------->
                                      ServerHello, key_share
                                     {EncryptedExtensions}
                                     {Certificate}
                                     {CertificateVerify}
                                     {Finished}
                               <-----------------------
{Finished}                     ---------------------->
[Application Data]             <--------------------->
```

`ClientHello` предлагает версии, symmetric cipher/hash pairs, key shares, signature algorithms и extensions. `ServerHello` выбирает параметры key exchange. После `ServerHello` последующие handshake messages защищены handshake traffic keys; фигурные скобки в trace показывают именно это.

`EncryptedExtensions` несёт выбранные параметры, не требующие отдельного доказательства key ownership. В TLS 1.3 server сообщает выбранный ALPN здесь. `Certificate` передаёт certificate chain, `CertificateVerify` подписывает контекст и transcript handshake, доказывая владение private key leaf certificate. `Finished` — MAC от transcript с derived finished key; он подтверждает, что peer вывел те же keys и видел те же handshake messages.

Server может запросить client certificate сообщением `CertificateRequest`. Если у client есть подходящий credential, он до своего `Finished` посылает `Certificate` и `CertificateVerify`; иначе TLS 1.3 требует пустое `Certificate` без `CertificateVerify`, а server решает, продолжать ли handshake. При успешном mutual TLS, или mTLS, обе стороны криптографически аутентифицируют credentials, но каждая всё равно применяет собственную trust и authorization policy.

### Что именно проверяет certificate path

Server обычно отправляет leaf certificate и необходимые intermediate CA certificates, но корневой certificate обычно не нужен: trust anchor уже находится в локальном trust store или задан конфигурацией. Client может построить path не буквально в порядке присланного списка; важен валидный путь от leaf через issuer certificates до подходящего trust anchor. Trust anchor — вход локальной политики и формально не является certificate внутри проверяемого path.

PKIX validation включает как минимум связанные проверки:

- подпись каждого certificate проверяется public key его issuer;
- текущее время попадает в интервал от `notBefore` до `notAfter` включительно;
- intermediate certificates разрешены быть CA через `basicConstraints`, соблюдаются `pathLenConstraint` и `nameConstraints`;
- `keyUsage`, extended key usage и application policy допускают server authentication;
- неизвестные critical extensions не игнорируются;
- path заканчивается trust anchor, которому доверяет именно этот client.

Revocation — отдельная часть deployment policy поверх path construction: CRL или OCSP status должны быть достаточно свежими и доступными, а client должен заранее решить, является ли отсутствие статуса hard failure. Недоступный revocation service не превращает certificate автоматически ни в отозванный, ни в гарантированно действующий. Нельзя описывать поведение всех клиентов одним универсальным «fail open» или «fail closed».

### Service identity: SAN, а не CN

После построения допустимого path client сопоставляет certificate с **reference identity** — именем сервиса из исходного URI, явной конфигурации или другого доверенного источника. DNS lookup, CNAME или адрес выбранного backend не должны незаметно подменять это имя: маршрутизация отвечает на вопрос «куда подключиться», а identity verification — «к кому требовалось подключиться».

RFC 9525 требует искать DNS identity в `subjectAltName` типа `dNSName` (DNS-ID), а IP literal — в `iPAddress` (IP-ID). Поле Common Name (`CN`) не используется как fallback. Если application protocol поддерживает wildcard certificates, `*` может целиком занимать только крайнюю левую label: `*.example.com` сопоставляется с `api.example.com`, но не с `a.b.example.com` и не с частичной label вроде `api-*.example.com`.

Проверка имени идёт **после и вместе с** path validation. Certificate от публично доверенного CA для `other.example` не подходит `api.example`, а self-signed certificate с правильным SAN не подходит без явно настроенного trust anchor.

### SNI и ALPN не заменяют validation

Server Name Indication (SNI) в `ClientHello` сообщает DNS name, чтобы server или TLS-terminating proxy выбрал virtual host и подходящий certificate. Literal IPv4/IPv6 не является допустимым `HostName` SNI. Сам факт выбора certificate по SNI ничего не доказывает: client всё равно проверяет path и SAN.

Application-Layer Protocol Negotiation (ALPN) позволяет client предложить, например, `h2` и `http/1.1`, а server выбрать один protocol без дополнительного round trip. В TLS 1.3 выбор приходит в `EncryptedExtensions`. ALPN предотвращает неоднозначность протокола поверх готового TLS channel, но не выдаёт business permissions и не заменяет service identity.

### Resumption, PSK и 0-RTT

После полного handshake server может послать post-handshake `NewSessionTicket`. Из initial handshake выводится PSK, который client предлагает в следующем `ClientHello`. При принятом resumption server может не отправлять `Certificate` и `CertificateVerify`: новый channel аутентифицируется через PSK, связанный с исходным handshake. Поэтому ticket cache должен быть привязан к правильному server identity и TLS context.

PSK с новым `(EC)DHE key_share` сохраняет forward secrecy application data нового соединения; PSK-only exchange её не даёт. Resumption не равно connection reuse: первое создаёт новый transport/TLS connection с сокращённым handshake, второе отправляет новый request по уже открытому channel. Практическая разница разобрана вместе с [[20 Бэкенд/Пулы соединений и keep-alive|стоимостью connection pooling]].

0-RTT — ещё одна, необязательная ступень: client шифрует early application data PSK и отправляет до `ServerHello`. Она не имеет гарантии forward secrecy и межсоединительной защиты от replay. Server может early data отвергнуть. Поэтому 0-RTT подходит только для операции, проходящей правила [[10 Основы CS/Retry safety|retry safety]], либо при наличии дополнительного application-level idempotency protocol.

### Где заканчивается TLS trust boundary

При L4 passthrough балансировщик пересылает TCP/QUIC transport, а certificate предъявляет конечный TLS endpoint. При L7 TLS termination client аутентифицирует proxy; proxy расшифровывает request и создаёт отдельный upstream channel. Если upstream тоже должен быть защищён, ему нужны собственные TLS handshake, trust anchors и service identity checks. Один внешний certificate не делает участок proxy → backend автоматически доверенным. Граница связана с выбором из [[10 Основы CS/Балансировка сетевой нагрузки|L4 и L7 балансировки]].

DNS, TCP и TLS negotiation занимают разные фазы. Общий request timeout без фазовой диагностики скрывает, застрял ли dial, certificate validation или приложение. [[10 Основы CS/Тайм-ауты на сетевых уровнях|TLS phase timeout]] должен вписываться в [[20 Бэкенд/Дедлайны запросов и распространение отмены|end-to-end deadline]], а cancellation — закрывать или выводить из reuse незавершённый channel по правилам библиотеки.

## Пример или трассировка

Client открывает `https://api.example/data`. Его reference identity — `api.example`.

```text
1. ClientHello:
   SNI=api.example
   ALPN=[h2, http/1.1]
   supported_versions=[TLS 1.3]
   key_share=<fresh client share>

2. ServerHello + encrypted flight:
   key_share=<server share>
   EncryptedExtensions: ALPN=h2
   Certificate: leaf SAN=DNS:api.example + intermediate CA
   CertificateVerify: signature over handshake transcript
   Finished: MAC over transcript

3. Client validation:
   leaf -> intermediate -> local trust anchor
   signatures, time, constraints, EKU=serverAuth: OK
   reference DNS-ID api.example matches SAN: OK
   CertificateVerify and Finished: OK

4. Client sends Finished and then HTTP/2 application data.
```

Наблюдаемый результат: после одного TLS round trip поверх уже установленного transport client аутентифицировал server, обе стороны вывели traffic keys и согласовали `h2`. Если server пришлёт такую же корректную цепочку, но leaf SAN будет только `DNS:other.example`, cryptographic signatures останутся верными, однако identity check завершит handshake ошибкой. Это показывает, почему «certificate подписан CA» и «certificate подходит этому сервису» — разные проверки.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| RFC 8446, август 2018 → RFC 9846, июль 2026 | Исходная спецификация TLS 1.3 содержала неоднозначности и накопленные errata | RFC 9846 сохранил TLS 1.3 и backward compatibility, но запретил reuse KeyShare между connections, запретил negotiation TLS 1.0/1.1 и уточнил PSK, KeyUpdate, alerts и другие требования | Новые технические ссылки должны вести на RFC 9846; номер версии на wire и базовая модель handshake не изменились | [RFC 9846, раздел 1.2](https://www.rfc-editor.org/rfc/rfc9846.html#section-1.2) |
| RFC 6125, март 2011 → RFC 9525, ноябрь 2023 | Старый профиль допускал ограниченный fallback к Common Name в некоторых условиях | RFC 9525 требует identifiers из `subjectAltName` и запрещает использовать CN | Legacy certificate только с CN не проходит современную service identity verification; SAN нужно выпускать явно | [RFC 9525, раздел 4.1](https://www.rfc-editor.org/rfc/rfc9525.html#section-4.1) |

## Trade-offs

| Выбор | Выигрыш | Цена и ближайшая альтернатива |
| --- | --- | --- |
| Полный TLS 1.3 handshake | Свежая certificate authentication и ephemeral key exchange | Дополнительный round trip и asymmetric CPU; resumption быстрее, но зависит от сохранённого PSK context |
| PSK + asymmetric key exchange | Быстрее full certificate handshake и сохраняет forward secrecy новых application keys | Ticket state/lifetime и identity binding; полный handshake проще как независимая точка trust |
| 0-RTT | Early request в первом flight | Replay и weaker forward secrecy; 1-RTT resumption безопаснее для операций с эффектом |
| Public CA trust | Удобная совместимость с внешними clients | Широкий trust store и зависимость от issuance ecosystem; private CA сужает trust, но требует distribution и rotation |
| mTLS | Сильная двусторонняя credential authentication на transport boundary | Выдача, rotation, revocation и mapping identity → authorization сложнее; application token гибче для end-user delegation |
| TLS termination на L7 proxy | Routing по HTTP, централизованные certificates и observability | Proxy видит plaintext и становится trust boundary; passthrough сохраняет end-to-end TLS до backend, но теряет L7 control |

## Типичные ошибки

### Проверять цепочку, но не имя

Неверное предположение: любая цепочка до доверенного root подтверждает нужный host. Симптом: client принимает certificate другого домена или внутренний proxy может impersonate service. Причина: PKIX path подтверждает делегирование ключа, а reference identity проверяется отдельно. Исправление: сопоставлять исходное DNS-ID/IP-ID с SAN по RFC 9525 и никогда не отключать hostname verification как «временный» production fix.

### Использовать SNI как доказательство identity

Неверное предположение: раз server выбрал certificate по SNI, он уже аутентифицирован. Симптом: misconfigured virtual host возвращает чужой certificate, который код принимает. Причина: SNI — routing hint от самого client. Исправление: независимо проверить path, SAN, usage и transcript signatures.

### Считать шифрование авторизацией

Неверное предположение: успешный TLS или mTLS автоматически разрешает business operation. Симптом: любой certificate доверенного CA получает избыточный доступ. Причина: TLS доказывает credential identity, но не роль, tenant и permission. Исправление: после TLS явно сопоставить identity с application authorization policy и журналировать обе части решения.

### Отправлять root вместо нужного intermediate

Неверное предположение: полная chain означает leaf плюс root, а intermediate client найдёт сам. Симптом: handshake работает на одной машине с кэшированным intermediate и падает на чистом client. Причина: trust anchor уже локален, а недостающий intermediate не обязан автоматически загружаться. Исправление: server отправляет leaf и необходимые intermediates; root остаётся в trust store.

### Полагаться на CN fallback

Неверное предположение: `CN=api.example` достаточно, даже если SAN отсутствует. Симптом: новый client отвергает certificate, хотя старый принимает. Причина: RFC 9525 не использует CN для service identity. Исправление: выпускать корректный `subjectAltName` и тестировать современную validation policy.

### Считать resumption тем же соединением

Неверное предположение: session ticket сохраняет socket, server process и выполненный request state. Симптом: retry после reconnect дублирует side effect или ожидает прежний affinity. Причина: resumption создаёт новое connection и лишь использует PSK от предыдущего TLS context. Исправление: отличать connection reuse, TLS resumption и application idempotency.

### Отключать validation из-за внутренних сертификатов

Неверное предположение: private network заменяет authentication. Симптом: любой узел или скомпрометированный proxy может выполнить MITM без ошибки client. Причина: encryption с непроверенным peer не фиксирует, кому принадлежат keys. Исправление: распространить минимальный private trust anchor, проверять точное service identity и автоматизировать rotation, а не включать insecure skip-verify.

## Когда применять

TLS нужен, когда network attacker не должен читать или незаметно менять traffic и peer identity имеет значение. Для публичного HTTPS обычно используют server certificate authentication; mTLS уместен для controlled service-to-service среды, где организация управляет client credentials и их lifecycle. Он не заменяет user-level authorization.

При расследовании handshake failure проверяйте по порядку: version/algorithm overlap, SNI и выбранный virtual host, наличие intermediates, local trust anchor, validity time, constraints/EKU, SAN match, `CertificateVerify`/`Finished`, ALPN. Такой порядок отделяет routing problem от PKIX, identity mismatch и cryptographic failure.

## Источники

- [RFC 9846: The Transport Layer Security (TLS) Protocol Version 1.3](https://www.rfc-editor.org/rfc/rfc9846.html) — IETF, RFC 9846 / TLS 1.3, июль 2026, проверено 2026-07-18.
- [RFC 8446: The Transport Layer Security (TLS) Protocol Version 1.3](https://www.rfc-editor.org/rfc/rfc8446.html) — IETF, RFC 8446 / исходная редакция TLS 1.3, август 2018, заменён RFC 9846, проверено 2026-07-18.
- [RFC 5280: Internet X.509 Public Key Infrastructure Certificate and CRL Profile](https://www.rfc-editor.org/rfc/rfc5280.html) — IETF, RFC 5280, май 2008, проверено 2026-07-18.
- [RFC 9525: Service Identity in TLS](https://www.rfc-editor.org/rfc/rfc9525.html) — IETF, RFC 9525, ноябрь 2023, проверено 2026-07-18.
- [RFC 6066: TLS Extensions — Extension Definitions](https://www.rfc-editor.org/rfc/rfc6066.html) — IETF, RFC 6066, январь 2011, проверено 2026-07-18.
- [RFC 7301: TLS Application-Layer Protocol Negotiation Extension](https://www.rfc-editor.org/rfc/rfc7301.html) — IETF, RFC 7301, июль 2014, проверено 2026-07-18.
