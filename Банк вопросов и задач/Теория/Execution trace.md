---
aliases:
  - "Теоретический вопрос: Execution trace"
tags:
  - область/go
  - тема/runtime
  - тема/диагностика
  - тип/вопрос
статус: проверено
---

# Execution trace

## Вопрос

Объясните тему «Execution trace» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Execution trace записывает временную причинную картину runtime: создание, запуск, blocking и unblocking goroutines, syscalls, processor states, GC events, heap changes и пользовательские tasks/regions. Профиль [[60 Go/Профилирование с pprof|pprof]] отвечает на вопрос «где накопилась стоимость». Trace дополнительно отвечает на вопрос «что произошло раньше и почему следующая работа ждала». Цена — больший объём и overhead, поэтому capture ограничивают проблемным окном либо используют `runtime/trace.FlightRecorder` для snapshot последних событий.

Полный разбор: [[60 Go/Execution trace|Execution trace]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «Для точечной подготовки уже существуют Context, deadlines и распространение отмены, Data races, deadlocks и livelocks, Execution trace, B-tree и B+tree и Distributed cache и KV store. Это не делает интервью «аналогом Авито»: MERLION — широкий fundamentals/code-review screen, Авито — набор отдельных algorithm и platform exercises с более глубокой практической постановкой.» — [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Связь с материалами репозитория|Telegram Собесы/MERLION — 2025-07-29 — 300к, раздел «Связь с материалами репозитория»]].
- «Кандидат назвал «G-P model» и тем самым потерял M, хотя дальше говорил про OS threads. Local queue он описал близко к истине. Ответ про mutex waiters был слишком общим, а network poller почти не раскрыт. Полная модель: GMP scheduler, netpoller и execution trace.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Scheduler, blocking и netpoll — `00:12:53–00:14:40`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Scheduler, blocking и netpoll — `00:12:53–00:14:40`»]].
- «Race detector, CPU/heap/mutex profiles и execution trace: Race detector, Профилирование с pprof, Execution trace.» — [[Авито/roadmap#Тестирование и диагностика Go|Авито/roadmap, раздел «Тестирование и диагностика Go»]].

- [[CurseHunter/6817/Бланк вопросов и заданий#5. Чем execution trace отличается от pprof и когда он нужен?|5. Чем execution trace отличается от pprof и когда он нужен?]] — точная формулировка вопроса курса 6817 из «Урок 12. Профилирование Go: contention, trace, PGO и continuous profiling».
- [[CurseHunter/6817/Бланк вопросов и заданий#6. Что показывает Minimum Mutator Utilization и как читать эксперимент с `sync.Pool`?|6. Что показывает Minimum Mutator Utilization и как читать эксперимент с `sync.Pool`?]] — точная формулировка вопроса курса 6817 из «Урок 12. Профилирование Go: contention, trace, PGO и continuous profiling».

## Источники

- [Package runtime/trace](https://pkg.go.dev/runtime/trace@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Diagnostics: Execution tracer](https://go.dev/doc/diagnostics) — The Go Project, документация Go 1.26, проверено 2026-07-15.
- [cmd/trace documentation and supported pprof types](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/cmd/trace/doc.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/trace implementation](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/trace/) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [Go 1.25 Release Notes: Trace flight recorder](https://go.dev/doc/go1.25) — The Go Project, Go 1.25, проверено 2026-07-15.
