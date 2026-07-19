---
aliases: []
tags:
  - область/go
  - тема/конкурентность
статус: проверено
---

# select, cancellation и timeout

## TL;DR

`select` ждёт первую готовую channel operation и позволяет одной goroutine реагировать на результат, отмену и timeout. Если готовы несколько cases, язык выбирает один псевдослучайно: порядок cases не задаёт приоритет. Поэтому ветка cancellation должна останавливать дальнейшую работу; рассчитывать, что она окажется «более важной», нельзя.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-15.
- GOOS и GOARCH: выбор планировщика по времени не фиксирован; семантика `select` одинакова.
- Пакеты или компоненты runtime: `select`, каналы, `time.Timer`.

## Ментальная модель

`select` — один шаг автомата состояний:

1. вычислить channel operands и значения sends;
2. определить готовые communications;
3. выполнить ровно одну готовую либо `default`;
4. если ничего не готово и `default` нет — уснуть до изменения готовности.

`select` не является циклом, очередью приоритетов или механизмом отмены сам по себе. Отмена — ещё одно событие, после которого код должен вернуть управление и освободить принадлежащие ему ресурсы.

## Как устроено

Receive из закрытого канала готов немедленно, поэтому закрываемый `done` удобен как broadcast cancellation. При этом закрытие и опустошение буфера различаются по правилам [[60 Go/Буферизация, ownership и закрытие каналов|ownership и закрытия каналов]]. Операция с `nil`-каналом никогда не готова; присваивание `nil` позволяет динамически отключать case. `default` делает проверку неблокирующей и при использовании в tight loop способен создать busy spin.

Timeout задаётся каналом timer; общий lifecycle timer и ticker разобран в [[60 Go/Пакет time, таймеры и тикеры|заметке о пакете `time`]]. `time.NewTimer` удобнее `time.After`, когда timer нужно явно остановить или переиспользовать. В toolchain Go 1.26.5 новый синхронный timer channel выбирается для main module с directive `go 1.23+`, если `GODEBUG=asynctimerchan=1` не возвращает legacy implementation. В новой семантике после успешного `Stop` последующий receive не получает stale value. `defer timer.Stop()` в коротком примере лишь показывает cleanup владельца и не влияет на результат.

Если одновременно готовы результат и cancellation, `select` вправе выбрать любой. Для жёсткой policy «после отмены результат не публиковать» нужна дополнительная проверка состояния или протокол, в котором публикация и отмена сериализованы.

## Код

```go
package main

import (
	"fmt"
	"time"
)

func main() {
	cancelled := make(chan struct{})
	close(cancelled)

	timer := time.NewTimer(time.Hour)
	defer timer.Stop()

	select {
	case <-cancelled:
		fmt.Println("cancelled")
	case <-timer.C:
		fmt.Println("timeout")
	}
}
```

## Ожидаемый результат

```text
cancelled
```

Cancellation case уже готов, а timer не может сработать раньше часа. Пример выполнен в официальном Go Playground на Go 1.26.5; вывод совпал с ожидаемым, проверено 2026-07-15.

## Эволюция и версии

| Версия | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| До Go 1.23 либо `GODEBUG=asynctimerchan=1` | Timer channel был buffered и stale value мог остаться после `Stop`/`Reset` | — | Для безопасного reuse требовались дополнительные drain-паттерны | [Go 1.23 release notes](https://go.dev/doc/go1.23#timer-changes) |
| Go 1.23+ directive без legacy GODEBUG | — | Timer channel синхронный; unreachable active timers могут быть собраны GC | Старые unconditional drain-паттерны не переносят механически; учитывайте `go` directive модуля | [Go 1.23 release notes](https://go.dev/doc/go1.23#timer-changes) |

## Trade-offs

- Один blocking `select` не расходует CPU в ожидании и хорошо выражает несколько событий. `default` уменьшает latency неблокирующей попытки, но перекладывает ожидание и pacing на вызывающий код.
- Локальный `time.Timer` ограничивает один этап. [[60 Go/Context, deadlines и распространение отмены|`context.Context`]] лучше переносит общий deadline через цепочку API.
- Закрываемый канал — лёгкий broadcast внутри компонента. Context добавляет deadline, cause и соглашение между пакетами.

## Типичные ошибки

- Предположение: «первый case имеет приоритет» → после cancellation иногда обрабатывается результат → среди готовых cases выбор псевдослучаен → кодируйте priority отдельным состоянием.
- Предположение: «`default` предотвращает блокировку бесплатно» → core загружен на 100% → цикл непрерывно выбирает `default` → блокируйтесь, добавьте pacing или измените архитектуру.
- Предположение: «`break` выйдет из окружающего `for`» → цикл продолжает работать → `break` без label завершает только `select` → используйте `return` или labeled break.
- Предположение: «timeout отменил операцию» → работа продолжается в дочерней goroutine и может стать [[60 Go/Goroutine и channel leaks|утечкой]] → timer разбудил только ожидающего → передайте cancellation исполняющей стороне.

## Когда применять

Используйте `select` на точке, где одна goroutine владеет выбором следующего события. Возвращайтесь из ветки cancellation, останавливайте принадлежащие timers и проверяйте поведение при одновременной готовности нескольких cases.

## Источники

- [Go Language Specification — Select statements](https://go.dev/ref/spec#Select_statements) — The Go Project, language version Go 1.26, проверено 2026-07-15.
- [Package time](https://pkg.go.dev/time@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
- [Go 1.23 Release Notes — Timer changes](https://go.dev/doc/go1.23#timer-changes) — The Go Project, Go 1.23, проверено 2026-07-15.
- [The Go Memory Model — Channel communication](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
