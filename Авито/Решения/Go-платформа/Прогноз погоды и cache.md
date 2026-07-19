---
aliases:
  - Avito Go — прогноз погоды и cache
tags:
  - область/go
  - тема/cache
  - тема/конкурентность
  - компания/авито
  - тип/кейс
статус: проверено
---

# Прогноз погоды и cache

## TL;DR

Кэш погоды должен синхронизировать и `map`, и сам процесс загрузки. Если 32 запроса одновременно промахнулись по одному городу, запускать 32 одинаковых обращения к dependency нельзя: один caller становится владельцем refresh, остальные ждут тот же результат. Это защита от cache stampede (thundering herd).

Решение ниже хранит свежие значения с TTL, объединяет concurrent misses по `cityID`, ограничивает число одновременных загрузок разных ключей и задаёт каждой загрузке deadline. Отмена одного HTTP-запроса прекращает только его ожидание; у общего refresh есть собственный `fetchTimeout`, и он может заполнить cache для других callers.

## Условие и контракт

Нужно реализовать HTTP-метод прогноза погоды по `city_id`, получать температуру из медленной dependency, кэшировать ответ и уметь заранее прогреть известный набор городов.

Нормализованный контракт:

- `GET ?city_id=N` возвращает JSON `{"temperature": T}`;
- успешное значение действительно в течение `ttl`, начиная с момента завершения загрузки;
- одновременно выполняется не более `maxInflight` загрузок разных ключей;
- concurrent misses одного ключа превращаются в один вызов `fetch`;
- caller может отменить ожидание через `context.Context`, а сама загрузка ограничена `fetchTimeout`;
- ошибка dependency не кэшируется;
- warmup использует не больше заданного числа workers;
- тесты не обращаются во внешнюю сеть.

### Неоднозначности исходника

- Не задана семантика устаревшего значения. Здесь expired entry считается miss: stale fallback не возвращается.
- Не задана политика eviction. Реализация ограничивает concurrent loads, но не число когда-либо встречавшихся `cityID`; для unbounded key space нужен отдельный capacity/eviction policy.
- Не сказано, должен ли уход caller отменять общий refresh. Здесь cache владеет refresh, иначе первый краткоживущий caller может сорвать загрузку всем ожидающим.
- Warmup может означать eager load всех городов или только hot set. Здесь он принимает явный список и останавливается при первой ошибке.
- HTTP mapping ошибок — часть API-контракта. Выбраны `400` для неверного input, `503` при исчерпании load budget, `504` при cancellation/deadline и `502` при ошибке dependency.

## Ментальная модель

В cache есть два разных состояния:

1. **Данные:** `entries[cityID]` с температурой и `expiresAt`.
2. **Работа:** `inflight[cityID]` с обещанием будущего результата.

Один mutex защищает оба состояния и переход между ними. На свежем hit функция сразу читает entry. На miss первый caller регистрирует `call` и запускает refresh; следующий caller видит тот же `call` и ждёт закрытия `done`. После fetch владелец под mutex публикует результат, удаляет запись из `inflight` и закрывает `done`. Закрытие channel происходит после записи полей, поэтому waiters наблюдают опубликованный результат; общий happens-before механизм описан в [[60 Go/Модель памяти Go и happens-before|модели памяти Go]].

`context.WithoutCancel` отделяет lifetime общей загрузки от lifetime первого caller. Это не делает refresh бесконечным: `load` сразу добавляет `context.WithTimeout`. `maxInflight` ограничивает число refresh goroutines для разных ключей, а callers одного ключа coalesce без дополнительной загрузки.

## Concurrency invariants

- `entries`, `inflight` и поля `call` изменяются только под `Cache.mu`.
- Для одного `cityID` в `inflight` находится не больше одного `call`, значит одновременно работает не больше одного `fetch` этого ключа.
- Число активных загрузок разных ключей не превышает `maxInflight`; превышение даёт `ErrBusy`, а не неограниченную очередь.
- `current.done` закрывает только goroutine-владелец загрузки и ровно один раз.
- Перед `close(current.done)` уже записаны `temperature` и `err`; waiters читают их только после получения из закрытого channel.
- Отмена waiter не удаляет shared call и не отменяет refresh. По истечении `fetchTimeout` refresh получает cancellation signal; фактическое завершение bounded только при условии, что dependency своевременно соблюдает context.
- TTL начинается после успешного `fetch`, а failure не заменяет существующий entry новым ошибочным значением.
- Warmup создаёт не больше `min(workers, len(cityIDs))` workers; producer один закрывает `jobs` после прекращения выдачи работы.

## Код Go 1.26.5

`weather.go`:

```go
package weather

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"sync"
	"time"
)

var ErrBusy = errors.New("weather cache has too many distinct loads in flight")

type FetchFunc func(context.Context, int) (int, error)

type entry struct {
	temperature int
	expiresAt   time.Time
}

type call struct {
	done        chan struct{}
	temperature int
	err         error
}

type Cache struct {
	mu           sync.Mutex
	entries      map[int]entry
	inflight     map[int]*call
	fetch        FetchFunc
	ttl          time.Duration
	fetchTimeout time.Duration
	maxInflight  int
	now          func() time.Time
}

func NewCache(fetch FetchFunc, ttl, fetchTimeout time.Duration, maxInflight int) (*Cache, error) {
	if fetch == nil {
		return nil, errors.New("fetch function is required")
	}
	if ttl <= 0 || fetchTimeout <= 0 || maxInflight <= 0 {
		return nil, errors.New("ttl, fetch timeout, and max inflight must be positive")
	}
	return &Cache{
		entries:      make(map[int]entry),
		inflight:     make(map[int]*call),
		fetch:        fetch,
		ttl:          ttl,
		fetchTimeout: fetchTimeout,
		maxInflight:  maxInflight,
		now:          time.Now,
	}, nil
}

// Get coalesces concurrent misses for one city into a single fetch.
func (c *Cache) Get(ctx context.Context, cityID int) (int, error) {
	c.mu.Lock()
	if cached, ok := c.entries[cityID]; ok && c.now().Before(cached.expiresAt) {
		c.mu.Unlock()
		return cached.temperature, nil
	}
	if current, ok := c.inflight[cityID]; ok {
		c.mu.Unlock()
		return wait(ctx, current)
	}
	if len(c.inflight) >= c.maxInflight {
		c.mu.Unlock()
		return 0, ErrBusy
	}

	current := &call{done: make(chan struct{})}
	c.inflight[cityID] = current
	c.mu.Unlock()

	// The cache owns the refresh. A caller may stop waiting, while the shared
	// refresh remains bounded by fetchTimeout and can populate the cache.
	go c.load(context.WithoutCancel(ctx), cityID, current)
	return wait(ctx, current)
}

func wait(ctx context.Context, current *call) (int, error) {
	select {
	case <-current.done:
		return current.temperature, current.err
	case <-ctx.Done():
		return 0, ctx.Err()
	}
}

func (c *Cache) load(parent context.Context, cityID int, current *call) {
	ctx, cancel := context.WithTimeout(parent, c.fetchTimeout)
	defer cancel()

	temperature, err := c.fetch(ctx, cityID)

	c.mu.Lock()
	if err == nil {
		c.entries[cityID] = entry{
			temperature: temperature,
			expiresAt:   c.now().Add(c.ttl),
		}
	}
	current.temperature = temperature
	current.err = err
	delete(c.inflight, cityID)
	close(current.done)
	c.mu.Unlock()
}

// Warm loads a known set of cities with a bounded worker pool.
func (c *Cache) Warm(ctx context.Context, cityIDs []int, workers int) error {
	if workers <= 0 {
		return errors.New("workers must be positive")
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	jobs := make(chan int)
	var (
		wg       sync.WaitGroup
		once     sync.Once
		firstErr error
	)

	for range min(workers, len(cityIDs)) {
		wg.Go(func() {
			for cityID := range jobs {
				if _, err := c.Get(ctx, cityID); err != nil {
					once.Do(func() {
						firstErr = err
						cancel()
					})
					return
				}
			}
		})
	}

sendLoop:
	for _, cityID := range cityIDs {
		select {
		case jobs <- cityID:
		case <-ctx.Done():
			break sendLoop
		}
	}
	close(jobs)
	wg.Wait()
	if firstErr != nil {
		return firstErr
	}
	return ctx.Err()
}

type Handler struct {
	Cache *Cache
}

func (h Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if h.Cache == nil {
		http.Error(w, "weather cache is not configured", http.StatusInternalServerError)
		return
	}

	cityID, err := strconv.Atoi(r.URL.Query().Get("city_id"))
	if err != nil || cityID < 0 {
		http.Error(w, "city_id must be a non-negative integer", http.StatusBadRequest)
		return
	}

	temperature, err := h.Cache.Get(r.Context(), cityID)
	if err != nil {
		switch {
		case errors.Is(err, ErrBusy):
			http.Error(w, "weather service is busy", http.StatusServiceUnavailable)
		case errors.Is(err, context.DeadlineExceeded), errors.Is(err, context.Canceled):
			http.Error(w, "weather request timed out", http.StatusGatewayTimeout)
		default:
			http.Error(w, "weather dependency failed", http.StatusBadGateway)
		}
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(struct {
		Temperature int `json:"temperature"`
	}{Temperature: temperature})
}
```

## Tests

`weather_test.go`:

```go
package weather

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCacheCoalescesStampede(t *testing.T) {
	var calls atomic.Int64
	started := make(chan struct{}, 1)
	release := make(chan struct{})
	cache, err := NewCache(func(ctx context.Context, cityID int) (int, error) {
		calls.Add(1)
		started <- struct{}{}
		select {
		case <-release:
			return cityID + 10, nil
		case <-ctx.Done():
			return 0, ctx.Err()
		}
	}, time.Hour, time.Second, 8)
	if err != nil {
		t.Fatal(err)
	}

	const callers = 32
	results := make(chan int, callers)
	errorsCh := make(chan error, callers)
	var wg sync.WaitGroup
	for range callers {
		wg.Go(func() {
			value, err := cache.Get(context.Background(), 7)
			results <- value
			errorsCh <- err
		})
	}

	<-started
	close(release)
	wg.Wait()
	close(results)
	close(errorsCh)

	for err := range errorsCh {
		if err != nil {
			t.Fatalf("Get() error = %v", err)
		}
	}
	for value := range results {
		if value != 17 {
			t.Fatalf("Get() = %d, want 17", value)
		}
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("fetch calls = %d, want 1", got)
	}
}

func TestHandlerWithHTTPTest(t *testing.T) {
	cache, err := NewCache(func(_ context.Context, cityID int) (int, error) {
		return cityID + 5, nil
	}, time.Minute, time.Second, 4)
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(Handler{Cache: cache})
	defer server.Close()

	response, err := server.Client().Get(server.URL + "?city_id=12")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", response.StatusCode)
	}
	var body struct {
		Temperature int `json:"temperature"`
	}
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.Temperature != 17 {
		t.Fatalf("temperature = %d, want 17", body.Temperature)
	}
}

func TestWarmIsBoundedAndFillsCache(t *testing.T) {
	var calls, inFlight, peak atomic.Int64
	started := make(chan struct{}, 4)
	release := make(chan struct{})
	cache, err := NewCache(func(_ context.Context, cityID int) (int, error) {
		calls.Add(1)
		current := inFlight.Add(1)
		defer inFlight.Add(-1)
		for {
			old := peak.Load()
			if current <= old || peak.CompareAndSwap(old, current) {
				break
			}
		}
		started <- struct{}{}
		<-release
		return cityID, nil
	}, time.Hour, time.Second, 8)
	if err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() {
		done <- cache.Warm(context.Background(), []int{1, 2, 3, 4}, 2)
	}()
	<-started
	<-started
	close(release)
	if err := <-done; err != nil {
		t.Fatalf("Warm() error = %v", err)
	}
	for cityID := 1; cityID <= 4; cityID++ {
		value, err := cache.Get(context.Background(), cityID)
		if err != nil || value != cityID {
			t.Fatalf("Get(%d) = (%d, %v)", cityID, value, err)
		}
	}
	if got := calls.Load(); got != 4 {
		t.Fatalf("fetch calls = %d, want 4", got)
	}
	if got := peak.Load(); got > 2 {
		t.Fatalf("peak concurrency = %d, limit = 2", got)
	}
}
```

## Проверка результата

Первый test одновременно запускает `32` callers одного города, удерживает dependency на barrier и подтверждает ровно один вызов `fetch`; все callers получают `17`. Второй test поднимает локальный `httptest.Server`, вызывает реальный HTTP handler и проверяет JSON без внешней сети. Третий test прогревает четыре ключа, измеряет peak не выше двух workers и затем убеждается, что чтения стали cache hits.

Код прошёл `go test`, `go vet` и `go test -race` на Go 1.26.5 `darwin/arm64`, проверено 2026-07-18.

## Сложность и ресурсы

Свежий hit и поиск shared call в среднем занимают `O(1)`. Miss запускает один `fetch` на ключ; `k` одинаковых concurrent misses используют `O(k)` waiters, но только одну загрузку. Число активных refresh goroutines ограничено `maxInflight`, warmup goroutines — `workers`.

Память `entries` — `O(number of distinct cached keys)`, и `maxInflight` её не ограничивает. Expired entries остаются до следующего успешного обращения к тому же ключу. При неограниченном key space нужны max entries, eviction и метрики cardinality; полный design space разобран в [[50 Проектирование систем/Проектирование и реализация in-memory cache в Go|заметке об in-memory cache]].

## Trade-offs и альтернативы

- Один `sync.Mutex` делает переход `entry ↔ inflight` атомарным и обычно достаточно коротким. `RWMutex` или `sync.Map` не реализуют TTL, coalescing и load budget автоматически; усложнять locking стоит только после профилирования contention.
- Здесь caller ждёт refresh. Stale-while-revalidate уменьшает tail latency, но может вернуть устаревшие данные и требует явно определить максимальный stale age.
- Встроенный cache быстр и не требует сети, но не делится между replicas. Redis или другой внешний cache даёт общий state и независимый capacity, ценой network hop и новых failure modes.
- Самописный `inflight` показывает invariant. В production можно использовать `singleflight`, но отдельно всё равно нужны timeout, overload policy, TTL и storage.
- Warmup полезен только для известного hot set. Прогрев всего key space переносит нагрузку на startup, замедляет readiness и может сам вызвать [[70 Практические кейсы/Thundering herd|thundering herd]].
- При ошибке `Warm` отменяет ожидание workers, но уже запущенные cache-owned refreshes могут продолжаться до своего `fetchTimeout`. Если readiness должна означать завершение каждой загрузки, warmup нужен другой ownership policy без detached refresh.
- Игнорирование ошибки `json.Encoder` допустимо в минимальном `ServeHTTP`, потому что status уже мог уйти клиенту. Production handler обычно логирует её и собирает метрику, не пытаясь записать второй HTTP error.

## Типичные ошибки

- **Защитить только `map` → после истечения TTL dependency получает десятки одинаковых запросов → mutex не объединяет работу за пределами critical section → хранить per-key inflight call.**
- **Выполнять `fetch` под общим mutex → один медленный город блокирует все hits и misses → I/O попал в critical section → регистрировать call под lock, а I/O делать после unlock.**
- **Привязать shared refresh к первому caller → его disconnect отменяет загрузку всем waiters → lifetime общей работы случайно принадлежит одному запросу → отделить cancellation и оставить жёсткий fetch deadline.**
- **Использовать `WithoutCancel` без timeout → зависшая dependency навсегда удерживает goroutine и слот `inflight` → cancellation снята, нового bound нет → сразу добавлять `WithTimeout` и требовать от `fetch` соблюдения context.**
- **Ограничить `inflight`, но считать память bounded → map растёт по числу уникальных ключей → concurrency budget не является storage budget → eviction/max entries.**
- **Кэшировать любую ошибку на полный TTL → краткий сбой превращается в длительную искусственную недоступность → error policy не определена → не кэшировать errors либо задавать отдельный короткий negative TTL.**

## Когда применять выводы

Этот pattern подходит для локального read-through cache над медленной dependency, когда одинаковые ключи часто приходят одновременно. Перед внедрением нужно зафиксировать freshness, stale/error policy, key cardinality, refresh timeout, overload response и ownership background work. TTL и время жизни timers подробнее разобраны в [[60 Go/Пакет time, таймеры и тикеры|заметке о time]], а конкурентный доступ к встроенному map — в [[60 Go/Map|заметке о map]].

## Источники

- [[90 Вложения/Авито/Go.pdf|Backend платформа Go]] — предоставленное условие задачи «Прогноз погоды», состояние материалов 2024 года, проверено 2026-07-18.
- [Package sync](https://pkg.go.dev/sync@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, `Mutex`, `Once` и `WaitGroup`, проверено 2026-07-18.
- [Package context](https://pkg.go.dev/context@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, `WithoutCancel`, `WithTimeout` и cancellation propagation, проверено 2026-07-18.
- [Package net/http](https://pkg.go.dev/net/http@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, handler и request context, проверено 2026-07-18.
- [Package net/http/httptest](https://pkg.go.dev/net/http/httptest@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, локальный HTTP server для тестов, проверено 2026-07-18.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, channel close и mutex synchronization, проверено 2026-07-18.
