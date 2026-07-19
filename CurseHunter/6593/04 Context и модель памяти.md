---
aliases:
  - CourseHunter 6593 — context и memory model
tags:
  - источник/coursehunter
  - язык/go
  - тема/concurrency/context
  - тема/concurrency/memory-model
статус: проверено
---

# Context и модель памяти

## TL;DR

`context.Context` переносит deadline, cancellation signal и request-scoped values через границы API. Он не убивает goroutine и не откатывает побочный эффект: код должен наблюдать `Done`, проверять `Err` или передавать context в context-aware I/O.

Go memory model отвечает на другой вопрос: какую запись может наблюдать concurrent read. Если между конфликтующими ordinary accesses нет happens-before, программа содержит data race. `Sleep`, «обычно успевает» и конкретный порядок на одном запуске это не исправляют.

## Контракт `Context`

### Как распространяется отмена

Derived context хранит связь с parent. Отмена parent отменяет descendants; отмена child не отменяет parent или siblings. Первый сработавший parent cancellation, child cancellation или deadline определяет завершение child.

### Почему всегда вызывают `cancel`

Даже если parent когда-нибудь завершится, ранний `cancel` удаляет child из parent и останавливает связанные timer/resources. Поэтому `defer cancel()` ставят сразу после успешного `WithCancel`, `WithTimeout` или `WithDeadline`.

### `Err` и `Cause`

- `Err` сообщает категорию: `context.Canceled` или `context.DeadlineExceeded`.
- `context.Cause` возвращает записанную причину для API `WithCancelCause`, `WithTimeoutCause` и `WithDeadlineCause`.
- Первая отмена в соответствующей цепочке фиксирует cause; поздняя причина не переписывает уже установленную.

### `WithValue`

Context values предназначены для request-scoped metadata, которая проходит через процессы и API: trace ID, auth principal, tenant. Это не optional parameters и не service locator.

Key должен быть comparable и отдельного пользовательского типа, а не встроенного `string`, иначе разные packages могут столкнуться по одинаковому значению.

![[90 Вложения/CurseHunter/6593/Кадры/029-context-values.jpg|720]]

### `WithoutCancel`

Добавленный в Go `1.21` `context.WithoutCancel(parent)` наследует values, но не deadline/cancellation: `Done()` возвращает `nil`, `Err()` и `Cause()` — `nil`. Он полезен для аккуратно отделённой post-request работы, но без собственного timeout легко создаёт бесконечную background task.

### Можно ли передавать `nil` context?

Нет. Когда неизвестно, какой context использовать, передают `context.TODO()`. Публичная функция обычно принимает `ctx` первым параметром и не хранит его в struct без веской lifecycle-причины.

## HTTP и отмена реальной работы

- Incoming `http.Request.Context()` отменяется при разрыве клиента и завершении handler lifecycle по контракту `net/http`.
- Outgoing request создают через `NewRequestWithContext` либо `req.WithContext`, чтобы transport мог отменить I/O.
- Обёртка `select { case <-ctx.Done(): return }` вокруг функции, не принимающей context, прекращает только ожидание caller; сама функция продолжит работу.
- После отмены результат всё ещё может прийти. Producer должен иметь buffered result channel, cancellation-aware send или быть явно join-нут.

## Graceful shutdown

Правильная последовательность:

1. перестать принимать новую работу;
2. отменить root context;
3. дождаться owners всех goroutine;
4. дать in-flight запросам ограниченный shutdown deadline;
5. flush/close зависимости в порядке, обратном их созданию;
6. после deadline перейти к принудительному завершению и оставить диагностику.

Отмена context — только шаг 2. Без `WaitGroup`, `errgroup`, `Server.Shutdown` или другого join protocol процесс может выйти раньше cleanup.

## Модель памяти

### DRF-SC

Для data-race-free программы Go гарантирует поведение, объяснимое sequentially consistent interleaving goroutine. Это не означает, что все goroutine физически выполняются последовательно; это модель наблюдаемого результата при корректной синхронизации.

### Happens-before

Happens-before — transitive closure двух отношений:

- sequenced-before внутри goroutine;
- synchronized-before между synchronization operations.

Для ordinary read значение гарантировано, когда нужная write видима через happens-before и не перекрыта более поздней видимой write.

### Ошибка `data + done bool`

```go
var data string
var done bool

go func() {
    data = "ready"
    done = true
}()

for !done {}
fmt.Println(data)
```

Здесь две data race. Наблюдение `done == true` не обязано публиковать `data`, а loop не обязан когда-либо увидеть новую write. Исправления:

- передать результат через channel;
- защитить оба поля одним mutex;
- использовать `sync.Once` для инициализации;
- построить полный atomic state protocol, где публикация и чтение соответствуют документированному инварианту.

### Что означают memory barriers в курсе

Слайды LoadLoad, LoadStore, StoreStore и StoreLoad описывают низкоуровневые ограничения reorder. В Go application code обычно не вставляет CPU fence вручную. Он использует операции, для которых memory model уже задаёт synchronized-before: channel, mutex, Once и atomics.

![[90 Вложения/CurseHunter/6593/Кадры/030-memory-barriers.jpg|720]]

Все операции `sync/atomic` в Go ведут себя так, будто находятся в одном sequentially consistent порядке. Поэтому перенос C++ `relaxed/acquire/release` один к одному в Go-код курса был бы неверным.

## Интервью-задачи

1. Провести propagation cancellation по дереву из parent, двух siblings и grandchild.
2. Объяснить, чей cause увидит child при почти одновременной отмене parent и child.
3. Найти утечку timer из-за потерянного `cancel`.
4. Исправить `WithValue(ctx, "user", ...)` между двумя packages.
5. Убрать config/logger/database из context values и оставить request metadata.
6. Добавить context в HTTP client и доказать, что отменяется именно transport operation.
7. Исправить timeout wrapper, где underlying query продолжает работать.
8. Спроектировать post-response audit task через `WithoutCancel` + новый bounded timeout.
9. Реализовать graceful shutdown server, worker pool и DB в правильном порядке.
10. Найти data race в `data + done bool` и провести happens-before после исправления.
11. Объяснить, почему `time.Sleep` не создаёт synchronized-before.
12. Показать publication immutable snapshot через `atomic.Pointer[T]` и запретить последующую мутацию.
13. Объяснить, почему два atomic поля могут давать бизнес-неконсистентную пару.
14. Сопоставить send/receive, close/receive, unlock/lock и Once с happens-before edges.
15. Отличить compiler/CPU reordering от недетерминированного scheduler order и от data race.

## Источники

- [Код урока 7](https://github.com/Balun-courses/concurrency_go/tree/47dfb8919653eb9528bd6fa5b4fadc2d38a56598/lessons/7_lesson_contexts_and_memory_barriers) — Balun-courses/concurrency_go, commit `47dfb89`, проверено 2026-07-19.
- [Package context](https://pkg.go.dev/context) — Go standard library, Go `1.26.5`, проверено 2026-07-19.
- [Go Concurrency Patterns: Context](https://go.dev/blog/context) — Go project, 2014-07-29, проверено 2026-07-19.
- [The Go Memory Model](https://go.dev/ref/mem) — Go project, версия документа от 2022-06-06, проверено 2026-07-19.
- [Package sync/atomic](https://pkg.go.dev/sync/atomic) — Go standard library, Go `1.26.5`, проверено 2026-07-19.
- [Package net/http](https://pkg.go.dev/net/http) — Go standard library, Go `1.26.5`, проверено 2026-07-19.
