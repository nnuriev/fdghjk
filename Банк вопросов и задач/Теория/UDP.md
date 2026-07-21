---
aliases:
  - "Теоретический вопрос: UDP"
tags:
  - область/основы-cs
  - тема/сети
  - протокол/udp
  - тип/вопрос
статус: проверено
---

# UDP

## Вопрос

Объясните тему «UDP»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

UDP передаёт независимые datagrams между ports. Один успешный receive возвращает не более одной datagram и сохраняет её boundary; слишком маленький buffer обрезает datagram, а остаток нельзя дочитать следующим вызовом. Сам UDP не гарантирует delivery, ordering, duplicate suppression, retransmission, flow control или congestion control.

`connect()` на UDP socket не выполняет handshake и не создаёт transport connection. Он назначает default peer, фильтрует входящие datagrams по peer address/port и упрощает сопоставление некоторых asynchronous errors. Peer по-прежнему ничего не узнаёт до отправки первой datagram.

Приложение обязано явно решить, что делать с loss, duplicates, reordering, overload, Path MTU (PMTU), authentication и повтором операции. Если эти решения нужны «как в TCP», готовый transport protocol обычно безопаснее самодельного набора timers и ACK.

Полный разбор: [[10 Основы CS/UDP|UDP]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «TCP/UDP, путь запроса, DNS, TLS и HTTP: Модель TCP-IP и путь пакета, TCP - handshake, надёжность и управление перегрузкой, UDP, DNS resolution и caching, TLS handshake и проверка сертификатов, HTTP-1.1.» — [[Авито/roadmap#Сети, ОС и инфраструктура|Авито/roadmap, раздел «Сети, ОС и инфраструктура»]].

- [[CurseHunter/6817/Бланк вопросов и заданий#4. Можно ли нескольким goroutines одновременно вызывать `PacketConn.ReadFrom`?|4. Можно ли нескольким goroutines одновременно вызывать `PacketConn.ReadFrom`?]] — точная формулировка вопроса курса 6817 из «Урок 14. Q&A после урока 6».

## Источники

- [RFC 768: User Datagram Protocol](https://www.rfc-editor.org/rfc/rfc768.html) — IETF, STD 6 / RFC 768, август 1980, проверено 2026-07-18.
- [RFC 1122: Requirements for Internet Hosts — Communication Layers](https://www.rfc-editor.org/rfc/rfc1122.html) — IETF, STD 3 / RFC 1122, октябрь 1989, проверено 2026-07-18.
- [RFC 8085: UDP Usage Guidelines](https://www.rfc-editor.org/rfc/rfc8085.html) — IETF, BCP 145 / RFC 8085, март 2017, проверено 2026-07-18.
- [RFC 8899: Packetization Layer Path MTU Discovery for Datagram Transports](https://www.rfc-editor.org/rfc/rfc8899.html) — IETF, RFC 8899, сентябрь 2020, проверено 2026-07-18.
- [RFC 8200: Internet Protocol, Version 6 (IPv6) Specification](https://www.rfc-editor.org/rfc/rfc8200.html) — IETF, Internet Standard / RFC 8200, июль 2017, проверено 2026-07-18.
- [RFC 6936: Applicability Statement for the Use of IPv6 UDP Datagrams with Zero Checksums](https://www.rfc-editor.org/rfc/rfc6936.html) — IETF, RFC 6936, апрель 2013, проверено 2026-07-18.
- [udp(7)](https://git.kernel.org/pub/scm/docs/man-pages/man-pages.git/tree/man/man7/udp.7?h=man-pages-6.18) — Linux man-pages, tag `man-pages-6.18`, апрель 2026, проверено 2026-07-18.
- [connect(2)](https://git.kernel.org/pub/scm/docs/man-pages/man-pages.git/tree/man/man2/connect.2?h=man-pages-6.18) — Linux man-pages, tag `man-pages-6.18`, апрель 2026, проверено 2026-07-18.
