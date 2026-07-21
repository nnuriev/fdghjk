---
aliases:
  - "Теоретический вопрос: Replay attacks"
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/криптография
  - тип/вопрос
статус: проверено
---

# Replay attacks

## Вопрос

Как работает «Replay attacks» и какие ограничения, failure modes и trade-offs нужно учитывать в backend-системе?

## Короткий ориентир

Replay attack повторно предъявляет уже валидное сообщение, credential или подтверждение операции. Подпись, MAC и TLS доказывают целостность и происхождение в своей области, но сами по себе не доказывают **свежесть** и **однократность**. Сервер способен дважды проверить одну и ту же корректную подпись и дважды выполнить эффект.

Защита связывает authenticator с principal, purpose, method, target, body и ограниченным временем, а затем атомарно потребляет уникальный `nonce`/`jti`/sequence number. Для retryable business operation отдельно нужен idempotency key: точный повтор операции возвращает прежний результат, а не создаёт второй эффект. Anti-replay и idempotency решают соседние, но разные задачи.

TLS 1.3 0-RTT требует особой осторожности: действующая спецификация RFC 9846 прямо не гарантирует non-replay ранних данных между соединениями. Неидемпотентные действия либо не принимают в 0-RTT, либо защищают на application layer.

Полный разбор: [[20 Бэкенд/Replay attacks|Replay attacks]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Защита от автоматизированных заказов — нужно исходное условие; база: Моделирование угроз, Rate limiting и quotas, Replay attacks.» — [[Авито/roadmap#System design и проектирование|Авито/roadmap, раздел «System design и проектирование»]].

## Источники

- [CWE-294: Authentication Bypass by Capture-replay](https://cwe.mitre.org/data/definitions/294.html) — MITRE, CWE 4.20 от 2026-04-30, проверено 2026-07-18.
- [RFC 9421: HTTP Message Signatures](https://datatracker.ietf.org/doc/html/rfc9421) — IETF, RFC 9421, февраль 2024, проверено 2026-07-18.
- [RFC 9449: OAuth 2.0 Demonstrating Proof of Possession](https://datatracker.ietf.org/doc/html/rfc9449) — IETF, RFC 9449, сентябрь 2023, проверено 2026-07-18.
- [RFC 9846: The Transport Layer Security Protocol Version 1.3](https://datatracker.ietf.org/doc/rfc9846/) — IETF, RFC 9846, июль 2026; obsoletes RFC 8446, разделы 2.3 и 8, проверено 2026-07-18.
- [Transaction Authorization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Transaction_Authorization_Cheat_Sheet.html) — OWASP Cheat Sheet Series, актуальная веб-версия, проверено 2026-07-18.
- [RFC 9700: Best Current Practice for OAuth 2.0 Security](https://datatracker.ietf.org/doc/html/rfc9700) — IETF, BCP 240 / RFC 9700, январь 2025, проверено 2026-07-18.
