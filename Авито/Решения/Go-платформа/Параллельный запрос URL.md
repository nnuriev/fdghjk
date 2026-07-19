---
aliases:
  - Avito Go — параллельный запрос URL
tags:
  - область/go
  - тема/http
  - тема/конкурентность
  - компания/авито
  - тип/кейс
статус: проверено
---

# Параллельный запрос URL

## TL;DR

Список URL нужно обрабатывать конкурентно, но не «по goroutine на всё». Worker pool задаёт глобальный предел активных запросов, общий `context.Context` отменяет очередь и уже начатые HTTP operations, а переиспользуемые `http.Client` и `Transport` ограничивают connections к одному host.

Решение сохраняет порядок input, возвращает status и error для каждого URL, закрывает response body и не делает внешних сетевых вызовов в tests: endpoints поднимаются через `httptest.Server`.

## Условие и контракт

Нужно параллельно выполнить `GET` для набора адресов и получить их HTTP statuses.

Нормализованный контракт `FetchStatuses`:

- вернуть один `Result` на каждый входной URL в исходном порядке;
- держать не больше `workers` активных operations во всём batch;
- передавать caller cancellation/deadline в каждый request;
- сохранить ошибку построения или выполнения конкретного request в соответствующем `Result`;
- при cancellation прекратить выдачу новой работы, дождаться workers и вернуть `ctx.Err()` как batch error;
- закрыть каждый полученный response body;
- переиспользовать переданный client, а не создавать новый на каждый URL.

### Неоднозначности исходника

- «Параллельно» не задаёт безопасный предел. Он должен учитывать rate limit dependency, file descriptors, memory, connection pool и latency SLO.
- Не указано, нужно ли fail-fast завершать весь batch при одном `500` или transport error. Здесь per-item failures не отменяют соседей; отменяет только caller context.
- HTTP status `500` — успешно полученный HTTP response, а не transport error. Caller сам решает, какие codes считать бизнес-ошибкой.
- Не задан размер response body. Поскольку задача требует status, код читает не больше `1 MiB` для bounded попытки connection reuse, затем закрывает body.
- Retry отсутствует: без idempotency, backoff, jitter и общего deadline автоматический retry способен умножить нагрузку.

## Ментальная модель

Здесь есть два независимых ограничения:

1. `workers` — глобальный budget batch: сколько requests одновременно исполняет функция.
2. `http.Transport` — budget connections и keep-alive для конкретных hosts.

Workers получают индексы через `jobs` и записывают только в уникальный `results[index]`. Поэтому дополнительный mutex для result slice не нужен: backing array общий, но две goroutines не обращаются к одному элементу. Coordinator один отправляет indices и закрывает `jobs`.

`http.NewRequestWithContext` связывает deadline с полным lifetime request: получением connection, отправкой запроса и чтением response. Но cancellation остаётся кооперативной на границе transport; собственный callback, который игнорирует context, таким способом остановить нельзя.

`http.Client` и `Transport` рассчитаны на reuse и безопасны для concurrent use. Именно повторное использование даёт connection pooling и keep-alive, разобранные в [[20 Бэкенд/Пулы соединений и keep-alive|заметке о пулах соединений]].

## Concurrency invariants

- Создаётся не больше `min(workers, len(addresses))` worker goroutines.
- Только coordinator пишет в `jobs` и закрывает его; workers канал не закрывают.
- Каждый index отправляется не больше одного раза и обрабатывается не больше одним worker.
- Worker с индексом `i` изменяет только `results[i]`; `wg.Wait` завершается до чтения slice caller.
- Все начатые requests получают один `ctx`, поэтому caller deadline распространяется до transport.
- После получения `*http.Response` body закрывается на каждой ветке.
- Глобальная concurrency ограничена workers, а connections к одному host дополнительно ограничены `MaxConnsPerHost`.

## Код Go 1.26.5

`urls.go`:

```go
package urls

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

type Result struct {
	URL        string
	StatusCode int
	Err        error
}

func NewHTTPClient(maxConnections int) (*http.Client, error) {
	if maxConnections <= 0 {
		return nil, errors.New("max connections must be positive")
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxIdleConns = maxConnections
	transport.MaxIdleConnsPerHost = maxConnections
	transport.MaxConnsPerHost = maxConnections
	transport.IdleConnTimeout = 90 * time.Second
	return &http.Client{Transport: transport}, nil
}

// FetchStatuses preserves input order and bounds the number of active requests.
func FetchStatuses(ctx context.Context, client *http.Client, addresses []string, workers int) ([]Result, error) {
	if client == nil {
		return nil, errors.New("http client is required")
	}
	if workers <= 0 {
		return nil, errors.New("workers must be positive")
	}

	results := make([]Result, len(addresses))
	for index, address := range addresses {
		results[index].URL = address
	}

	jobs := make(chan int)
	var wg sync.WaitGroup
	for range min(workers, len(addresses)) {
		wg.Go(func() {
			for index := range jobs {
				address := addresses[index]
				request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
				if err != nil {
					results[index].Err = fmt.Errorf("build request: %w", err)
					continue
				}

				response, err := client.Do(request)
				if err != nil {
					results[index].Err = fmt.Errorf("GET %s: %w", address, err)
					continue
				}
				results[index].StatusCode = response.StatusCode
				_, copyErr := io.Copy(io.Discard, io.LimitReader(response.Body, 1<<20))
				closeErr := response.Body.Close()
				results[index].Err = errors.Join(copyErr, closeErr)
			}
		})
	}

	sent := 0
sendLoop:
	for index := range addresses {
		select {
		case jobs <- index:
			sent++
		case <-ctx.Done():
			break sendLoop
		}
	}
	close(jobs)
	wg.Wait()

	if err := ctx.Err(); err != nil {
		for index := sent; index < len(results); index++ {
			results[index].Err = err
		}
		return results, err
	}
	return results, nil
}
```

## Tests

`urls_test.go`:

```go
package urls

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestFetchStatusesUsesHTTPTestAndBoundsConcurrency(t *testing.T) {
	var inFlight, peak atomic.Int64
	started := make(chan struct{}, 4)
	release := make(chan struct{})
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		current := inFlight.Add(1)
		defer inFlight.Add(-1)
		for {
			old := peak.Load()
			if current <= old || peak.CompareAndSwap(old, current) {
				break
			}
		}
		started <- struct{}{}
		select {
		case <-release:
			w.WriteHeader(http.StatusNoContent)
		case <-r.Context().Done():
			return
		}
	})
	serverA := httptest.NewServer(handler)
	defer serverA.Close()
	serverB := httptest.NewServer(handler)
	defer serverB.Close()

	type outcome struct {
		results []Result
		err     error
	}
	done := make(chan outcome, 1)
	go func() {
		results, err := FetchStatuses(
			context.Background(),
			serverA.Client(),
			[]string{serverA.URL, serverB.URL, serverA.URL, serverB.URL},
			2,
		)
		done <- outcome{results: results, err: err}
	}()

	<-started
	<-started
	close(release)
	result := <-done
	if result.err != nil {
		t.Fatalf("FetchStatuses() error = %v", result.err)
	}
	for _, got := range result.results {
		if got.Err != nil || got.StatusCode != http.StatusNoContent {
			t.Fatalf("result = %+v", got)
		}
	}
	if got := peak.Load(); got > 2 {
		t.Fatalf("peak concurrency = %d, limit = 2", got)
	}
}

func TestFetchStatusesHonorsDeadline(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	results, err := FetchStatuses(ctx, server.Client(), []string{server.URL, server.URL}, 1)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("FetchStatuses() error = %v, want deadline exceeded", err)
	}
	for _, result := range results {
		if result.Err == nil {
			t.Fatalf("result without error after deadline: %+v", result)
		}
	}
}
```

## Проверка результата

Первый test запускает два локальных `httptest.Server`, удерживает handlers на barrier и доказывает, что при четырёх URL peak concurrency не превышает `2`; все responses имеют status `204`. Второй test ставит общий deadline `20 ms`: уже начатый request получает cancellation через request context, невыданный элемент помечается той же ошибкой.

Тесты не используют внешний DNS или интернет. Код прошёл `go test`, `go vet` и `go test -race` на Go 1.26.5 `darwin/arm64`, проверено 2026-07-18.

## Сложность и ресурсы

Общее число operations — `O(n)`, result storage — `O(n)`, число workers — `O(min(workers, n))`. При сопоставимой latency wall-clock складывается примерно из `ceil(n/workers)` волн, но реальные hosts и pool limits могут уменьшить фактический parallelism.

Unbuffered `jobs` не хранит весь batch отдельно. В каждый момент начатые requests, sockets и основная часть сетевых buffers ограничены worker budget; idle connections дополнительно живут в transport pool.

## Trade-offs и альтернативы

- Worker pool ограничивает и активные requests, и число goroutines. «Goroutine на URL + semaphore» ограничит requests, но создаст `O(n)` ожидающих goroutines.
- Один batch context даёт общий deadline. Для отдельного per-host/per-request budget можно создать child context внутри worker, но он не должен переживать общий deadline.
- `http.Client.Timeout` — общий предел на request, включая чтение body. Context гибче: сохраняет причину и объединяется с caller cancellation; часто используют context как operation budget, а transport timeouts — как нижнеуровневую защиту.
- Полное чтение небольшого body помогает reuse connection. Лимит `1 MiB` удерживает bounded work; если сервер прислал больше, ранний `Close` может запретить reuse этой connection. Для произвольного payload нужен отдельный size contract.
- Компонент, которому принадлежит client, может вызвать `CloseIdleConnections` при shutdown. Делать это после каждого batch нельзя: так пропадает смысл keep-alive pool.
- При множестве dependencies одного глобального limit мало: отдельные per-host bulkheads и [[40 Распределённые системы/Circuit breaker|circuit breakers]] защищают разные failure domains.

## Типичные ошибки

- **Создать `http.Client` на каждый URL → connection churn, лишние DNS/dial/TLS и отсутствие устойчивого pool → client/transport не переиспользуются → держать долгоживущий concurrent-safe client.**
- **Сделать `go client.Get` для каждого input → FD exhaustion или overload downstream → число inputs ошибочно принято за capacity → bounded worker pool и transport limits.**
- **Не закрыть response body → connections не возвращаются в pool и исчерпываются resources → ownership body осталось неявным → закрывать body на каждой ветке после успешного `Do`.**
- **Использовать `http.Get` без caller context → batch deadline не отменяет in-flight requests → cancellation не дошла до I/O boundary → `NewRequestWithContext` и `client.Do`.**
- **Записывать results через `append` из workers → data race и потеря input order → общий slice header изменяют несколько goroutines → заранее выделить slice и дать worker уникальный index.**
- **Считать любой `500` transport error → retry/error policy смешивается с HTTP protocol → response получен успешно → сохранить status и интерпретировать его на бизнес-уровне.**

## Когда применять выводы

Pattern подходит для health checks, batch enrichment, fan-out и параллельной проверки endpoints. Перед production-запуском фиксируют global/per-host concurrency, deadline, response size, retry policy и partial-result contract. Настройки и ownership transport подробнее разобраны в [[60 Go/HTTP-клиент и Transport|заметке об HTTP client]], а его закрытие при lifecycle сервиса — в [[60 Go/Graceful shutdown|заметке о graceful shutdown]].

## Источники

- [[90 Вложения/Авито/Go.pdf|Backend платформа Go]] — предоставленное условие задачи «Параллельный запрос URL», состояние материалов 2024 года, проверено 2026-07-18.
- [Package net/http: Client](https://pkg.go.dev/net/http@go1.26.5#Client) — стандартная библиотека Go, tag `go1.26.5`, concurrent reuse и request execution, проверено 2026-07-18.
- [Package net/http: Transport](https://pkg.go.dev/net/http@go1.26.5#Transport) — стандартная библиотека Go, tag `go1.26.5`, connection pooling и per-host limits, проверено 2026-07-18.
- [NewRequestWithContext](https://pkg.go.dev/net/http@go1.26.5#NewRequestWithContext) — стандартная библиотека Go, tag `go1.26.5`, context на lifetime outbound request, проверено 2026-07-18.
- [Package net/http/httptest](https://pkg.go.dev/net/http/httptest@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, локальные HTTP servers для tests, проверено 2026-07-18.
- [Package context](https://pkg.go.dev/context@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, deadlines и cancellation, проверено 2026-07-18.
- [Package sync](https://pkg.go.dev/sync@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, `WaitGroup`, проверено 2026-07-18.
