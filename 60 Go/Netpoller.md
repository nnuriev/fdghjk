---
aliases:
  - Network poller в runtime Go
tags:
  - область/go
  - тема/runtime
  - тема/сеть
статус: проверено
---

# Netpoller

## TL;DR

Netpoller позволяет goroutine ждать network I/O, не удерживая отдельный OS thread на всё время ожидания. На Unix пакеты `net` и `internal/poll` используют non-blocking descriptor: при `EAGAIN` runtime паркует G до readiness от epoll/kqueue. Windows path другой: overlapped `WSARecv`/`WSASend` завершаются completion packet через IOCP. В обоих случаях scheduler снова делает G runnable. Это не делает I/O неблокирующим на уровне API: `Read` всё ещё выглядит blocking и может вернуть partial data, timeout или error.

## Область применимости

- Версия Go: API `net` Go 1.26; runtime implementation Go 1.26.5.
- GOOS/GOARCH: основной механизм разобран для linux/amd64 и epoll; platform-independent contract отделён от epoll/kqueue/IOCP implementations.
- Компоненты: `net`, `internal/poll`, runtime netpoller, scheduler и timers.
- Вне scope: protocol parsing, TLS и application-level backpressure.

## Ментальная модель

Blocking call в Go API не равен заблокированному OS thread.

Для pollable socket путь чтения выглядит так:

~~~text
Conn.Read
  → non-blocking read syscall
  → data ready: вернуть bytes
  → EAGAIN: зарегистрировать interest и park G
  → epoll/kqueue readiness
  → сделать G runnable
  → повторить read syscall
~~~

Readiness означает «операцию стоит повторить», а не «полный application message уже доступен». Поэтому `Read` может вернуть меньше requested bytes, а framing остаётся обязанностью protocol code.

## Как устроено

Platform-independent `runtime/netpoll.go` определяет контракт backend: initialize, register descriptor, poll с timeout, break blocked poll и вернуть список goroutines. `pollDesc` содержит отдельные atomic states для reader и writer, deadline timers и generation, защищающую от stale event после close/reuse file descriptor.

На Linux `runtime/netpoll_epoll.go` использует epoll. Когда `internal/poll.FD` получает `EAGAIN`, он вызывает runtime poll wait. [[60 Go/Планировщик GMP|Scheduler]] проверяет netpoller без блокировки среди источников runnable work, а при отсутствии другой работы один M может ждать в blocking poll без P. Ready list инжектируется в runnable queues.

На Windows `internal/poll` запускает overlapped Winsock operation и связывает её с completion port; `runtime/netpoll_windows.go` получает IOCP completion, а не readiness для повторного syscall. Общий результат тот же: ожидающая G становится runnable. Но Unix-схему `EAGAIN → readiness → retry` к Windows применять нельзя.

Deadline не требует отдельной sleeping goroutine на socket. Timer помечает read/write deadline expired и разблокирует waiter с timeout error. `Close` также должен разбудить ожидание и отличаться от обычной readiness; generation в `pollDesc` не позволяет старому event ошибочно разбудить новый descriptor с тем же numeric fd.

Netpoller покрывает не всё:

- regular files на многих OS не дают полезной readiness semantics;
- cgo и произвольный blocking syscall могут удерживать M;
- user-space locks и channels паркуются другими runtime primitives;
- медленный remote peer не ограничивает число goroutines и memory автоматически — нужен timeout и backpressure.

## Код

Пример для Unix создаёт настоящий pollable socket pair без внешней сети и затем оставляет один P:

~~~go
package main

import (
	"fmt"
	"net"
	"os"
	"runtime"
	"syscall"
)

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func main() {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	must(err)
	leftFile := os.NewFile(uintptr(fds[0]), "left")
	rightFile := os.NewFile(uintptr(fds[1]), "right")
	left, err := net.FileConn(leftFile)
	must(err)
	right, err := net.FileConn(rightFile)
	must(err)
	leftFile.Close()
	rightFile.Close()
	defer left.Close()
	defer right.Close()

	runtime.GOMAXPROCS(1)

	started := make(chan struct{})
	result := make(chan string)
	go func() {
		close(started)
		buf := make([]byte, 2)
		n, err := right.Read(buf)
		must(err)
		result <- string(buf[:n])
	}()

	<-started
	runtime.Gosched()
	fmt.Println("main still runs")

	_, err = left.Write([]byte("ok"))
	must(err)
	fmt.Println(<-result)
}
~~~

Команда:

~~~text
go run main.go
~~~

## Ожидаемый результат

~~~text
main still runs
ok
~~~

`net.FileConn` дублирует исходные descriptors, поэтому временные `os.File` закрываются сразу. `Gosched` даёт reader возможность войти в network wait, не вводя timer-зависимость. [[60 Go/Execution trace|Execution trace]] должен показать goroutine в network wait и последующее unblock. Программа выполнена десять раз в официальном Go Playground на Go 1.26.5; каждый запуск дал ожидаемый вывод. Отдельный trace для этого примера не снимался, проверено 2026-07-15.

## Trade-offs

Goroutine-per-connection сохраняет простой sequential control flow и хорошо использует netpoller; тот же принцип лежит под обработкой connections в [[60 Go/HTTP-сервер на net-http|HTTP-сервере `net/http`]]. Event-loop вручную может уменьшить число goroutines в узком high-scale случае, но переносит scheduling, state machine и [[60 Go/Goroutines и lifecycle|lifecycle goroutines]] в application code. Без профиля это обычно усложнение.

Deadline ограничивает lifetime зависшего I/O, но слишком короткий timeout превращает нормальную tail latency в ошибки. [[60 Go/Тайм-ауты HTTP-сервера и клиента|Context cancellation и connection/HTTP deadlines]] решают связанные, но разные задачи: context сообщает intent по call tree, deadline socket прерывает конкретное ожидание I/O.

Большое число parked goroutines почти не расходует OS threads, но всё равно потребляет stacks, descriptors, buffers и application state. Bounded admission остаётся обязательным при ограниченном memory или downstream capacity.

## Типичные ошибки

**Неверное предположение:** одна ожидающая connection равна одному thread. **Симптом:** сложный application event loop без подтверждённой проблемы. **Причина:** pollable network waits паркуют G. **Исправление:** сначала посмотреть execution trace и thread profile.

**Неверное предположение:** readiness означает полный message. **Симптом:** truncated frame или ошибочный JSON parse. **Причина:** stream `Read` допускает partial result. **Исправление:** использовать framing и `io.ReadFull` там, где длина известна.

**Неверное предположение:** netpoller предотвращает resource exhaustion. **Симптом:** goroutine, fd и buffer count растут без bound. **Причина:** poller экономит threads, но не вводит admission control. **Исправление:** deadlines, connection limits и backpressure.

**Неверное предположение:** любой blocking syscall интегрирован с netpoller. **Симптом:** неожиданный рост OS threads и latency. **Причина:** regular file, cgo или custom syscall идёт другим путём. **Исправление:** trace syscall blocking и изучить конкретный package/port.

## Когда применять

- Используйте blocking-style `net` API; runtime уже предоставляет multiplexing.
- Ставьте deadlines на внешние I/O boundaries.
- Диагностируйте network wait через execution trace, а не по одному лишь числу goroutines.
- Для implementation claims фиксируйте GOOS, Go 1.26.5 и backend poller.

## Источники

- [Package net](https://pkg.go.dev/net@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [runtime/netpoll.go: platform-independent poller contract и pollDesc](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/netpoll.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/netpoll_epoll.go: Linux epoll backend](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/netpoll_epoll.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [internal/poll/fd_unix.go: non-blocking I/O loop](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/poll/fd_unix.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/netpoll_windows.go: IOCP backend](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/netpoll_windows.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [internal/poll/fd_windows.go: overlapped socket I/O](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/poll/fd_windows.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/proc.go: scheduler integration with netpoll](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/proc.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
