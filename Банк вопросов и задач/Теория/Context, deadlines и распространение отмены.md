---
aliases:
  - "Теоретический вопрос: Context, deadlines и распространение отмены"
tags:
  - область/go
  - тема/конкурентность
  - тип/вопрос
статус: проверено
---

# Context, deadlines и распространение отмены

## Вопрос

Объясните тему «Context, deadlines и распространение отмены» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

`context.Context` переносит через API request-scoped deadline, cancellation signal, cause и редкие request-scoped values. `WithCancel`, `WithDeadline` и `WithTimeout` образуют дерево: отмена parent отменяет descendants; `WithoutCancel` намеренно разрывает наследование cancellation и deadline. Вызов `cancel` лишь публикует сигнал и освобождает связанные ресурсы; он не ждёт фактической остановки goroutines.

Полный разбор: [[60 Go/Context, deadlines и распространение отмены|Context, deadlines и распространение отмены]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/6593/04 Context и модель памяти#Контракт `Context`|Контракт `Context`]] — исходный блок о cancellation tree, deadlines и ownership `cancel`.
- [[CurseHunter/6593/04 Context и модель памяти#Как распространяется отмена|Как распространяется отмена]] — вопрос о parent-child propagation.
- [[CurseHunter/6593/04 Context и модель памяти#Почему всегда вызывают `cancel`|Почему всегда вызывают `cancel`]] — вопрос об освобождении timer и ссылки parent на child.
- [[CurseHunter/6593/04 Context и модель памяти#`Err` и `Cause`|`Err` и `Cause`]] — сравнительная формулировка stable category и domain cause.
- [[CurseHunter/6593/04 Context и модель памяти#`WithoutCancel`|`WithoutCancel`]] — вопрос о detached cancellation при сохранении values.
- [[CurseHunter/6860/05 Контексты, итераторы и Swiss Tables#Контексты: вопросы из урока|Контексты: вопросы из урока]] — вопросы о cancellation tree, deadlines, causes, values, HTTP/database integration, graceful shutdown и `errgroup`.
- «Context передают первым argument, не хранят в long-lived struct без особой причины и не используют как мешок optional parameters. Модель распространения — в заметке о context.» — [[CurseHunter/6609/14 Контексты#Урок 106. Что предоставляет `context.Context`|CurseHunter/6609/14 Контексты, раздел «Урок 106. Что предоставляет `context.Context`»]].
- «Cancellation и HTTP resource lifecycle связывают Context, deadlines и распространение отмены, HTTP-клиент и Transport и Тайм-ауты HTTP-клиента.» — [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Lamoda — 2026-06-10 — 400к, раздел «Сопоставление с материалами vault»]].
- «Для точечной подготовки уже существуют Context, deadlines и распространение отмены, Data races, deadlocks и livelocks, Execution trace, B-tree и B+tree и Distributed cache и KV store. Это не делает интервью «аналогом Авито»: MERLION — широкий fundamentals/code-review screen, Авито — набор отдельных algorithm и platform exercises с более глубокой практической постановкой.» — [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Связь с материалами репозитория|Telegram Собесы/MERLION — 2025-07-29 — 300к, раздел «Связь с материалами репозитория»]].
- «Сборка сниппета — две независимые цепочки вызовов, общий deadline и политика ошибок. База: fan-out/fan-in, context, ошибки, retry, circuit breaker.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «Параллельный запрос URL — `http.Client`, `httptest`, отмена sibling requests и ограничение числа in-flight запросов. База: HTTP client/Transport, HTTP timeouts, cancellation, connection pools.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «`context.Context`, deadlines и обязательный вызов `CancelFunc`: Context, deadlines и распространение отмены.» — [[Авито/roadmap#Concurrency и runtime|Авито/roadmap, раздел «Concurrency и runtime»]].

- [[Telegram Собесы/Adcamp — 2026-03-23 — 280к/Бланк вопросов и заданий#`context` — `00:24:59–00:26:21`|`context` — `00:24:59–00:26:21`]] — точная проверенная формулировка соответствующего технического блока интервью.
- [[Telegram Собесы/Adcamp — 2026-03-23 — 280к/Бланк вопросов и заданий#`context` и tracing|`context` и tracing]] — точная проверенная формулировка соответствующего технического блока интервью.

## Источники

- [Package context](https://pkg.go.dev/context@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
- [The Go Memory Model — Channel communication](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
