---
aliases: []
tags:
  - область/go
  - тема/конкурентность
статус: проверено
---

# Backpressure

## TL;DR

Backpressure — обратная связь от медленного consumer к быстрому producer. В Go её естественно выражает [[60 Go/Буферизация, ownership и закрытие каналов|ограниченный channel]]: когда capacity исчерпана, send блокируется. Это не «проблема производительности», а выбранная overload policy; альтернативы — ограниченно ждать, отклонять, отбрасывать, объединять или деградировать работу.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-15.
- GOOS и GOARCH: семантика channel не зависит от платформы; capacity выбирается по workload.
- Пакеты или компоненты runtime: buffered channels, `select`.

## Ментальная модель

Очередь хранит разницу скоростей во времени. Если средняя скорость producer постоянно выше consumer, любой конечный buffer когда-нибудь заполнится. Увеличение buffer лишь откладывает момент выбора и одновременно повышает память и queueing latency.

Поэтому bounded queue должна иметь явный контракт:

1. сколько элементов допустимо in-flight;
2. сколько producer может ждать;
3. что происходит при насыщении;
4. как перегрузка видна метрикам и caller.

## Как устроено

Для channel capacity `C` k-й receive синхронизируется перед завершением (k+`C`)-го send. Это ограничивает число завершившихся sends относительно receives, но не весь объём in-flight работы. Общий bound включает очередь, элементы у active consumers, значения и ресурсы заблокированных producers и upstream buffers. Если каждый заблокированный send спрятать в новую goroutine, их число останется неограниченным.

Blocking send передаёт backpressure вверх автоматически. Это безопасно лишь если upstream допускает ожидание и не удерживает lock или дефицитный connection. [[60 Go/select, cancellation и timeout|`select` с deadline/cancellation]] превращает бесконечное ожидание в ограниченное. `default` реализует немедленный drop/reject, но loss policy должна быть частью API, а не скрытой оптимизацией.

Создание новой goroutine для каждой заблокированной отправки не устраняет очередь: оно превращает goroutine stacks в неограниченный скрытый buffer.

## Код

```go
package main

import "fmt"

func main() {
	queue := make(chan int, 1)
	queue <- 1

	secondSent := make(chan struct{})
	go func() {
		queue <- 2
		close(secondSent)
	}()

	select {
	case <-secondSent:
		fmt.Println("unexpected")
	default:
		fmt.Println("producer blocked")
	}

	fmt.Println(<-queue)
	<-secondSent
	fmt.Println(<-queue)
}
```

## Ожидаемый результат

```text
producer blocked
1
2
```

Вторая отправка не может завершиться, пока единственная ячейка занята `1`. Первый receive освобождает capacity, после чего send `2` и закрытие `secondSent` завершаются. Пример выполнен в официальном Go Playground на Go 1.26.5; вывод совпал с ожидаемым, проверено 2026-07-15.

## Trade-offs

- **Block:** сохраняет все элементы и ограничивает память, но переносит latency upstream и может исчерпать request budget.
- **Reject/drop:** удерживает latency и ресурсы, но теряет работу; нужны явная ошибка или loss metrics.
- **Coalesce:** несколько устаревающих updates заменяются последним; подходит только если промежуточные состояния не имеют самостоятельной ценности.
- **Больший buffer:** поглощает подтверждённый краткий burst, но маскирует устойчивое отставание и увеличивает хвост latency.

## Типичные ошибки

- Предположение: «buffer устранил перегрузку» → спустя время очередь снова полна → средние rates не сбалансированы → ограничьте admission или увеличьте processing capacity.
- Предположение: «blocked sends безопасны» → request goroutines и connections накапливаются → ожидание не ограничено budget → добавьте context/deadline.
- Предположение: «goroutine вокруг send делает его неблокирующим» → растут goroutines и память → очередь переместилась в runtime → используйте [[60 Go/Worker pool, fan-in, fan-out и bounded concurrency|bounded workers]].
- Предположение: «drop можно не наблюдать» → система выглядит здоровой, но теряет данные → считайте rejects/drops и документируйте semantics.

## Когда применять

Проектируйте backpressure на каждой границе producer/consumer. Размер channel выводите из допустимого in-flight объёма и burst, а overload action — из ценности работы и latency budget. Между сервисами выбор admission и overload policy устроен так же; его разбирает [[40 Распределённые системы/Карта — Распределённые системы|карта распределённых систем]]. Проверяйте steady-state overload, а не только короткий happy path.

## Источники

- [The Go Memory Model — Channel communication](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
- [Go Language Specification — Send statements](https://go.dev/ref/spec#Send_statements) — The Go Project, language version Go 1.26, проверено 2026-07-15.
- [Go Language Specification — Select statements](https://go.dev/ref/spec#Select_statements) — The Go Project, language version Go 1.26, проверено 2026-07-15.
