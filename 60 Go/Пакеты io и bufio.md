---
aliases: []
tags:
  - область/go
статус: проверено
---

# Пакеты io и bufio

## TL;DR

`io.Reader` и `io.Writer` — минимальные pull/push-контракты байтового потока. Благодаря узкому контракту можно соединять файлы, sockets, compression, hashing и memory buffers без знания конкретного типа.

`bufio` оборачивает stream буфером и меняет гранулярность обращений к нижнему слою. Буфер не меняет ownership: writer нужно явно `Flush`, underlying resource — отдельно `Close`; у `Scanner` есть предел token size и потеря точного контроля над продвижением reader.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5.
- GOOS и GOARCH: интерфейсы переносимы; поведение конкретного file/socket зависит от ОС.
- Пакеты: `io`, `bufio`.
- Вне scope: системные модели I/O и zero-copy конкретной ОС.

## Ментальная модель

`Reader` передаёт ownership только над первыми `n` bytes буфера `p`; `Writer` принимает первые `n` bytes входа. Один вызов не равен одному сообщению и не обязан заполнить buffer. Границы сообщений задаёт протокол поверх byte stream.

Буфер — staging area между producer и consumer. Он сокращает число дорогих нижележащих операций, но откладывает видимость данных и добавляет ещё одно место, где должна быть обработана ошибка.

## Как устроено

`Read(p)` возвращает `n, err`. Допустимо `n > 0` одновременно с ненулевой ошибкой, поэтому caller сначала обрабатывает bytes, затем error. `io.EOF` означает нормальное завершение stream; оборачивать его не следует, потому что многие callers сравнивают ошибку напрямую.

`Write(p)` обязан вернуть ошибку, если принял меньше `len(p)`; иначе package helpers преобразуют short write в `io.ErrShortWrite`. Интерфейсы сами по себе не обещают concurrent safety — это свойство конкретной реализации.

`io.Copy` читает до EOF и возвращает `nil` при нормальном завершении. Для эффективности он сначала проверяет `src.(io.WriterTo)`, затем `dst.(io.ReaderFrom)`; поэтому добавление внешнего buffer не всегда ускоряет copy и иногда скрывает оптимизированный path.

`bufio.Reader` полезен для delimiter-oriented protocol и lookahead. `bufio.Writer` накапливает записи; `Flush` переносит их в underlying writer, но не вызывает его `Close`. `Scanner` удобен для line/word tokenization, однако default maximum token приблизительно 64 KiB; после `Scan() == false` нужно проверить `Err()`. Для больших или точно framing-controlled records лучше `bufio.Reader`.

## Код

```go
package main

import (
	"bufio"
	"bytes"
	"fmt"
)

func main() {
	var destination bytes.Buffer
	writer := bufio.NewWriter(&destination)

	fmt.Fprintln(writer, "alpha")
	fmt.Fprintln(writer, "beta")
	fmt.Println("before flush:", destination.Len())

	if err := writer.Flush(); err != nil {
		panic(err)
	}

	scanner := bufio.NewScanner(&destination)
	for scanner.Scan() {
		fmt.Println("token:", scanner.Text())
	}
	if err := scanner.Err(); err != nil {
		panic(err)
	}
}
```

## Ожидаемый результат

```text
before flush: 0
token: alpha
token: beta
```

До `Flush` underlying `bytes.Buffer` пуст; после flush scanner получает две строки без line terminators. Пример выполнен в официальном Go Playground на Go 1.26.5; вывод совпал с ожидаемым, проверено 2026-07-15.

## Trade-offs

- Прямой `io.Copy` сохраняет возможность `WriterTo`/`ReaderFrom` fast path. `CopyBuffer` нужен, когда benchmark подтверждает пользу контролируемого reusable buffer или конкретные реализации не имеют fast path; его reuse оценивайте через [[60 Go/Аллокации, GC и GC pressure|allocation profile]], а общий buffer — по правилам [[60 Go/Снижение аллокаций и sync.Pool|sync.Pool]].
- `Scanner` даёт простой token loop и встроенные split functions. `Reader.ReadString`/`ReadSlice` лучше, когда tokens могут быть большими, нужно различать delimiter/error или продолжать последовательное чтение после ошибки.
- Больший buffer уменьшает число syscalls на последовательном I/O, но увеличивает память на каждое соединение и задержку видимости записи. Размер выбирают по workload, а не максимальному возможному message.

## Типичные ошибки

- Предположение: при `err != nil` bytes можно игнорировать. Симптом: теряется последний фрагмент stream. Причина: `Read` может вернуть `n > 0, io.EOF`. Исправление: всегда сначала обработать `p[:n]`.
- Предположение: `bufio.Writer.Write` сразу отправил данные. Симптом: peer или файл не видит хвост. Причина: bytes остались в buffer. Исправление: проверить `Flush` до закрытия/передачи ownership.
- Предположение: `Scanner.Scan() == false` означает только EOF. Симптом: длинная строка молча обрезает обработку. Причина: scanner остановился с token-too-long или I/O error. Исправление: всегда проверять `Scanner.Err`, настраивать `Buffer` либо использовать `Reader`.
- Предположение: wrapper закроет underlying resource. Симптом: file descriptor или connection остаётся открыт, например незакрытый `Response.Body` мешает [[60 Go/HTTP-клиент и Transport|HTTP Transport]] вернуть соединение в pool. Причина: `bufio.Reader/Writer` не владеют `Close`. Исправление: ownership `Close` держит код, создавший resource.

## Когда применять

Определяйте функции через узкие `io.Reader`/`io.Writer`, когда им нужен только поток: это упрощает композицию и тесты, а typed stream decoder вроде [[60 Go/Пакет encoding-json|encoding/json]] можно подключить без смены ownership. Добавляйте buffering у границы с дорогими мелкими I/O operations, измеряя память и latency.

Перед чтением недоверенного stream задавайте byte limit. Token limit `Scanner` защищает только один token и не является общим ограничением request body.

## Источники

- [Документация пакета io](https://pkg.go.dev/io@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Документация пакета bufio](https://pkg.go.dev/bufio@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Исходный код io.Copy](https://github.com/golang/go/blob/go1.26.5/src/io/io.go#L387-L430) — репозиторий golang/go, tag go1.26.5, файл `src/io/io.go`, функция `Copy`, проверено 2026-07-15.
- [Исходный код bufio.Scanner](https://github.com/golang/go/blob/go1.26.5/src/bufio/scan.go) — репозиторий golang/go, tag go1.26.5, файл `src/bufio/scan.go`, тип `Scanner`, проверено 2026-07-15.
