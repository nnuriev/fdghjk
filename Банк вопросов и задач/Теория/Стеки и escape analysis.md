---
aliases:
  - "Теоретический вопрос: Стеки и escape analysis"
tags:
  - область/go
  - тема/runtime
  - тема/производительность
  - тип/вопрос
статус: проверено
---

# Стеки и escape analysis

## Вопрос

Объясните тему «Стеки и escape analysis» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

У каждой goroutine есть растущий stack, который runtime при необходимости заменяет большим и копирует. Отдельно компилятор выполняет escape analysis: если время жизни значения или доступ к нему нельзя безопасно ограничить stack frame, storage размещается в heap. Синтаксис `new(T)`, pointer receiver или локальная переменная сами по себе не определяют размещение. Heap allocation — не ошибка, но она добавляет работу allocator и потенциальный объём сканирования [[60 Go/Аллокации, GC и GC pressure|GC]]; оптимизировать её следует по diagnostics и профилю, а не по догадке.

Полный разбор: [[60 Go/Стеки и escape analysis|Стеки и escape analysis]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «В курсе `createPointer()` с отключённым inlining демонстрирует heap, а локальный `new(int)`, не escaping, — stack. Проверять нужно `go build -gcflags=-m=2` и production-like benchmark. Механизм разобран в заметке об escape analysis.» — [[CurseHunter/6609/09 Аллокатор#Задача курса|CurseHunter/6609/09 Аллокатор, раздел «Задача курса»]].
- «Базовые варианты — stack allocation, preallocation/capacity hint, reuse destination, grouping lifetime в arena и pool ограниченного размера. Их границы подробно разобраны в escape analysis и снижении аллокаций через reuse и `sync.Pool`. `sync.Pool` — GC-aware optional cache: runtime вправе удалить entries, размер не ограничен business policy, а object перед `Put` надо привести к безопасному состоянию. Это не allocator с гарантированным lifetime и не bounded cache.» — [[CurseHunter/6817/Бланк вопросов и заданий#6. Прямой вопрос: почему хвалятся `allocation-free`|CurseHunter/6817, раздел «6. Прямой вопрос: почему хвалятся `allocation-free`»]].
- «Точные модели `panic/recover`, slices, races, escape analysis и GC уже есть в defer, panic и recover, массивах и слайсах, race detector, стеках и escape analysis и GC pressure. Для идемпотентности платежей и POST-операций нужен полный protocol из заметки о ключах идемпотентности, а не только случайный token.» — [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Go и API — `00:22:43–00:33:03`|Telegram Собесы/M.Tech — 2026-07-17 — 350к, раздел «Go и API — `00:22:43–00:33:03`»]].
- «После подсказки кандидат вспомнил command-line report и различие stack/heap, но не объяснил dataflow/lifetime mechanism. Ожидаемая ментальная модель и инструменты собраны в заметке о стеках и escape analysis.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Escape analysis — `00:11:11–00:12:51`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Escape analysis — `00:11:11–00:12:51`»]].
- «Кандидат вспомнил LIFO, динамический stack около `2 KiB` и идею заранее нарезанных blocks, но не связал stack growth, escape analysis и allocator hierarchy. Направление роста адресов для reasoning не нужно: runtime может копировать user stack. См. стеки и escape analysis и аллокации и GC pressure.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Stack, heap и allocator spans — `00:16:00–00:19:10`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Stack, heap и allocator spans — `00:16:00–00:19:10`»]].
- «Escape/stack → GMP → memory model → GC.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Минимальный маршрут по vault»]].
- «Goroutines, threads и GMP соответствуют Goroutines и lifecycle, Планировщику GMP, Стекам и escape analysis и Netpoller.» — [[Telegram Собесы/Сбер — 2026-05-28 — 250к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Сбер — 2026-05-28 — 250к, раздел «Сопоставление с материалами vault»]].
- «Allocator, escape analysis, goroutine stacks и GC pressure: Стеки и escape analysis, Аллокации, GC и GC pressure, Стек, heap и виртуальная память.» — [[Авито/roadmap#Concurrency и runtime|Авито/roadmap, раздел «Concurrency и runtime»]].

- [[Telegram Собесы/АМТЕХ — 2026-04-06 — 350к/Бланк вопросов и заданий#Stack, heap и escape analysis — `00:43:44–00:51:37`|Stack, heap и escape analysis — `00:43:44–00:51:37`]] — точная проверенная формулировка технического блока интервью АМТЕХ.

- [[Telegram Собесы/CoinsPaid — 2026-04-27 — 6633 EUR/Бланк вопросов и заданий#Stack, heap, escape analysis и версии — `00:11:22–00:17:59`|Stack, heap, escape analysis и версии — `00:11:22–00:17:59`]] — точная проверенная формулировка соответствующего технического блока интервью.

- [[Telegram Собесы/Магнит — 2025-12-26 — 400к/Бланк вопросов и заданий#Stack, heap и escape analysis — `01:14:57–01:18:53`|Stack, heap и escape analysis — `01:14:57–01:18:53`]] — точная проверенная формулировка самостоятельного технического блока интервью.

- [[CurseHunter/6817/Бланк вопросов и заданий#7. Почему два почти одинаковых фрагмента дали разный escape analysis?|7. Почему два почти одинаковых фрагмента дали разный escape analysis?]] — точная формулировка вопроса курса 6817 из «Урок 10. Оптимизации в Go».

## Источники

- [runtime/stack.go: stack guards, minimum stack и growth machinery](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/stack.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [cmd/compile/internal/escape](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/cmd/compile/internal/escape/) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [Package runtime](https://pkg.go.dev/runtime@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Package unsafe: Pointer rules](https://pkg.go.dev/unsafe@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Go 1.26 Release Notes: compiler](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
