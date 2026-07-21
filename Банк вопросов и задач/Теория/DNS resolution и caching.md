---
aliases:
  - "Теоретический вопрос: DNS resolution и caching"
tags:
  - область/основы-cs
  - тема/сети
  - механизм/dns
  - тип/вопрос
статус: проверено
---

# DNS resolution и caching

## Вопрос

Объясните тему «DNS resolution и caching»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

DNS — распределённая делегированная база записей, а не один каталог `имя → IP`. Обычно приложение вызывает stub resolver, тот отправляет recursive query рекурсивному резолверу, а резолвер при cache miss сам проходит цепочку root → TLD → authoritative server с помощью iterative queries. Referral сообщает, где искать дальше; authoritative answer сообщает данные зоны.

Cache хранит не только положительные RRsets, но и отрицательные ответы и кратковременные failures. TTL задаёт срок повторного использования конкретного RRset, но не гарантирует мгновенное переключение трафика: кэш существует на нескольких уровнях, а уже открытые соединения переживают DNS-запись. DNS также не проверяет readiness или здоровье процесса — эту границу раскрывает [[40 Распределённые системы/Service discovery|service discovery]].

Полный разбор: [[10 Основы CS/DNS resolution и caching|DNS resolution и caching]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Вопросы про process state, signals, DNS и TLS пересекаются с процессами, signals, DNS resolution и TLS handshake. Здесь интервью не предлагает принципиально новых задач, но делает акцент на диагностике через наблюдаемые признаки.» — [[Telegram Собесы/FLANT — 2026-06-30 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/FLANT — 2026-06-30 — 400к, раздел «Сопоставление с материалами vault»]].
- «TCP/UDP, путь запроса, DNS, TLS и HTTP: Модель TCP-IP и путь пакета, TCP - handshake, надёжность и управление перегрузкой, UDP, DNS resolution и caching, TLS handshake и проверка сертификатов, HTTP-1.1.» — [[Авито/roadmap#Сети, ОС и инфраструктура|Авито/roadmap, раздел «Сети, ОС и инфраструктура»]].

- [[Telegram Собесы/FLANT — 2026-06-30 — 400к/Бланк вопросов и заданий#Сети: DNS, MAC и TLS — `00:31:37–00:36:40`|Сети: DNS, MAC и TLS — `00:31:37–00:36:40`]] — точная проверенная формулировка соответствующего технического блока интервью.
- [[Telegram Собесы/FLANT — 2026-06-30 — 400к/Бланк вопросов и заданий#Сети|Сети]] — точная проверенная формулировка соответствующего технического блока интервью.

## Источники

- [RFC 1034 — Domain Names: Concepts and Facilities](https://www.rfc-editor.org/rfc/rfc1034.html) — IETF, RFC 1034, ноябрь 1987, проверено 2026-07-18.
- [RFC 1035 — Domain Names: Implementation and Specification](https://www.rfc-editor.org/rfc/rfc1035.html) — IETF, RFC 1035, ноябрь 1987, проверено 2026-07-18.
- [RFC 2181 — Clarifications to the DNS Specification](https://www.rfc-editor.org/rfc/rfc2181.html) — IETF, RFC 2181, июль 1997, проверено 2026-07-18.
- [RFC 2308 — Negative Caching of DNS Queries](https://www.rfc-editor.org/rfc/rfc2308.html) — IETF, RFC 2308, март 1998, проверено 2026-07-18.
- [RFC 4033 — DNS Security Introduction and Requirements](https://www.rfc-editor.org/rfc/rfc4033.html) — IETF, RFC 4033, март 2005, проверено 2026-07-18.
- [RFC 5452 — Measures for Making DNS More Resilient against Forged Answers](https://www.rfc-editor.org/rfc/rfc5452.html) — IETF, RFC 5452, январь 2009, проверено 2026-07-18.
- [RFC 6891 — Extension Mechanisms for DNS (EDNS(0))](https://www.rfc-editor.org/rfc/rfc6891.html) — IETF, RFC 6891, апрель 2013, проверено 2026-07-18.
- [RFC 7766 — DNS Transport over TCP: Implementation Requirements](https://www.rfc-editor.org/rfc/rfc7766.html) — IETF, RFC 7766, март 2016, проверено 2026-07-18.
- [RFC 9499 — DNS Terminology](https://www.rfc-editor.org/rfc/rfc9499.html) — IETF, BCP 219 / RFC 9499, март 2024; заменяет RFC 8499, проверено 2026-07-18.
- [RFC 8767 — Serving Stale Data to Improve DNS Resiliency](https://www.rfc-editor.org/rfc/rfc8767.html) — IETF, RFC 8767, март 2020, проверено 2026-07-18.
- [RFC 9520 — Negative Caching of DNS Resolution Failures](https://www.rfc-editor.org/rfc/rfc9520.html) — IETF, RFC 9520, декабрь 2023, проверено 2026-07-18.
- [RFC 9715 — IP Fragmentation Avoidance in DNS over UDP](https://www.rfc-editor.org/rfc/rfc9715.html) — IETF, Informational RFC 9715, январь 2025, проверено 2026-07-18.
