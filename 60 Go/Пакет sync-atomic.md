---
aliases:
  - Пакет sync/atomic
tags:
  - область/go
  - тема/конкурентность
статус: проверено
---

# Пакет sync/atomic

## TL;DR

`sync/atomic` делает одну memory operation неделимой и устанавливает ordering между наблюдающими друг друга atomic operations. Это хороший инструмент для счётчиков, flags и публикации immutable snapshot, но не для инварианта из нескольких полей. Если корректность трудно доказать одной короткой фразой, используйте mutex или channel.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-15.
- GOOS и GOARCH: API сохраняет гарантии на поддерживаемых платформах; стоимость инструкций зависит от архитектуры.
- Пакеты или компоненты runtime: `sync/atomic`, typed atomics.

## Ментальная модель

Atomic variable — отдельная сериализуемая точка состояния. Каждая atomic operation занимает место в едином sequentially consistent order. Если operation B наблюдает эффект A, A синхронизируется перед B; точный смысл этого edge задаёт [[60 Go/Модель памяти Go и happens-before|модель памяти Go]].

Это не превращает окружающий код в транзакцию. Два последовательных atomic loads могут увидеть состояния из разных моментов, а два atomic fields не образуют общий invariant.

## Как устроено

Typed atomics (`atomic.Int64`, `Bool`, `Pointer[T]` и другие) инкапсулируют корректное выравнивание и явно показывают, что доступ должен идти через `Load`, `Store`, `Add`, `Swap` или `CompareAndSwap`. Такие значения нельзя копировать после первого использования.

`Add` выполняет read-modify-write как одну operation. Обычное `n++` состоит из read, вычисления и write, поэтому конкурентные increments могут потеряться. `CompareAndSwap` позволяет условно заменить значение, но цикл CAS под contention способен многократно повторять работу. Успешный CAS `A → X` не доказывает, что состояние между load и swap не менялось как `A → B → A`: это ABA problem. Нужны version/tag, immutable state с корректным lifetime либо mutex.

Нельзя смешивать atomic и non-atomic access к одной переменной: обычный read всё равно конфликтует с atomic write и нарушает единый протокол. Первый `atomic.Value.Store` фиксирует concrete type; `Store(nil)` и последующий store другого concrete type вызывают panic.

## Код

```go
package main

import (
	"fmt"
	"sync"
	"sync/atomic"
)

func main() {
	var (
		n  atomic.Int64
		wg sync.WaitGroup
	)

	for i := 0; i < 4; i++ {
		wg.Go(func() {
			for j := 0; j < 1000; j++ {
				n.Add(1)
			}
		})
	}

	wg.Wait()
	fmt.Println(n.Load())
}
```

## Ожидаемый результат

```text
4000
```

Каждый `Add(1)` участвует в одном atomic order, а `Wait` гарантирует завершение всех tasks до `Load`. Обычный запуск выполнен в официальном Go Playground на Go 1.26.5 и дал `4000`; режим `-race` в Playground недоступен, проверено 2026-07-15.

## Trade-offs

- Atomic counter не требует critical section и хорошо масштабируется при умеренном contention. Один mutex проще расширить, если позднее счётчик станет частью многополевого инварианта.
- CAS избегает blocking mutex, но не гарантирует дешёвого progress под contention и усложняет доказательство.
- `atomic.Value` или `atomic.Pointer[T]` удобен для публикации целого immutable snapshot: writer строит новый объект и атомарно меняет pointer. Мутация уже опубликованного объекта снова потребует синхронизации.

## Типичные ошибки

- Предположение: «каждое поле atomic — вся структура атомарна» → читатель видит несовместимые значения → loads относятся к разным моментам → публикуйте один immutable snapshot либо используйте mutex.
- Предположение: «иногда можно прочитать напрямую» → возникает [[60 Go/Data races, deadlocks и livelocks|data race]] и race detector сообщает конфликт → протокол доступа смешан → используйте atomic для каждого access.
- Предположение: «CAS loop всегда быстрее lock» → CPU растёт при падении throughput → goroutines повторяют CAS → измерьте contention и сравните с mutex.
- Предположение: «CAS подтвердил, что state не менялся» → update применяется к логически другому состоянию с тем же значением → произошёл цикл ABA → добавьте version/tag либо используйте immutable snapshot или mutex.
- Предположение: «`atomic.Value` принимает любые последовательные значения» → process panic при store → nil и смена concrete type запрещены → установите один стабильный тип и представляйте отсутствие через typed wrapper/pointer.
- Предположение: «atomic value можно копировать» → две копии перестают представлять одну synchronization point → координация теряется → храните его по стабильному адресу.

## Когда применять

Используйте typed atomic для одного независимо интерпретируемого числа, boolean state или pointer на immutable state. Для составного перехода, условных действий с побочными эффектами и поддерживаемого бизнес-инварианта выбирайте [[60 Go/Mutex, RWMutex и примитивы координации sync|`Mutex`]]. Если задача описывается передачей владения, а не защитой общей ячейки, вернитесь к выбору [[60 Go/Каналы или mutex|между каналом и mutex]].

## Источники

- [Package sync/atomic](https://pkg.go.dev/sync/atomic@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
- [The Go Memory Model — Atomic Values](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
