---
aliases: []
tags:
  - область/go
  - тема/конкурентность
статус: проверено
---

# Goroutine и channel leaks

## TL;DR

Goroutine leak возникает, когда goroutine больше не нужна владельцу, но не может достичь `return`: обычно она навсегда ждёт receive, send, lock или I/O. Channel сам освобождается GC, когда недостижим; «channel leak» практически означает потерянный протокол, из-за которого goroutines или buffered values остаются достижимыми.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-15.
- GOOS и GOARCH: lifecycle semantics платформонезависима.
- Пакеты или компоненты runtime: goroutines, channels, `context`, goroutine profile.

## Ментальная модель

Каждая запущенная goroutine — ресурс, чей owner и путь завершения определяются общим [[60 Go/Goroutines и lifecycle|lifecycle]]. Для каждого blocking point должен существовать хотя бы один путь разблокировки:

- value или `close` для receive;
- receiver либо cancellation для send;
- `Unlock` для lock;
- deadline/close/cancel для I/O.

GC не завершает goroutine только потому, что caller потерял к ней ссылку. Её stack остаётся корнем для достижимых объектов, поэтому одна зависшая goroutine способна удерживать большие buffers и целый object graph.

## Как устроено

Типичный pipeline leak появляется, когда downstream берёт один результат и возвращается, а upstream продолжает отправлять в канал без receiver. Поэтому [[60 Go/Worker pool, fan-in, fan-out и bounded concurrency|worker pool или pipeline]] обязан распространять ранний выход downstream. Буфер лишь разрешает нескольким sends завершиться; после заполнения leak проявится снова.

Закрытие input корректно завершает `for range` только если owner действительно может гарантировать конец producers. Для abandonment нужен отдельный cancellation signal. Production-loop обычно выбирает работу и `ctx.Done()` как при receive, так и при потенциально блокирующем send; правила распространения этого сигнала задаёт [[60 Go/Context, deadlines и распространение отмены|`context.Context`]].

Cancel лишь подаёт сигнал остановки. Owner всё равно должен дождаться `stopped`/`WaitGroup`, иначе shutdown не подтверждает фактическое освобождение ресурсов.

## Код

```go
package main

import (
	"context"
	"fmt"
)

func worker(ctx context.Context, input <-chan int, stopped chan<- struct{}) {
	defer close(stopped)

	select {
	case <-input:
		// Обработать одно значение.
	case <-ctx.Done():
		return
	}
}

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	input := make(chan int)
	stopped := make(chan struct{})

	go worker(ctx, input, stopped)
	cancel()
	<-stopped

	fmt.Println("worker stopped")
}
```

## Ожидаемый результат

```text
worker stopped
```

Без case `ctx.Done()` worker остался бы на receive, потому что никто не отправляет и не закрывает `input`. `<-stopped` подтверждает фактический возврат. Обычный запуск выполнен в официальном Go Playground на Go 1.26.5 и напечатал `worker stopped`; режим `-race` в Playground недоступен, проверено 2026-07-15.

## Trade-offs

- Закрытие work channel просто для нормального конца конечного потока. Context лучше выражает отказ consumer и отмену дерева работы.
- Buffered result channel иногда позволяет producer завершить заранее известное малое число sends, но такое доказательство зависит от capacity и не заменяет общую cancellation strategy.
- Периодический [[60 Go/Профилирование с pprof|goroutine profile]] помогает находить рост, но не заменяет ownership design: некоторые long-lived goroutines легитимны.

## Типичные ошибки

- Предположение: «goroutine соберёт GC» → `runtime.NumGoroutine` и память растут → stack остаётся активным root → обеспечьте cancellation и join.
- Предположение: «закроем channel со стороны consumer» → concurrent producer паникует → consumer не владеет окончанием sends → отменяйте отдельным signal.
- Предположение: «buffer размером один предотвращает leak» → на втором результате producer зависает → capacity лишь отложила блокировку → сделайте send отменяемым.
- Предположение: «cancel означает stopped» → ресурсы ещё используются после shutdown → cancellation кооперативна → дождитесь completion.

## Когда применять

На code review перечисляйте все `go` statements и blocking operations. Для каждой goroutine фиксируйте owner, cancel path и join. В tests проверяйте ранний выход consumer, ошибку посередине pipeline и shutdown под заполненным channel.

## Источники

- [Package context — WithCancel example](https://pkg.go.dev/context@go1.26.5#example-WithCancel) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
- [Go Concurrency Patterns: Pipelines and cancellation](https://go.dev/blog/pipelines) — The Go Project, публикация 2014-03-13, проверено 2026-07-15.
- [Go Language Specification — Channel types](https://go.dev/ref/spec#Channel_types) — The Go Project, language version Go 1.26, проверено 2026-07-15.
