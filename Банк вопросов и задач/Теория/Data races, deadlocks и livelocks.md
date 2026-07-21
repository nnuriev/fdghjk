---
aliases:
  - "Теоретический вопрос: Data races, deadlocks и livelocks"
tags:
  - область/go
  - тема/конкурентность
  - тип/вопрос
статус: проверено
---

# Data races, deadlocks и livelocks

## Вопрос

Объясните тему «Data races, deadlocks и livelocks» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Data race нарушает safety: конфликтующие memory accesses не упорядочены [[60 Go/Модель памяти Go и happens-before|happens-before]] и хотя бы один из них — non-synchronizing. Atomic operations подчиняются отдельному protocol и сами по себе не образуют race. Deadlock и livelock нарушают liveness: в первом участники ждут навсегда, во втором продолжают выполнять действия, но не продвигают полезную работу. Отсутствие data race не доказывает progress. Тем более о progress нельзя судить лишь по активности CPU.

Полный разбор: [[60 Go/Data races, deadlocks и livelocks|Data races, deadlocks и livelocks]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Каждая goroutine удерживает один mutex и бесконечно крутит `TryLock` второго. Состояние владения не меняется, поэтому это busy-wait deadlock/spin-deadlock, а не классический livelock. При livelock участники активно меняют состояние и уступают друг другу, но общий progress не происходит. Различие и диагностика — в заметке о races и liveness failures.» — [[CurseHunter/6609/12 Примитивы синхронизации#Урок 86. «Livelock»|CurseHunter/6609/12 Примитивы синхронизации, раздел «Урок 86. «Livelock»»]].
- [[CurseHunter/7146/Бланк вопросов и заданий#Mutex плюс channel|Mutex плюс channel]] — failure-сценарий цикла ожиданий между lock и блокирующей channel operation.
- «В Go ответ удобно связать с happens-before и различием data race и нарушения составного инварианта. Устранить report race detector недостаточно: несколько отдельно корректных atomic operations всё ещё могут реализовывать неверный protocol.» — [[CurseHunter/6817/Бланк вопросов и заданий#3. Вопрос со слайда: каким станет `a`?|CurseHunter/6817, раздел «3. Вопрос со слайда: каким станет `a`?»]].
- «Для точечной подготовки уже существуют Context, deadlines и распространение отмены, Data races, deadlocks и livelocks, Execution trace, B-tree и B+tree и Distributed cache и KV store. Это не делает интервью «аналогом Авито»: MERLION — широкий fundamentals/code-review screen, Авито — набор отдельных algorithm и platform exercises с более глубокой практической постановкой.» — [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Связь с материалами репозитория|Telegram Собесы/MERLION — 2025-07-29 — 300к, раздел «Связь с материалами репозитория»]].
- «Ответ кандидата про scheduler quantum не объясняет показанный scenario. В исходниках `sync.Mutex` waiter после ожидания свыше `1 ms` включает starvation mode, где ownership передаётся голове очереди напрямую. Это implementation detail Go `1.26.5`, а практическое правило — не рассчитывать на fairness и измерять contention. См. Mutex/RWMutex и deadlock/livelock.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Mutex starvation — `00:14:40–00:16:00`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Mutex starvation — `00:14:40–00:16:00`»]].
- «Mutex, RWMutex, WaitGroup, Once, Cond и atomics: Mutex, RWMutex и примитивы координации sync, Пакет sync-atomic, Data races, deadlocks и livelocks.» — [[Авито/roadmap#Concurrency и runtime|Авито/roadmap, раздел «Concurrency и runtime»]].

- [[Telegram Собесы/Lunar Rails — 2026-04-27 — 7800 USD/Бланк вопросов и заданий#Concurrency и execution — `00:08:43–00:14:50`|Concurrency и execution — `00:08:43–00:14:50`]] — точная проверенная формулировка соответствующего технического блока интервью.

## Источники

- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
- [Data Race Detector](https://go.dev/doc/articles/race_detector) — The Go Project, официальная документация для toolchain Go 1.26.5, проверено 2026-07-15.
- [runtime/proc.go — checkdead](https://github.com/golang/go/blob/go1.26.5/src/runtime/proc.go#L6367-L6468) — репозиторий golang/go, tag go1.26.5, `checkdead`, проверено 2026-07-15.
