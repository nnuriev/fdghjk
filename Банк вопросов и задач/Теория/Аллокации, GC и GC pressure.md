---
aliases:
  - "Теоретический вопрос: Аллокации, GC и GC pressure"
tags:
  - область/go
  - тема/runtime
  - тема/производительность
  - тип/вопрос
статус: проверено
---

# Аллокации, GC и GC pressure

## Вопрос

Объясните тему «Аллокации, GC и GC pressure» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Garbage collector (GC) Go освобождает недостижимую heap memory. Число allocations — лишь один из факторов его стоимости. Ключевые величины — allocation rate, live heap, объём pointer-rich roots и частота циклов. `GOGC` выбирает CPU/memory trade-off, а `GOMEMLIMIT` задаёт soft limit для памяти, управляемой runtime. Сначала устраняйте лишний lifetime и горячие allocations, затем настраивайте GC; уменьшение `GOGC` не лечит retention, а слишком жёсткий memory limit может превратить процесс в почти непрерывный GC.

Полный разбор: [[60 Go/Аллокации, GC и GC pressure|Аллокации, GC и GC pressure]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- [[CurseHunter/6860/03 Дженерики, рефлексия и память#Garbage collector|Garbage collector]] — вопросы о tracing, roots, tri-color invariant, barriers, allocation rate, `GOGC`, `GOMEMLIMIT` и stop-the-world boundaries.
- «GC освобождает unreachable, а не «ненужное по мнению программы». Поэтому retention через slice, map, goroutine, timer или global остаётся logical leak даже при исправном collector. Подробная причинная модель — в заметке об allocation и GC pressure.» — [[CurseHunter/6609/10 Сборщик мусора#Урок 72. Concurrent tracing GC|CurseHunter/6609/10 Сборщик мусора, раздел «Урок 72. Concurrent tracing GC»]].
- «В Go аналогия требует точности. В Go `1.23.4` `mcache` привязан к runtime P, а не к OS thread: small object проходит через per-P cache, затем `mcentral` нужного span class и `mheap`. Поэтому фразу «thread-local allocator Go» лучше не использовать. Развёрнутый Go path уже разобран в уроке 9 и связан с стоимостью allocation и GC pressure.» — [[CurseHunter/6817/Бланк вопросов и заданий#4. Почему arenas, local caches и batching снижают contention|CurseHunter/6817, раздел «4. Почему arenas, local caches и batching снижают contention»]].
- «Точные модели `panic/recover`, slices, races, escape analysis и GC уже есть в defer, panic и recover, массивах и слайсах, race detector, стеках и escape analysis и GC pressure. Для идемпотентности платежей и POST-операций нужен полный protocol из заметки о ключах идемпотентности, а не только случайный token.» — [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Go и API — `00:22:43–00:33:03`|Telegram Собесы/M.Tech — 2026-07-17 — 350к, раздел «Go и API — `00:22:43–00:33:03`»]].
- «Кандидат вспомнил LIFO, динамический stack около `2 KiB` и идею заранее нарезанных blocks, но не связал stack growth, escape analysis и allocator hierarchy. Направление роста адресов для reasoning не нужно: runtime может копировать user stack. См. стеки и escape analysis и аллокации и GC pressure.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Stack, heap и allocator spans — `00:16:00–00:19:10`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Stack, heap и allocator spans — `00:16:00–00:19:10`»]].
- «Кандидат верно назвал mark-sweep, roots и tri-color terms. Неточности: concurrent mark не означает постоянное «одно ядро из четырёх», sweep не просто отдельная финальная фаза «в фоне», а tuning задаётся не вызовом абстрактной функции, а `GOGC`/`SetGCPercent` и memory limit. Практическая модель есть в аллокациях, GC и GC pressure.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Garbage collector — `00:23:40–00:25:42`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Garbage collector — `00:23:40–00:25:42`»]].
- «Escape/stack → GMP → memory model → GC.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Минимальный маршрут по vault»]].
- «Allocator, escape analysis, goroutine stacks и GC pressure: Стеки и escape analysis, Аллокации, GC и GC pressure, Стек, heap и виртуальная память.» — [[Авито/roadmap#Concurrency и runtime|Авито/roadmap, раздел «Concurrency и runtime»]].

- [[Telegram Собесы/АМТЕХ — 2026-04-06 — 350к/Бланк вопросов и заданий#Garbage collector, `GOGC`, `GOMEMLIMIT` — `00:51:37–00:54:50`|Garbage collector, `GOGC`, `GOMEMLIMIT` — `00:51:37–00:54:50`]] — точная проверенная формулировка технического блока интервью АМТЕХ.

- [[Telegram Собесы/Adcamp — 2026-03-23 — 280к/Бланк вопросов и заданий#Memory, GC и `sync.Pool`|Memory, GC и `sync.Pool`]] — точная проверенная формулировка соответствующего технического блока интервью.
- [[Telegram Собесы/Lunar Rails — 2026-04-27 — 7800 USD/Бланк вопросов и заданий#Go — `00:23:13–00:28:20`|Go — `00:23:13–00:28:20`]] — точная проверенная формулировка соответствующего технического блока интервью.

- [[Telegram Собесы/MagnitTech — 2026-04-13 — 400200 руб/Бланк вопросов и заданий#Goroutines, memory и synchronization — `00:16:51–00:33:00`|Goroutines, memory и synchronization — `00:16:51–00:33:00`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Магнит — 2025-12-26 — 400к/Бланк вопросов и заданий#Garbage Collector — `01:18:53–01:22:39`|Garbage Collector — `01:18:53–01:22:39`]] — точная проверенная формулировка самостоятельного технического блока интервью.

- [[CurseHunter/6817/Бланк вопросов и заданий#3. Чем garbage collector отличается от scavenger и почему `HeapSys` не равен RSS?|3. Чем garbage collector отличается от scavenger и почему `HeapSys` не равен RSS?]] — точная формулировка вопроса курса 6817 из «Урок 9. Устройство памяти Go и бенчмарки».
- [[CurseHunter/6817/Бланк вопросов и заданий#10. Когда preallocation слайса или map действительно помогает?|10. Когда preallocation слайса или map действительно помогает?]] — точная формулировка вопроса курса 6817 из «Урок 9. Устройство памяти Go и бенчмарки».
- [[CurseHunter/6817/Бланк вопросов и заданий#11. Почему специализированный `strconv` может выиграть у `fmt.Sprintf`?|11. Почему специализированный `strconv` может выиграть у `fmt.Sprintf`?]] — точная формулировка вопроса курса 6817 из «Урок 9. Устройство памяти Go и бенчмарки».
- [[CurseHunter/6817/Бланк вопросов и заданий#1. Как `GOGC` задаёт момент запуска следующего GC cycle?|1. Как `GOGC` задаёт момент запуска следующего GC cycle?]] — точная формулировка вопроса курса 6817 из «Урок 10. Оптимизации в Go».
- [[CurseHunter/6817/Бланк вопросов и заданий#2. Почему `GOMEMLIMIT` не равен лимиту RSS или cgroup?|2. Почему `GOMEMLIMIT` не равен лимиту RSS или cgroup?]] — точная формулировка вопроса курса 6817 из «Урок 10. Оптимизации в Go».
- [[CurseHunter/6817/Бланк вопросов и заданий#3. Когда допустимы `runtime.GC`, `SetGCPercent` и `SetMemoryLimit`?|3. Когда допустимы `runtime.GC`, `SetGCPercent` и `SetMemoryLimit`?]] — точная формулировка вопроса курса 6817 из «Урок 10. Оптимизации в Go».
- [[CurseHunter/6817/Бланк вопросов и заданий#4. Что на самом деле измеряют функции пакета `runtime` со слайда?|4. Что на самом деле измеряют функции пакета `runtime` со слайда?]] — точная формулировка вопроса курса 6817 из «Урок 10. Оптимизации в Go».

## Источники

- [A Guide to the Go Garbage Collector](https://go.dev/doc/gc-guide) — The Go Project, документированная модель для Go 1.19; сопоставлена с Go 1.26.5, проверено 2026-07-15.
- [Package runtime: environment variables and MemStats](https://pkg.go.dev/runtime@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Package runtime/metrics](https://pkg.go.dev/runtime/metrics@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [runtime/mgc.go: garbage collector](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/mgc.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/mgcpacer.go: GC pacer](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/mgcpacer.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [Go 1.19 Release Notes: soft memory limit](https://go.dev/doc/go1.19) — The Go Project, Go 1.19, проверено 2026-07-15.
- [Go 1.25 Release Notes: experimental Green Tea GC](https://go.dev/doc/go1.25) — The Go Project, Go 1.25, проверено 2026-07-15.
- [Go 1.26 Release Notes: Green Tea GC by default](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
