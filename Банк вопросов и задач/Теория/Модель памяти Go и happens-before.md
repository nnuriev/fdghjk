---
aliases:
  - "Теоретический вопрос: Модель памяти Go и happens-before"
tags:
  - область/go
  - тема/конкурентность
  - тип/вопрос
статус: проверено
---

# Модель памяти Go и happens-before

## Вопрос

Объясните тему «Модель памяти Go и happens-before» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Happens-before отвечает не на вопрос «что runtime, вероятно, выполнит раньше», а на вопрос «какую запись read обязан видеть». Он строится как транзитивное замыкание program order внутри goroutine и документированных synchronization edges между goroutines. Неупорядоченные конфликтующие accesses образуют [[60 Go/Data races, deadlocks и livelocks|data race]], когда хотя бы один из них — non-synchronizing; atomic operations подчиняются отдельному synchronization protocol. Timing и `time.Sleep` ordering не создают.

Полный разбор: [[60 Go/Модель памяти Go и happens-before|Модель памяти Go и happens-before]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/6593/04 Context и модель памяти#Модель памяти|Модель памяти]] — исходный блок о visibility и synchronization events.
- [[CurseHunter/6593/04 Context и модель памяти#DRF-SC|DRF-SC]] — вопрос о sequentially consistent explanation для race-free programs.
- [[CurseHunter/6593/04 Context и модель памяти#Happens-before|Happens-before]] — вопрос о partial order synchronizing operations.
- [[CurseHunter/6593/04 Context и модель памяти#Что означают memory barriers в курсе|Что означают memory barriers в курсе]] — вопрос о границе language contract и hardware/compiler implementation.
- [[CurseHunter/6593/04 Context и модель памяти#Интервью-задачи|Интервью-задачи]] — исходный блок litmus-test и publication exercises.
- [[CurseHunter/6593/03 Каналы, время и паттерны#Что гарантирует коммуникация|Что гарантирует коммуникация]] — вопрос о happens-before edges send, receive и close.
- «Data race — конфликтующие concurrent accesses без synchronization, хотя бы один write. Race condition шире: output зависит от scheduling и может быть логически неверным даже при отсутствии data race. Модель — в заметке о memory model.» — [[CurseHunter/6609/12 Примитивы синхронизации#Задача курса|CurseHunter/6609/12 Примитивы синхронизации, раздел «Задача курса»]].
- «В Go ответ удобно связать с happens-before и различием data race и нарушения составного инварианта. Устранить report race detector недостаточно: несколько отдельно корректных atomic operations всё ещё могут реализовывать неверный protocol.» — [[CurseHunter/6817/Бланк вопросов и заданий#3. Вопрос со слайда: каким станет `a`?|CurseHunter/6817, раздел «3. Вопрос со слайда: каким станет `a`?»]].
- «Это объяснение относится к ordinary accesses к write-back memory в x86 ordering model. Его нельзя переносить напрямую на racy Go source: compiler и Go memory model стоят выше ISA. В Go reasoning начинается с happens-before; ordinary conflicting accesses без synchronization — data race. В Go `1.23.4` operations `sync/atomic` входят в sequentially consistent order, а race-free program получает DRF-SC guarantee.» — [[CurseHunter/6817/Бланк вопросов и заданий#6. Почему тот же outcome допускает x86-TSO|CurseHunter/6817, раздел «6. Почему тот же outcome допускает x86-TSO»]].
- «Mutex/RWMutex → memory model → race detector.» — [[Telegram Собесы/VK Tech — 2025-09-12 — 350к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/VK Tech — 2025-09-12 — 350к, раздел «Минимальный маршрут по vault»]].
- «Кандидат понял, что synchronization primitives связаны с visibility, но фактически заменил модель памяти словами «специальные инструкции и memory barriers». На интервью ждут contract: без data race чтения объяснимы sequentially consistent interleaving, а Mutex/channel/atomic создают конкретные ordering edges. См. модель памяти и sync/atomic.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Synchronization primitives и happens-before — `00:19:10–00:21:12`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Synchronization primitives и happens-before — `00:19:10–00:21:12`»]].
- «Escape/stack → GMP → memory model → GC.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Минимальный маршрут по vault»]].
- «Горутины в цикле — loop-variable semantics, ожидание завершения и data race на общем максимуме. База: замыкания, lifecycle goroutine, happens-before, race detector, WaitGroup и Mutex.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «Один mutex защищает оба состояния и переход между ними. На свежем hit функция сразу читает entry. На miss первый caller регистрирует `call` и запускает refresh; следующий caller видит тот же `call` и ждёт закрытия `done`. После fetch владелец под mutex публикует результат, удаляет запись из `inflight` и закрывает `done`. Закрытие channel происходит после записи полей, поэтому waiters наблюдают опубликованный результат; общий happens-before механизм описан в модели памяти Go.» — [[Авито/Решения/Go-платформа/Прогноз погоды и cache#Ментальная модель|Авито/Решения/Go-платформа/Прогноз погоды и cache, раздел «Ментальная модель»]].

- [[CurseHunter/6817/Бланк вопросов и заданий#7. Что не так с конкурентным Go-кодом, который ждёт `done` и затем читает `name` без синхронизации?|7. Что не так с конкурентным Go-кодом, который ждёт `done` и затем читает `name` без синхронизации?]] — точная формулировка вопроса курса 6817 из «Урок 1. Микроархитектура процессора».

## Источники

- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
- [Package sync](https://pkg.go.dev/sync@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
- [Package sync/atomic](https://pkg.go.dev/sync/atomic@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
