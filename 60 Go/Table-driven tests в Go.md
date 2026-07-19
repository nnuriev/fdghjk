---
aliases:
  - Табличные тесты в Go
  - Go table-driven tests
tags:
  - область/go
  - тема/тестирование
статус: черновик
---

# Table-driven tests в Go

## TL;DR

Table-driven test в Go — это не отдельный тип теста, а способ отделить данные сценариев от общего механизма вызова и проверки. Каждая строка таблицы должна быть полным сценарием: имя, input, expected observable result и, если нужно, setup.

`t.Run` даёт кейсам адресуемые имена, отдельные failures и selective run. Таблица улучшает тест только пока кейсы делят один контракт. Если строки требуют разных control flow и assertions, «универсальная» таблица с набором callbacks обычно читается хуже нескольких явных tests.

## Область применимости

- Версия Go: 1.26.5; `t.Run` доступен с Go 1.7.
- GOOS/GOARCH: механика `testing` переносима; сами integration fixtures могут зависеть от платформы.
- Пакеты: `testing`; в примере также `errors`, `fmt` и `strconv`.
- Техника одинаково применима к unit, integration и contract scenarios; уровень теста определяет boundary системы, а не форма таблицы.

## Ментальная модель

Таблица — это конечная спецификация примерами:

```text
case = name + precondition + input + expected outcome
runner(case) = arrange -> act -> assert
```

Инвариант хорошей таблицы: чтобы понять причину failure, достаточно имени кейса и сообщения assertion. Тест не должен требовать мысленно исполнить всю таблицу, чтобы понять одну строку.

Table-driven форма не генерирует покрытие. Автор всё равно выбирает partitions и границы. Для неизвестных inputs её дополняют [[20 Бэкенд/Property-based testing|property-based testing]] и [[60 Go/Fuzzing|fuzzing]].

## Как устроено

### Строка таблицы хранит контракт, а не логику теста

Обычно достаточно named struct или anonymous struct с полями `name`, `input`, `want` и `wantErr`. Поля `setup func`, `check func` и десяток flags — сигнал, что кейсы больше не делят один runner. Вынесите отдельный test или сгруппируйте строки по одному observable contract.

Expected error лучше задавать как category (`errors.Is`/`errors.As`) или typed fields, а не как полную строку, если текст не является частью контракта.

### Subtests дают имя и lifecycle

`t.Run(name, func(t *testing.T))` создаёт subtest. Полное имя состоит из path родителей и подходит для `go test -run` с slash-separated regular expressions. Слеш в имени кейса создаст ещё один сегмент path, поэтому имена должны быть короткими и стабильными.

`Fatal` останавливает текущий subtest, но не соседние строки. Resource ownership стоит фиксировать через `t.Cleanup` в том subtest, где resource создан. Для HTTP cases общий runner удобно сочетается с [[60 Go/Тестирование и httptest|`httptest`]].

### Slice и map несут разные гарантии

Slice задаёт воспроизводимый порядок и допускает одинаковые labels, хотя имена subtests всё равно лучше делать уникальными. Map удобна, когда key естественно является именем, но Go не определяет порядок iteration. Это может обнаружить скрытый shared state, но не является управляемым schedule exploration. Для воспроизводимой диагностики предпочтите slice.

### Parallel — только после изоляции fixture

Subtest, вызвавший `t.Parallel`, приостанавливается и продолжается после возврата последовательной функции parent. Поэтому rows не должны менять общий mock, database row, temporary file или process-wide state. `T.Setenv` не совместим с parallel tests.

Параллелизм — не оптимизация «по умолчанию». Он окупается для медленных и изолированных cases; для микротестов overhead и сложность владения state могут быть дороже.

## Код

```go
package port

import (
	"errors"
	"fmt"
	"strconv"
	"testing"
)

var ErrPort = errors.New("invalid port")

func parsePort(s string) (uint16, error) {
	n, err := strconv.ParseUint(s, 10, 16)
	if err != nil || n == 0 {
		return 0, fmt.Errorf("%w: %q", ErrPort, s)
	}
	return uint16(n), nil
}

func TestParsePort(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    uint16
		wantErr bool
	}{
		{name: "minimum", input: "1", want: 1},
		{name: "maximum", input: "65535", want: 65535},
		{name: "zero", input: "0", wantErr: true},
		{name: "overflow", input: "65536", wantErr: true},
		{name: "syntax", input: "80/tcp", wantErr: true},
	}

	for _, tc := range tests {
		tc := tc // Сохраняет корректность и для language version < Go 1.22.
		t.Run(tc.name, func(t *testing.T) {
			got, err := parsePort(tc.input)
			if (err != nil) != tc.wantErr {
				t.Fatalf("parsePort(%q) error = %v, wantErr = %v", tc.input, err, tc.wantErr)
			}
			if tc.wantErr {
				if !errors.Is(err, ErrPort) {
					t.Fatalf("error = %v, want errors.Is(..., ErrPort)", err)
				}
				return
			}
			if got != tc.want {
				t.Fatalf("parsePort(%q) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}
```

## Ожидаемый результат

`go test -run '^TestParsePort$' -v` должен создать пять subtests и завершиться с exit code 0:

```text
TestParsePort/minimum
TestParsePort/maximum
TestParsePort/zero
TestParsePort/overflow
TestParsePort/syntax
```

Кейсы доказывают включённые границы `1..65535` и общую error category для zero, overflow и malformed input. Пример не запускался локально: Go toolchain в доступной среде отсутствует, поэтому вывод указан как ожидаемый, а статус заметки оставлен `черновик`.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| Go 1.7 | Кейсы в loop не имели standard subtest lifecycle | `T.Run` и `B.Run` добавили named subtests/sub-benchmarks | Selective run, отдельные failures и групповой setup стали частью `testing` | [Using Subtests and Sub-benchmarks](https://go.dev/blog/subtests) |
| Language version до Go 1.22 | Range variable переиспользовалась между iterations | — | Closure, особенно после `t.Parallel`, требовала `tc := tc` | [Go Wiki: LoopvarExperiment](https://go.dev/wiki/LoopvarExperiment) |
| Language version Go 1.22+ | — | Каждая iteration имеет свою declared variable | Дополнительное shadowing для корректности не нужно, но может сохранять compatibility с модулями старой language version | [Go 1.22 Release Notes](https://go.dev/doc/go1.22#language) |

## Trade-offs

- Таблица удаляет copy-paste и выравнивает assertions. Отдельные tests выигрывают, когда сценариям нужны разные fixtures, actions и доказательства.
- Exact `want` даёт сильный oracle, но может закрепить несущественное представление. Проверяйте semantic value, если bytes, order и текст не являются контрактом.
- Общий setup сокращает время, но позволяет одной строке загрязнить следующую. Per-row fixture дороже, зато сохраняет isolation.
- Много rows покрывают известные equivalence classes. Они не заменяют генерацию или mutation на большом input space.

## Типичные ошибки

- Неверное предположение: «если строк много, coverage полное». Симптом: десятки happy-path variants и ни одной границы. Причина: форма не выбирает partitions. Исправление: сначала построить boundary/failure matrix, затем перенести representative cases в table.
- Неверное предположение: один общий fixture эквивалентен сумме изолированных cases. Симптом: test падает только после другой строки. Причина: case меняет shared state. Исправление: fresh fixture или явный reset с проверкой cleanup.
- Неверное предположение: `t.Parallel` механически ускоряет любую таблицу. Симптом: flaky results и [[60 Go/Race detector|race reports]]. Причина: rows делят mutable fixture или process-wide state. Исправление: сначала доказать isolation и ownership.
- Неверное предположение: полное сравнение error string всегда сильнее. Симптом: тест ломается от context wrapping или редакторской правки. Причина: display text принят за machine contract. Исправление: `errors.Is`, `errors.As` и проверка значимых typed fields.

## Когда применять

Используйте table-driven form, когда cases различаются данными, но доказывают один контракт. Это особенно удобно для parser/validator, mapping error codes, protocol matrices и [[20 Бэкенд/Тестирование границ и failure paths|соседних граничных значений]].

Оставьте отдельные tests, если у сценариев разные phases, failure semantics или дорогие fixtures. Таблица должна делать контракт видимым, а не сжимать любую сложность в один loop.

## Источники

- [Package testing](https://pkg.go.dev/testing@go1.26.5) — Go project, Go 1.26.5, проверено 2026-07-18.
- [Go Wiki: TableDrivenTests](https://go.dev/wiki/TableDrivenTests) — Go project, official wiki, проверено 2026-07-18.
- [Using Subtests and Sub-benchmarks](https://go.dev/blog/subtests) — Go project, `T.Run`/`B.Run` с Go 1.7, проверено 2026-07-18.
- [Go 1.22 Release Notes — Changes to the language](https://go.dev/doc/go1.22#language) — Go project, Go 1.22, поведение loop variables, проверено 2026-07-18.
- [The Go Programming Language Specification — For statements](https://go.dev/ref/spec#For_statements) — Go project, спецификация для language version Go 1.26, проверено 2026-07-18.
