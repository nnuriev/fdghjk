---
aliases:
  - Go memory model
tags:
  - область/go
  - тема/конкурентность
статус: проверено
---

# Модель памяти Go и happens-before

## TL;DR

Happens-before отвечает не на вопрос «что runtime, вероятно, выполнит раньше», а на вопрос «какую запись read обязан видеть». Он строится как транзитивное замыкание program order внутри goroutine и документированных synchronization edges между goroutines. Неупорядоченные конфликтующие accesses образуют [[60 Go/Data races, deadlocks и livelocks|data race]], когда хотя бы один из них — non-synchronizing; atomic operations подчиняются отдельному synchronization protocol. Timing и `time.Sleep` ordering не создают.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-15.
- GOOS и GOARCH: memory model — гарантия языка для всех реализаций; стоимость primitives платформозависима.
- Пакеты или компоненты runtime: channels, `sync`, `sync/atomic`, goroutine creation.

## Ментальная модель

Рассуждение состоит из трёх слоёв:

1. **sequenced-before:** порядок операций одной goroutine по правилам языка;
2. **synchronized-before:** edge, созданный channel, lock, atomic или другим документированным primitive;
3. **happens-before:** все пути, полученные объединением и транзитивностью первых двух.

Read видит write, когда write happens-before read и между ними нет другой более поздней write к той же location. Для data-race-free программ результат объясним некоторым sequentially consistent interleaving (DRF-SC).

## Как устроено

Ключевые synchronization edges:

- `go f()` синхронизирует запуск с началом `f`, но завершение `f` само по себе ничего не публикует;
- send синхронизируется перед завершением соответствующего receive; влияние [[60 Go/Буферизация, ownership и закрытие каналов|буферизации канала]] уточняется ниже;
- `close(ch)` синхронизируется перед receive, который возвращает zero value из-за закрытия;
- `Unlock` синхронизируется перед последующим [[60 Go/Mutex, RWMutex и примитивы координации sync|`Lock` того же mutex]];
- return task из `WaitGroup.Go`/`Done` синхронизируется перед разблокированным `Wait`;
- наблюдающая [[60 Go/Пакет sync-atomic|atomic operation]] синхронизируется с atomic operation, чей эффект она увидела; все atomics образуют sequentially consistent order.

Buffered channel добавляет capacity-dependent edge: k-й receive синхронизируется перед завершением (k+`C`)-го send. Поэтому завершение send в buffer не означает, что конкретный consumer уже обработал значение.

## Код

```go
package main

import "fmt"

func main() {
	var message string
	done := make(chan struct{})

	go func() {
		message = "ready"
		close(done)
	}()

	<-done
	fmt.Println(message)
}
```

## Ожидаемый результат

```text
ready
```

Write `message = "ready"` sequenced-before `close(done)`; close synchronized-before receive; receive sequenced-before print. Транзитивно write happens-before read. Обычный запуск выполнен в официальном Go Playground на Go 1.26.5 и напечатал `ready`; режим `-race` в Playground недоступен, проверено 2026-07-15.

## Trade-offs

- Channel одновременно передаёт значение и ordering, но добавляет protocol и возможную блокировку.
- Mutex публикует произвольный составной invariant между critical sections и часто проще atomics.
- Atomics дают точный low-level edge с малой surface area; сложный multi-step protocol труднее проверить.
- Completion synchronization (`Wait`/done channel) нужна даже тогда, когда scheduler «всегда успевает» на тестовой машине.

## Типичные ошибки

- Предположение: «goroutine завершилась — записи видимы» → иногда читается zero value → completion edge отсутствует → используйте channel, lock или `WaitGroup`.
- Предположение: «`Sleep` достаточно» → flaky test или race → время не создаёт happens-before → синхронизируйте событие.
- Предположение: «увидел flag — увижу и payload» → partially published state → обычные accesses не упорядочены → защищайте оба одним protocol.
- Предположение: «buffered send означает обработку» → producer освобождает ресурс слишком рано → send завершился при копировании в buffer → нужен acknowledgment после обработки.

## Когда применять

Для каждого shared access нарисуйте путь happens-before от writer к reader. Если путь нельзя назвать одной из документированных guarantees, код нельзя оправдать наблюдаемым scheduling. Предпочитайте самый простой primitive, который публикует весь invariant.

## Источники

- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
- [Package sync](https://pkg.go.dev/sync@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
- [Package sync/atomic](https://pkg.go.dev/sync/atomic@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
