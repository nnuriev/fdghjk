---
aliases:
  - "Теоретический вопрос: Планировщик GMP"
tags:
  - область/go
  - тема/runtime
  - тип/вопрос
статус: проверено
---

# Планировщик GMP

## Вопрос

Объясните тему «Планировщик GMP» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Планировщик Go распределяет готовые goroutines (`G`) по потокам ОС (`M`) через ограниченный набор ресурсов выполнения (`P`). `GOMAXPROCS` ограничивает число `P`, то есть максимальное число goroutines, одновременно исполняющих Go-код, но не число goroutines и не обязательно число OS threads. Блокировка goroutine на channel или pollable network I/O освобождает возможность исполнять другую работу; блокирующий syscall может временно отделить `M` от `P`. На scheduler latency влияют загрузка CPU, длина runnable-очередей, stop-the-world фазы, syscalls, preemption и oversubscription.

Полный разбор: [[60 Go/Планировщик GMP|Планировщик GMP]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- [[CurseHunter/6860/04 Планировщик, синхронизация и каналы#Горутины и scheduler|Горутины и scheduler]] — вопросы о G/M/P, run queues, work stealing, blocking syscalls, netpoller, preemption и growth stack.
- [[CurseHunter/6593/01 Выполнение кода, горутины и планировщик#Вопросы и ожидаемая глубина ответа|Вопросы и ожидаемая глубина ответа]] — исходный блок вопросов о scheduler runtime.
- [[CurseHunter/6593/01 Выполнение кода, горутины и планировщик#Что такое G, M и P?|Что такое G, M и P?]] — вопрос о ролях goroutine, OS thread и execution resource.
- [[CurseHunter/6593/01 Выполнение кода, горутины и планировщик#Откуда scheduler берёт работу?|Откуда scheduler берёт работу?]] — вопрос о local/global run queues и netpoll.
- [[CurseHunter/6593/01 Выполнение кода, горутины и планировщик#Зачем global runnable queue, если есть local queues?|Зачем global runnable queue, если есть local queues?]] — follow-up о fairness и внешнем admission runnable work.
- [[CurseHunter/6593/01 Выполнение кода, горутины и планировщик#Work sharing и work stealing — в чём разница?|Work sharing и work stealing — в чём разница?]] — сравнительный вопрос о распределении runnable work.
- [[CurseHunter/6593/01 Выполнение кода, горутины и планировщик#Что происходит при blocking syscall?|Что происходит при blocking syscall?]] — вопрос о передаче `P` другому `M`.
- [[CurseHunter/6593/01 Выполнение кода, горутины и планировщик#Зачем sysmon?|Зачем sysmon?]] — вопрос о retake, timer/netpoll и preemption duties sysmon.
- [[CurseHunter/6593/01 Выполнение кода, горутины и планировщик#Что делают `runtime.Gosched`, `runtime.Goexit` и `runtime.LockOSThread`?|Что делают `runtime.Gosched`, `runtime.Goexit` и `runtime.LockOSThread`?]] — точная формулировка вопроса о runtime control operations.
- [[CurseHunter/6593/01 Выполнение кода, горутины и планировщик#Задачи курса|Задачи курса]] — исходный practical-блок по runtime behavior.
- [[CurseHunter/6593/01 Выполнение кода, горутины и планировщик#Реализуйте учебный scheduler на C|Реализуйте учебный scheduler на C]] — упражнение на runnable/parked states, context switch и stack lifetime.
- «Scheduler ищет работу в local run queue, периодически учитывает global queue, выполняет work stealing и забирает готовые network operations из netpoller. Blocking syscall может отделить `M` от `P`, чтобы другой thread продолжил Go work. Это implementation model, а не детерминированный порядок запуска. Полный механизм — в заметке о GMP scheduler.» — [[CurseHunter/6609/11 Горутины и планировщик#Урок 76. GMP scheduler|CurseHunter/6609/11 Горутины и планировщик, раздел «Урок 76. GMP scheduler»]].
- «GMP-вопросы напрямую соответствуют Планировщику GMP.» — [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Lamoda — 2026-06-10 — 400к, раздел «Сопоставление с материалами vault»]].
- «Кандидат назвал «G-P model» и тем самым потерял M, хотя дальше говорил про OS threads. Local queue он описал близко к истине. Ответ про mutex waiters был слишком общим, а network poller почти не раскрыт. Полная модель: GMP scheduler, netpoller и execution trace.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Scheduler, blocking и netpoll — `00:12:53–00:14:40`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Scheduler, blocking и netpoll — `00:12:53–00:14:40`»]].
- «Escape/stack → GMP → memory model → GC.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Минимальный маршрут по vault»]].
- «Goroutines, threads и GMP соответствуют Goroutines и lifecycle, Планировщику GMP, Стекам и escape analysis и Netpoller.» — [[Telegram Собесы/Сбер — 2026-05-28 — 250к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Сбер — 2026-05-28 — 250к, раздел «Сопоставление с материалами vault»]].
- «Goroutine, OS thread, GMP и точки блокировки: Goroutines и lifecycle, Планировщик GMP, Процесс, поток и goroutine.» — [[Авито/roadmap#Concurrency и runtime|Авито/roadmap, раздел «Concurrency и runtime»]].

- [[Telegram Собесы/АМТЕХ — 2026-04-06 — 350к/Бланк вопросов и заданий#Go scheduler: G/M/P, очереди и fairness — `00:33:19–00:43:44`|Go scheduler: G/M/P, очереди и fairness — `00:33:19–00:43:44`]] — точная проверенная формулировка технического блока интервью АМТЕХ.
- [[Telegram Собесы/АМТЕХ — 2026-04-06 — 350к/Бланк вопросов и заданий#`GOMAXPROCS` и производительность — `00:54:50–00:58:10`|`GOMAXPROCS` и производительность — `00:54:50–00:58:10`]] — точная проверенная формулировка технического блока интервью АМТЕХ.

- [[Telegram Собесы/Adcamp — 2026-03-23 — 280к/Бланк вопросов и заданий#Goroutines и G/M/P — `00:08:28–00:10:48`|Goroutines и G/M/P — `00:08:28–00:10:48`]] — точная проверенная формулировка соответствующего технического блока интервью.
- [[Telegram Собесы/Adcamp — 2026-03-23 — 280к/Бланк вопросов и заданий#Goroutine, concurrency и scheduler|Goroutine, concurrency и scheduler]] — точная проверенная формулировка соответствующего технического блока интервью.
- [[Telegram Собесы/CoinsPaid — 2026-04-27 — 6633 EUR/Бланк вопросов и заданий#Опыт, goroutines и планировщик — `00:00:38–00:11:22`|Опыт, goroutines и планировщик — `00:00:38–00:11:22`]] — точная проверенная формулировка соответствующего технического блока интервью.
- [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#GMP, `GOMAXPROCS` и run queues — `00:23:24–00:31:00`|GMP, `GOMAXPROCS` и run queues — `00:23:24–00:31:00`]] — точная проверенная формулировка соответствующего технического блока интервью.
- [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#GMP без мифов|GMP без мифов]] — точная проверенная формулировка соответствующего технического блока интервью.

- [[Telegram Собесы/MagnitTech — 2026-04-13 — 400200 руб/Бланк вопросов и заданий#Goroutines, memory и synchronization — `00:16:51–00:33:00`|Goroutines, memory и synchronization — `00:16:51–00:33:00`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Plata — 2026-04-13 — 4252 EUR/Бланк вопросов и заданий#Goroutines, G/M/P, `GOMAXPROCS`, `sync` и `errgroup` — `00:41:50–00:49:00`|Goroutines, G/M/P, `GOMAXPROCS`, `sync` и `errgroup` — `00:41:50–00:49:00`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Авито — 2026-07-17/Бланк вопросов и заданий#Теория goroutines и планировщика — `01:02–01:09`|Теория goroutines и планировщика — `01:02–01:09`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Магнит — 2025-12-26 — 400к/Бланк вопросов и заданий#Goroutines и scheduler — `01:11:16–01:14:57`|Goroutines и scheduler — `01:11:16–01:14:57`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Сбер — 2026-05-28 — 250к/Бланк вопросов и заданий#Goroutines, threads и scheduler — `00:00:12–00:04:30`|Goroutines, threads и scheduler — `00:00:12–00:04:30`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/ШИФТ — 2026-04-20 — 500к/Бланк вопросов и заданий#Goroutines, scheduler и liveness — `00:20:31–00:31:08`|Goroutines, scheduler и liveness — `00:20:31–00:31:08`]] — точная проверенная формулировка самостоятельного технического блока интервью.

- [[CurseHunter/6817/Бланк вопросов и заданий#1. Как выбирать `GOMAXPROCS` для Go-сервиса в Kubernetes?|1. Как выбирать `GOMAXPROCS` для Go-сервиса в Kubernetes?]] — точная формулировка вопроса курса 6817 из «Урок 13. Q&A после курса».

## Источники

- [Package runtime](https://pkg.go.dev/runtime@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [runtime/proc.go: scheduler, findRunnable и run queues](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/proc.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/runtime2.go: структуры g, m и p](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/runtime2.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [Go 1.25 Release Notes: container-aware GOMAXPROCS](https://go.dev/doc/go1.25) — The Go Project, Go 1.25, проверено 2026-07-15.
- [GODEBUG defaults](https://go.dev/doc/godebug) — The Go Project, compatibility defaults для toolchain Go 1.26.5, проверено 2026-07-15.
- [runtime/debug.go: GOMAXPROCS и SetDefaultGOMAXPROCS](https://github.com/golang/go/blob/go1.26.5/src/runtime/debug.go#L12-L120) — репозиторий golang/go, tag go1.26.5, файл `src/runtime/debug.go`, проверено 2026-07-15.
- [Go 1.26 Release Notes: runtime/metrics](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
