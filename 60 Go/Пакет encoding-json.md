---
aliases:
  - Пакет encoding/json
tags:
  - область/go
статус: проверено
---

# Пакет encoding/json

## TL;DR

`encoding/json` связывает динамическую JSON-модель с конкретной Go-моделью через reflection, exported fields и struct tags. За permissive defaults приходится платить: unknown fields обычно игнорируются, числа в `any` становятся `float64`, совпадение field names допускает регистронезависимый fallback.

На строгой API-границе декодируйте в отдельный transport struct, включайте `DisallowUnknownFields`, сохраняйте числа через `UseNumber`, ограничивайте размер body и проверяйте, что после первого JSON value нет trailing data.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5.
- GOOS и GOARCH: поведение пакета переносимо.
- Пакет: `encoding/json` первой версии.
- Вне scope: экспериментальный `encoding/json/v2`, JSON Schema и кодогенераторы.

## Ментальная модель

JSON содержит objects, arrays, strings, numbers, booleans и null; Go требует статический destination type. Decoder выполняет проекцию входного дерева в форму destination. Struct и tags задают schema, но default schema намеренно терпима ради совместимости.

Из этого следует: успешный `Decode` означает синтаксически допустимую и конвертируемую проекцию, а не валидный бизнес-объект. Required fields, ranges, cross-field invariants и отсутствие второго value проверяет приложение.

## Как устроено

`Marshal` обходит значение через reflection. Видимы только exported struct fields; tag `json:"name,omitempty"` меняет имя и может опустить empty value. Unsupported values, включая channel, func и complex, дают `UnsupportedTypeError`; cycle в pointer graph также приводит к ошибке.

`Unmarshal` или `Decoder.Decode` сопоставляет object keys с field tag/name, предпочитая точное совпадение, но допускает case-insensitive match. Unknown key по умолчанию игнорируется. Повторяющиеся keys обрабатываются по порядку, поэтому более позднее значение заменяет или дополняет предыдущее; это может отличаться от других JSON implementations и важно для security boundary.

При destination `any` number становится `float64`, что теряет точность для целых больше $2^{53}$. `Decoder.UseNumber` сохраняет lexical number как `json.Number`, после чего приложение явно выбирает `Int64`, `Float64` или иной parser.

`Decoder` следует потоковой модели [[60 Go/Пакеты io и bufio|io.Reader]] и может прочитать один value, оставив следующий во входе. Для HTTP body после первого `Decode` нужно вызвать второй и ожидать `io.EOF`; иначе строка `{} {}` будет частично принята. Сам decoder не ограничивает размер входа. Для HTTP используйте `http.MaxBytesReader`; для общего `io.Reader` читайте не более `N+1` bytes и явно отклоняйте превышение. Один `io.LimitReader(r, N)` недостаточен: после `N` bytes он возвращает обычный EOF и не отличает точную границу от обрезанного хвоста.

## Код

```go
package main

import (
	"encoding/json"
	"fmt"
	"strings"
)

func main() {
	numberDecoder := json.NewDecoder(
		strings.NewReader(`{"id":9007199254740993}`),
	)
	numberDecoder.UseNumber()
	var envelope map[string]any
	if err := numberDecoder.Decode(&envelope); err != nil {
		panic(err)
	}
	id := envelope["id"].(json.Number)
	fmt.Printf("%T %s\n", id, id.String())

	strictDecoder := json.NewDecoder(
		strings.NewReader(`{"name":"Ada","extra":true}`),
	)
	strictDecoder.DisallowUnknownFields()
	var request struct {
		Name string `json:"name"`
	}
	err := strictDecoder.Decode(&request)
	fmt.Println(err)
}
```

## Ожидаемый результат

```text
json.Number 9007199254740993
json: unknown field "extra"
```

`UseNumber` сохраняет точную decimal-запись, а strict decoder отвергает поле, отсутствующее в destination struct. Пример выполнен в официальном Go Playground на Go 1.26.5; вывод совпал с ожидаемым, проверено 2026-07-15.

## Эволюция и версии

| Версия | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| Go 1.24 | `omitempty` не выражал все случаи Go zero value одинаково | Добавлен стабильный `omitzero`: используется `IsZero() bool` либо zero value языка; вместе с `omitempty` достаточно любого условия | Можно отделить JSON-empty от Go-zero без pointer workaround | [Go 1.24 Release Notes](https://go.dev/doc/go1.24#encoding/json) |
| Go 1.25–1.26.5 | Стабильным API остаётся `encoding/json` v1 | `encoding/json/v2` и `encoding/json/jsontext` доступны только с `GOEXPERIMENT=jsonv2` | Experimental API не покрыт Go 1 compatibility promise; production scope фиксируйте отдельно | [Go 1.25 Release Notes](https://go.dev/doc/go1.25#new-experimental-encoding-json-v2-package) |

## Trade-offs

- Struct destination даёт статический контракт, меньше assertions и предсказуемые allocations. `map[string]any` полезен для действительно динамической схемы, но переносит type checking в runtime.
- `Marshal`/`Unmarshal` удобны для одного value в памяти. `Encoder`/`Decoder` подходят для stream, но всё равно могут буферизовать часть входа и не заменяют size limit.
- Strict unknown-field policy быстрее выявляет contract drift, но мешает forward compatibility клиентов, если сервер должен принимать новые поля. Решение должно быть частью API compatibility policy, а не случайным default.

## Типичные ошибки

- Предположение: decoder сообщит об опечатке в field. Симптом: zero value проходит дальше. Причина: unknown fields игнорируются по умолчанию. Исправление: `DisallowUnknownFields` и отдельная validation обязательных полей.
- Предположение: JSON integer в `any` сохраняет точность. Симптом: ID округляется после decode/encode. Причина: default type — `float64`. Исправление: typed destination или `UseNumber`.
- Предположение: один успешный `Decode` потребил body целиком. Симптом: trailing JSON или мусор незаметно принимается. Причина: decoder работает с потоком values. Исправление: второй `Decode` должен вернуть `io.EOF`.
- Предположение: `omitempty` означает «поле неизвестно». Симптом: значимые `false`, `0` или пустая строка исчезают. Причина: tag опускает empty value. Исправление: использовать pointer/optional representation, если нужно различать «не передано» и zero.

## Когда применять

Используйте `encoding/json` для стандартных API и storage formats, когда reflection cost приемлем и schema выражается Go types. Если контракт зависит от различия bytes, runes и некорректного UTF-8, сначала зафиксируйте модель из [[60 Go/Строки, байты, руны и UTF-8|заметки о строках, байтах, рунах и UTF-8]]. На недоверенной границе [[60 Go/HTTP-сервер на net-http|HTTP handler]] сначала ограничивает bytes, затем декодирует transport DTO и проверяет trailing data и бизнес-инварианты.

Если profiling показывает, что JSON — bottleneck, сравнивайте альтернативы benchmark на реальной schema; не меняйте codec только по общему обещанию меньшего числа allocations. Parser и round-trip invariant этой границы хорошо дополняются [[60 Go/Fuzzing|fuzzing-тестом]].

## Источники

- [Документация пакета encoding/json](https://pkg.go.dev/encoding/json@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Go 1.24 Release Notes — encoding/json](https://go.dev/doc/go1.24#encoding/json) — The Go Project, Go 1.24, проверено 2026-07-15.
- [Go 1.25 Release Notes — experimental encoding/json/v2](https://go.dev/doc/go1.25#new-experimental-encoding-json-v2-package) — The Go Project, Go 1.25; применимо к Go 1.26.5, проверено 2026-07-15.
- [Исходный код omitzero](https://github.com/golang/go/blob/go1.26.5/src/encoding/json/encode.go#L107-L145) — репозиторий golang/go, tag go1.26.5, файл `src/encoding/json/encode.go`, проверено 2026-07-15.
- [Документация experimental json/v2 в исходном коде](https://github.com/golang/go/blob/go1.26.5/src/encoding/json/v2/doc.go#L5-L15) — репозиторий golang/go, tag go1.26.5, файл `src/encoding/json/v2/doc.go`, проверено 2026-07-15.
- [Исходный код io.LimitReader](https://github.com/golang/go/blob/go1.26.5/src/io/io.go#L458-L480) — репозиторий golang/go, tag go1.26.5, файл `src/io/io.go`, проверено 2026-07-15.
- [Исходный код http.MaxBytesReader](https://github.com/golang/go/blob/go1.26.5/src/net/http/request.go#L1176-L1225) — репозиторий golang/go, tag go1.26.5, файл `src/net/http/request.go`, проверено 2026-07-15.
- [Исходный код JSON decoder](https://github.com/golang/go/blob/go1.26.5/src/encoding/json/decode.go#L363-L731) — репозиторий golang/go, tag go1.26.5, файл `src/encoding/json/decode.go`, функции `decodeState.value` и `decodeState.object`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
