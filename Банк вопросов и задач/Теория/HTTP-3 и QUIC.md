---
aliases:
  - "Теоретический вопрос: HTTP-3 и QUIC"
tags:
  - область/основы-cs
  - тема/сети
  - тема/http
  - механизм/quic
  - тип/вопрос
статус: проверено
---

# HTTP-3 и QUIC

## Вопрос

Объясните тему «HTTP-3 и QUIC»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

HTTP/3 переносит HTTP поверх QUIC, а QUIC реализует поверх UDP защищённые connections, надёжные streams, loss recovery, flow control и congestion control. UDP здесь лишь datagram substrate: прикладной код получает не «ненадёжный HTTP», а упорядоченные байты внутри каждого QUIC stream.

Ключевое отличие от HTTP/2 — отсутствие общего транспортного порядка между streams. Потеря данных одного stream не мешает доставить уже полученные данные другого stream. При этом loss не исчезает: streams делят congestion budget, connection-level flow control, stream limits и судьбу connection. QPACK тоже может временно заблокировать header block, если тот ссылается на ещё не доставленное состояние dynamic table.

Полный разбор: [[10 Основы CS/HTTP-3 и QUIC|HTTP-3 и QUIC]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «HTTP/1.1 → HTTP/2 → HTTP/3.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Минимальный маршрут по vault»]].

## Источники

- [RFC 9000: QUIC — A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000.html) — IETF, RFC 9000 / QUIC version 1, май 2021, проверено 2026-07-18.
- [RFC 9001: Using TLS to Secure QUIC](https://www.rfc-editor.org/rfc/rfc9001.html) — IETF, RFC 9001 / QUIC version 1, май 2021, проверено 2026-07-18.
- [RFC 9002: QUIC Loss Detection and Congestion Control](https://www.rfc-editor.org/rfc/rfc9002.html) — IETF, RFC 9002 / QUIC version 1, май 2021, проверено 2026-07-18.
- [RFC 9114: HTTP/3](https://www.rfc-editor.org/rfc/rfc9114.html) — IETF, RFC 9114, июнь 2022, проверено 2026-07-18.
- [RFC 9204: QPACK — Field Compression for HTTP/3](https://www.rfc-editor.org/rfc/rfc9204.html) — IETF, RFC 9204, июнь 2022, проверено 2026-07-18.
- [RFC 8470: Using Early Data in HTTP](https://www.rfc-editor.org/rfc/rfc8470.html) — IETF, RFC 8470, сентябрь 2018, проверено 2026-07-18.
- [RFC 9369: QUIC Version 2](https://www.rfc-editor.org/rfc/rfc9369.html) — IETF, RFC 9369 / QUIC version 2, май 2023, проверено 2026-07-18.
- [RFC 9308: Applicability of the QUIC Transport Protocol](https://www.rfc-editor.org/rfc/rfc9308.html) — IETF, RFC 9308, сентябрь 2022, проверено 2026-07-18.
