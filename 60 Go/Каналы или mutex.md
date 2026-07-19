---
aliases: []
tags:
  - область/go
  - тема/конкурентность
статус: проверено
---

# Каналы или mutex

## TL;DR

Выбирайте не по лозунгу, а по ownership. Mutex подходит, когда несколько goroutines должны кратко обращаться к одному состоянию. Channel подходит, когда значение или команда передаётся владельцу, а ordering, backpressure и lifecycle являются частью протокола. Channel не делает shared state автоматически проще, а mutex не мешает хорошо изолировать данные.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-15.
- GOOS и GOARCH: решение зависит от workload, а не платформенной семантики.
- Пакеты или компоненты runtime: каналы, `sync.Mutex`.

## Ментальная модель

Есть два способа сериализовать изменение:

- **shared-memory ownership:** любая goroutine временно становится owner, захватив mutex;
- **message ownership:** одна goroutine постоянно владеет состоянием, остальные посылают ей команды.

Оба способа создают happens-before. Разница — в форме API и failure modes. [[60 Go/Mutex, RWMutex и примитивы координации sync|Lock protocol]] требует не забыть lock на каждом access. Message protocol требует обслуживать owner goroutine, закрывать channels, обрабатывать cancellation и не блокировать reply.

## Как устроено

Mutex сериализует critical sections без дополнительной goroutine. Он подходит для cache/map, где операция — короткое чтение или изменение и caller должен получить результат синхронно.

Channel переносит данные и одновременно регулирует скорость. Он подходит для pipeline, очереди команд и смены ownership mutable value. Directional channel types фиксируют, кто может отправлять и получать, но не определяют владельца `close` — это часть контракта [[60 Go/Буферизация, ownership и закрытие каналов|ownership и закрытия канала]].

В примере counter существует только в owner goroutine. Запрос содержит команду и reply channel; поэтому caller получает состояние после своей команды, а прямого общего доступа к `n` нет.

## Код

```go
package main

import "fmt"

type request struct {
	delta int
	reply chan<- int
}

func main() {
	requests := make(chan request)
	stopped := make(chan struct{})

	go func() {
		defer close(stopped)
		n := 0
		for r := range requests {
			n += r.delta
			r.reply <- n
		}
	}()

	reply := make(chan int)
	requests <- request{delta: 2, reply: reply}
	fmt.Println(<-reply)
	requests <- request{delta: 3, reply: reply}
	fmt.Println(<-reply)

	close(requests)
	<-stopped
}
```

## Ожидаемый результат

```text
2
5
```

Owner обрабатывает команды последовательно; каждый print ждёт соответствующий reply. Пример выполнен в официальном Go Playground на Go 1.26.5; вывод совпал с ожидаемым, проверено 2026-07-15.

## Trade-offs

- Mutex даёт меньше allocations и scheduling points для простой структуры, но caller работает с shared state и может удержать lock слишком долго.
- Owner goroutine централизует invariant и легко добавляет ordering и [[60 Go/Backpressure|backpressure]], но становится serial bottleneck и требует shutdown protocol.
- Channel полезен, когда модель должна явно описывать передачу данных. Оборачивать каждый getter/setter в request/reply channel без такой причины обычно сложнее mutex.
- Иногда нужны оба: mutex защищает локальное состояние stage, channels соединяют stages, а [[60 Go/Worker pool, fan-in, fan-out и bounded concurrency|worker pool]] ограничивает число одновременно работающих stages.

## Типичные ошибки

- Предположение: «channels всегда idiomatic» → простой map превращается в сложный RPC внутри процесса → protocol дороже состояния → используйте mutex.
- Предположение: «mutex нужен на каждый field» → deadlocks и inconsistent snapshots → lock должен защищать invariant, а не синтаксическую переменную → сгруппируйте состояние.
- Предположение: «отправка гарантированно завершится» → shutdown зависает → owner перестал получать → добавьте cancellation и ограничьте lifetime requests.
- Предположение: «reply channel можно не читать» → owner блокируется и перестаёт обслуживать всех → request protocol требует consume или buffered/cancelled reply.

## Когда применять

Сначала сформулируйте владельца состояния. Если ownership передаётся вместе с работой — channel. Если ownership кратко берут многие callers — mutex. Затем проверьте shutdown, contention и требуемый ordering минимальным benchmark или load test.

## Источники

- [Package sync](https://pkg.go.dev/sync@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
- [Go Language Specification — Channel types](https://go.dev/ref/spec#Channel_types) — The Go Project, language version Go 1.26, проверено 2026-07-15.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
