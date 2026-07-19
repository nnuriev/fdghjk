---
aliases: []
tags:
  - область/go
статус: проверено
---

# Graceful shutdown

## TL;DR

Graceful shutdown — протокол смены ownership: перестать принимать новую работу, сообщить долгоживущим компонентам об отмене, дождаться уже принятой работы в ограниченный budget и только затем завершить процесс.

`http.Server.Shutdown` закрывает listeners, закрывает idle connections и ждёт, пока active connections станут idle. Он не ждёт hijacked connections, включая WebSocket, и не заменяет координацию фоновых workers.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5.
- GOOS и GOARCH: API переносим; доставка process signals и поведение orchestration platform зависят от окружения.
- Пакеты: `net/http`, `context`, `os/signal` для production entrypoint.
- Вне scope: конкретные Kubernetes probes и drain policy load balancer.

## Ментальная модель

Shutdown — двухфазный barrier:

1. **Quiesce:** закрыть вход и перестать создавать новую работу.
2. **Drain:** дождаться владельцев уже принятой работы либо прервать ожидание по deadline.

Если процесс завершится между фазами, in-flight work оборвётся. Если drain не ограничен, один зависший request удержит deployment навсегда. Shutdown context задаёт последнюю временную границу процесса.

## Как устроено

После `Shutdown(ctx)` методы `Serve`, `ServeTLS`, `ListenAndServe` и `ListenAndServeTLS` возвращают `http.ErrServerClosed`. Это ожидаемый sentinel, а не incident. Главная goroutine не должна завершать процесс сразу после такого возврата: она обязана дождаться результата `Shutdown`.

`Shutdown` сначала закрывает все listeners, затем idle connections и опрашивает active connections до их перехода в idle. Новый request уже не принимается, но handler, который был active, может закончить ответ. При истечении context метод возвращает `ctx.Err()`; вызывающий код решает, применять ли жёсткий `Server.Close`.

После hijack connection больше не принадлежит HTTP server. Его нужно зарегистрировать и закрыть отдельно; `RegisterOnShutdown` подходит для отправки сигнала протоколу, но callback не блокирует ожидание его завершения — wait group остаётся ответственностью приложения.

В production entrypoint корневой сигнал остановки обычно создаёт `signal.NotifyContext`. Вызов возвращаемого `stop` освобождает signal subscription; после `<-ctx.Done()` этот context становится причиной перехода к quiesce, но тот же context не следует передавать в `Shutdown`, потому что он уже отменён — для drain нужен новый context с собственным timeout.

Production-порядок обычно таков: signal context отменяется → readiness переводится в not ready → даётся время load balancer перестать направлять трафик → вызывается `Shutdown` → останавливаются consumers/workers в порядке зависимостей → flush ограниченных буферов → процесс выходит.

## Код

```go
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
	"time"
)

type pipeListener struct {
	connections chan net.Conn
	done        chan struct{}
	closeOnce   sync.Once
}

func (l *pipeListener) Accept() (net.Conn, error) {
	select {
	case connection := <-l.connections:
		return connection, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *pipeListener) Close() error {
	l.closeOnce.Do(func() { close(l.done) })
	return nil
}

func (l *pipeListener) Addr() net.Addr { return pipeAddr("in-memory") }

type pipeAddr string

func (pipeAddr) Network() string { return "pipe" }
func (a pipeAddr) String() string { return string(a) }

func main() {
	started := make(chan struct{})
	release := make(chan struct{})

	mux := http.NewServeMux()
	mux.HandleFunc("GET /work", func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-release
		fmt.Fprint(w, "done")
	})

	serverSide, clientSide := net.Pipe()
	defer clientSide.Close()
	listener := &pipeListener{
		connections: make(chan net.Conn, 1),
		done:        make(chan struct{}),
	}
	listener.connections <- serverSide

	server := &http.Server{Handler: mux}
	serveErr := make(chan error, 1)
	go func() { serveErr <- server.Serve(listener) }()

	clientResult := make(chan string, 1)
	go func() {
		request, _ := http.NewRequest(http.MethodGet, "http://example/work", nil)
		fmt.Fprint(
			clientSide,
			"GET /work HTTP/1.1\r\nHost: example\r\nConnection: close\r\n\r\n",
		)
		resp, err := http.ReadResponse(bufio.NewReader(clientSide), request)
		if err != nil {
			clientResult <- err.Error()
			return
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		clientResult <- fmt.Sprintf("%d %s", resp.StatusCode, body)
	}()

	<-started
	go func() {
		time.Sleep(20 * time.Millisecond)
		close(release)
	}()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	shutdownErr := server.Shutdown(ctx)

	fmt.Println("shutdown:", shutdownErr)
	fmt.Println("request:", <-clientResult)
	fmt.Println("serve stopped:", errors.Is(<-serveErr, http.ErrServerClosed))
}
```

## Ожидаемый результат

```text
shutdown: <nil>
request: 200 done
serve stopped: true
```

`Shutdown` прекращает приём, но ждёт active handler; после освобождения handler клиент получает полный ответ, а `Serve` возвращает ожидаемый `ErrServerClosed`. `net.Pipe` и однократный listener заменяют только внешний socket, сохраняя настоящий `http.Server.Serve`. Пример выполнен в официальном Go Playground на Go 1.26.5; вывод совпал с ожидаемым, проверено 2026-07-15.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| До 1.16 | Signal channel и cancel function связывались вручную | Go 1.16 добавил `signal.NotifyContext` | Lifecycle process signal выражается обычным context и обязательным `stop` | [Go 1.16 Release Notes](https://go.dev/doc/go1.16) |
| До 1.26 | Отмена signal context не сообщала signal через `context.Cause` | Go 1.26 использует cause, указывающую полученный signal | Диагностика может отличить signal-driven shutdown, сохраняя общий `ctx.Err() == context.Canceled` | [Go 1.26 Release Notes](https://go.dev/doc/go1.26) |

## Trade-offs

- Длинный drain budget сохраняет больше in-flight работы, но замедляет rollout и удерживает старую версию. Короткий ускоряет замену, но повышает долю прерванных запросов. Выбор должен согласовываться с [[60 Go/Тайм-ауты HTTP-сервера и клиента|request timeout]] и внешним termination grace period.
- Последовательную остановку проще доказать: сначала producers, затем consumers и dependencies. Параллельная быстрее, но может закрыть ресурс, которым ещё пользуется другой компонент; ownership задач задавайте по правилам [[60 Go/Goroutines и lifecycle|lifecycle goroutines]].
- Жёсткий `Close` гарантирует верхнюю границу, но обрывает active connections. Это fallback после истечения graceful budget, а не равнозначная замена.

## Типичные ошибки

- Предположение: возврат `ErrServerClosed` означает ошибку запуска. Симптом: нормальный rollout логируется как fatal. Причина: `Serve` так сообщает о вызове `Shutdown`. Исправление: считать sentinel ожидаемым и отдельно обрабатывать другие ошибки.
- Предположение: можно вызвать `Shutdown` после выхода из `main`. Симптом: active requests обрываются. Причина: завершение `main` немедленно завершает процесс и goroutines. Исправление: `main` ждёт shutdown полностью.
- Предположение: `Shutdown` закроет WebSocket и background workers. Симптом: timeout drain или потерянная работа. Причина: эти ресурсы не принадлежат active HTTP connection set. Исправление: отдельный [[60 Go/Context, deadlines и распространение отмены|cancellation context]], registry и wait group.
- Предположение: readiness можно снять одновременно с закрытием listener без задержки распространения. Симптом: load balancer ещё направляет запросы в уже закрытый процесс. Причина: control plane обновляется не мгновенно. Исправление: согласовать quiesce interval с platform routing.

## Когда применять

Любой долгоживущий [[60 Go/HTTP-сервер на net-http|HTTP-сервер]] должен иметь ограниченный shutdown, даже если handler обычно короткий. Особенно важен протокол для streaming, очередей, batch workers и соединений с внешними системами.

Проверяйте shutdown integration-тестом: один in-flight request должен завершиться, новый — перестать приниматься, а зависший handler — привести к `context.DeadlineExceeded` в заданный budget.

## Источники

- [Документация Server.Shutdown](https://pkg.go.dev/net/http@go1.26.5#Server.Shutdown) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Исходный код Server.Shutdown](https://github.com/golang/go/blob/go1.26.5/src/net/http/server.go#L3150-L3215) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/server.go`, символ `Server.Shutdown`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Документация пакета os/signal](https://pkg.go.dev/os/signal@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Go 1.16 Release Notes: signal.NotifyContext](https://go.dev/doc/go1.16) — The Go Project, Go 1.16, проверено 2026-07-15.
- [Go 1.26 Release Notes: os/signal](https://go.dev/doc/go1.26) — The Go Project, Go 1.26, проверено 2026-07-15.
