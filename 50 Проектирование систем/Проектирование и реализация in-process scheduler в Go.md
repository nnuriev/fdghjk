---
aliases:
  - In-process scheduler в Go
  - Локальный планировщик задач в Go
tags:
  - область/go
  - тема/низкоуровневое-проектирование
статус: черновик
---

# Проектирование и реализация in-process scheduler в Go

## TL;DR

Вопрос заметки: как запланировать one-shot jobs по времени внутри одного процесса, разрешить отмену и не запускать goroutine на каждую job? Один owner-loop владеет min-heap, `map[id]*job` и единственным `time.Timer`. Остальные goroutines посылают команды, но не касаются состояния напрямую.

Scheduler только передаёт due-job через channel; выполнение принадлежит consumer или [[60 Go/Worker pool, fan-in, fan-out и bounded concurrency|bounded worker pool]]. Persistence, retries, leases и восстановление после отказа относятся к [[50 Проектирование систем/Проектирование планировщика задач и workflow engine|распределённому scheduler/workflow engine]].

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-18.
- Пакеты: `container/heap`, `context`, `sync`, `time`.
- Scope: one-shot jobs одного процесса, bounded pending queue, cancel-before-delivery, deterministic order при одинаковом `At`.
- Вне scope: cron/calendar semantics, execution result, retry, persistence, multi-node ownership и exactly-once.

Код статически разобран, но не выполнен: локальной Go toolchain нет. Статус остаётся `черновик`.

## Ментальная модель

Heap отвечает на вопрос «какая job ближайшая», timer — «когда снова разбудить loop», map — «где job с этим ID». Источник истины один: owner-loop. Channel `Due` — граница ownership; после успешной отправки scheduler забывает job, а consumer отвечает за выполнение.

Медленный consumer не блокирует `Schedule` и `Cancel` навсегда: overdue job остаётся вершиной heap, а `select` продолжает принимать команды. Но delivery lag растёт, поэтому это backpressure, а не гарантия точного старта.

## Public API и состояния

```go
func NewScheduler(maxPending int) (*Scheduler, error)
func (s *Scheduler) Schedule(ctx context.Context, at time.Time, name string) (uint64, error)
func (s *Scheduler) Cancel(ctx context.Context, id uint64) (bool, error)
func (s *Scheduler) Due() <-chan Job
func (s *Scheduler) Close()
```

```text
absent --Schedule--> scheduled --Due send--> delivered
                           \--Cancel-----> canceled
                           \--Close------> discarded
```

`Schedule` возвращает `ErrFull`, если heap достиг `maxPending`. `Cancel` возвращает `false`, если ID отсутствует, уже доставлен или отменён. `Close` идемпотентен, прекращает приём команд, отбрасывает pending jobs и закрывает `Due`; он не закрывает и не ждёт внешних workers.

`ctx` ограничивает только ожидание admission в command loop. После принятого send метод ждёт окончательный reply и не возвращает cancellation для уже применённой команды.

`Scheduler` используют только через pointer из `NewScheduler` и не копируют: копия разделила бы channels, но получила отдельный `sync.Once` для того же `stop`.

## Инварианты, concurrency и lifecycle

Только loop изменяет heap и `byID`, поэтому locks для них не нужны. Для каждой scheduled job `byID[id]` указывает на тот же объект и корректный heap index; `len(heap) <= maxPending`. Tie-break по ID сохраняет порядок регистрации при одинаковом `At`.

До `Reset` timer останавливается и при необходимости дренируется. Код опирается на default synchronous timer-channel semantics Go 1.26.5. `stop` закрывает только `Close`, `due` и `done` — только owner-loop.

## Минимальная реализация

```go
package main

import (
	"container/heap"
	"context"
	"errors"
	"fmt"
	"sync"
	"time"
)

var (
	ErrClosed = errors.New("scheduler closed")
	ErrFull   = errors.New("scheduler queue full")
	ErrSize   = errors.New("maxPending must be positive")
)

type Job struct {
	ID    uint64
	At    time.Time
	Name  string
	index int
}

type jobHeap []*Job

func (h jobHeap) Len() int { return len(h) }
func (h jobHeap) Less(i, j int) bool {
	return h[i].At.Before(h[j].At) || h[i].At.Equal(h[j].At) && h[i].ID < h[j].ID
}
func (h jobHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i]; h[i].index, h[j].index = i, j }
func (h *jobHeap) Push(x any)   { j := x.(*Job); j.index = len(*h); *h = append(*h, j) }
func (h *jobHeap) Pop() any {
	old := *h
	n := len(old)
	j := old[n-1]
	old[n-1], j.index = nil, -1
	*h = old[:n-1]
	return j
}

type addReq struct{ at time.Time; name string; reply chan addResult }
type addResult struct{ id uint64; err error }
type cancelReq struct{ id uint64; reply chan bool }

type Scheduler struct {
	cmd        chan any
	due        chan Job
	stop, done chan struct{}
	once       sync.Once
	maxPending int
}

func NewScheduler(maxPending int) (*Scheduler, error) {
	if maxPending <= 0 { return nil, ErrSize }
	s := &Scheduler{cmd: make(chan any), due: make(chan Job), stop: make(chan struct{}), done: make(chan struct{}), maxPending: maxPending}
	go s.loop()
	return s, nil
}

func (s *Scheduler) Schedule(ctx context.Context, at time.Time, name string) (uint64, error) {
	reply := make(chan addResult, 1)
	select {
	case s.cmd <- addReq{at: at, name: name, reply: reply}:
	case <-ctx.Done(): return 0, ctx.Err()
	case <-s.done: return 0, ErrClosed
	}
	r := <-reply
	return r.id, r.err
}

func (s *Scheduler) Cancel(ctx context.Context, id uint64) (bool, error) {
	reply := make(chan bool, 1)
	select {
	case s.cmd <- cancelReq{id: id, reply: reply}:
	case <-ctx.Done(): return false, ctx.Err()
	case <-s.done: return false, ErrClosed
	}
	return <-reply, nil
}

func (s *Scheduler) Due() <-chan Job { return s.due }
func (s *Scheduler) Close() { s.once.Do(func() { close(s.stop) }); <-s.done }

func stopTimer(t *time.Timer) {
	if !t.Stop() { select { case <-t.C: default: } }
}

func (s *Scheduler) loop() {
	timer := time.NewTimer(time.Hour)
	stopTimer(timer)
	q, byID, nextID := jobHeap{}, make(map[uint64]*Job), uint64(0)
	defer func() { stopTimer(timer); close(s.due); close(s.done) }()

	for {
		stopTimer(timer)
		var timerC <-chan time.Time
		var out chan Job
		var next Job
		if len(q) > 0 {
			d := time.Until(q[0].At)
			if d <= 0 { out, next = s.due, *q[0] } else { timer.Reset(d); timerC = timer.C }
		}
		select {
		case <-s.stop:
			return
		case out <- next:
			j := heap.Pop(&q).(*Job)
			delete(byID, j.ID)
		case <-timerC:
		case raw := <-s.cmd:
			switch r := raw.(type) {
			case addReq:
				if len(q) >= s.maxPending { r.reply <- addResult{err: ErrFull}; continue }
				nextID++
				j := &Job{ID: nextID, At: r.at, Name: r.name}
				heap.Push(&q, j); byID[j.ID] = j; r.reply <- addResult{id: j.ID}
			case cancelReq:
				j, ok := byID[r.id]
				if ok { heap.Remove(&q, j.index); delete(byID, r.id) }
				r.reply <- ok
			}
		}
	}
}

func main() {
	s, _ := NewScheduler(2)
	ctx := context.Background()
	id, _ := s.Schedule(ctx, time.Now().Add(time.Hour), "obsolete")
	canceled, _ := s.Cancel(ctx, id)
	_, _ = s.Schedule(ctx, time.Now(), "ready")
	fmt.Println(canceled)
	fmt.Println((<-s.Due()).Name)
	s.Close()
}
```

## Ожидаемый результат

```text
true
ready
```

Первая job переходит `scheduled → canceled`. Вторая сразу становится due, передаётся consumer и удаляется из heap/map. Пример не подтверждает timing accuracy; для этого нужен тест в `testing/synctest` и отдельное измерение delivery lag.

## Complexity

`Schedule` и успешный `Cancel` — `O(log n)`, получение ближайшей job — `O(1)`, delivery с удалением — `O(log n)`, память — `O(maxPending)`. Все команды сериализованы owner-loop, что упрощает correctness, но ограничивает command throughput.

## Trade-offs

- Один timer и heap масштабируются лучше timer-per-job и сохраняют единый state machine, но требуют owner-loop.
- Unbuffered `Due` делает backpressure видимым. Buffer сглаживает burst, но добавляет queued latency и второй capacity contract.
- Запуск callback через `go task()` снизил бы delivery latency, но создал бы unbounded concurrency и неясный shutdown. Execution лучше передать bounded executor.
- `time.Ticker` подходит для периодического сигнала, но может пропускать ticks у медленного receiver и не заменяет durable scheduler.

## Типичные ошибки

- Предположение: «timer означает точный старт» → job приходит позже `At` → scheduler/consumer заняты → измеряйте lag и задавайте допустимую lateness.
- Предположение: «`Close` дождётся уже доставленной работы» → process выходит раньше task → ownership перешёл consumer → worker pool должен иметь собственный graceful shutdown.
- Предположение: «callback можно запускать прямо в owner-loop» → длинная job блокирует Schedule/Cancel → control plane смешан с execution → передавайте job executor-у.
- Предположение: «после admission можно вернуть `ctx.Err()` вместо reply» → caller повторяет уже применённый Schedule и теряет первый ID → outcome неизвестен → context отменяет только admission, принятая команда всегда возвращает окончательный результат.
- Предположение: «in-memory queue переживёт restart» → pending jobs исчезают → persistence отсутствует → для обязательных jobs используйте durable scheduler.

## Когда применять

Подходит для TTL-like housekeeping, локальных debounce/retry hints и необязательной работы, которую безопасно потерять при restart. Не используйте как источник истины для billing, workflow или singleton cron между replicas.

## Эволюция и версии

Начиная с Go 1.23 timer channels синхронные: после успешного `Stop` или `Reset` receive не получает stale value старой конфигурации. Реализация рассчитана на default timer semantics Go 1.26.5; legacy-режим `GODEBUG=asynctimerchan=1` находится вне scope.

## Источники

- [Package container/heap](https://pkg.go.dev/container/heap@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Priority queue example](https://github.com/golang/go/blob/go1.26.5/src/container/heap/example_pq_test.go) — репозиторий `golang/go`, tag `go1.26.5`, проверено 2026-07-18.
- [Package time](https://pkg.go.dev/time@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Package testing/synctest](https://pkg.go.dev/testing/synctest@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-18.
