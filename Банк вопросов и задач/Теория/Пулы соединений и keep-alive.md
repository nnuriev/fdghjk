---
aliases:
  - "Теоретический вопрос: Пулы соединений и keep-alive"
tags:
  - область/бэкенд
  - тема/http
  - тема/производительность
  - тип/вопрос
статус: проверено
---

# Пулы соединений и keep-alive

## Вопрос

Как работает «Пулы соединений и keep-alive» и какие ограничения, failure modes и trade-offs нужно учитывать в backend-системе?

## Короткий ориентир

Connection pool повторно использует уже установленные соединения и при явной настройке ограничивает число создаваемых и активных transport resources. Это убирает лишние DNS, TCP и TLS handshakes, но добавляет очередь за соединением, idle lifecycle и риск держать связь с уже нежелательным backend. Сам факт наличия пула не задаёт bound: например, в Go `MaxConnsPerHost=0` означает отсутствие предела.

В HTTP/1.1 persistent connection обычно обслуживает один активный обмен за раз, поэтому concurrency требует несколько соединений. HTTP/2 мультиплексирует streams поверх одного соединения, но не отменяет лимиты streams, flow control и общую судьбу TCP connection. HTTP keep-alive при этом не следует путать с TCP keepalive probes: первое означает повторное использование HTTP-соединения, второе обнаруживает мёртвого peer на транспортном уровне.

Полный разбор: [[20 Бэкенд/Пулы соединений и keep-alive|Пулы соединений и keep-alive]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «Параллельный запрос URL — `http.Client`, `httptest`, отмена sibling requests и ограничение числа in-flight запросов. База: HTTP client/Transport, HTTP timeouts, cancellation, connection pools.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «`http.Client` и `Transport` рассчитаны на reuse и безопасны для concurrent use. Именно повторное использование даёт connection pooling и keep-alive, разобранные в заметке о пулах соединений.» — [[Авито/Решения/Go-платформа/Параллельный запрос URL#Ментальная модель|Авито/Решения/Go-платформа/Параллельный запрос URL, раздел «Ментальная модель»]].

## Источники

- [RFC 9112: HTTP/1.1](https://datatracker.ietf.org/doc/html/rfc9112) — IETF, RFC 9112, июнь 2022, проверено 2026-07-18.
- [RFC 9113: HTTP/2](https://datatracker.ietf.org/doc/html/rfc9113) — IETF, RFC 9113, июнь 2022, проверено 2026-07-18.
- [Package net/http](https://pkg.go.dev/net/http@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-18.
- [Package net](https://pkg.go.dev/net@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-18.
