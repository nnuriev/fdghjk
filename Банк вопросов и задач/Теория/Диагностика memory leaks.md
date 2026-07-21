---
aliases:
  - "Теоретический вопрос: Диагностика memory leaks"
tags:
  - область/reliability-performance-operations
  - тема/диагностика
  - тема/производительность
  - технология/go
  - тип/вопрос
статус: проверено
---

# Диагностика memory leaks

## Вопрос

Разберите тему «Диагностика memory leaks»: какая ментальная модель помогает принять решение, какие trade-offs и failure modes нужно проверить?

## Короткий ориентир

Растущий RSS ещё не доказывает Go heap leak. Production-диагностика должна разделить live Go objects, allocation churn, goroutine/thread stacks, runtime metadata, страницы, не возвращённые ОС, и native/cgo/mmap memory. Для удержания важен устойчивый рост live heap после GC и diff двух сопоставимых `inuse_space` profiles; `alloc_space` отвечает на другой вопрос — сколько памяти было выделено за время процесса.

Если memory headroom позволяет, timebox-ните сбор metrics и двух sampled profiles до restart; при близком OOM containment имеет приоритет над полнотой evidence. Heap dump используйте только когда sampled evidence недостаточно и оправданы stop-the-world, размер и чувствительность содержимого. Обзор различий memory, CPU и goroutine leak уже есть в [[70 Практические кейсы/Memory, CPU и goroutine leaks|широкой заметке об утечках]]; здесь — отдельный runbook поиска retention path.

Полный разбор: [[70 Практические кейсы/Диагностика memory leaks|Диагностика memory leaks]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «В примерах этого урока память не потеряна для программы: объекты остаются достижимыми через маленький slice или pointer. Точнее называть это непреднамеренным retention, а не классической утечкой недостижимой памяти. Для диагностики полезна общая схема из runbook по memory leaks.» — [[CurseHunter/6754/Бланк вопросов и заданий#Урок 10. Retention и «утечки» памяти|CurseHunter/6754, раздел «Урок 10. Retention и «утечки» памяти»]].

- [[CurseHunter/6817/Бланк вопросов и заданий#13. Какие ошибки намеренно заложены в leak demo и как их найти по профилям?|13. Какие ошибки намеренно заложены в leak demo и как их найти по профилям?]] — точная формулировка вопроса курса 6817 из «Урок 12. Профилирование Go: contention, trace, PGO и continuous profiling».

## Источники

- [Package runtime/pprof](https://pkg.go.dev/runtime/pprof@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, heap/allocs sample indexes и момент snapshot, проверено 2026-07-18.
- [Исходный код heap/allocs profiles](https://github.com/golang/go/blob/go1.26.5/src/runtime/pprof/pprof.go) — репозиторий golang/go, tag `go1.26.5`, файл `src/runtime/pprof/pprof.go`, разделы `Heap profile` и `Allocs profile`, проверено 2026-07-18.
- [Package runtime/metrics](https://pkg.go.dev/runtime/metrics@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, memory classes, GC и stack metrics, проверено 2026-07-18.
- [A Guide to the Go Garbage Collector](https://go.dev/doc/gc-guide) — The Go Project, модель live heap, GC CPU и memory limit; living document явно описывает состояние collector для Go 1.19, проверено 2026-07-18.
- [Package runtime/debug](https://pkg.go.dev/runtime/debug@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, `WriteHeapDump` и `SetMemoryLimit`, проверено 2026-07-18.
- [Diagnostics](https://go.dev/doc/diagnostics) — The Go Project, heap profiling, runtime statistics и heap dump, проверено 2026-07-18.
- [Go 1.19 Release Notes](https://go.dev/doc/go1.19) — The Go Project, Go 1.19, введение soft memory limit, проверено 2026-07-18.
