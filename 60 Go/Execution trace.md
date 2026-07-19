---
aliases:
  - Go execution tracer
tags:
  - область/go
  - тема/runtime
  - тема/диагностика
статус: проверено
---

# Execution trace

## TL;DR

Execution trace записывает временную причинную картину runtime: создание, запуск, blocking и unblocking goroutines, syscalls, processor states, GC events, heap changes и пользовательские tasks/regions. Профиль [[60 Go/Профилирование с pprof|pprof]] отвечает на вопрос «где накопилась стоимость». Trace дополнительно отвечает на вопрос «что произошло раньше и почему следующая работа ждала». Цена — больший объём и overhead, поэтому capture ограничивают проблемным окном либо используют `runtime/trace.FlightRecorder` для snapshot последних событий.

## Область применимости

- Версия Go: `runtime/trace` и `go tool trace` Go 1.26.5.
- GOOS/GOARCH: публичный API переносим; основной interpretation baseline — linux/amd64, platform syscalls и scheduler behavior различаются.
- Компоненты: scheduler, goroutines, netpoller, syscalls, timers, GC, user annotations.
- Вне scope: cross-service distributed trace и долгосрочное хранение telemetry.

## Ментальная модель

Pprof сворачивает множество events в weighted stacks. Execution trace сохраняет sequence:

~~~text
G1 создаёт G2
G2 становится runnable
G2 получает P и начинает region
G2 блокируется на channel
G1 отправляет value
G2 снова runnable и завершает region
~~~

Так можно различить:

- **execution time** — goroutine реально исполнялась;
- **runnable latency** — могла работать, но ждала P из модели [[60 Go/Планировщик GMP|планировщика GMP]];
- **blocking latency** — ждала channel, mutex, [[60 Go/Netpoller|network I/O]], syscall или timer;
- **GC interference** — [[60 Go/Аллокации, GC и GC pressure|assists, workers и stop-the-world intervals]].

Task объединяет логическую operation, которая проходит через несколько goroutines. Region отмечает interval внутри одной goroutine. Log добавляет timestamped event. Без annotations runtime events видны, но связать их с request/domain operation сложнее.

## Как устроено

`runtime/trace.Start` допускает одну активную streaming session и потоково пишет binary trace; второй `Start` завершится ошибкой. Отдельно допускается один active `FlightRecorder`, причём streaming trace и flight recorder могут работать одновременно. `Stop` ждёт завершения writes. В tests trace записывают командой `go test -trace=trace.out`; live endpoint доступен через `net/http/pprof`.

`go tool trace` строит views scheduler, goroutines, tasks, network/syscall/synchronization blocking и GC. Из trace можно получить pprof-like aggregates:

~~~text
go tool trace -pprof=net trace.out > net.pprof
go tool trace -pprof=sync trace.out > sync.pprof
go tool trace -pprof=syscall trace.out > syscall.pprof
go tool trace -pprof=sched trace.out > sched.pprof
~~~

Затем файл анализируется обычным `go tool pprof`. `sched` показывает delay от runnable до execution, а не CPU time.

Continuous full trace создаёт overhead и быстро растущий output. Начиная с Go 1.25 `FlightRecorder` хранит moving window в memory ring buffer; при anomaly приложение вызывает `WriteTo` и сохраняет недавний контекст. Это выигрывает для редких spikes, но buffer всё равно имеет memory/CPU cost и должен быть настроен.

## Код

Пример создаёт task и две regions, связанные через channel synchronization:

~~~go
package main

import (
	"context"
	"fmt"
	"os"
	"runtime/trace"
	"sync"
)

func main() {
	f, err := os.Create("trace.out")
	if err != nil {
		panic(err)
	}
	if err := trace.Start(f); err != nil {
		panic(err)
	}

	ctx, task := trace.NewTask(context.Background(), "request")

	var wg sync.WaitGroup
	wg.Add(1)
	values := make(chan string)
	go func() {
		defer wg.Done()
		trace.WithRegion(ctx, "produce", func() {
			values <- "ok"
		})
	}()

	trace.WithRegion(ctx, "consume", func() {
		fmt.Println(<-values)
	})

	wg.Wait()
	task.End()
	trace.Stop()
	if err := f.Close(); err != nil {
		panic(err)
	}

	fmt.Println("trace.out written")
}
~~~

Команды:

~~~text
go run main.go
go tool trace trace.out
~~~

## Ожидаемый результат

Программа печатает:

~~~text
ok
trace.out written
~~~

и создаёт non-empty `trace.out`, который `go tool trace` открывает без parse error. В task view присутствует task type `request`, а user regions содержат `produce` и `consume`; channel send/receive задаёт causal unblock. Точные timestamps и scheduler order не фиксируются. Программа выполнена в официальном Go Playground на Go 1.26.5 и сообщила о записи trace; отдельный запуск `go tool trace` над удалённым файлом недоступен, проверено 2026-07-15.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| до 1.25 | Для capture редкого события обычно требовался непрерывный полный trace или воспроизведение | — | Output и overhead мешали долгому наблюдению | [Go 1.25 Release Notes](https://go.dev/doc/go1.25) |
| 1.25 | — | Добавлен `runtime/trace.FlightRecorder` с moving in-memory window и snapshot через `WriteTo` | Можно сохранить последние секунды после anomaly без полного долгого trace | [Go 1.25 Release Notes](https://go.dev/doc/go1.25) |

## Trade-offs

Pprof компактнее и лучше отвечает на устойчивые aggregate hotspots. Trace нужен для tail latency, starvation, blocking chains и scheduler/GC interaction, но дороже собирается и анализируется.

Full trace даёт всю timeline выбранного окна. Flight recorder уменьшает output до pre-incident window, но может не содержать раннюю причину, если окно слишком коротко. Большое окно удерживает больше memory.

User annotations повышают объяснимость, но чрезмерные logs увеличивают trace и overhead. Tasks/regions стоит ставить на архитектурных boundaries, а не на каждую мелкую function.

## Типичные ошибки

**Неверное предположение:** runnable goroutine была занята CPU. **Симптом:** CPU profile не объясняет latency. **Причина:** она ждала доступного P. **Исправление:** смотреть scheduler latency и runnable intervals в trace.

**Неверное предположение:** длинная goroutine lifetime означает долгую работу или сама по себе доказывает [[60 Go/Goroutine и channel leaks|goroutine leak]]. **Симптом:** оптимизируют её code либо объявляют утечкой, хотя почти всё время она ожидаемо blocked. **Причина:** lifetime смешивает execution и wait, а leak определяется потерей пути завершения. **Исправление:** разложить states по timeline и проверить ownership/cancellation.

**Неверное предположение:** full trace можно постоянно писать без operational bound. **Симптом:** большой файл, I/O pressure и искажённая нагрузка. **Причина:** event stream растёт со временем и activity. **Исправление:** короткое окно, sampling workflow или FlightRecorder.

**Неверное предположение:** task автоматически передаётся без context. **Симптом:** дочерняя goroutine не связана с logical request. **Причина:** annotations привязываются к переданному `context.Context`. **Исправление:** явно распространять task context.

## Когда применять

- Для scheduler latency и CPU starvation.
- Для channel/mutex/network/syscall blocking chains.
- Для взаимодействия GC с tail latency.
- Для редких incidents через FlightRecorder.
- После pprof, если aggregate stacks не объясняют порядок событий.

## Источники

- [Package runtime/trace](https://pkg.go.dev/runtime/trace@go1.26.5) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [Diagnostics: Execution tracer](https://go.dev/doc/diagnostics) — The Go Project, документация Go 1.26, проверено 2026-07-15.
- [cmd/trace documentation and supported pprof types](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/cmd/trace/doc.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/trace implementation](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/trace/) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [Go 1.25 Release Notes: Trace flight recorder](https://go.dev/doc/go1.25) — The Go Project, Go 1.25, проверено 2026-07-15.
