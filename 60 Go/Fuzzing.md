---
aliases:
  - Fuzz testing
tags:
  - область/go
статус: проверено
---

# Fuzzing

## TL;DR

Встроенный fuzzing Go генерирует и мутирует inputs, используя coverage для поиска новых execution paths. Он эффективен только вместе с oracle — быстрым детерминированным invariant, который превращает panic, ошибку или несоответствие результата в воспроизводимый failure.

Seed corpus запускается обычным `go test`; найденный failing input сохраняется в `testdata/fuzz/<Name>` и становится regression test. Fuzzing дополняет example/table tests, но не доказывает отсутствие ошибок.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5.
- Native fuzzing доступен начиная с Go 1.18.
- В Go 1.26.5 fuzzing поддерживается на Darwin, FreeBSD, Linux, OpenBSD и Windows; coverage instrumentation используется на поддерживаемых комбинациях `amd64`, `arm64` и `loong64` (порт `loong64` — Linux). Seed mode обычного `go test` остаётся тестом независимо от длительной fuzz campaign.
- Пакеты и tools: `testing`, `go test -fuzz`.

## Ментальная модель

Fuzzer — search engine по input space. Seed задаёт стартовые точки, mutator предлагает варианты, coverage сообщает о новых путях, invariant решает, является ли наблюдение ошибкой.

Полезный target имеет четыре свойства: детерминирован, быстр, не зависит от persistent global state и проверяет сильный контракт. Без invariant fuzzer лишь доказывает «не было panic на просмотренных inputs», а не корректность результата.

## Как устроено

Fuzz test имеет имя `FuzzXxx`, принимает `*testing.F` и находится в `*_test.go`. До `F.Fuzz` вызывают `F.Add` для seeds. Target принимает первым `*testing.T`, затем поддерживаемые builtin types; типы и порядок seeds должны точно совпасть с arguments target.

Без флага `-fuzz` target выполняется на seed corpus из `F.Add` и `testdata/fuzz/<Name>`. С `-fuzz=regexp` engine мутирует inputs, инструментирует coverage и сохраняет generated corpus в build cache. При failure input минимизируется и записывается как corpus file; его следует commit после исправления, чтобы обычный `go test` предотвращал regression.

Target исполняется многими workers в недетерминированном порядке. Нельзя сохранять mutable argument или pointer на него между вызовами: backing memory может быть переиспользована. Из-за network, clock и shared database failure трудно воспроизвести; parser/codec/pure transformation — хорошие кандидаты.

У campaign должен быть budget через `-fuzztime` и отдельная resource policy в CI. Случайно найденный crash сначала воспроизводят обычным `go test`, затем исправляют root cause; удалять failing corpus, чтобы «починить» pipeline, нельзя.

## Код

```go
package hexroundtrip

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func FuzzHexRoundTrip(f *testing.F) {
	f.Add([]byte{})
	f.Add([]byte("Go"))
	f.Add([]byte{0x00, 0xff})

	f.Fuzz(func(t *testing.T, input []byte) {
		encoded := hex.EncodeToString(input)
		decoded, err := hex.DecodeString(encoded)
		if err != nil {
			t.Fatalf("decode generated hex: %v", err)
		}
		if !bytes.Equal(decoded, input) {
			t.Fatalf("round trip: got %x, want %x", decoded, input)
		}
	})
}
```

## Ожидаемый результат

`go test` выполняет три seeds и завершается с exit code 0. `go test -fuzz=FuzzHexRoundTrip -fuzztime=1000x` выполняет ограниченную campaign и также должен завершиться с exit code 0: для каждого input должен выполняться invariant

```text
DecodeString(EncodeToString(input)) == input
```

Количество executions, workers и duration в terminal output недетерминированы и не входят в ожидаемый результат. Официальный Go Playground на Go 1.26.5 выполнил обычный `go test`: все три seed cases завершились `PASS`; отдельную fuzz campaign Playground не запускает, проверено 2026-07-15.

## Эволюция и версии

| Версия Go | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| До Go 1.18 | В standard toolchain не было native coverage-guided fuzz test API | — | Использовались внешние engines или вручную сгенерированные cases | [Go Fuzzing](https://go.dev/doc/security/fuzz/) |
| Go 1.18+, включая Go 1.26.5 | — | `testing.F`, `F.Add`, `F.Fuzz` и `go test -fuzz` входят в toolchain | Seeds становятся обычными regression tests, failures сохраняются в стандартном corpus format | [Go Fuzzing](https://go.dev/doc/security/fuzz/) |

## Trade-offs

- [[60 Go/Тестирование и httptest|Table tests]] дешёво фиксируют известные partitions и expected values. Fuzzing выигрывает на большом input space и неизвестных edge cases, но требует CPU budget и сильного invariant; обычно нужны оба.
- Round-trip invariant универсален для codec, но может пропустить симметричную ошибку encoder и decoder. Дополняйте его independent checks: canonical form, reference implementation, limits и известные vectors.
- Большой seed corpus увеличивает baseline time и может дублировать coverage. Маленькие representative seeds дают mutator разнообразные shapes без превращения fuzz test в медленный fixture.

## Типичные ошибки

- Предположение: отсутствие crash за минуту означает корректность. Симптом: ложная уверенность при слабом oracle. Причина: исследована только часть input space. Исправление: формулировать invariants и сохранять обычные boundary tests.
- Предположение: target может использовать shared mutable cache. Симптом: нерепродуцируемый failure или [[60 Go/Race detector|data race]]. Причина: workers выполняют calls параллельно и в другом порядке. Исправление: локальное состояние на invocation или явная concurrency-safe dependency и отдельный запуск с `-race`.
- Предположение: любой invalid input нужно `t.Skip`. Симптом: fuzzer никогда не исследует parser error paths. Причина: слишком широкая precondition отбрасывает интересные inputs. Исправление: skip только inputs вне реального domain, а errors проверять как часть контракта.
- Предположение: найденный corpus — временный artifact. Симптом: bug возвращается после очистки cache. Причина: failing input не стал regression test. Исправление: добавить минимизированный файл из `testdata/fuzz` в commit с fix.

## Когда применять

Лучшие цели — parsers, decoders, protocol state machines, binary/text transformations и функции с ясным invariant. Например, [[60 Go/Пакет encoding-json|JSON decoder]] стоит проверять на trailing values и limits, а операции над [[60 Go/Строки, байты, руны и UTF-8|UTF-8 и bytes]] — на некорректные sequences. Перед fuzzing сделайте target bounded по памяти и времени: специально созданный input не должен бесконтрольно аллоцировать или зависать.

Запускайте seeds в каждом `go test`, короткий fuzz budget — периодически или в CI по выбранной policy, длинные campaigns — отдельно с сохранением corpus.

## Источники

- [Go Fuzzing](https://go.dev/doc/security/fuzz/) — Go project, документация native fuzzing для Go 1.18–1.26, проверено 2026-07-15.
- [Документация testing.F](https://pkg.go.dev/testing@go1.26.5#F) — Go project, Go 1.26.5, проверено 2026-07-15.
- [Исходный код testing.F](https://github.com/golang/go/blob/go1.26.5/src/testing/fuzz.go#L69-L267) — репозиторий golang/go, tag go1.26.5, файл `src/testing/fuzz.go`, тип `F` и методы `Add`, `Fuzz`, проверено 2026-07-15.
- [Поддерживаемые платформы fuzzing](https://github.com/golang/go/blob/go1.26.5/src/internal/platform/supported.go#L60-L80) — репозиторий golang/go, tag go1.26.5, файл `src/internal/platform/supported.go`, функции `FuzzSupported` и `FuzzInstrumented`, проверено 2026-07-15.
- [История релизов Go](https://go.dev/doc/devel/release) — Go project, Go 1.26.5, проверено 2026-07-15.
