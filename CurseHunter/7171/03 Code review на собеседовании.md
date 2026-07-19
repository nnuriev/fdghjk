---
aliases:
  - Code review — GO ПРОРВЁМСЯ
tags:
  - тип/разбор-курса
  - источник/coursehunter
  - язык/go
  - тема/code-review
  - тема/собеседования
статус: проверено
---

# Code review на собеседовании

## Порядок ревью

Задачи 77–85 специально содержат несколько классов дефектов. На интервью полезнее не перечислять их в порядке строк, а сначала восстановить контракт и пройтись по рискам:

1. correctness и сохранность данных;
2. security boundary и валидация внешнего input;
3. concurrency, lifecycle и cancellation;
4. resource ownership: response body, rows, DB pool, goroutines;
5. observability и обработка ошибок;
6. performance после доказанной корректности;
7. naming/style в самом конце.

Формат хорошего замечания: **сценарий → наблюдаемый симптом → причинный механизм → исправление → проверка**. Фраза «тут race» слабее, чем «два POST одновременно читают одинаковый `nextID`, один user перезаписывает другого; ID и запись надо менять в одной critical section и проверить `go test -race`».

## 77. Сбор курсов валют из банков

### Что делает код

CLI по команде `update` последовательно опрашивает два bank endpoints. Для одного банка добавляется authorization header, response body преобразуется в `float64`, после чего `updateCurrency` открывает PostgreSQL и записывает курс.

### Что искать

- `http.NewRequest`, `ReadAll`, `ParseFloat`, `sql.Open`, `Ping`, `Exec` errors местами игнорируются или превращаются в `panic`. Для CLI надо вернуть contextual error и определить, прекращать всю batch или продолжать остальные банки.
- `http.Client{}` без timeout способен ждать бесконечно. Request должен получать caller context/deadline.
- Не проверяется HTTP status и content type. Даже корректно прочитанная error page может попасть в parser.
- `defer resp.Body.Close()` находится внутри loop: bodies закроются только при выходе из `main`. При большом числе банков это удерживает connections/resources. Лучше выделить `fetchRate` и закрывать body внутри одного вызова.
- Body читается без limit. Даже trusted integration имеет response-size budget.
- Authentication token и DB credentials захардкожены. Secrets должны приходить из защищённой configuration boundary и не попадать в log/error.
- Замена запятой на точку — хрупкий protocol parser. Adapter каждого банка должен декодировать документ по его schema и явно валидировать currency pair.
- `sql.Open` вызывается на каждую запись. `*sql.DB` — concurrent-safe pool, его создают один раз, проверяют при startup и переиспользуют.
- SQL собирается через `fmt.Sprintf`. Это SQL injection и проблемы quoting; значения передаются parameters.
- Нет transaction/upsert/idempotency semantics: повторный update может создать duplicate или потерять согласованность batch.

### Граница исправления

Разделить код на adapters:

```text
command → fetch bank payload → parse/validate quote → repository upsert
```

Каждый слой возвращает wrapped error с bank/currency context, но без secret. HTTP client и repository инъецируются, поэтому adapters тестируются через `httptest.Server`, а запись — fake repository/integration test. Для нескольких банков можно добавить bounded parallelism, но только после определения partial-failure policy.

## 78. HTTP-аналитика посещений

![[90 Вложения/CurseHunter/7171/Кадры/7171-78-visits-code-review.jpg]]

*Кадр урока 78: контракт endpoint `/visits` и требования к ревью.*

### Контракт

`GET /visits?period=day|week` должен взять visits из PostgreSQL, сгруппировать их по дням и вернуть для каждого дня count и top location. В условии отдельно требуют отсутствие SQL injection, корректные types и обработку errors.

### Дефекты request path

- DB DSN с credentials находится в коде; ошибки `sql.Open`, startup `Ping` и `ListenAndServe` игнорируются.
- Handler создаёт `context.Background()` вместо использования `r.Context()`. Client disconnect и server timeout не отменяют query.
- `period` помещается в untyped context value. Это не request-scoped cross-cutting metadata, а обычный проверенный аргумент domain function.
- Значения кроме `day`/`week` не отклоняются. Type alias сам по себе не валидирует string.
- Ошибки query, scan, aggregation, JSON encoding и response write игнорируются; status/content type не выставляются.

### Дефекты SQL/resource layer

- Interval вставляется через `fmt.Sprintf`; даже при enum-like input это плохая security boundary. Лучше преобразовать period в заранее известную `time.Duration`/cutoff и передать timestamp parameter.
- Используется `db.Query`, а не `QueryContext` с request context.
- `rows.Close()` не гарантирован, `rows.Err()` после loop не проверяется, `Scan` error игнорируется.
- Выборка всех raw visits и aggregation в Go может быть неоправданно дорогой. `GROUP BY date, location` и window/tie-breaking в SQL уменьшают transfer, если DB является подходящим compute boundary.

### Дефекты aggregation

Нужно одновременно считать daily total и per-location count. `maxCounter` не может быть одной глобальной переменной на все дни; иначе популярная локация первого дня задаёт порог следующим. Для ties нужен deterministic rule, например `count DESC, location ASC`.

День зависит от timezone. `timestamp with time zone` — момент времени, но календарная дата определяется business timezone, которую надо согласовать. Сортировка результата по распарсенным строкам допустима после проверки errors, однако date-only ISO string уже сортируется лексикографически.

### Что должно получиться

Handler валидирует query, передаёт `r.Context()` в service, domain получает typed period/cutoff, repository выполняет parameterized query, errors мапятся в стабильные HTTP responses. JSON response имеет deterministic order и явно определённую tie/timezone semantics.

## 79. Пять goroutines отправляют сообщения в канал

В исходнике:

- запускаются пять producers;
- channel имеет capacity `3`;
- каждый send обёрнут общим `Mutex`;
- main бесконечно читает через `for { select { case ... } }`;
- `WaitGroup` уменьшается, но никто не использует его для завершения consumer.

Capacity `3` сама по себе не ошибка: main читает параллельно, поэтому producers постепенно разблокируются. Настоящая liveness-проблема — канал никогда не закрывается и receive loop не имеет termination condition.

Mutex не защищает shared memory и потому не нужен. Более того, он удерживается во время potentially blocking send и искусственно сериализует producers. Correct lifecycle:

```go
for i := 0; i < n; i++ {
	wg.Add(1)
	go func(i int) {
		defer wg.Done()
		results <- fmt.Sprintf("Goroutine %d", i)
	}(i)
}

go func() {
	wg.Wait()
	close(results)
}()

for result := range results {
	fmt.Println(result)
}
```

В исходном closure `i` передаётся параметром, поэтому нет loop-capture bug. В Go 1.22 изменились loop variables, объявленные внутри `for`, но явная передача параметра остаётся читаемым и version-independent намерением.

## 80. Параллельные HTTP-запросы и отмена

### Исходный сценарий

Для четырёх URL запускаются goroutines с `fetch(context.Background(), url)`. Затем `main` спит `400ms` и завершается. `fetch` строит request with context, но использует client без timeout и не закрывает response body.

### Проблемы

- `time.Sleep` — не синхронизация: быстрый network может успеть, медленный — быть оборван завершением process.
- У каждого worker независимый `Background`, поэтому batch нельзя отменить.
- Нет overall deadline и bounded concurrency.
- `resp.Body` не закрывается; status code не проверяется, body не читается.
- Создание client внутри `fetch` мешает transport reuse; client/transport должны быть long-lived.
- Ошибки только печатаются конкурентно и не образуют результата batch.

`WaitGroup` устраняет sleep, но не даёт error propagation/cancellation. Для связанной группы лучше `errgroup.WithContext`: первый error отменяет siblings, а `Wait` возвращает cause. Если требуются все результаты, policy другая: workers отправляют indexed result, batch ждёт всех и агрегирует errors.

Порядок внутри `fetch` важен:

```go
resp, err := client.Do(req)
if err != nil {
	return err
}
defer resp.Body.Close()
```

Нельзя ставить `defer resp.Body.Close()` до проверки `err`: при error `resp` обычно `nil`. Request context должен происходить от batch/root context, а не создаваться заново в leaf.

## 81. Worker pool с panic и незакрытыми каналами

![[90 Вложения/CurseHunter/7171/Кадры/7171-81-worker-pool-review.jpg]]

*Кадр урока 81: исходная заготовка worker pool для ревью.*

### Что показывает код

Пять tasks, включая `Data: "corrupt"`, отправляются в `jobChan`. На каждую task запускается отдельный `worker`, то есть число workers равно числу tasks. `processTask` может panic. Main ждёт ровно `len(tasks)` результатов.

### Failure modes

- `jobChan` в исходнике не закрывается, поэтому workers после обработки ждут следующую task и остаются живы.
- Это не bounded pool: на каждую task создан worker. На unbounded input число goroutines растёт вместе с входом.
- Panic в любой goroutine без `recover` завершает весь process, а не превращается в `Result.Error`.
- Если production policy перехватывает panic, worker обязан всё равно отправить результат либо сообщить coordinator; иначе fixed-count receive зависнет.
- `resultChan` не закрывается, lifecycle зависит от заранее известного count.
- Нет cancellation/backpressure; producer и workers могут блокироваться без общего shutdown path.

Корректная topology: фиксированный `workerCount`, producer-owned close `jobs`, workers под `WaitGroup`, отдельный closer закрывает `results`, main делает `range`. Panic recovery допустим только на boundary, где его можно залогировать со stack и превратить в controlled failure; не любой panic следует скрывать и продолжать process.

Если порядок output должен совпадать с input, result несёт sequence number, а collector переупорядочивает. Это отдельная цена памяти/latency, а не свойство worker pool по умолчанию.

## 82. Cache race и cache stampede

`Cache` содержит обычный `map[string]string`; `Get`, `Set`, `Delete` вызываются конкурентно. `GetOrCompute` сначала читает cache, при miss выполняет дорогую функцию, затем записывает значение.

Есть две независимые проблемы:

1. concurrent map read/write — data race и возможный runtime panic;
2. после добавления `RWMutex` два misses одного key всё равно параллельно выполняют дорогое вычисление — cache stampede.

Locks в `Get`/`Set` решают только первое. Удерживать global write lock во время вычисления гарантирует single execution, но сериализует даже разные keys и опасно для медленной/внешней функции.

Варианты:

- `singleflight.Group` coalesces concurrent calls одного key, но сам по себе не является persistent cache;
- per-key promise/entry с ready channel даёт контроль над cancellation и error caching;
- sharded/per-key locks уменьшают contention;
- для multi-instance service нужен distributed coordination только если duplicate computation действительно недопустимо.

Нужно определить, кешируются ли errors, каковы TTL/eviction/size limit, допустима ли stale value и кто отменяет shared computation, если один из waiters ушёл.

## 83. JSON CRUD API пользователей

### Исходник

HTTP server хранит `users map[int]User` и `nextID` в global variables. Handlers вручную разбирают methods/path, читают request body целиком и игнорируют большинство errors.

### Correctness и concurrency

- Concurrent handlers читают и меняют map без lock; возможны race и `concurrent map read and map write`.
- `nextID++` не атомарен относительно вставки: два requests могут получить один ID. Оба действия должны быть в одной repository critical section.
- Возврат map values имеет nondeterministic order; API/tests должны определить сортировку или явно считать порядок незначимым.

### HTTP boundary

- Неизвестный method должен получить `405 Method Not Allowed` и `Allow`, неизвестный resource — `404`.
- `io.ReadAll` без limit позволяет memory exhaustion. Применяют `http.MaxBytesReader`/ограниченный decoder.
- Ошибки чтения/JSON decode игнорируются. Полезны `DisallowUnknownFields`, проверка одного JSON value без trailing garbage и domain validation.
- Client не должен задавать server-generated `ID`; input/output DTO лучше разделить.
- Перед body нужны status и `Content-Type: application/json`; после `WriteHeader` status изменить нельзя.
- `http.Server` без `ReadHeaderTimeout`, `ReadTimeout`/body policy, `WriteTimeout` и `IdleTimeout` уязвим для slow clients и плохо управляется при shutdown.
- Error `ListenAndServe` нельзя терять; `http.ErrServerClosed` обрабатывается отдельно при graceful shutdown.

### Performance без преждевременной оптимизации

`json.Decoder` позволяет stream decode и limit body, но не автоматически «быстрее» `ReadAll+Unmarshal` во всех случаях. Главные выигрыши здесь — bounded memory, меньше intermediate copy и корректная boundary. Конкретную serialization optimization доказывают benchmark/profile.

Global mutex вокруг JSON encoding удерживал бы lock на медленном client. Под lock надо сделать snapshot/copy, затем unlock и encode response отдельно.

## 84. Рефакторинг channel lifecycle

Эта задача похожа на 79, но не является поводом терять её при дедубликации: здесь показан другой вариант кода — closure использует loop variable напрямую, сообщение имеет другой формат, а в ходе рефакторинга обсуждается добавление cancellation.

Исходные проблемы те же: ненужный mutex вокруг send, бесконечный `select`, `Wait()` после недостижимого loop и отсутствие close. Closer должен ждать всех producers и закрыть канал, main — читать `range`.

Для Go 1.22+ переменная `i`, объявленная самим `for`, создаётся заново на каждой итерации. На более старых версиях closure могло увидеть позднее значение; явный параметр `go func(i int) { ... }(i)` устраняет version ambiguity.

Если один producer может вызвать `cancel`, недостаточно проверить context только перед вычислением. Send тоже должен быть interruptible:

```go
select {
case results <- value:
case <-ctx.Done():
	return
}
```

При отмене output всё равно закрывает coordinator после завершения всех producers; вызывающий `cancel` producer не имеет права закрывать общий channel.

## 85. Cache с локальным mutex и лишним Unlock

`CachedLongCalculation` использует global `map[int]int`, но создаёт `var mu sync.Mutex` **внутри каждого вызова**. Concurrent calls получают разные mutexes, поэтому никакой mutual exclusion между ними нет.

Кроме того, после уже выполненного unlock на read path присутствует ещё один `mu.Unlock()`: при cache hit это `fatal error: sync: unlock of unlocked mutex`.

Mutex должен принадлежать тому же object, что и защищаемое состояние:

```go
type Cache struct {
	mu   sync.RWMutex
	data map[int]int
}
```

Read проходит под `RLock`, write — под `Lock`. Но check-compute-set всё равно не атомарен: несколько misses считают одно значение. После вычисления нужна как минимум повторная проверка под write lock, если важно не перезаписать более свежее значение. Она устраняет lost publication, но не duplicate work; для exactly-once-per-key in-flight computation нужен singleflight/per-key state.

Задача отличается от 82 конкретным failure mechanism: там map вовсе не защищён, здесь lock визуально присутствует, но имеет неправильный lifetime и дополнительно ломается несбалансированным unlock.

## 88. MEGA CODE REVIEW: task processor целиком

![[90 Вложения/CurseHunter/7171/Кадры/7171-88-mega-code-review.jpg]]

*Кадр урока 88: единая задача на cache, metrics, retry, workers и graceful shutdown.*

Бесплатный урок содержит отдельную комплексную задачу, а не сводный пересказ 77–85. Требуется проверить сервис обработки `Task`: несколько workers, cache результатов, metrics, retries и graceful shutdown.

### Cache и mutable aliases

`Cache` хранит `map[string]*Result`, но не имеет lock. Одновременные `Get`/`Set` приводят к race. `GetAll()` возвращает внутреннюю map напрямую: caller способен менять её без синхронизации и обходить все будущие инварианты.

Даже после `RWMutex` pointer-value остаётся mutable alias. Если `Result.Data []byte` или поля результата меняются, read lock защищает только lookup, а не дальнейшую мутацию объекта. Cache должен публиковать immutable values либо делать defensive copies map/result/bytes.

В collector встречается `cache.Set(result.TaskID, &result)`. В Go до 1.22 address range variable мог повторно указывать на одну storage cell; в актуальном Go 1.26 переменная, объявленная range clause, создаётся на каждой итерации. Но cache всё равно проще и безопаснее хранит `Result` по значению, явно копируя mutable bytes.

### Metrics

В `Metrics` mutex используется только в `IncrementCached`; `IncrementProcessed`, `IncrementFailed` и `GetStats` обращаются к тем же counters без lock. Частичная синхронизация не работает: все accesses конкретного shared field следуют одному protocol.

Нужно выбрать один вариант:

- один mutex и snapshot всех counters под lock;
- независимые `atomic.Uint64` для независимых counters;
- production metrics backend, у которого уже определена concurrent semantics.

Кроме race есть semantic bug: collector увеличивает `Cached` при записи нового результата, а worker — при cache hit. Одна метрика смешивает writes и hits; нужны отдельные `cache_hit`, `cache_miss`, `cache_write`, `processed`, `failed`, `retry`.

### Lifecycle `ProcessTasks`

- `workers <= 0` не валидируется: producer блокируется на первом unbuffered send, результатов никогда не будет.
- Producer отправляет `taskChan <- task` без `select` по `ctx.Done()`. При отмене или выходе workers он может утечь.
- Workers должны делать cancellation-aware receive и result send; иначе collector/consumer exit оставляет их заблокированными.
- Только coordinator закрывает `resultChan` после `wg.Wait()`. Worker не закрывает общий output и не отправляет sentinel «для закрытия».
- Collector append-ит в `tp.results`. Если один `TaskProcessor` допускает одновременные `ProcessTasks`/read results, slice и cache снова race. Проще вернуть batch results из метода, чем накапливать mutable history в service object.
- `ProcessTasks` возвращает `nil` независимо от task errors и cancellation. Контракт должен определить partial results и aggregate error.
- Goroutine panic не должен навсегда оставить `WaitGroup` или канал без close. Recovery policy размещается на worker boundary и сохраняет stack/task identity.

### Retries

Loop `for i := 0; i <= maxRetries; i++` означает `1 + maxRetries` attempts; это нормально, только если `maxRetries` именно число **повторов**, а не attempts. Название и tests должны закрепить контракт.

Fixed `time.Sleep(100ms)` игнорирует cancellation и синхронно будит всех failed workers. Нужны timer/select с context, exponential backoff, jitter и upper bound. Retry допустим только для классифицированной transient error и idempotent operation; permanent validation error не повторяют.

`Task.Retries++` меняет локальную копию task и не обязательно отражается в `Result`/metrics. Attempts должны быть явным полем результата/telemetry, а не скрытой мутацией input copy.

### Graceful shutdown

Одного `wg.Wait()` для graceful shutdown недостаточно. Нужно прекратить admission новых tasks, отменить или дождаться уже принятых в рамках deadline, закрыть producer-owned inputs, дождаться workers, закрыть result output и только после drain вернуть управление.

Нужно выбрать policy для deadline:

- finish in-flight, но не брать новые;
- немедленно cancel in-flight;
- вернуть недоделанные tasks в durable queue;
- считать shutdown timeout error и какие данные всё равно гарантированно опубликованы.

Тестовый набор: `go test -race`; `workers=0`; пустая batch; concurrent cache hit одного key; cancellation пока producer blocked; cancellation пока worker отправляет result; panic; permanent/transient errors; shutdown deadline; повторный или concurrent вызов `ProcessTasks`.

## Мини-чеклист ответа на code review

- Какой внешний контракт и какие inputs считаются недоверенными?
- Что произойдёт при одновременных запросах, timeout, panic и partial failure?
- Кто закрывает body/rows/channel и кто ждёт goroutines?
- Все ли blocking operations получают `Context` и deadline?
- Ограничены ли body, queue, concurrency, cache и result size?
- Не удерживается ли lock во время I/O, JSON encoding или пользовательского callback?
- Ошибка сохранена с cause/context и попала в правильный HTTP/CLI outcome?
- Как воспроизвести дефект: unit test, `httptest`, integration test, `go test -race`, benchmark или fault injection?

## Источники

- [Package net/http](https://pkg.go.dev/net/http) — Go standard library, Go 1.26, проверено 2026-07-19.
- [Package database/sql](https://pkg.go.dev/database/sql) — Go standard library, Go 1.26, проверено 2026-07-19.
- [Package encoding/json](https://pkg.go.dev/encoding/json) — Go standard library, Go 1.26, проверено 2026-07-19.
- [Package sync](https://pkg.go.dev/sync) — Go standard library, Go 1.26, проверено 2026-07-19.
- [Package singleflight](https://pkg.go.dev/golang.org/x/sync/singleflight) — Go project, `golang.org/x/sync`, проверено 2026-07-19.
- [Go 1.22 Release Notes — Changes to the language](https://go.dev/doc/go1.22#language) — Go project, Go 1.22, проверено 2026-07-19.
- [The Go Memory Model](https://go.dev/ref/mem) — Go project, версия от 2022-06-06, проверено 2026-07-19.
- [GO ПРОРВЁМСЯ](https://olezhek28.courses/gothrough) — авторская страница курса, проверено 2026-07-19.
