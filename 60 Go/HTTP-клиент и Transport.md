---
aliases: []
tags:
  - область/go
статус: проверено
---

# HTTP-клиент и Transport

## TL;DR

`http.Client` задаёт политику запроса: redirects, cookies и общий timeout. Его `RoundTripper`, обычно `*http.Transport`, выполняет один обмен и владеет состоянием соединений, proxy, TLS и HTTP/2.

И `Client`, и `Transport` рассчитаны на повторное конкурентное использование. Pool принадлежит transport: новые clients с `Transport == nil` разделяют `http.DefaultTransport`, а новый transport на каждый запрос создаёт отдельный pool. Непрочитанный или незакрытый `Response.Body` может помешать повторному использованию HTTP/1.x-соединения.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5.
- GOOS и GOARCH: API переносим; DNS, proxy, socket и TLS зависят от платформы и окружения.
- Пакет: `net/http`.
- Вне scope: детали wire protocol HTTP/2, custom DNS resolver и retry policy приложения.

## Ментальная модель

`Client` — диспетчер политики, `Transport` — долгоживущий пул и машина одного сетевого обмена. Вызов проходит как `Client.Do → redirect/auth policy → RoundTripper.RoundTrip → response`.

Connection pool принадлежит `Transport`, а не `Client` или отдельному запросу. Несколько clients могут разделять transport и при этом иметь разные timeout, redirect и cookie policies. В отличие от входящего body, которым управляет [[60 Go/HTTP-сервер на net-http|HTTP-сервер]], исходящий `Response.Body` принадлежит caller клиента. Поэтому время жизни transport должно быть не короче потока запросов к одним и тем же upstream. Когда caller закрывает response body, transport может завершить lifecycle обмена.

## Как устроено

`Client.Do` валидирует запрос, применяет deadline, вызывает `RoundTripper` и при необходимости следует redirect. Ответ с кодом не-2xx не является Go-ошибкой: transport успешно выполнил HTTP-обмен, а статус интерпретирует приложение.

`Transport` кеширует idle connections и безопасен для нескольких goroutines. Для HTTP/1.x reuse обычно требует дочитать body до `io.EOF` и закрыть его. Простой `Close` до EOF нельзя считать универсальной гарантией reuse: если body больше не нужен, приложение может ограниченно дочитать его либо принять закрытие соединения как осознанную цену.

Настраиваемый transport обычно получают через `http.DefaultTransport.(*http.Transport).Clone()`, затем меняют поля до первого запроса. Структуру нельзя копировать после начала использования: внутри уже есть mutex, cache и состояние соединений.

Интерфейс `RoundTripper` — удобный seam для адаптера и [[60 Go/Тестирование и httptest|unit test]]. Он должен вернуть response с ненулевым body при nil error, не интерпретировать HTTP status как ошибку и учитывать отмену через [[60 Go/Context, deadlines и распространение отмены|`Request.Context`]].

## Код

```go
package main

import (
	"fmt"
	"io"
	"net/http"
	"strings"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}

func main() {
	var calls int
	rt := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		body := "ok:" + r.Header.Get("X-Request-ID")
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     make(http.Header),
			Body:       io.NopCloser(strings.NewReader(body)),
			Request:    r,
		}, nil
	})

	client := &http.Client{Transport: rt}
	for _, id := range []string{"a", "b"} {
		req, _ := http.NewRequest(http.MethodGet, "https://service.test/data", nil)
		req.Header.Set("X-Request-ID", id)

		resp, err := client.Do(req)
		if err != nil {
			panic(err)
		}
		body, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			panic(err)
		}
		fmt.Printf("%d %s\n", resp.StatusCode, body)
	}
	fmt.Println("round trips:", calls)
}
```

## Ожидаемый результат

Для Go 1.26.5:

```text
200 ok:a
200 ok:b
round trips: 2
```

Один `Client` повторно использует один `RoundTripper`; каждый `Do` означает отдельный логический обмен. В реальном `Transport` два обмена могут разделить одно физическое соединение, но этот детерминированный пример такого не показывает. Пример выполнен в официальном Go Playground на Go 1.26.5; вывод совпал с ожидаемым, проверено 2026-07-15.

## Эволюция и версии

| Версия | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| Go 1.24 | HTTP/2 настраивался менее явно через transport defaults/GODEBUG | `Transport.HTTP2` и `Transport.Protocols` сделали protocol policy явной | Конфигурацию HTTP/1/HTTP/2 можно фиксировать на экземпляре transport | [Go 1.24 Release Notes](https://go.dev/doc/go1.24#net/http) |
| Go 1.26 | — | Добавлены `HTTP2Config.StrictMaxConcurrentRequests` и low-level `Transport.NewClientConn`; cookie jar учитывает `Request.Host`, если он задан | `NewClientConn` не входит в pool: caller владеет connection и обязан закрыть его; Host override теперь влияет на cookie URL | [Go 1.26 Release Notes](https://go.dev/doc/go1.26#net/http) |

## Trade-offs

- Общий client/transport снижает число handshakes и sockets, но общая конфигурация должна подходить всем вызовам. Отдельный client оправдан другой redirect, cookie или timeout policy; отдельный transport — отдельным proxy, TLS или connection limits.
- `http.DefaultClient` удобен, но имеет нулевой общий timeout. С явно созданным client budget и dependency видны в коде; уровни ограничения выбираются по [[60 Go/Тайм-ауты HTTP-сервера и клиента|модели HTTP-тайм-аутов]].
- Полное чтение небольшого body помогает reuse. Для большого или ненужного body выгоднее прекратить чтение и пожертвовать конкретным соединением, чем тратить bandwidth и память только ради pool.

## Типичные ошибки

- Предположение: любой новый `http.Client` создаёт новый pool. Симптом: неверная модель ресурсов или лишние transports ради разных timeout. Причина: `Transport == nil` использует общий `http.DefaultTransport`, а pool разделяется именно через transport. Исправление: переиспользовать transport; создавать отдельные clients для client-level policy и отдельный transport только для proxy/TLS/connection policy.
- Предположение: `err == nil` означает успешный бизнес-ответ. Симптом: 500 или 404 обрабатывается как успех. Причина: HTTP status принадлежит протоколу, а не ошибке выполнения `Do`. Исправление: отдельно классифицировать status и transport error.
- Предположение: достаточно проверить `resp`, но body можно не закрывать. Симптом: connection reuse ухудшается и растёт число соединений. Причина: lifecycle response не завершён. Исправление: после успешного `Do` всегда закрывать body и осознанно решать, дочитывать ли его.
- Предположение: transport можно менять во время трафика. Симптом: data race или непредсказуемая смесь настроек. Причина: конфигурационные поля не являются runtime control plane. Исправление: настроить до использования либо создать новый transport и атомарно переключить владельца.

## Когда применять

Создавайте один долгоживущий client на устойчивую upstream-policy и инъецируйте его зависимостям. Для unit tests подменяйте `RoundTripper`, а для integration-проверки реального pooling и протокола используйте локальный `httptest.Server`.

После остановки новых запросов завершение процесса дополняйте `CloseIdleConnections`.

## Источники

- [Документация пакета net/http: Client и Transport](https://pkg.go.dev/net/http@go1.26.5#Client) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Go 1.24 Release Notes — net/http](https://go.dev/doc/go1.24#net/http) — The Go Project, Go 1.24, проверено 2026-07-15.
- [Go 1.26 Release Notes — net/http](https://go.dev/doc/go1.26#net/http) — The Go Project, Go 1.26, проверено 2026-07-15.
- [Исходный код Client.Do](https://github.com/golang/go/blob/go1.26.5/src/net/http/client.go#L173-L193) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/client.go`, проверено 2026-07-15.
- [Исходный код Transport.NewClientConn](https://github.com/golang/go/blob/go1.26.5/src/net/http/clientconn.go#L93-L113) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/clientconn.go`, проверено 2026-07-15.
- [Исходный код Transport](https://github.com/golang/go/blob/go1.26.5/src/net/http/transport.go#L97-L335) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/transport.go`, тип `Transport`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
