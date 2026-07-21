---
aliases:
  - Контексты, итераторы и Swiss Tables — CourseHunter 6860
tags:
  - тип/разбор-курса
  - источник/coursehunter
  - язык/go
  - тема/context
  - тема/итераторы
  - тема/map
статус: проверено
---

# Контексты, итераторы и Swiss Tables

## TL;DR

Context распространяет cancellation, deadline и request-scoped metadata по call tree; он не убивает работу сам. Range-over-function iterator передаёт elements через `yield` и обязан остановиться после `false`. Swiss map с Go `1.24` заменяет старую bucket/overflow модель: groups по 8 slots, control word с H2, probing и directory из ограниченных tables. Финальный урок курса соединяет все три темы, хотя его название упоминает только contexts.

## Контексты: вопросы из урока

1. Какие четыре операции задаёт `context.Context`: `Deadline`, `Done`, `Err`, `Value`?
2. Почему interface, а не concrete `*Context`, является public contract?
3. Как cancellation распространяется от parent к descendants?
4. Почему `cancel` нужно вызывать даже при timeout?
5. Чем `WithCancel`, `WithDeadline`, `WithTimeout`, `WithCancelCause`, `WithTimeoutCause` различаются?
6. Как safely close `Done` ровно один раз в учебной реализации context?
7. Почему функция должна принимать context первым argument и не хранить его в struct без веской причины?
8. Почему `nil` context недопустим и когда использовать `context.TODO`?
9. Почему `context.Background` предназначен для top-level root, а не для разрыва caller cancellation внутри library?
10. Какие values допустимо передавать через context?
11. Почему key должен иметь private type и typed accessor?
12. Что наследует `context.WithoutCancel`, а что отрезает?
13. Как передать context в HTTP client/server и database operation?
14. Как `signal.NotifyContext` участвует в graceful shutdown?
15. Почему timeout вокруг wrapper не прекращает dependency, если dependency не принимает context?
16. Как `errgroup.WithContext` отменяет sibling goroutines после первой ошибки?

Основные задачи про cancellation, HTTP и timeout уже разобраны в [[CurseHunter/6609/14 Контексты]]. Здесь главный новый практический блок — собственный errgroup.

## Задание 15. Упрощённый errgroup

### Происхождение задания

Отдельного слайда «Домашнее задание №15» в видео нет. В уроке показано использование `golang.org/x/sync/errgroup.WithContext`, а точный шаблон задачи находится в [`homework/contexts`](https://github.com/Balun-courses/deep_go/blob/aacfeb63b810479f98cebcaa16a444e3c8710ee0/homework/contexts/homework_test.go) репозитория курса.

```go
type Group struct { /* ... */ }

func NewErrGroup(ctx context.Context) (*Group, context.Context)
func (g *Group) Go(action func() error)
func (g *Group) Wait() error
```

Без ошибок `Wait` ждёт пять functions и возвращает `nil`. Если дополнительная function сразу возвращает error, derived context отменяется; пять siblings выбирают `ctx.Done` и не увеличивают counter; `Wait` возвращает error.

### State и protocol

Минимальные компоненты:

- `context.WithCancel(parent)` и сохранённая `cancel`;
- `sync.WaitGroup` для всех launched functions;
- `sync.Once` для публикации первой non-nil error;
- поле `err`, записываемое внутри `Once`.

`Go` делает `Add(1)` до запуска goroutine. Wrapper вызывает action, а при первой non-nil error атомарно сохраняет именно её и вызывает cancel. `defer Done` выполняется независимо от result. `Wait` ждёт всех и вызывает cancel для release resources даже при успехе.

### Главный race результата

После первой business error siblings часто возвращают `context.Canceled`. Если каждая goroutine без координации записывает `g.err`, outcome станет timing-dependent. `sync.Once` фиксирует первую observed error; функция, которая инициировала cancel, должна записать error до вызова cancel, чтобы производные cancellation errors не победили её.

### Contract gaps

- Разрешён ли `Go` одновременно с `Wait`?
- Можно ли повторно вызвать `Wait`?
- Что происходит при panic action?
- Возвращается ли parent cancellation как group error, если actions вернули `nil`?
- Нужен ли concurrency limit?

Стандартный `errgroup.Group` уже решает основной protocol и поддерживает `SetLimit/TryGo`. Собственная версия полезна как упражнение, но не как замена без дополнительной причины.

### Уточнения интервьюера

- Почему `WaitGroup` сам не хранит errors?
- Когда `context.Cause` полезнее `ctx.Err()`?
- Как гарантировать cleanup при раннем return caller?
- Как ограничить параллелизм, не создавая goroutine до admission?

## Итераторы Go 1.23

После context-блока урок переходит к range-over-function, добавленному в Go `1.23`.

![[90 Вложения/CurseHunter/6860/Кадры/15-iterators-contract.jpg|720]]

### Контракт языка

`for range` принимает функции форм:

```go
func(func() bool)
func(func(K) bool)
func(func(K, V) bool)
```

Пакет `iter` даёт имена двум частым вариантам:

```go
type Seq[V any]     func(yield func(V) bool)
type Seq2[K, V any] func(yield func(K, V) bool)
```

Producer вызывает `yield` для каждого element. `true` означает «продолжать», `false` — loop body завершил iteration через `break`, return или panic, и producer обязан немедленно прекратить вызовы.

### Минимальный invariant producer

```go
func Backward[T any](s []T) iter.Seq[T] {
    return func(yield func(T) bool) {
        for i := len(s) - 1; i >= 0; i-- {
            if !yield(s[i]) {
                return
            }
        }
    }
}
```

Ошибочный producer игнорирует return value `yield` и продолжает iteration; runtime обнаруживает нарушение protocol и panic.

### Почему concurrent yield ломает protocol

![[90 Вложения/CurseHunter/6860/Кадры/16-iterator-concurrent-yield-panic.jpg|720]]

Курс показывает запуск `yield` из нескольких goroutines. Это не превращает sequence в parallel iterator: loop body и compiler-generated state machine не рассчитаны на concurrent calls. После завершения loop одна goroutine может вызвать `yield` снова, что приводит к `range function continued iteration...` panic. Даже если panic случайно не проявился, ordering и synchronization остаются недоопределёнными.

Если нужно parallel processing:

1. iterator последовательно перечисляет work;
2. отдельный bounded worker pool выполняет tasks;
3. ordering/results задаются явным protocol;
4. cancellation останавливает producer и workers.

### Resources и errors

Лекция рассматривает iterator над database rows. Resource owner должен гарантировать `rows.Close` при normal exhaustion и раннем `break`. Возможные API:

- `Seq2[T,error]`, где каждый step отдаёт value/error;
- iterator closure захватывает rows и делает `defer Close`;
- outer constructor возвращает initial query error отдельно;
- cleanup function возвращается явно, если iterator не владеет resource.

Нельзя вернуть iterator, который молча держит connection, и надеяться, что caller обязательно дойдёт до конца. Ownership должен быть виден в contract.

### Pipeline

`iter.Seq` позволяет lazy composition:

```text
Range → Map/Mul → Filter → consumer
```

Каждый stage вызывает upstream только по мере запроса downstream и прокидывает `false` назад. Это избегает intermediate slices, но усложняет debugging и single-use resource lifetimes. Для небольших in-memory collections обычный slice часто проще.

### Вопросы для интервью

1. Чем push iterator отличается от pull iterator и что делает `iter.Pull`?
2. Почему iterator может быть single-use?
3. Кто закрывает captured resource при раннем break?
4. Как передать error, не смешав её с обычным element?
5. Когда `slices.Collect` возвращает materialized snapshot?
6. Почему benchmark одного тривиального loop не доказывает преимущество iterator для workload?

## Swiss Tables в Go 1.24

Урок 4 подробно объясняет старую `hmap/bmap` модель, а в приложении урока 15 показывает актуальный переход Go `1.24`.

![[90 Вложения/CurseHunter/6860/Кадры/17-swiss-table-h2.jpg|720]]

### Ментальная модель

Swiss Table — open-addressed hash table. В реализации Go `1.24`:

- **slot** хранит key/value;
- **group** содержит 8 slots и 8-byte control word;
- control byte отмечает empty/deleted/used, а для used хранит нижние 7 bits hash — H2;
- H1 — верхние 57 bits hash — выбирает initial group/probe path;
- lookup сравнивает искомый H2 со всеми восемью control bytes параллельно с помощью word-level bit tricks, затем full key проверяется только у candidates;
- tombstone сохраняет probe chain после delete;
- map состоит из directory и одной или нескольких независимых Swiss tables.

H2 match не доказывает равенство key: вероятность collision по 7 bits остаётся, поэтому нужен full comparison.

### Почему несколько tables

Классическая Swiss Table обычно grows целиком, что создаёт большой latency spike. Go сохраняет incremental-growth property через extendible hashing: одна table хранит максимум 1024 entries. При growth splitting/copying ограничен этой table, а не всей map; directory верхними hash bits выбирает table.

Таким образом, дополнительная indirection покупает bounded single-insert growth work, важный для latency-sensitive servers.

### Small map и iteration

До восьми entries map может жить в одной group без обычного directory array. Go language contract по-прежнему не определяет iteration order и допускает определённые modifications during iteration; новая implementation обязана сохранить semantics, хотя physical layout полностью изменился.

### Коррекция про SIMD

Слайд говорит, что `GOEXPERIMENT=noswissmap` актуален для старых processors без SIMD. Официальное описание уточняет: сравнение восьми control bytes можно реализовать стандартными arithmetic/bitwise operations, когда специального SIMD нет. Поэтому отсутствие SIMD не делает Swiss map неработоспособной и само по себе не является основанием отключать её. Release notes Go `1.24` действительно документируют escape hatch `GOEXPERIMENT=noswissmap`, но это implementation switch, а не portable application feature.

### Версионная граница

- Go `1.23.4` и старше: runtime bucket/overflow implementation, показанная в основной лекции 4.
- Go `1.24`: новая built-in `map` на Swiss Tables включена по умолчанию.
- Go `1.26` — актуальный major release на дату проверки `2026-07-19`; semantic `map` contract остаётся спецификацией, внутренности могут продолжать меняться.

На собеседовании сначала отвечают contract: comparable keys, zero value, nil behavior, iteration semantics, concurrency restrictions. Internal structure добавляют с точной version boundary.

### Вопросы для интервью

1. Зачем H2, если всё равно сравнивать full key?
2. Почему deleted slot нельзя немедленно сделать empty?
3. Как load factor влияет на probe length и memory?
4. Зачем tables ограничены 1024 entries?
5. Как directory depth меняется при split?
6. Почему нельзя брать address map element независимо от реализации?
7. Что из Swiss design видно application code, а что остаётся implementation detail?

## Failure modes

| Неверное предположение | Симптом | Причина | Исправление |
| --- | --- | --- | --- |
| timeout убивает dependency | работа течёт после ответа | dependency не слушает context | передать ctx до blocking operation |
| `Value` для optional args | скрытый runtime contract | signature не показывает dependency | обычный parameter/options |
| любой errgroup error равнозначен | возвращается `context.Canceled` | race первой причины | publish error before cancel + `Once` |
| `yield(false)` можно игнорировать | runtime panic | нарушен iterator protocol | немедленный return |
| concurrent yield ускоряет loop | panic/race/order loss | state machine single-flow | отдельный worker protocol |
| H2 равенство = key равенство | неверный lookup | 7-bit collision | full-key comparison |
| Swiss map требует SIMD | лишнее отключение optimization | есть bitwise fallback | доверять runtime, benchmark workload |

## Источники

- [Homework: contexts](https://github.com/Balun-courses/deep_go/blob/aacfeb63b810479f98cebcaa16a444e3c8710ee0/homework/contexts/homework_test.go) — Balun-courses/deep_go, commit `aacfeb6`, проверено 2026-07-19.
- [Package context](https://pkg.go.dev/context) — Go project, актуальная документация, проверено 2026-07-19.
- [Package errgroup](https://pkg.go.dev/golang.org/x/sync/errgroup) — Go project, актуальная документация, проверено 2026-07-19.
- [Go 1.23 Release Notes](https://go.dev/doc/go1.23) — range-over-function и пакет `iter`, Go `1.23`, проверено 2026-07-19.
- [Range Over Function Types](https://go.dev/blog/range-functions) — Go project, 2024, проверено 2026-07-19.
- [Package iter](https://pkg.go.dev/iter) — Go project, актуальная документация, проверено 2026-07-19.
- [Go 1.24 Release Notes](https://go.dev/doc/go1.24) — Swiss built-in map, Go `1.24`, проверено 2026-07-19.
- [Faster Go maps with Swiss Tables](https://go.dev/blog/swisstable) — Go project, 2025-02-26, проверено 2026-07-19.
- [Swiss map source](https://github.com/golang/go/blob/go1.24.0/src/internal/runtime/maps/map.go) — golang/go, tag `go1.24.0`, проверено 2026-07-19.
- [The Go Programming Language Specification](https://go.dev/ref/spec) — context-independent language contracts for range and map, проверено 2026-07-19.
