---
aliases:
  - Reuse памяти и sync.Pool
tags:
  - область/go
  - тема/runtime
  - тема/производительность
статус: проверено
---

# Снижение аллокаций и sync.Pool

## TL;DR

Снижать allocations выгодно там, где профиль показывает значимый [[60 Go/Аллокации, GC и GC pressure|allocation churn и GC pressure]]. Сначала помогают [[60 Go/Стеки и escape analysis|stack allocation]], предварительная capacity, streaming и более короткий lifetime. `sync.Pool` — GC-aware cache временных объектов, а не хранилище и не bounded object pool: runtime может удалить любой item без уведомления, а `Get` вправе игнорировать ранее выполненный `Put`. Корректный код обязан работать и при постоянных misses, сбрасывать состояние перед reuse и ограничивать retained capacity крупных buffers.

## Область применимости

- Версия Go: API Go 1.26; implementation baseline Go 1.26.5.
- GOOS/GOARCH: контракт переносим; per-P shards и victim cache описаны только как реализация Go 1.26.5, основной baseline linux/amd64.
- Компоненты: allocator, GC, `sync.Pool`, `bytes.Buffer`.
- Вне scope: pooling connection-like ресурсов с обязательным `Close` и fixed-size semaphore pools.

## Ментальная модель

Pool — необязательная остановка на пути создания временного object:

~~~text
Get → cache hit или New → полное логическое Reset → use → очистка → Put
~~~

Ни identity, ни наличие item после `Put` не гарантированы. Следовательно:

- `New` задаёт обычный путь miss, а не аварийный fallback;
- object не принадлежит pool, пока его использует caller;
- после `Put` caller больше не должен обращаться к object;
- состояние и capacity требуют явной политики.

Если correctness зависит от того, что item вернётся, нужна другая структура: channel/semaphore для bounded resources или собственный freelist с определённым lifecycle.

## Как устроено

В терминах [[60 Go/Модель памяти Go и happens-before|модели памяти Go]] документация `sync.Pool` гарантирует два object-specific synchronization edges: `Put(x)` synchronizes-before `Get`, вернувшим тот же `x`, а возврат `x` из `New` — before `Get`, вернувшим этот `x`. Ни один из этих edges не служит общим barrier между произвольными callers.

В Go 1.26.5 Pool использует per-P local storage: private slot и shared chain. Local P предпочитает свои свежие items; slow path может steal из других shards и затем проверить victim cache прошлого GC cycle. Во время GC runtime меняет поколения pool caches и со временем позволяет освободить невостребованные items. Эти детали объясняют locality и отсутствие retention guarantee, но код не должен зависеть от их порядка.

До pool обычно выгоднее:

1. не материализовать данные — использовать [[60 Go/Пакеты io и bufio|`io.Reader`/`io.Writer` и буферизацию]];
2. переиспользовать buffer внутри одного owner без synchronization;
3. заранее выбрать реалистичную capacity;
4. сократить escape и lifetime;
5. только затем разделять временные objects через `sync.Pool`.

`Reset` часто обнуляет длину, но сохраняет backing storage. Это полезно для обычных buffers и опасно после редкого очень большого request: один item может удерживать мегабайты. При `Cap` выше порога его лучше не возвращать.

## Код

Пример корректен и при cache hit, и при miss:

~~~go
package main

import (
	"bytes"
	"fmt"
	"sync"
)

func main() {
	pool := sync.Pool{
		New: func() any { return new(bytes.Buffer) },
	}

	write := func(s string) {
		buf := pool.Get().(*bytes.Buffer)
		buf.Reset()

		buf.WriteString(s)
		fmt.Println(buf.String())

		buf.Reset()
		if buf.Cap() <= 64<<10 {
			pool.Put(buf)
		}
	}

	write("first")
	write("second")
}
~~~

Команда:

~~~text
go run main.go
~~~

## Ожидаемый результат

~~~text
first
second
~~~

Результат не зависит от того, вернул ли второй `Get` тот же buffer. Проверять identity было бы ошибкой, потому что контракт разрешает miss в любой момент. Пример выполнен в официальном Go Playground на Go 1.26.5; вывод совпал с ожидаемым, проверено 2026-07-15.

## Trade-offs

Локальный reusable buffer имеет минимальный coordination overhead и явного owner, но не помогает между независимыми calls. `sync.Pool` масштабирует совместный cache и может уменьшить GC pressure при устойчивой параллельной нагрузке, но добавляет type assertion, reset protocol и непредсказуемый hit rate.

Bounded channel pool гарантирует верхнюю границу ресурса и backpressure, что нужно для connections или scarce handles. Цена — ожидание и необходимость возвращать каждый item. `sync.Pool` не ограничивает число одновременно созданных objects и потому не решает admission control.

Крупная предварительная capacity уменьшает reallocations, но повышает retained memory. Порог discard выбирают по распределению request sizes и heap profile, а не по максимальному когда-либо увиденному request.

## Типичные ошибки

**Неверное предположение:** `Put` гарантирует следующий `Get` того же object. **Симптом:** потеря состояния или panic после GC. **Причина:** Pool может удалить или проигнорировать item. **Исправление:** хранить обязательное состояние отдельно; считать `New` нормальным.

**Неверное предположение:** `Reset` удаляет чувствительные bytes. **Симптом:** секрет остаётся в backing array и попадает следующему caller либо в memory dump. **Причина:** многие Reset methods меняют длину, а не затирают storage. **Исправление:** не помещать sensitive data в pool либо явно zero memory до `Put`.

**Неверное предположение:** после `Put` object всё ещё принадлежит caller. **Симптом:** data race и перемешанные ответы. **Причина:** другой goroutine уже мог получить тот же object. **Исправление:** считать `Put` передачей ownership и не сохранять aliases.

**Неверное предположение:** Pool всегда уменьшает allocations. **Симптом:** benchmark становится медленнее, heap остаётся большим. **Причина:** workload короткий, objects малы или retained capacity перевешивает savings. **Исправление:** сравнивать `allocs/op`, CPU и in-use heap в [[60 Go/Бенчмарки|репрезентативном benchmark]].

## Когда применять

- Для временных, независимых, часто создаваемых objects с дорогой allocation.
- Когда miss дешёв и полностью корректен.
- После profile, показывающего allocation hot spot.
- С явным reset, maximum retained capacity и ownership protocol.

## Источники

- [Package sync: Pool](https://pkg.go.dev/sync@go1.26.5#Pool) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
- [sync/pool.go: per-P locals, victim cache и Get/Put](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/sync/pool.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [runtime/mgc.go: pool cleanup at GC](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/mgc.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
- [Package bytes: Buffer.Reset and Buffer.Cap](https://pkg.go.dev/bytes@go1.26.5#Buffer) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-15.
