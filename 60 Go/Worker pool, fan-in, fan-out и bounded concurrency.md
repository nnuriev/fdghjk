---
aliases: []
tags:
  - область/go
  - тема/конкурентность
статус: проверено
---

# Worker pool, fan-in, fan-out и bounded concurrency

## TL;DR

Worker pool запускает фиксированное число workers и тем самым ограничивает число одновременно выполняемых работ. Fan-out распределяет вход между workers, fan-in собирает результаты. Корректный pipeline обязан определить ownership закрытия, остановку при раннем выходе consumer и верхнюю границу одновременно удерживаемой работы.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-15.
- GOOS и GOARCH: корректность платформонезависима; оптимальный parallelism зависит от CPU, I/O и внешних лимитов.
- Пакеты или компоненты runtime: каналы, `sync.WaitGroup`, goroutines.

## Ментальная модель

Pipeline состоит из stages. Каждый stage:

1. получает ownership входного элемента;
2. выполняет ограниченную работу;
3. передаёт результат downstream;
4. прекращает отправку при отмене;
5. закрывает только свой outbound channel после завершения всех senders.

Fan-out означает, что несколько workers получают из одного input. Fan-in означает, что несколько producers сводятся в один output. Worker count — concurrency limit, а не автоматически подходящее значение `GOMAXPROCS`.

## Как устроено

Общий jobs channel выдаёт каждую job ровно одному worker. Workers могут завершать в любом порядке, поэтому output order не совпадает с input order без дополнительной нумерации и reorder buffer.

Закрывает `jobs` producer, знающий, что заданий больше нет. Закрыть `results` можно только после завершения всех workers; иначе оставшийся sender получит panic. `WaitGroup` образует этот barrier, а распределение права на `close` следует общему контракту [[60 Go/Буферизация, ownership и закрытие каналов|ownership каналов]].

Bounded concurrency ограничивает активные operations числом workers. Buffered channels дополнительно ограничивают queued jobs/results. Если consumer прекращает receive раньше, workers блокируются на send; при отправке результата production-worker должен выбирать между `results <- value` и `<-ctx.Done()`, распространяя [[60 Go/Context, deadlines и распространение отмены|cancellation context]].

## Код

```go
package main

import (
	"fmt"
	"sort"
	"sync"
)

func main() {
	jobs := make(chan int)
	results := make(chan int)
	var workers sync.WaitGroup

	for i := 0; i < 2; i++ {
		workers.Go(func() {
			for n := range jobs {
				results <- n * n
			}
		})
	}

	go func() {
		defer close(jobs)
		for _, n := range []int{1, 2, 3, 4} {
			jobs <- n
		}
	}()

	go func() {
		workers.Wait()
		close(results)
	}()

	var got []int
	for result := range results {
		got = append(got, result)
	}
	sort.Ints(got)
	fmt.Println(got)
}
```

## Ожидаемый результат

```text
[1 4 9 16]
```

Порядок фактического завершения workers не определён, поэтому пример сортирует результаты перед печатью. Каждая job получена одним worker; `results` закрывается после всех sends. Обычный запуск выполнен в официальном Go Playground на Go 1.26.5 и напечатал `[1 4 9 16]`; режим `-race` в Playground недоступен, проверено 2026-07-15.

## Trade-offs

- Больше workers повышают throughput только до насыщения CPU, I/O, connection pool или downstream. После этого растут contention и latency.
- Сохранение input order требует sequence number и buffer либо последовательной публикации; это память и head-of-line blocking.
- Отдельная goroutine на job проще для малого гарантированно ограниченного набора. Worker pool нужен, когда вход потенциально велик или внешний ресурс имеет строгий лимит.
- Unbuffered jobs быстро передаёт [[60 Go/Backpressure|backpressure]] producer. Buffer сглаживает burst, но увеличивает queued work.

## Типичные ошибки

- Предположение: «consumer всегда дочитает results» → workers остаются навсегда на send и образуют [[60 Go/Goroutine и channel leaks|goroutine leak]] → ранний выход не распространяет cancellation → выбирайте `ctx.Done()` при send и receive.
- Предположение: «любой sender может закрыть output» → panic `send on closed channel` → другие senders ещё активны → закрывайте после `Wait` всех senders.
- Предположение: «worker count равен числу CPU» → внешний сервис перегружается → bottleneck находится downstream → лимит выводите из ресурса и измерений.
- Предположение: «fan-out сохраняет порядок» → ответы переставлены → durations различаются → добавьте sequence/reorder либо не обещайте порядок.

## Когда применять

Применяйте bounded concurrency для массового I/O, CPU jobs и обращения к ограниченному downstream. До реализации задайте limit, queue capacity, order contract, cancellation path и владельца каждого `close`.

## Источники

- [Go Concurrency Patterns: Pipelines and cancellation](https://go.dev/blog/pipelines) — The Go Project, публикация 2014-03-13, проверено 2026-07-15.
- [Package sync](https://pkg.go.dev/sync@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
- [Go Language Specification — Channel types](https://go.dev/ref/spec#Channel_types) — The Go Project, language version Go 1.26, проверено 2026-07-15.
