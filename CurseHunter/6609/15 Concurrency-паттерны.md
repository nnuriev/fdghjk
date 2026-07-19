---
aliases:
  - CourseHunter 6609 — concurrency-паттерны
tags:
  - тип/разбор-курса
  - источник/coursehunter
  - язык/go
  - тема/concurrency-паттерны
статус: проверено
---

# Concurrency-паттерны: 7 задач курса

## Урок 111. Fan-in

![[90 Вложения/CurseHunter/6609/Кадры/111.jpg]]

`MergeChannels` запускает по goroutine на input, пересылает values в один output, а отдельная closer goroutine ждёт `WaitGroup` и закрывает output. Это правильное close ownership: workers не могут каждый закрывать общий channel.

Failure modes: nil input блокирует соответствующий worker навсегда; если consumer прекращает читать, forwarding goroutines зависают на `result <- value`. Production version принимает context/done и завершает sends через select.

## Урок 112. Fan-out

![[90 Вложения/CurseHunter/6609/Кадры/112.jpg]]

Показанный `SplitChannel` — deterministic round-robin router: один dispatcher последовательно отправляет `0,2,…` в первый output и `1,3,…` во второй. Это не обычный competing-workers fan-out, где несколько workers читают один channel и distribution определяется готовностью.

Минус round-robin: медленный consumer блокирует dispatcher и все outputs. Выбор между строгим распределением и work-conserving workers — явный trade-off.

## Урок 113. Worker pool

![[90 Вложения/CurseHunter/6609/Кадры/113.jpg]]

Курс ограничивает workers и очередь размером `workersNumber`; `AddTask` возвращает `pool is full`, то есть backpressure выражен reject policy. Нужно также определить panic isolation, cancellation, fairness, drain semantics и ownership `Close`.

**Ошибка source:** `Close` читает `wp.closed` до lock. Два concurrent callers оба увидят false и оба могут `close(tasksCh)`, получив panic. Проверку и изменение state выполняют под одним lock или через `sync.Once`; `AddTask` и Close должны иметь линейную точку, исключающую send-after-close.

Базовые варианты разобраны в [[60 Go/Worker pool, fan-in, fan-out и bounded concurrency|заметке о bounded concurrency]].

## Урок 114. Pipeline

![[90 Вложения/CurseHunter/6609/Кадры/114.jpg]]

`gen` создаёт stream, `mul` преобразует и закрывает свой output. Каждый stage закрывает только созданный им channel. Для полного чтения pipeline корректен, но ранний выход consumer оставляет upstream blocked на send. Поэтому reusable stage принимает context и select-ит send против cancellation.

## Урок 115. Синхронизация cache

![[90 Вложения/CurseHunter/6609/Кадры/115.jpg]]

Курс сочетает periodic full refresh, `RWMutex`, copy-on-refresh map и `singleflight` для одинаковых cache misses. Идея полезная, но код оставляет важные вопросы:

1. Initial load отсутствует: до первого minute tick каждый miss идёт в database.
2. `MGet` result индексируется по `keys` без проверки равной длины — возможен panic.
3. У `singleflight.Group.Do` context winning caller управляет общей DB operation. Его отмена может сорвать запрос всем; waiting callers сами не могут перестать ждать `Do`. Нужен explicit shared-flight policy/`DoChan` и select по caller context.
4. `withRetries` делает `defer cancel()` внутри loop, поэтому timers живут до выхода function; cancel вызывают сразу после attempt.
5. `time.Sleep` игнорирует context, отсутствует jitter, и sleep выполняется даже после последней неудачной attempt.
6. Full refresh заменяет map atomically под lock, но удаляет entries, которых не было в snapshot; нужно определить consistency contract и stale-data policy.

## Урок 116. Первый ответ от replicas

![[90 Вложения/CurseHunter/6609/Кадры/116.jpg]]

Одна goroutine на replica выполняет query, а buffered channel size 1 принимает первый результат; остальные non-blocking sends отбрасываются. Но database calls losers продолжаются, потому что interface не принимает context. Errors тоже отсутствуют, empty `replicas` блокирует навсегда, а медленный/hung backend течёт resources.

Рабочий hedged request принимает parent context, отменяет losers после приемлемого ответа, различает success/error, ограничивает concurrency и обрабатывает empty input. Запрос ко всем replicas повышает load; hedging обычно запускают после delay, а не одновременно всегда.

## Урок 117. Запрос по shards

![[90 Вложения/CurseHunter/6609/Кадры/117.jpg]]

`errgroup.WithContext` запускает запрос к каждому shard и возвращает первую error. Mutex защищает append results, но order nondeterministic.

**Проблемы source:** parent hardcoded `context.TODO`; `Database.Query` context не принимает; каждый group worker запускает ещё одну goroutine, которая продолжает query после cancellation. Buffered result channel предотвращает blocked send, но не останавливает backend. Нужен `Query(ctx, ...)`, прямой call внутри `group.Go`, parent context argument и заранее определённый output order/partial-result policy.

Пример из repository не компилируется standalone: отсутствуют dependency `golang.org/x/sync/errgroup` в `go.mod` и определения `ClickHouseDatabase`. То же относится к replica example с `PgSQLDatabase`; это ограничение материалов, а не ошибка Go.

## Источники

- [Go Concurrency Patterns: Pipelines and cancellation](https://go.dev/blog/pipelines) — Go project, проверено 2026-07-19.
- [Package errgroup](https://pkg.go.dev/golang.org/x/sync/errgroup) — Go project, проверено 2026-07-19.
- [Package singleflight](https://pkg.go.dev/golang.org/x/sync/singleflight) — Go project, проверено 2026-07-19.
- [Package context](https://pkg.go.dev/context) — Go standard library, проверено 2026-07-19.
- [Код модуля](https://github.com/Balun-courses/interview_go/tree/f562c12b4d0d85fd0b00cb662efc7f68edc96476/concurrency_patterns) — Balun-courses/interview_go, commit `f562c12`, проверено 2026-07-19.
