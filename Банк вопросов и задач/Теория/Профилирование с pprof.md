---
aliases:
  - "Теоретический вопрос: Профилирование с pprof"
tags:
  - область/go
  - тема/диагностика
  - тема/производительность
  - тип/вопрос
статус: проверено
---

# Профилирование с pprof

## Вопрос

Объясните тему «Профилирование с pprof» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Pprof агрегирует samples или events по stack traces и отвечает «где накапливается CPU, memory allocation или blocking cost». CPU profile показывает sampled on-CPU stacks; heap и allocs различают live memory и cumulative allocation churn; block и mutex profiles показывают разные причины ожидания. Pprof не хранит полную временную последовательность — для causal timeline нужен [[60 Go/Execution trace|execution trace]]. Сначала выбирайте правильный profile и sample index, затем проверяйте `top`, call graph и source view; проценты без понимания denominator легко приводят к неверной оптимизации.

Полный разбор: [[60 Go/Профилирование с pprof|Профилирование с pprof]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «alloc/heap profile из pprof показывает allocation traffic и retained live set;» — [[CurseHunter/6817/Бланк вопросов и заданий#6. Прямой вопрос: почему хвалятся `allocation-free`|CurseHunter/6817, раздел «6. Прямой вопрос: почему хвалятся `allocation-free`»]].
- «Четвёртая задача является failure-сценарием из Worker pool и bounded concurrency и Goroutine и channel leaks, а production-проверка опирается на pprof.» — [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Lamoda — 2026-06-10 — 400к, раздел «Сопоставление с материалами vault»]].
- «Race detector, CPU/heap/mutex profiles и execution trace: Race detector, Профилирование с pprof, Execution trace.» — [[Авито/roadmap#Тестирование и диагностика Go|Авито/roadmap, раздел «Тестирование и диагностика Go»]].

- [[Telegram Собесы/CoinsPaid — 2026-04-27 — 6633 EUR/Бланк вопросов и заданий#Profiling story — `01:21:01–01:25:27`|Profiling story — `01:21:01–01:25:27`]] — точная проверенная формулировка соответствующего технического блока интервью.

- [[Telegram Собесы/Plata — 2026-04-13 — 4252 EUR/Бланк вопросов и заданий#Profiling, escape analysis и PGO — `00:28:48–00:32:40`|Profiling, escape analysis и PGO — `00:28:48–00:32:40`]] — точная проверенная формулировка самостоятельного технического блока интервью.

- [[CurseHunter/6817/Бланк вопросов и заданий#1. Чем instrumentation отличается от sampling и когда выбирать каждый подход?|1. Чем instrumentation отличается от sampling и когда выбирать каждый подход?]] — точная формулировка вопроса курса 6817 из «Урок 11. Основы профилирования Go и CPU pprof».
- [[CurseHunter/6817/Бланк вопросов и заданий#2. Как устроен CPU profiler Go и зачем ему lock-free `profBuf`?|2. Как устроен CPU profiler Go и зачем ему lock-free `profBuf`?]] — точная формулировка вопроса курса 6817 из «Урок 11. Основы профилирования Go и CPU pprof».
- [[CurseHunter/6817/Бланк вопросов и заданий#3. Какой Go profile выбирать по наблюдаемому симптому?|3. Какой Go profile выбирать по наблюдаемому симптому?]] — точная формулировка вопроса курса 6817 из «Урок 11. Основы профилирования Go и CPU pprof».
- [[CurseHunter/6817/Бланк вопросов и заданий#4. Чем программный `runtime/pprof` отличается от `net/http/pprof`?|4. Чем программный `runtime/pprof` отличается от `net/http/pprof`?]] — точная формулировка вопроса курса 6817 из «Урок 11. Основы профилирования Go и CPU pprof».
- [[CurseHunter/6817/Бланк вопросов и заданий#5. Что означают profile rates и почему значение `1` опасно оставлять постоянно?|5. Что означают profile rates и почему значение `1` опасно оставлять постоянно?]] — точная формулировка вопроса курса 6817 из «Урок 11. Основы профилирования Go и CPU pprof».
- [[CurseHunter/6817/Бланк вопросов и заданий#6. Как читать `Duration`, `Total samples`, `flat` и `cum`?|6. Как читать `Duration`, `Total samples`, `flat` и `cum`?]] — точная формулировка вопроса курса 6817 из «Урок 11. Основы профилирования Go и CPU pprof».
- [[CurseHunter/6817/Бланк вопросов и заданий#7. Почему line view и disassembly не являются точным таймером строки Go?|7. Почему line view и disassembly не являются точным таймером строки Go?]] — точная формулировка вопроса курса 6817 из «Урок 11. Основы профилирования Go и CPU pprof».
- [[CurseHunter/6817/Бланк вопросов и заданий#8. Как собрать профиль, которому можно доверять, и использовать его для regression/PGO?|8. Как собрать профиль, которому можно доверять, и использовать его для regression/PGO?]] — точная формулировка вопроса курса 6817 из «Урок 11. Основы профилирования Go и CPU pprof».
- [[CurseHunter/6817/Бланк вопросов и заданий#1. Чем `allocs` отличается от `heap`, а `objects` — от `space`?|1. Чем `allocs` отличается от `heap`, а `objects` — от `space`?]] — точная формулировка вопроса курса 6817 из «Урок 12. Профилирование Go: contention, trace, PGO и continuous profiling».
- [[CurseHunter/6817/Бланк вопросов и заданий#4. Зачем named profiles собирать как delta и почему в них виден сам HTTP collector?|4. Зачем named profiles собирать как delta и почему в них виден сам HTTP collector?]] — точная формулировка вопроса курса 6817 из «Урок 12. Профилирование Go: contention, trace, PGO и continuous profiling».
- [[CurseHunter/6817/Бланк вопросов и заданий#7. Какие форматы goroutine profile выбирать для incident и continuous profiling?|7. Какие форматы goroutine profile выбирать для incident и continuous profiling?]] — точная формулировка вопроса курса 6817 из «Урок 12. Профилирование Go: contention, trace, PGO и continuous profiling».
- [[CurseHunter/6817/Бланк вопросов и заданий#9. Как выглядит воспроизводимый PGO workflow и почему нужен representative profile?|9. Как выглядит воспроизводимый PGO workflow и почему нужен representative profile?]] — точная формулировка вопроса курса 6817 из «Урок 12. Профилирование Go: contention, trace, PGO и continuous profiling».
- [[CurseHunter/6817/Бланк вопросов и заданий#10. Насколько PGO устойчив к изменению исходников?|10. Насколько PGO устойчив к изменению исходников?]] — точная формулировка вопроса курса 6817 из «Урок 12. Профилирование Go: contention, trace, PGO и continuous profiling».
- [[CurseHunter/6817/Бланк вопросов и заданий#11. Чем `-diff_base`, `-base` и `-normalize` отличаются друг от друга?|11. Чем `-diff_base`, `-base` и `-normalize` отличаются друг от друга?]] — точная формулировка вопроса курса 6817 из «Урок 12. Профилирование Go: contention, trace, PGO и continuous profiling».
- [[CurseHunter/6817/Бланк вопросов и заданий#12. Что даёт continuous profiling и какую цену нужно заложить?|12. Что даёт continuous profiling и какую цену нужно заложить?]] — точная формулировка вопроса курса 6817 из «Урок 12. Профилирование Go: contention, trace, PGO и continuous profiling».

## Источники

- [Package runtime/pprof](https://pkg.go.dev/runtime/pprof@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Package net/http/pprof](https://pkg.go.dev/net/http/pprof@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Diagnostics: Profiling](https://go.dev/doc/diagnostics) — The Go Project, документация Go 1.26, проверено 2026-07-15.
- [runtime/pprof/pprof.go: predefined profile semantics](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/pprof/pprof.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/mprof.go: MemProfile lag](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/mprof.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [Go 1.25 Release Notes: mutex profile](https://go.dev/doc/go1.25) — The Go Project, Go 1.25, проверено 2026-07-15.
- [Go 1.26 Release Notes: pprof UI and goroutineleak profile](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
