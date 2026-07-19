---
aliases:
  - HTTP-сервер на net/http
tags:
  - область/go
статус: проверено
---

# HTTP-сервер на net/http

## TL;DR

`net/http` разделяет транспортный lifecycle и прикладную обработку. `http.Server` принимает соединения и управляет ими, `ServeMux` выбирает обработчик по методу, host и пути, а `Handler` преобразует один `*http.Request` в ответ через `http.ResponseWriter`.

Практическое правило: в production создавайте собственные `Server` и `ServeMux`, явно задавайте эксплуатационные параметры и собирайте middleware вокруг `Handler`. Глобальные `DefaultServeMux` и `ListenAndServe` удобны для маленького примера, но скрывают зависимости и конфигурацию.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5. Для method/wildcard patterns примера main module/workspace должен иметь directive `go 1.22+`, без `GODEBUG=httpmuxgo121=1` и эквивалентного `godebug` в `go.mod`/`go.work`.
- GOOS и GOARCH: семантика API переносима; детали TCP и HTTP/2 зависят от ОС, сети и согласованного протокола.
- Пакеты: `net/http`, в примере — `net/http/httptest`.
- Вне scope: TLS-конфигурация, HTTP/2 internals, WebSocket и выбор стороннего router.

## Ментальная модель

Сервер — это конвейер `listener → connection → request → mux → handler → response`. Транспорт владеет соединением и телом входящего запроса, router выбирает функцию, middleware оборачивает её сквозной политикой, а handler владеет только логикой одного запроса.

Исходящие обращения этого же компонента имеют другой lifecycle: connection pool и response body принадлежат [[60 Go/HTTP-клиент и Transport|HTTP-клиенту и его Transport]], а не server handler.

Отсюда правило: handler не должен управлять listener или завершением процесса. Он обязан либо вернуть ответ, либо прекратить работу после отмены `Request.Context`; lifecycle всего процесса остаётся на уровне `Server`.

## Как устроено

`Server.Serve` принимает соединения из `net.Listener`. Для каждого соединения сервер запускает обслуживающую goroutine; HTTP/1-запросы на одном соединении читаются и передаются handler последовательно, тогда как HTTP/2 допускает несколько потоков внутри соединения. До вызова handler сервер разбирает start line и headers и формирует `Request`.

`Handler` имеет единственный метод `ServeHTTP(ResponseWriter, *Request)`. Первый вызов `WriteHeader` фиксирует статус; первый `Write` без явного статуса неявно отправляет `200 OK`. Поэтому headers нужно установить до записи body. Сервер закрывает входящий `Request.Body`; handler обычно не должен закрывать его сам.

Новый `ServeMux` поддерживает patterns с методом и wildcard-сегментами, например `GET /users/{id}`; значение извлекается через `Request.PathValue`. Его выбор определяется не только toolchain: при main-module directive старше `go 1.22` Go 1.26.5 по умолчанию включает legacy `httpmuxgo121`, а `GODEBUG=httpmuxgo121=1` может включить его явно. Middleware — обычная функция `func(http.Handler) http.Handler`: обёртка может выполнить работу до и после следующего handler, не меняя транспортный контракт.

Наблюдаемый результат определяется самым внутренним handler, но политика проходит снаружи внутрь. Поэтому порядок `recover → tracing → authentication → business handler` значим: перестановка меняет, какие сбои и метрики увидит каждая обёртка.

## Код

```go
package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
)

func withRequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Header.Set("X-Request-ID", "req-7")
		next.ServeHTTP(w, r)
	})
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /users/{id}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(
			w,
			"{\"id\":%q,\"request_id\":%q}\n",
			r.PathValue("id"),
			r.Header.Get("X-Request-ID"),
		)
	})

	req := httptest.NewRequest(http.MethodGet, "/users/42", nil)
	rec := httptest.NewRecorder()
	withRequestID(mux).ServeHTTP(rec, req)

	fmt.Println(rec.Code)
	fmt.Println(rec.Header().Get("Content-Type"))
	fmt.Print(rec.Body.String())
}
```

## Ожидаемый результат

Для Go 1.26.5:

```text
200
application/json
{"id":"42","request_id":"req-7"}
```

При новой семантике `ServeMux` извлекает `42` из wildcard, middleware добавляет request ID до передачи управления, а первая запись body фиксирует статус `200`. Пример выполнен в официальном Go Playground на Go 1.26.5 с новой семантикой mux; вывод совпал с ожидаемым, проверено 2026-07-15.

## Эволюция и версии

| Версия | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| До Go 1.22 | `ServeMux` сопоставлял в основном host и path | — | Pattern `GET /users/{id}` не имел новой method/wildcard semantics | [Go 1.22 Release Notes](https://go.dev/doc/go1.22#enhanced-routing-patterns) |
| Go 1.22+ directive | — | Добавлены method/wildcard patterns и `Request.PathValue`; legacy доступен через `httpmuxgo121` | Семантика зависит от `go` directive и GODEBUG, а не только от версии toolchain | [GODEBUG defaults](https://go.dev/doc/godebug) |
| Go 1.26, новый mux | Trailing-slash redirect нового mux возвращал `301` | Возвращается `307`, сохраняющий method и body; legacy mux остаётся с `301` | POST/PUT больше не превращаются redirect-клиентом в GET только из-за status | [Go 1.26 Release Notes](https://go.dev/doc/go1.26#net/http) |

## Trade-offs

- `ServeMux` из standard library даёт минимальную зависимость, совместимость с обычным `Handler` и достаточную маршрутизацию для большинства API. Сторонний router выигрывает, если действительно нужны его генерация маршрутов, binding или иная дополнительная семантика, но добавляет собственный lifecycle и правила совместимости.
- Общий middleware централизует политику, но скрывает control flow при слишком глубокой цепочке. Локальный явный вызов проще там, где правило относится только к одному endpoint.
- Один общий `Server` проще эксплуатировать. Раздельные public/admin servers позволяют разные access policy и timeout, но требуют отдельного shutdown и наблюдаемости.

## Типичные ошибки

- Предположение: headers можно изменить после записи body. Симптом: клиент не видит header или получает уже выбранный статус. Причина: первый `Write` вызывает неявный `WriteHeader(http.StatusOK)`. Исправление: сформировать status и headers до body.
- Предположение: `http.ListenAndServe` с nil handler достаточно для production. Симптом: неявные глобальные routes, нулевые timeout и трудно тестируемая конфигурация. Причина: используются `DefaultServeMux` и значения `Server` по умолчанию. Исправление: создать собственные `ServeMux` и `Server`.
- Предположение: goroutine, запущенная handler, автоматически заканчивается вместе с запросом. Симптом: после disconnect продолжается работа или растёт число goroutines. Причина: фоновая работа игнорирует `r.Context().Done()`. Исправление: передавать context вниз и явно определять ownership долгоживущей работы.

## Когда применять

Используйте `net/http` напрямую, когда API укладывается в стандартный `Handler`, а команде важны прозрачные зависимости и совместимость middleware. Выносите транспортную адаптацию в тонкий handler, а бизнес-логику — в функции, не зависящие от `ResponseWriter`; [[60 Go/Тестирование и httptest|httptest]] тогда проверяет HTTP-адаптер без внешней сети.

Эксплуатационный `Server` дополняйте ограничениями из [[60 Go/Тайм-ауты HTTP-сервера и клиента|заметки о HTTP-тайм-аутах]] и завершайте по модели [[60 Go/Graceful shutdown|graceful shutdown]].

## Источники

- [Документация пакета net/http](https://pkg.go.dev/net/http@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [GODEBUG defaults](https://go.dev/doc/godebug) — The Go Project, поведение toolchain Go 1.26.5, проверено 2026-07-15.
- [Go 1.22 Release Notes — Enhanced routing patterns](https://go.dev/doc/go1.22#enhanced-routing-patterns) — The Go Project, Go 1.22, проверено 2026-07-15.
- [Go 1.26 Release Notes — net/http](https://go.dev/doc/go1.26#net/http) — The Go Project, Go 1.26, проверено 2026-07-15.
- [Исходный код HTTP-сервера](https://github.com/golang/go/blob/go1.26.5/src/net/http/server.go#L1897-L2010) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/server.go`, символ `conn.serve`, проверено 2026-07-15.
- [Исходный код нового ServeMux redirect](https://github.com/golang/go/blob/go1.26.5/src/net/http/server.go#L2647-L2696) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/server.go`, проверено 2026-07-15.
- [Исходный код legacy ServeMux redirect](https://github.com/golang/go/blob/go1.26.5/src/net/http/servemux121.go#L104-L132) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/servemux121.go`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
