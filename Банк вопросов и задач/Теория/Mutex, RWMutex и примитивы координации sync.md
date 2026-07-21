---
aliases:
  - "Теоретический вопрос: Mutex, RWMutex и примитивы координации sync"
tags:
  - область/go
  - тема/конкурентность
  - тип/вопрос
статус: проверено
---

# Mutex, RWMutex и примитивы координации sync

## Вопрос

Объясните тему «Mutex, RWMutex и примитивы координации sync» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

`sync.Mutex` защищает не отдельную переменную, а инвариант общего состояния: каждое чтение и изменение этого состояния выполняется под тем же lock. `RWMutex` допускает параллельных readers, но полезен только при измеренном выигрыше. `WaitGroup`, `Once` и `Cond` решают другие задачи — ожидание набора работ, однократную инициализацию и ожидание изменения условия — и не заменяют взаимное исключение.

Полный разбор: [[60 Go/Mutex, RWMutex и примитивы координации sync|Mutex, RWMutex и примитивы координации sync]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- [[CurseHunter/6860/04 Планировщик, синхронизация и каналы#Примитивы синхронизации|Примитивы синхронизации]] — вопросы о data races, happens-before, mutex invariants, deadlock, starvation, CAS, `sync.Cond` и false sharing.
- [[CurseHunter/6593/02 Примитивы синхронизации#`WaitGroup`|`WaitGroup`]] — самостоятельный блок о counter lifecycle и happens-before.
- [[CurseHunter/6593/02 Примитивы синхронизации#Ментальная модель|Ментальная модель `WaitGroup`]] — точная модель счётчика незавершённой работы.
- [[CurseHunter/6593/02 Примитивы синхронизации#Что спрашивают|Что спрашивают о `WaitGroup`]] — варианты о `Add`, copying, reuse и negative counter.
- [[CurseHunter/6593/02 Примитивы синхронизации#`Mutex`: инвариант важнее lock/unlock|`Mutex`: инвариант важнее lock/unlock]] — вопрос о защищаемом составном инварианте.
- [[CurseHunter/6593/02 Примитивы синхронизации#Частые задачи на code review|Частые задачи на code review `Mutex`]] — набор failure-сценариев с local/copy/reentrant mutex.
- [[CurseHunter/6593/02 Примитивы синхронизации#Normal и starvation mode|Normal и starvation mode]] — implementation follow-up о throughput и передаче ownership waiter.
- [[CurseHunter/6593/02 Примитивы синхронизации#Priority inversion|Priority inversion]] — вопрос о latency-sensitive waiter и долгом owner critical section.
- [[CurseHunter/6593/02 Примитивы синхронизации#`sync.Once`|`sync.Once`]] — вопрос об однократной публикации, panic и recursive deadlock.
- [[CurseHunter/6593/02 Примитивы синхронизации#`sync.Cond`|`sync.Cond`]] — вопрос о predicate loop, lost signal и broadcast.
- [[CurseHunter/6593/02 Примитивы синхронизации#`RWMutex`, map и `sync.Map`|`RWMutex`, map и `sync.Map`]] — сравнительный блок выбора synchronization primitive.
- [[CurseHunter/6593/02 Примитивы синхронизации#Когда `RWMutex` может проиграть `Mutex`|Когда `RWMutex` может проиграть `Mutex`]] — вопрос о коротких critical sections и writer contention.
- «Полные правила — в заметке о sync primitives.» — [[CurseHunter/6609/12 Примитивы синхронизации#Урок 89. Опасные операции с Mutex/RWMutex|CurseHunter/6609/12 Примитивы синхронизации, раздел «Урок 89. Опасные операции с Mutex/RWMutex»]].
- «Channel protocol, map synchronization и диагностика покрывают Каналы или mutex, Map, Mutex и RWMutex и Race detector.» — [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Lamoda — 2026-06-10 — 400к, раздел «Сопоставление с материалами vault»]].
- «Mutex/RWMutex → memory model → race detector.» — [[Telegram Собесы/VK Tech — 2025-09-12 — 350к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/VK Tech — 2025-09-12 — 350к, раздел «Минимальный маршрут по vault»]].
- «Ответ кандидата про scheduler quantum не объясняет показанный scenario. В исходниках `sync.Mutex` waiter после ожидания свыше `1 ms` включает starvation mode, где ownership передаётся голове очереди напрямую. Это implementation detail Go `1.26.5`, а практическое правило — не рассчитывать на fairness и измерять contention. См. Mutex/RWMutex и deadlock/livelock.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Mutex starvation — `00:14:40–00:16:00`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Mutex starvation — `00:14:40–00:16:00`»]].
- «Channel protocol и synchronization покрыты в Буферизации и закрытии каналов, select и cancellation, Каналах или mutex, Mutex и RWMutex и sync/atomic.» — [[Telegram Собесы/Сбер — 2026-05-28 — 250к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Сбер — 2026-05-28 — 250к, раздел «Сопоставление с материалами vault»]].
- «Горутины в цикле — loop-variable semantics, ожидание завершения и data race на общем максимуме. База: замыкания, lifecycle goroutine, happens-before, race detector, WaitGroup и Mutex.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «Mutex, RWMutex, WaitGroup, Once, Cond и atomics: Mutex, RWMutex и примитивы координации sync, Пакет sync-atomic, Data races, deadlocks и livelocks.» — [[Авито/roadmap#Concurrency и runtime|Авито/roadmap, раздел «Concurrency и runtime»]].

- [[Telegram Собесы/АМТЕХ — 2026-04-06 — 350к/Бланк вопросов и заданий#Mutex, atomics и synchronization — `00:58:10–01:01:54`|Mutex, atomics и synchronization — `00:58:10–01:01:54`]] — точная проверенная формулировка технического блока интервью АМТЕХ.

- [[Telegram Собесы/MagnitTech — 2026-04-13 — 400200 руб/Бланк вопросов и заданий#Goroutines, memory и synchronization — `00:16:51–00:33:00`|Goroutines, memory и synchronization — `00:16:51–00:33:00`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Магнит — 2025-12-26 — 400к/Бланк вопросов и заданий#Mutex, RWMutex, atomic и `sync` — `01:07:05–01:11:16`|Mutex, RWMutex, atomic и `sync` — `01:07:05–01:11:16`]] — точная проверенная формулировка самостоятельного технического блока интервью.

- [[CurseHunter/6817/Бланк вопросов и заданий#2. Почему mutex profile указывает на `Unlock`, а block profile — на ожидающую сторону?|2. Почему mutex profile указывает на `Unlock`, а block profile — на ожидающую сторону?]] — точная формулировка вопроса курса 6817 из «Урок 12. Профилирование Go: contention, trace, PGO и continuous profiling».
- [[CurseHunter/6817/Бланк вопросов и заданий#3. Когда `sync.RWMutex` действительно лучше `sync.Mutex` и что доказывает профиль курса?|3. Когда `sync.RWMutex` действительно лучше `sync.Mutex` и что доказывает профиль курса?]] — точная формулировка вопроса курса 6817 из «Урок 12. Профилирование Go: contention, trace, PGO и continuous profiling».

## Источники

- [Package sync](https://pkg.go.dev/sync@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, публичный контракт `Mutex`, `RWMutex`, `WaitGroup`, `Once` и `Cond`, проверено 2026-07-18.
- [waitgroup.go](https://github.com/golang/go/blob/go1.26.5/src/sync/waitgroup.go) — репозиторий `golang/go`, tag `go1.26.5`, packing `state`, semaphore path, misuse checks и реализация `WaitGroup.Go`, проверено 2026-07-18.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
