---
aliases:
  - "Теоретический вопрос: Race detector"
tags:
  - область/go
  - тема/конкурентность
  - тема/диагностика
  - тип/вопрос
статус: проверено
---

# Race detector

## Вопрос

Объясните тему «Race detector» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Race detector динамически находит [[60 Go/Data races, deadlocks и livelocks|data race]]: конфликтующие non-synchronizing memory accesses, между которыми нет [[60 Go/Модель памяти Go и happens-before|happens-before]], когда две goroutines обращаются к одной memory location и хотя бы одно обращение — write. Atomic operations образуют отдельный synchronization protocol. Флаг `-race` добавляет instrumentation и race runtime, поэтому проверяются только реально выполненные paths и interleavings. Найденный report — доказательство bug; отсутствие report не доказывает safety. Detector не ищет deadlocks, leaks и нарушения бизнес-инварианта, если все отдельные accesses уже синхронизированы.

Полный разбор: [[60 Go/Race detector|Race detector]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «Tests запускают много одновременных списаний с barrier start и проверяют conservation: число successes согласуется с итоговым balance, отрицательное значение невозможно. В защите сравнить linearization point, starvation/retry cost, расширяемость на несколько полей и crash durability. `go test -race` обязателен, но race detector не доказывает бизнес-инвариант.» — [[CurseHunter/6817/Бланк вопросов и заданий#Задание 2. Исправить условное списание|CurseHunter/6817, раздел «Задание 2. Исправить условное списание»]].
- «Channel protocol, map synchronization и диагностика покрывают Каналы или mutex, Map, Mutex и RWMutex и Race detector.» — [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Lamoda — 2026-06-10 — 400к, раздел «Сопоставление с материалами vault»]].
- «Точные модели `panic/recover`, slices, races, escape analysis и GC уже есть в defer, panic и recover, массивах и слайсах, race detector, стеках и escape analysis и GC pressure. Для идемпотентности платежей и POST-операций нужен полный protocol из заметки о ключах идемпотентности, а не только случайный token.» — [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Go и API — `00:22:43–00:33:03`|Telegram Собесы/M.Tech — 2026-07-17 — 350к, раздел «Go и API — `00:22:43–00:33:03`»]].
- «Mutex/RWMutex → memory model → race detector.» — [[Telegram Собесы/VK Tech — 2025-09-12 — 350к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/VK Tech — 2025-09-12 — 350к, раздел «Минимальный маршрут по vault»]].
- «Общий `sum` без synchronization и способ проверки рассмотрены в Race detector.» — [[Telegram Собесы/Редлаб — 2026-06-30 — 300к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Редлаб — 2026-06-30 — 300к, раздел «Сопоставление с материалами vault»]].
- «Горутины в цикле — loop-variable semantics, ожидание завершения и data race на общем максимуме. База: замыкания, lifecycle goroutine, happens-before, race detector, WaitGroup и Mutex.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «Race detector, CPU/heap/mutex profiles и execution trace: Race detector, Профилирование с pprof, Execution trace.» — [[Авито/roadmap#Тестирование и диагностика Go|Авито/roadmap, раздел «Тестирование и диагностика Go»]].

- [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Data race и race detector — `00:39:55–00:43:15`|Data race и race detector — `00:39:55–00:43:15`]] — точная проверенная формулировка соответствующего технического блока интервью.
- [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Race detector: что доказывает, а что нет|Race detector: что доказывает, а что нет]] — точная проверенная формулировка соответствующего технического блока интервью.

## Источники

- [Data Race Detector](https://go.dev/doc/articles/race_detector) — The Go Project, документация Go 1.26, проверено 2026-07-15.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
- [runtime/race.go и race runtime integration](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/race.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [cmd/compile/internal/ssagen/ssa.go: compiler race instrumentation](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/cmd/compile/internal/ssagen/ssa.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [Go 1.26 Release Notes: linux/riscv64 race detector](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
