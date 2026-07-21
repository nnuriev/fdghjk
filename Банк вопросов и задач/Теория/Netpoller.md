---
aliases:
  - "Теоретический вопрос: Netpoller"
tags:
  - область/go
  - тема/runtime
  - тема/сеть
  - тип/вопрос
статус: проверено
---

# Netpoller

## Вопрос

Объясните тему «Netpoller» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Netpoller позволяет goroutine ждать network I/O, не удерживая отдельный OS thread на всё время ожидания. На Unix пакеты `net` и `internal/poll` используют non-blocking descriptor: при `EAGAIN` runtime паркует G до readiness от epoll/kqueue. Windows path другой: overlapped `WSARecv`/`WSASend` завершаются completion packet через IOCP. В обоих случаях scheduler снова делает G runnable. Это не делает I/O неблокирующим на уровне API: `Read` всё ещё выглядит blocking и может вернуть partial data, timeout или error.

Полный разбор: [[60 Go/Netpoller|Netpoller]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/6593/01 Выполнение кода, горутины и планировщик#Что делает netpoller?|Что делает netpoller?]] — самостоятельный вопрос о парковке goroutine на readiness network I/O.
- «Кандидат назвал «G-P model» и тем самым потерял M, хотя дальше говорил про OS threads. Local queue он описал близко к истине. Ответ про mutex waiters был слишком общим, а network poller почти не раскрыт. Полная модель: GMP scheduler, netpoller и execution trace.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Scheduler, blocking и netpoll — `00:12:53–00:14:40`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Scheduler, blocking и netpoll — `00:12:53–00:14:40`»]].
- «Goroutines, threads и GMP соответствуют Goroutines и lifecycle, Планировщику GMP, Стекам и escape analysis и Netpoller.» — [[Telegram Собесы/Сбер — 2026-05-28 — 250к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Сбер — 2026-05-28 — 250к, раздел «Сопоставление с материалами vault»]].
- «Netpoll и большое число соединений: Netpoller, select, poll, epoll и kqueue, Блокирующий и неблокирующий ввод-вывод.» — [[Авито/roadmap#Concurrency и runtime|Авито/roadmap, раздел «Concurrency и runtime»]].

## Источники

- [Package net](https://pkg.go.dev/net@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [runtime/netpoll.go: platform-independent poller contract и pollDesc](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/netpoll.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/netpoll_epoll.go: Linux epoll backend](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/netpoll_epoll.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [internal/poll/fd_unix.go: non-blocking I/O loop](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/poll/fd_unix.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/netpoll_windows.go: IOCP backend](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/netpoll_windows.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [internal/poll/fd_windows.go: overlapped socket I/O](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/poll/fd_windows.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/proc.go: scheduler integration with netpoll](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/proc.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
