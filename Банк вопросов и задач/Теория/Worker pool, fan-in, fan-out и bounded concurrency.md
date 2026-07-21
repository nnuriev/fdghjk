---
aliases:
  - "Теоретический вопрос: Worker pool, fan-in, fan-out и bounded concurrency"
tags:
  - область/go
  - тема/конкурентность
  - тип/вопрос
статус: проверено
---

# Worker pool, fan-in, fan-out и bounded concurrency

## Вопрос

Объясните тему «Worker pool, fan-in, fan-out и bounded concurrency» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Worker pool запускает фиксированное число workers и тем самым ограничивает число одновременно выполняемых работ. Fan-out распределяет вход между workers, fan-in собирает результаты. Корректный pipeline обязан определить ownership закрытия, остановку при раннем выходе consumer и верхнюю границу одновременно удерживаемой работы.

Полный разбор: [[60 Go/Worker pool, fan-in, fan-out и bounded concurrency|Worker pool, fan-in, fan-out и bounded concurrency]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/6593/03 Каналы, время и паттерны#Composable channel patterns|Composable channel patterns]] — исходный блок о pipeline lifecycle, merge и cancellation.
- «Базовые варианты разобраны в заметке о bounded concurrency.» — [[CurseHunter/6609/15 Concurrency-паттерны#Урок 113. Worker pool|CurseHunter/6609/15 Concurrency-паттерны, раздел «Урок 113. Worker pool»]].
- «Четвёртая задача является failure-сценарием из Worker pool и bounded concurrency и Goroutine и channel leaks, а production-проверка опирается на pprof.» — [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Lamoda — 2026-06-10 — 400к, раздел «Сопоставление с материалами vault»]].
- «| Merge N channels | fan-in/fan-out | Прямое совпадение паттерна fan-in; точного задания в папке решений нет |» — [[Telegram Собесы/Авито — 2026-04-20 — 470к/Бланк вопросов и заданий#Сопоставление с папкой «Авито»|Telegram Собесы/Авито — 2026-04-20 — 470к, раздел «Сопоставление с папкой «Авито»»]].
- «Сборка сниппета — две независимые цепочки вызовов, общий deadline и политика ошибок. База: fan-out/fan-in, context, ошибки, retry, circuit breaker.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «10 000 сетевых запросов — I/O concurrency с ограничением ресурса, ожиданием и безопасной агрегацией. База: bounded concurrency, sync/atomic, лимиты процесса, диагностика FD и соединений.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «Worker pool разделяет число inputs и число одновременно активных resources. Канал `jobs` — bounded handoff без накопления очереди, `workers` — concurrency budget, context — общий stop signal. Это частный случай bounded concurrency.» — [[Авито/Решения/Go-платформа/10 000 сетевых запросов#Ментальная модель|Авито/Решения/Go-платформа/10 000 сетевых запросов, раздел «Ментальная модель»]].
- «Для дорогой обработки inputs workers могут вычислять local maxima, а один reducer — общий максимум. Это уменьшает contention и позволяет bounded concurrency через worker pool.» — [[Авито/Решения/Go-платформа/Горутины в цикле#Trade-offs и альтернативы|Авито/Решения/Go-платформа/Горутины в цикле, раздел «Trade-offs и альтернативы»]].

- [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Semaphore, worker pool и goroutine leak — `00:43:15–00:56:13`|Semaphore, worker pool и goroutine leak — `00:43:15–00:56:13`]] — точная проверенная формулировка соответствующего технического блока интервью.

## Источники

- [Go Concurrency Patterns: Pipelines and cancellation](https://go.dev/blog/pipelines) — The Go Project, публикация 2014-03-13, проверено 2026-07-15.
- [Package sync](https://pkg.go.dev/sync@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
- [Go Language Specification — Channel types](https://go.dev/ref/spec#Channel_types) — The Go Project, language version Go 1.26, проверено 2026-07-15.
