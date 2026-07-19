---
aliases: []
tags:
  - область/go
  - тема/конкурентность
статус: проверено
---

# Data races, deadlocks и livelocks

## TL;DR

Data race нарушает safety: конфликтующие memory accesses не упорядочены [[60 Go/Модель памяти Go и happens-before|happens-before]] и хотя бы один из них — non-synchronizing. Atomic operations подчиняются отдельному protocol и сами по себе не образуют race. Deadlock и livelock нарушают liveness: в первом участники ждут навсегда, во втором продолжают выполнять действия, но не продвигают полезную работу. Отсутствие data race не доказывает progress. Тем более о progress нельзя судить лишь по активности CPU.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-15.
- GOOS и GOARCH: определения платформонезависимы; race detector поддерживается не на всех target-платформах.
- Пакеты или компоненты runtime: memory model, channels, `sync`, runtime deadlock detection.

## Ментальная модель

Проверяйте concurrent design двумя независимыми вопросами:

- **Safety:** может ли наблюдаться запрещённое состояние?
- **Liveness:** гарантирован ли следующий полезный шаг?

Data race — два concurrent accesses к одной memory location, хотя бы один write, без ordering и не как единый atomic protocol. Deadlock — wait-for graph содержит неразрешимый цикл или событие без возможного producer. Livelock — граф не заблокирован, но реакции участников постоянно отменяют progress.

## Как устроено

Для data-race-free программы Go гарантирует sequentially consistent объяснение исполнения (DRF-SC). Scheduling при этом не становится детерминированным. Гарантия означает другое: результат можно объяснить interleaving операций goroutines.

[[60 Go/Race detector|Race detector]] инструментирует реально выполненные accesses. Он доказывает наличие найденной race, но успешный запуск не доказывает отсутствие race в непокрытом пути.

Runtime Go способен сообщить глобальный deadlock, когда нет runnable goroutines и нет события, способного разбудить программу. Он не сообщает о частичном deadlock, если другие goroutines продолжают работу, и не распознаёт доменный livelock.

Обычные причины: разный порядок захвата locks, send без receiver, ожидание channel, который никто не закроет, пропущенный `Done`, retry-loop без budget и два участника, бесконечно «уступающие» друг другу.

## Код

```go
package main

func main() {
	values := make(chan int)
	values <- 1
}
```

## Ожидаемый результат

Для стандартного runtime Go 1.26.5 программа завершается с ненулевым status; первая диагностическая строка:

```text
fatal error: all goroutines are asleep - deadlock!
```

Stack trace и строка `exit status` зависят от способа запуска. У unbuffered send нет receiver, поэтому единственная goroutine блокируется навсегда. Пример выполнен в официальном Go Playground на Go 1.26.5: первая диагностическая строка совпала с указанной, проверено 2026-07-15.

## Trade-offs

- Грубая lock hierarchy уменьшает риск deadlock и упрощает доказательство, но может увеличить contention.
- Fine-grained locks повышают потенциальный parallelism ценой более сложного wait-for graph.
- Timeout восстанавливает liveness caller, но не исправляет потерянный invariant и может оставить работу исполняться. Сначала определите ownership/cancellation.
- Retry помогает при transient conflict; без backoff, jitter и общего budget может создать livelock.

## Типичные ошибки

- Предположение: «простое чтение int безопасно» → `-race` показывает конфликт → access не упорядочен → используйте [[60 Go/Mutex, RWMutex и примитивы координации sync|mutex]], atomic или channel.
- Предположение: «race detector прошёл — races нет» → сбой появляется на другом input → detector видит только выполненные пути → расширьте tests и прогоняйте realistic workload.
- Предположение: «runtime найдёт любой deadlock» → часть сервиса зависла без crash → другие goroutines остаются runnable → наблюдайте goroutine profiles и progress metrics.
- Предположение: «есть retries — есть progress» → CPU и запросы растут без результата → участники повторяют конфликт → добавьте ordering, backoff и bounded attempts.

## Когда применять

Для каждого протокола сформулируйте инвариант safety и условие progress. Прогоняйте tests с `-race`, фиксируйте единый порядок locks, ограничивайте ожидание контекстом и диагностируйте зависания по stack dump/goroutine profile. Временную картину scheduler и blocking восстанавливайте через [[60 Go/Execution trace|execution trace]], а не по CPU alone.

## Источники

- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
- [Data Race Detector](https://go.dev/doc/articles/race_detector) — The Go Project, официальная документация для toolchain Go 1.26.5, проверено 2026-07-15.
- [runtime/proc.go — checkdead](https://github.com/golang/go/blob/go1.26.5/src/runtime/proc.go#L6367-L6468) — репозиторий golang/go, tag go1.26.5, `checkdead`, проверено 2026-07-15.
