---
aliases:
  - Property testing
  - Тестирование на основе свойств
tags:
  - область/бэкенд
  - тема/тестирование
статус: черновик
---

# Property-based testing

## TL;DR

Property-based testing проверяет не один заранее выбранный example, а общее свойство на множестве сгенерированных inputs. Минимум для такого test — generator, который задаёт domain и distribution, и oracle/invariant, который определяет неверное поведение. Практически полезный framework обычно добавляет shrinker: он ищет более простой воспроизводимый counterexample, но отсутствие shrinking не превращает проверку в другую технику.

Это random testing, а не доказательство для всех значений. Сильная property с плохим generator не видит нужный класс inputs; хороший generator со слабым oracle лишь быстро подтверждает малозначимое утверждение.

## Область применимости

- Модель применима к pure transformations, codecs, parsers, state machines, financial/domain calculations и API invariants.
- Пример Go ориентирован на Go 1.26.5 и standard package `testing/quick`.
- `testing/quick` заморожен и не принимает новые features. Его public API генерирует значения и ищет failure, но не предлагает shrink protocol и coverage-guided corpus.
- Вне scope: формальное доказательство, exhaustive model checking и выбор конкретного third-party framework.

## Ментальная модель

В упрощённом виде property записывается так:

```text
для многих x из domain D:
    precondition(x) => invariant(SUT(x))
```

Два слова здесь критичны:

- **domain** не означает «все bytes»; это множество допустимых или сознательно недопустимых значений с конкретным распределением;
- **invariant** — observable relation, которая следует из контракта, а не из текущей implementation.

Каждый generated case остаётся одним обычным тестом. Ценность в том, что автор фиксирует закон, а framework исследует много конкретных точек.

## Как устроено

### Generator задаёт не только тип, но и distribution

Генератор должен попадать в смысловые partitions: empty/singleton/many, min/max, duplicate keys, Unicode classes, valid/invalid states, rare transitions. Uniform random integer часто почти никогда не попадает в немногие бизнес-значимые числа. Их нужно взвешивать явно.

Для structured domain valid-by-construction generator обычно сильнее схемы «сгенерировать всё и отбросить 99,9%». Массовый reject маскирует реальное число проверенных cases и искажает distribution. Для invalid-input property нужен отдельный generator, который нарушает одно условие за раз.

Качество distribution проверяют так же, как result: классифицируют cases и ставят minimum coverage для редких классов, если framework это умеет.

### Oracle должен быть независимым

Типичные формы oracle:

- **алгебраический закон:** `reverse(reverse(x)) == x`, commutativity или idempotence там, где они действительно часть контракта;
- **round trip:** `decode(encode(x)) == x`, с отдельной проверкой canonical representation;
- **metamorphic relation:** предсказуемое отношение между results после преобразования input, например добавление identity element;
- **reference/model:** сравнение с медленной, но простой и независимой реализацией;
- **state invariant:** balance conservation, monotonic version, отсутствие duplicate identity или запрещённого transition.

Round trip может не увидеть одинаковую ошибку encoder и decoder. Reference implementation, скопировавшая тот же algorithm, тоже не даёт независимого oracle.

### Shrinking превращает failure в диагностический пример

После failure shrinker генерирует «меньших» candidates и оставляет те, на которых property всё ещё падает. Для list это может быть удаление chunks и уменьшение elements; для command sequence — удаление steps с сохранением valid preconditions.

Шринкер — часть domain model. Если он разрушает валидность, минимизация уходит в несвязанные rejects. «Минимальный» counterexample зависит от shrink relation и порядка candidates; это не обязательно глобально самый маленький input.

`testing/quick` не реализует этот этап. Поэтому его failure нужно вручную свести к понятному regression case или выбрать framework с shrink API.

### Reproducibility закрывает цикл от random failure к regression test

При failure сохраняйте seed, версию generator/framework и конечный counterexample. Фиксированный seed делает кампанию повторяемой в той же среде, но не заменяет корпус: изменение generator может изменить sequence при том же seed.

Найденный минимальный example стоит добавить в обычный deterministic regression test. Тогда random search ищет новые bugs, а известный bug больше не зависит от удачи.

### Table, property и fuzz отвечают на разные вопросы

| Техника | Как выбирает input | Что является oracle | Сильная сторона | Граница |
| --- | --- | --- | --- | --- |
| [[60 Go/Table-driven tests в Go|Table-driven test]] | Автор явно задаёт конечные cases | Exact expected values/errors | Известные examples, boundaries и регрессии | Не исследует неизвестное space |
| Property-based | Generator с заданным domain/distribution | Invariant, relation или model | Много structured valid cases и domain laws | Качество зависит от generator и property |
| [[60 Go/Fuzzing|Coverage-guided fuzzing]] | Mutation seeds с feedback о новых execution paths | Crash или invariant target | Malformed inputs и неизвестные parser paths | Требует corpus, CPU budget и bounded target |

Property-based test может быть поверх fuzz engine, если target проверяет инвариант. Отличие тогда остаётся в search strategy: generator-driven sampling против coverage-guided mutation.

## Пример или трассировка

```go
package reverse

import (
	"math/rand"
	"slices"
	"testing"
	"testing/quick"
)

func reverse(xs []int) []int {
	out := slices.Clone(xs)
	slices.Reverse(out)
	return out
}

func TestReverseIsInvolution(t *testing.T) {
	config := &quick.Config{
		MaxCount: 1_000,
		Rand:     rand.New(rand.NewSource(20260718)),
	}

	property := func(xs []int) bool {
		return slices.Equal(reverse(reverse(xs)), xs)
	}

	if err := quick.Check(property, config); err != nil {
		t.Fatal(err)
	}
}
```

Трассировка одного case:

```text
generator -> xs = [4, -1, 2]
reverse   -> [2, -1, 4]
reverse   -> [4, -1, 2]
oracle    -> result == xs
```

Для другого input, например `[1, 2, 3]`, промежуточный result изменится, но relation останется той же. Семантика property не требует знать exact output одного `reverse`; она проверяет закон involution.

Ожидается, что `quick.Check` вернёт `nil` после 1000 cases. Код локально не запускался из-за отсутствия Go toolchain; это ожидаемый, а не наблюдавшийся result. `testing/quick` сообщит arguments при failure, но не будет автоматически их shrink.

## Trade-offs

- Property сжимает много examples в один закон. Цена — нужно найти независимый oracle; для arbitrary CRUD это может быть сложнее, чем exact scenario.
- Valid-by-construction generator эффективно исследует domain. Он может повторить ошибку production constructor, если переиспользует его логику; generator нужен как независимая модель input.
- Fixed seed облегчает повтор. Rotating/random seed исследует больше paths между runs, но failure должен печатать и сохранять seed/counterexample.
- Shrinking уменьшает debugging cost, но может быть дорогим и требует domain-aware relation. Без shrink failure всё ещё ценен, но крупный generated object труднее диагностировать.

## Типичные ошибки

- Неверное предположение: 10 000 generated cases доказывают property. Симптом: уверенность без анализа distribution. Причина: проверена конечная sample. Исправление: классифицировать cases и сохранять язык «не найден counterexample в этом run».
- Неверное предположение: любая true property полезна. Симптом: test проверяет только «не было panic» для total function. Причина: oracle слабее бизнес-контракта. Исправление: добавить conservation, canonical form, reference result или state invariant.
- Неверное предположение: широкая precondition бесплатна. Симптом: тысячи discarded cases и единицы реальных checks. Причина: generator не знает domain. Исправление: генерировать valid structures напрямую и измерять discard ratio.
- Неверное предположение: для воспроизведения достаточно seed. Симптом: после обновления generator failure исчезает. Причина: sequence зависит от implementation. Исправление: коммитить минимальный counterexample как обычный test/corpus entry.

## Когда применять

Применяйте property-based testing, когда domain больше набора ручных examples, но контракт даёт сильные законы: codecs, normalization, sorting, allocation, ledgers, state transitions и compatibility transformations.

Начинайте не с framework, а с трёх вопросов: какие inputs значимы, какой независимый закон должен сохраняться и как превратить failure в маленькую regression. Если на второй вопрос нет ответа, конечная [[60 Go/Table-driven tests в Go|таблица exact examples]] может быть честнее и сильнее.

## Источники

- [QuickCheck: A Lightweight Tool for Random Testing of Haskell Programs](https://doi.org/10.1145/351240.351266) — Koen Claessen, John Hughes, ICFP 2000, DOI 10.1145/351240.351266, проверено 2026-07-18.
- [Test.QuickCheck](https://hackage.haskell.org/package/QuickCheck-2.18.0.0/docs/Test-QuickCheck.html) — QuickCheck project, версия 2.18.0.0, generators, shrinking и distribution checks, проверено 2026-07-18.
- [Package testing/quick](https://pkg.go.dev/testing/quick@go1.26.5) — Go project, Go 1.26.5, package frozen, `Check`, `CheckEqual`, `Config` и `Generator`, проверено 2026-07-18.
- [Source testing/quick](https://github.com/golang/go/blob/go1.26.5/src/testing/quick/quick.go) — репозиторий golang/go, tag `go1.26.5`, файл `src/testing/quick/quick.go`, проверено 2026-07-18.
- [Go Fuzzing](https://go.dev/doc/security/fuzz/) — Go project, native coverage-guided fuzzing для Go 1.18–1.26, проверено 2026-07-18.
