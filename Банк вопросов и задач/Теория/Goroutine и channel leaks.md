---
aliases:
  - "Теоретический вопрос: Goroutine и channel leaks"
tags:
  - область/go
  - тема/конкурентность
  - тип/вопрос
статус: проверено
---

# Goroutine и channel leaks

## Вопрос

Объясните тему «Goroutine и channel leaks» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Goroutine leak возникает, когда goroutine больше не нужна владельцу, но не может достичь `return`: обычно она навсегда ждёт receive, send, lock или I/O. Channel сам освобождается GC, когда недостижим; «channel leak» практически означает потерянный протокол, из-за которого goroutines или buffered values остаются достижимыми.

Полный разбор: [[60 Go/Goroutine и channel leaks|Goroutine и channel leaks]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/6593/03 Каналы, время и паттерны#Как возникает goroutine leak?|Как возникает goroutine leak?]] — набор failure-сценариев blocked send/receive и отсутствующей cancellation.
- «Во втором first-response-wins пять goroutines send в unbuffered channel, а caller принимает одно value; четыре losers блокируются навсегда. Buffer size 1 спасает только одного sender. Используют buffer на число producers, cancellation, non-blocking loser send или errgroup. Практические patterns — в заметке о goroutine leaks.» — [[CurseHunter/6609/13 Каналы#Урок 101. Goroutine leaks|CurseHunter/6609/13 Каналы, раздел «Урок 101. Goroutine leaks»]].
- «Четвёртая задача является failure-сценарием из Worker pool и bounded concurrency и Goroutine и channel leaks, а production-проверка опирается на pprof.» — [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Lamoda — 2026-06-10 — 400к, раздел «Сопоставление с материалами vault»]].
- «Для большого списка нужен concurrency limit: без него программа одновременно создаёт столько goroutines и сетевых операций, сколько URL пришло на вход. Отмена и безопасная отправка защищают от утечек goroutines, но не заменяют backpressure.» — [[Telegram Собесы/Ozon — 2026-07-03 — 300к/Бланк вопросов и заданий#Остановка после двух успехов|Telegram Собесы/Ozon — 2026-07-03 — 300к, раздел «Остановка после двух успехов»]].
- «| HTTP + cancellation | HTTP-клиент и Transport и Goroutine и channel leaks | Прямое совпадение resource lifetime и cancellation | Ozon поэтапно доводит задачу до channel lifecycle и остановки после двух success |» — [[Telegram Собесы/Ozon — 2026-07-03 — 300к/Бланк вопросов и заданий#Сопоставление с материалами репозитория|Telegram Собесы/Ozon — 2026-07-03 — 300к, раздел «Сопоставление с материалами репозитория»]].
- «Timeout-wrapper над неотменяемой функцией — bounded wait не означает отмену работы; buffered result channel не оставляет producer заблокированным. База: select и timeout, goroutine leaks, буферизация каналов.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «Если `fn` может зависнуть навсегда, повторные timeout calls создают unbounded число goroutines: memory растёт `O(number of never-returning calls)`. Это goroutine leak, а не полноценная cancellation.» — [[Авито/Решения/Go-платформа/Timeout-wrapper над неотменяемой функцией#Сложность и ресурсы|Авито/Решения/Go-платформа/Timeout-wrapper над неотменяемой функцией, раздел «Сложность и ресурсы»]].

## Источники

- [Package context — WithCancel example](https://pkg.go.dev/context@go1.26.5#example-WithCancel) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
- [Go Concurrency Patterns: Pipelines and cancellation](https://go.dev/blog/pipelines) — The Go Project, публикация 2014-03-13, проверено 2026-07-15.
- [Go Language Specification — Channel types](https://go.dev/ref/spec#Channel_types) — The Go Project, language version Go 1.26, проверено 2026-07-15.
