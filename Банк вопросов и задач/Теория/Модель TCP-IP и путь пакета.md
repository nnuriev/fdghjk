---
aliases:
  - "Теоретический вопрос: Модель TCP-IP и путь пакета"
tags:
  - область/основы-cs
  - тема/сети
  - механизм/инкапсуляция
  - тип/вопрос
статус: проверено
---

# Модель TCP-IP и путь пакета

## Вопрос

Объясните тему «Модель TCP-IP и путь пакета»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

Стек TCP/IP удобнее представлять четырьмя слоями: приложение, транспорт, Internet layer и link layer. Приложение передаёт данные через [[10 Основы CS/Сокеты|сокет]], транспорт добавляет end-to-end семантику, IP доставляет datagram между адресами через цепочку routers, а link layer переносит IP packet только до соседнего узла. При отправке headers добавляются снаружи, при приёме снимаются в обратном порядке.

IP packet обычно сохраняет source и destination IP на всём пути, но каждый router создаёт для следующего link новый frame с новыми link-layer addresses и уменьшает Time to Live (TTL) или Hop Limit. NAT, tunnels и proxies нарушают отдельные части этой упрощённой картины, поэтому при диагностике сначала фиксируют границу наблюдения и слой.

Успех на одном слое не подтверждает следующий: успешный `send()` говорит о принятии данных локальным kernel, ACK TCP — о приёме байтов peer TCP, а HTTP response — о результате application protocol. Эти границы нельзя склеивать в одну «сетевую операцию».

Полный разбор: [[10 Основы CS/Модель TCP-IP и путь пакета|Модель TCP-IP и путь пакета]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «TCP/UDP, путь запроса, DNS, TLS и HTTP: Модель TCP-IP и путь пакета, TCP - handshake, надёжность и управление перегрузкой, UDP, DNS resolution и caching, TLS handshake и проверка сертификатов, HTTP-1.1.» — [[Авито/roadmap#Сети, ОС и инфраструктура|Авито/roadmap, раздел «Сети, ОС и инфраструктура»]].

- [[Telegram Собесы/FLANT — 2026-06-30 — 400к/Бланк вопросов и заданий#Сети|Сети]] — точная проверенная формулировка соответствующего технического блока интервью.

## Источники

- [RFC 1122: Requirements for Internet Hosts — Communication Layers](https://www.rfc-editor.org/rfc/rfc1122.html) — IETF, STD 3 / RFC 1122, октябрь 1989, проверено 2026-07-18.
- [RFC 1812: Requirements for IP Version 4 Routers](https://www.rfc-editor.org/rfc/rfc1812.html) — IETF, RFC 1812, июнь 1995, проверено 2026-07-18.
- [RFC 8200: Internet Protocol, Version 6 (IPv6) Specification](https://www.rfc-editor.org/rfc/rfc8200.html) — IETF, Internet Standard / RFC 8200, июль 2017, проверено 2026-07-18.
- [RFC 826: An Ethernet Address Resolution Protocol](https://www.rfc-editor.org/rfc/rfc826.html) — IETF, STD 37 / RFC 826, ноябрь 1982, проверено 2026-07-18.
- [RFC 4861: Neighbor Discovery for IP version 6](https://www.rfc-editor.org/rfc/rfc4861.html) — IETF, RFC 4861, сентябрь 2007, проверено 2026-07-18.
- [RFC 768: User Datagram Protocol](https://www.rfc-editor.org/rfc/rfc768.html) — IETF, STD 6 / RFC 768, август 1980, проверено 2026-07-18.
- [RFC 6936: Applicability Statement for the Use of IPv6 UDP Datagrams with Zero Checksums](https://www.rfc-editor.org/rfc/rfc6936.html) — IETF, RFC 6936, апрель 2013, проверено 2026-07-18.
- [Segmentation Offloads](https://github.com/torvalds/linux/blob/v7.1/Documentation/networking/segmentation-offloads.rst) — Linux kernel, tag `v7.1`, файл `Documentation/networking/segmentation-offloads.rst`, проверено 2026-07-18.
