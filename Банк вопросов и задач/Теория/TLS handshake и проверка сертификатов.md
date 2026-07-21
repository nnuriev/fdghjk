---
aliases:
  - "Теоретический вопрос: TLS handshake и проверка сертификатов"
tags:
  - область/основы-cs
  - тема/сети
  - тема/безопасность
  - механизм/tls
  - тип/вопрос
статус: проверено
---

# TLS handshake и проверка сертификатов

## Вопрос

Объясните тему «TLS handshake и проверка сертификатов»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

TLS 1.3 handshake решает две разные задачи: согласует ключи защищённого канала и аутентифицирует peer. В обычном HTTPS server доказывает владение private key сертификата, а client отдельно строит PKIX certification path до локального trust anchor и проверяет, что certificate разрешён именно для исходного service identity. Успешная криптографическая подпись без проверки имени подтверждает неизвестный ключ, а не нужный host.

TLS даёт confidentiality, integrity и peer authentication в рамках выбранного credential. Он не выполняет application authorization и не гарантирует exactly-once. mTLS certificate может доказать identity клиента, но решение «этому identity разрешена операция» остаётся за приложением.

По состоянию на 2026-07-18 действующая спецификация TLS 1.3 — RFC 9846, опубликованный в июле 2026 года и заменивший RFC 8446. Это обратно совместимое уточнение той же версии TLS 1.3, а не новый wire protocol.

Полный разбор: [[10 Основы CS/TLS handshake и проверка сертификатов|TLS handshake и проверка сертификатов]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «Вопросы про process state, signals, DNS и TLS пересекаются с процессами, signals, DNS resolution и TLS handshake. Здесь интервью не предлагает принципиально новых задач, но делает акцент на диагностике через наблюдаемые признаки.» — [[Telegram Собесы/FLANT — 2026-06-30 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/FLANT — 2026-06-30 — 400к, раздел «Сопоставление с материалами vault»]].
- «TCP/UDP, путь запроса, DNS, TLS и HTTP: Модель TCP-IP и путь пакета, TCP - handshake, надёжность и управление перегрузкой, UDP, DNS resolution и caching, TLS handshake и проверка сертификатов, HTTP-1.1.» — [[Авито/roadmap#Сети, ОС и инфраструктура|Авито/roadmap, раздел «Сети, ОС и инфраструктура»]].

- [[Telegram Собесы/FLANT — 2026-06-30 — 400к/Бланк вопросов и заданий#Сети: DNS, MAC и TLS — `00:31:37–00:36:40`|Сети: DNS, MAC и TLS — `00:31:37–00:36:40`]] — точная проверенная формулировка соответствующего технического блока интервью.

## Источники

- [RFC 9846: The Transport Layer Security (TLS) Protocol Version 1.3](https://www.rfc-editor.org/rfc/rfc9846.html) — IETF, RFC 9846 / TLS 1.3, июль 2026, проверено 2026-07-18.
- [RFC 8446: The Transport Layer Security (TLS) Protocol Version 1.3](https://www.rfc-editor.org/rfc/rfc8446.html) — IETF, RFC 8446 / исходная редакция TLS 1.3, август 2018, заменён RFC 9846, проверено 2026-07-18.
- [RFC 5280: Internet X.509 Public Key Infrastructure Certificate and CRL Profile](https://www.rfc-editor.org/rfc/rfc5280.html) — IETF, RFC 5280, май 2008, проверено 2026-07-18.
- [RFC 9525: Service Identity in TLS](https://www.rfc-editor.org/rfc/rfc9525.html) — IETF, RFC 9525, ноябрь 2023, проверено 2026-07-18.
- [RFC 6066: TLS Extensions — Extension Definitions](https://www.rfc-editor.org/rfc/rfc6066.html) — IETF, RFC 6066, январь 2011, проверено 2026-07-18.
- [RFC 7301: TLS Application-Layer Protocol Negotiation Extension](https://www.rfc-editor.org/rfc/rfc7301.html) — IETF, RFC 7301, июль 2014, проверено 2026-07-18.
