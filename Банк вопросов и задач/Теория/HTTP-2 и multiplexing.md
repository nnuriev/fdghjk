---
aliases:
  - "Теоретический вопрос: HTTP-2 и multiplexing"
tags:
  - область/основы-cs
  - тема/сети
  - тема/http
  - механизм/мультиплексирование
  - тип/вопрос
статус: проверено
---

# HTTP-2 и multiplexing

## Вопрос

Объясните тему «HTTP-2 и multiplexing»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

HTTP/2 сохраняет семантику HTTP, но заменяет текстовый wire format бинарными frames и разбивает одно TCP connection на независимые streams. Frames разных streams можно чередовать, поэтому готовый короткий response не обязан ждать медленный response, как при HTTP/1.1 pipelining. Это и есть multiplexing на уровне HTTP.

Независимость неполная. Все frames всё ещё лежат в одном упорядоченном TCP byte stream: потерянный TCP-сегмент задерживает доставку последующих байтов всех HTTP/2 streams до retransmission. Кроме того, streams делят connection-level flow-control window, HPACK state, congestion state и судьбу самого connection. Поэтому «один connection устраняет все очереди» — неверная модель.

Полный разбор: [[10 Основы CS/HTTP-2 и multiplexing|HTTP-2 и multiplexing]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «HTTP/1.1 → HTTP/2 → HTTP/3.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Минимальный маршрут по vault»]].

## Источники

- [RFC 9113: HTTP/2](https://www.rfc-editor.org/rfc/rfc9113.html) — IETF, RFC 9113, июнь 2022, проверено 2026-07-18.
- [RFC 7541: HPACK — Header Compression for HTTP/2](https://www.rfc-editor.org/rfc/rfc7541.html) — IETF, RFC 7541, май 2015, проверено 2026-07-18.
- [RFC 9218: Extensible Prioritization Scheme for HTTP](https://www.rfc-editor.org/rfc/rfc9218.html) — IETF, RFC 9218, июнь 2022, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, STD 97 / RFC 9110, июнь 2022, проверено 2026-07-18.
