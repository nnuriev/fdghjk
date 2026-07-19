---
aliases: []
tags:
  - область/go
статус: проверено
---

# Пакет time, таймеры и тикеры

## TL;DR

`Timer` моделирует одно будущее событие, `Ticker` посылает периодические сигналы, а deadline через `Context` отменяет операцию по времени. Ни один из них не гарантирует точный момент выполнения: событие становится доступно не раньше заданного duration, а scheduler может доставить его позже.

В Go 1.26 при module directive `go 1.23` или новее channel-based timers используют синхронные каналы: после возврата `Stop` или `Reset` нельзя получить stale value от прежней конфигурации. `Stop` не закрывает канал.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5.
- Семантика timer channels: модуль с `go 1.23` или новее и без возврата к старому поведению через `GODEBUG=asynctimerchan=1`.
- GOOS и GOARCH: API переносим; resolution и задержка scheduling зависят от платформы.
- Пакеты: `time`, косвенно `context`.

## Ментальная модель

Timer не выполняет работу в момент времени; runtime ставит событие в очередь, после чего goroutine ещё должна быть запланирована. Поэтому duration — нижняя граница ожидания, а не real-time SLA.

`Timer.C` и `Ticker.C` — каналы уведомлений, не очереди всех произошедших моментов. Медленный consumer ticker может пропустить ticks: пакет корректирует интервал или отбрасывает сигналы, чтобы не копить unbounded backlog.

## Как устроено

`time.NewTimer(d)` создаёт одно событие. `Stop` возвращает true, если остановил активный timer, и false, если тот уже истёк или был остановлен. `Reset` переназначает timer и сообщает, был ли он активен до вызова.

`time.After(d)` эквивалентен получению channel нового timer и удобен в одноразовом `select`. Если нужна отмена, reuse или различение состояний, явный `NewTimer` даёт `Stop` и `Reset`.

`NewTicker(d)` периодически предлагает значения. `Stop` прекращает будущие ticks, но намеренно не закрывает `C`: закрытие выглядело бы consumer как бесконечный поток zero values при receive без `ok`. Lifecycle consumer завершается по отдельному context/done channel.

Начиная с Go 1.23 runtime может собирать недостижимые неостановленные timers/tickers. Но `Stop` по-прежнему нужен, если объект ещё достижим, а работа больше не нужна: GC не заменяет timely cancellation.

## Код

```go
package main

import (
	"fmt"
	"time"
)

func main() {
	timer := time.NewTimer(time.Hour)
	fmt.Println("stop active:", timer.Stop())
	fmt.Println("reset stopped:", timer.Reset(0))
	<-timer.C
	fmt.Println("timer fired")

	ticker := time.NewTicker(time.Hour)
	ticker.Stop()
	select {
	case <-ticker.C:
		fmt.Println("unexpected tick")
	default:
		fmt.Println("ticker channel stays open")
	}
}
```

## Ожидаемый результат

```text
stop active: true
reset stopped: false
timer fired
ticker channel stays open
```

Часовой timer активен и успешно останавливается; `Reset(0)` перезапускает ранее остановленный timer и возвращает false, затем событие приходит. Остановленный ticker не отправляет tick и не закрывает канал. Пример выполнен в официальном Go Playground на Go 1.26.5; вывод совпал с ожидаемым, проверено 2026-07-15.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| До Go 1.23 | Channel timer имел buffer capacity 1; после `Stop`/`Reset` требовалось учитывать или drain stale value; недостижимый ticker без `Stop` не собирался | — | Старые helper-паттерны содержали stop-and-drain protocol | [Go 1.23 release notes](https://go.dev/doc/go1.23#timer-changes) |
| Go 1.23+, включая Go 1.26.5 при `go 1.23+` | — | Timer channel синхронный; после возврата `Stop`/`Reset` stale receive исключён; недостижимые timers/tickers доступны GC | Reset активного/истёкшего timer проще, но поведение зависит от module directive и `GODEBUG` | [Go 1.23 release notes](https://go.dev/doc/go1.23#timer-changes) |

## Trade-offs

- Новый timer на каждую итерацию проще локально, но создаёт allocations и сложный cleanup в hot loop. Один `Timer` с `Reset` уменьшает churn, но требует единственного владельца состояния.
- `Ticker` задаёт cadence, но не обрабатывает overload. Цикл «выполнить работу, затем `NewTimer`» задаёт паузу после завершения и естественно не накапливает отставание.
- `time.AfterFunc` удобен для callback, но запускает функцию в собственной goroutine; `Stop` не ждёт уже начавшийся callback. Channel timer легче координировать внутри одного [[60 Go/select, cancellation и timeout|select event loop]].

## Типичные ошибки

- Предположение: ticker channel закрывается после `Stop`. Симптом: consumer навсегда ждёт `range ticker.C`. Причина: `Stop` канал не закрывает. Исправление: отдельный context/done signal и явный [[60 Go/Goroutines и lifecycle|владелец goroutine]].
- Предположение: каждый tick будет доставлен. Симптом: счётчик меньше elapsed/period. Причина: ticker отбрасывает или корректирует ticks для медленного receiver. Исправление: вычислять состояние из времени либо использовать durable queue, если каждое событие значимо.
- Предположение: `AfterFunc.Stop() == false` означает, что callback завершён. Симптом: callback продолжает менять state после cleanup. Причина: false означает, что функция уже запущена или timer остановлен; ожидания завершения нет. Исправление: отдельная synchronization с callback, доказанная через [[60 Go/Модель памяти Go и happens-before|happens-before]].
- Предположение: правила stop-and-drain одинаковы для всех module versions. Симптом: лишний drain блокируется или старый код получает stale value. Причина: семантика изменилась в Go 1.23 и управляется module directive/GODEBUG. Исправление: фиксировать version scope.

## Когда применять

Используйте `Timer` для одного отменяемого ожидания, `Ticker` — для best-effort периодического wake-up, а [[60 Go/Context, deadlines и распространение отмены|Context]] — для deadline операции через call graph. Для scheduled business events, которые нельзя потерять при рестарте, нужен durable storage/queue, а не in-process timer.

## Источники

- [Документация пакета time](https://pkg.go.dev/time@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Go 1.23 Release Notes: Timer changes](https://go.dev/doc/go1.23#timer-changes) — Go project, Go 1.23, проверено 2026-07-15.
- [Исходный код Timer](https://github.com/golang/go/blob/go1.26.5/src/time/sleep.go#L113-L181) — репозиторий golang/go, tag go1.26.5, файл `src/time/sleep.go`, методы `Timer.Stop`, `NewTimer`, `Timer.Reset`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
