---
aliases:
  - Local rate limiter в Go
  - Token bucket в Go
tags:
  - область/go
  - тема/низкоуровневое-проектирование
статус: черновик
---

# Проектирование и реализация локального rate limiter в Go

## TL;DR

Вопрос заметки: как ограничить скорость операций внутри одного Go-процесса, разрешив короткий burst и не создавая собственную конкурентную арифметику времени? Практический компонент композирует `golang.org/x/time/rate.Limiter` v0.15.0: token bucket уже concurrency-safe, а локальный wrapper фиксирует policy и не выпускает наружу методы её незаметного изменения.

Локальный limiter ограничивает только тот процесс, в котором живёт. При `N` независимых replicas общий пропускной предел может приблизиться к `N × rate`. Глобальная quota, fairness между tenants и поведение при сетевых разделениях относятся к [[50 Проектирование систем/Проектирование rate limiter|распределённому rate limiter]].

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-18.
- Модуль: `golang.org/x/time/rate` tag `v0.15.0`.
- GOOS и GOARCH: контракт платформонезависим; точность ожидания ограничена системным timer resolution и scheduling latency.
- Scope: один token bucket на процесс, один token на операцию, режимы немедленного решения и отменяемого ожидания.
- Вне scope: per-key registry, distributed quota, persisted state, dynamic reconfiguration и weighted requests.

Код не выполнен из-за отсутствия локальной Go toolchain и модуля; заметка остаётся черновиком.

## Ментальная модель

Bucket вмещает не больше `burst` tokens. Время пополняет его со скоростью `r` tokens/second, а успешная операция списывает один token. Поэтому `rate` ограничивает долгосрочную скорость, а `burst` — сколько накопленной работы можно пропустить сразу.

Для интервала длины `d` число успешно допущенных операций ограничено накопленным остатком плюс `r × d`; начальный bucket полон. Limiter не создаёт очередь сам по себе: `Allow` отклоняет немедленно, а `Wait` превращает будущий token в ожидание caller.

## Public API и контракт

```go
type Limiter

func NewLimiter(perSecond float64, burst int) (*Limiter, error)
func (l *Limiter) Allow() bool
func (l *Limiter) Wait(ctx context.Context) error
```

- `perSecond` — конечное число больше нуля, `burst > 0`; `NaN`, оба infinity и `float64(rate.Inf)` отклоняются. Последнее значение численно равно `math.MaxFloat64`, но библиотека трактует его как unlimited rate, при котором `burst` игнорируется.
- `Allow` атомарно потребляет token при успехе и не ждёт при отказе.
- `Wait` ждёт один token и возвращает ошибку, если context отменён или его deadline слишком близок.
- Методы можно вызывать конкурентно.
- Zero value `Limiter` непригоден: компонент создают через `NewLimiter` и используют возвращённый pointer.
- Rate и burst неизменяемы после construction: смена quota требует нового policy decision, а не случайного вызова `SetLimit`.

Если компоненту не нужны собственные метрики, конфигурационная граница или перевод `false` в domain error, wrapper можно убрать и внедрять `*rate.Limiter` напрямую.

## Инварианты, state transitions и lifecycle

Состояние bucket логически состоит из текущего количества tokens и времени последнего расчёта. Перед каждой операцией limiter сначала начисляет tokens за прошедшее время, ограничивает остаток `burst`, затем либо списывает token, либо отказывает/резервирует будущее время.

Для API этой заметки переходы такие:

```text
token available --Allow--> consumed
token absent    --Allow--> rejected, state не ждёт caller
token absent    --Wait--> reserved future token --time--> consumed
                                     --ctx.Done--> error/cancellation
```

`rate.Limiter` сам защищает состояние от data races. Wrapper не содержит goroutines и не требует `Close`. Вызванный `Wait` принадлежит caller и завершается по token либо [[60 Go/Context, deadlines и распространение отмены|отмене context]].

## Минимальная реализация

```go
package main

import (
	"context"
	"errors"
	"fmt"
	"math"
	"time"

	"golang.org/x/time/rate"
)

var ErrInvalidLimit = errors.New("rate must be positive and below rate.Inf; burst must be positive")

type Limiter struct {
	inner *rate.Limiter
}

func NewLimiter(perSecond float64, burst int) (*Limiter, error) {
	if perSecond <= 0 || math.IsNaN(perSecond) || math.IsInf(perSecond, 0) || rate.Limit(perSecond) == rate.Inf || burst <= 0 {
		return nil, ErrInvalidLimit
	}
	return &Limiter{inner: rate.NewLimiter(rate.Limit(perSecond), burst)}, nil
}

func (l *Limiter) Allow() bool {
	return l.inner.Allow()
}

func (l *Limiter) Wait(ctx context.Context) error {
	return l.inner.WaitN(ctx, 1)
}

func (l *Limiter) allowAt(now time.Time) bool {
	return l.inner.AllowN(now, 1)
}

func main() {
	limiter, _ := NewLimiter(2, 2)
	t0 := time.Unix(0, 0)

	fmt.Println(limiter.allowAt(t0))
	fmt.Println(limiter.allowAt(t0))
	fmt.Println(limiter.allowAt(t0))
	fmt.Println(limiter.allowAt(t0.Add(500 * time.Millisecond)))
}
```

## Ожидаемый результат и trace

```text
true
true
false
true
```

В начальном bucket два tokens. Первые два вызова при `t0` их списывают, третий получает отказ. За `500 ms` при `2 tokens/s` появляется один token, поэтому четвёртый вызов успешен. Закрытый `allowAt` нужен только детерминированному тесту; production-методы `Allow` и `Wait` используют wall clock согласованно. Тесты `Wait` требуют контролируемого времени или conservative deadline.

`NewLimiter(math.MaxFloat64, 2)` возвращает `ErrInvalidLimit`, а не создаёт unlimited limiter, который обошёл бы burst-контракт wrapper-а.

## Complexity

Одна операция использует `O(1)` времени и `O(1)` памяти; lock contention остаётся общей точкой для hot limiter. Registry из limiters по tenant добавит `O(T)` памяти и потребует eviction, иначе число случайных tenant IDs станет memory DoS.

## Trade-offs

- **Token bucket:** допускает burst и ограничивает средний rate. Strict interval counter проще объяснить, но создаёт boundary burst; sliding window точнее моделирует окно, но хранит больше состояния.
- **Allow:** сохраняет низкую latency и подходит для overload rejection, но caller должен получить наблюдаемый retry/drop contract.
- **Wait:** сглаживает краткий burst, но превращает перегрузку в queueing latency и удержание goroutines. Deadline обязан быть частью API.
- **Один limiter на процесс:** дёшево и без сети. Несколько replicas не разделяют tokens, поэтому это защита локального ресурса, а не глобальная business quota.

## Типичные ошибки

- Предположение: «`10 req/s` на replica означает `10 req/s` для сервиса» → quota растёт после autoscaling → buckets независимы → делите budget осознанно или используйте distributed coordination.
- Предположение: «большой burst только улучшает throughput» → downstream получает мгновенный spike → bucket накопил много tokens → выводите burst из допустимой конкурентной нагрузки, а не из среднего QPS.
- Предположение: «`Wait` безопаснее отказа» → p99 растёт до deadline, goroutines копятся → limiter формирует очередь → ограничьте ожидание context и примените load shedding.
- Предположение: «per-tenant map можно только пополнять» → память растёт от уникальных keys → lifecycle limiter не определён → задайте capacity, idle TTL и cleanup ownership.
- Предположение: «динамический `SetLimit` мгновенно перепишет прошлое» → старые reservations ещё влияют на расписание → reservation уже обещала время → либо запретите mutation, либо документируйте переходный режим.

## Когда применять

Используйте локальный limiter для защиты connection pool, CPU-heavy endpoint, внешнего SDK или фонового consumer внутри одного процесса. Сначала выберите overload policy: `Allow` для reject/drop, `Wait` для bounded queueing. Не выдавайте локальный результат за tenant-wide или cross-region guarantee.

## Источники

- [Package rate](https://pkg.go.dev/golang.org/x/time@v0.15.0/rate) — Go repository `golang.org/x/time`, tag `v0.15.0`, проверено 2026-07-18.
- [rate.go](https://github.com/golang/time/blob/v0.15.0/rate/rate.go) — репозиторий `golang/time`, tag `v0.15.0`, проверено 2026-07-18.
- [Package context](https://pkg.go.dev/context@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [Package time](https://pkg.go.dev/time@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
