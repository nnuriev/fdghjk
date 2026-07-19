---
aliases:
  - Unit testing
  - Модульные тесты
tags:
  - область/бэкенд
  - тема/тестирование
статус: проверено
---

# Unit tests

## TL;DR

Unit test проверяет один отделимый фрагмент поведения независимо от остальной системы. Unit — это не обязательно одна функция и не обязательно один production type: граница проходит вокруг минимальной ответственности, контракт которой можно вызвать и наблюдать без реальной сети, базы, process-global state и неконтролируемого времени.

Сильный unit test задаёт вход и controlled dependencies, выполняет одно предметное действие и проверяет публичный результат, изменение состояния либо значимый side effect. Он должен ломаться при нарушении поведения, но переживать безопасный refactoring внутренней реализации.

## Область применимости

Основные принципы не зависят от языка. Для Go здесь зафиксирована toolchain Go 1.26.5: `go test` собирает `*_test.go`, находит `TestXxx(*testing.T)` и допускает тесты как в production package, так и во внешнем package с суффиксом `_test`.

Database schema, wire compatibility, реальные drivers и multi-process configuration не входят в доказательство unit test. Их проверяют [[20 Бэкенд/Integration tests|integration]] и [[20 Бэкенд/Contract tests|contract tests]].

## Ментальная модель

Unit удобно мыслить как детерминированное отображение:

```text
явные входы + начальное состояние + controlled effects
    -> действие
    -> результат + новое состояние + разрешённые effects
```

Тест фиксирует контракт вокруг стрелки, а не последовательность внутренних строк. Если observable outcome тот же, переименование helper, смена структуры данных или объединение внутренних вызовов не должны ломать тест.

Изоляция нужна не ради термина. Она даёт быстрый feedback и локализует причину: единственным production behavior в сценарии остаётся выбранная unit. Для этого дизайн должен явно передавать clock, randomness, repository или sender; связь с API и lifecycle компонента подробнее разобрана в [[50 Проектирование систем/Testability Go-компонента|заметке о testability]].

## Как устроено

### Выбрать поведенческую границу

Хорошими units обычно становятся:

- чистое предметное решение или state transition;
- parser/validator и преобразование форматов;
- use case с небольшим числом явно переданных ports;
- policy выбора retry, routing или authorization;
- локальный concurrent component, если scheduling контролируется отдельным harness.

Если тесту для простого правила требуется поднимать application container, сеть и базу, граница ответственности размыта. Если для проверки приходится читать private fields, тест, скорее всего, привязан к representation, а не к контракту.

### Построить сценарий

1. **Arrange:** создать минимальное валидное начальное состояние; зафиксировать clock/randomness; подготовить только нужные responses зависимостей.
2. **Act:** выполнить одно предметное действие.
3. **Assert:** проверить return/error, новое observable state и отсутствие запрещённых effects.

Название теста должно сообщать условие и результат, например `insufficient_limit_rejects_without_debit`, а failure message — показывать `got`, `want` и существенный вход. Один тест может иметь несколько assertions, если все они описывают один outcome.

### Разделить примеры и пространство входов

Обычные example-based cases включают:

- типичный допустимый вход;
- значения непосредственно на границе и по обе стороны от неё;
- zero/empty/nil, если они допустимы типом;
- invalid state и ошибку dependency;
- повторный вызов, если операция заявлена идемпотентной.

Table-driven style хорошо выражает одну и ту же операцию и oracle на разных данных; в Go idiom раскрыт в [[60 Go/Тестирование и httptest|заметке о `testing` и `httptest`]]. Если cases требуют разных setup, действий и критериев успеха, отдельные tests читаются лучше универсальной таблицы. Большое неизвестное пространство входов дополняют property-based и fuzz testing, а не тысячей вручную придуманных examples.

### Выбрать правильный oracle

Предпочтительный порядок наблюдений:

1. возвращаемое значение или typed error;
2. новое состояние через публичный query;
3. записанный command/event на внешней границе;
4. interaction expectation, только если сама кратность или отсутствие вызова является контрактом.

Проверка exact error string, порядка внутренних helper calls или полного private object graph обычно создаёт ложные отказы. Exact bytes нужны только тогда, когда representation сама является внешним контрактом.

### Сохранить детерминизм

Unit test не должен ждать «достаточно долго». Wall clock заменяют фиксированным clock, случайность — заданным generator/seed, завершение goroutine — явным signal или completion API. Process globals и shared fixtures делают tests зависимыми от порядка; mutable fixture создают внутри case либо синхронизируют явно.

## Пример или трассировка

Unit `DecideWithdrawal` получает `balance`, `amount`, уже использованный дневной лимит и `dailyLimit`. Она только принимает решение и не пишет в базу.

| Сценарий | Вход | Ожидаемый outcome |
| --- | --- | --- |
| На границе лимита | `balance=100`, `amount=30`, `used=20`, `limit=50` | debit `30`, новый balance `70`, новый used `50` |
| За границей лимита | `balance=100`, `amount=30`, `used=21`, `limit=50` | `ErrDailyLimit`, состояние не меняется |
| Недопустимая сумма | `balance=100`, `amount=0`, `used=20`, `limit=50` | `ErrInvalidAmount`, состояние не меняется |

Трассировка второго case:

1. Предусловия валидны, но `used + amount = 51`.
2. Инвариант требует `used + amount <= dailyLimit`.
3. Unit возвращает `ErrDailyLimit` и не формирует debit command.
4. Oracle проверяет error и отсутствие command; число вызовов внутренних функций не проверяется.

Этот test точно локализует off-by-one в сравнении `<=`. Он ничего не утверждает о transaction isolation, точности decimal encoding или mapping ошибки в HTTP status — это другие границы.

## Trade-offs

Black-box test через exported API лучше защищён от refactoring и одновременно проверяет удобство публичного контракта. White-box test в том же package может быть оправдан для сложного внутреннего algorithm или редкого failure state, но повышает coupling к реализации. В Go внешний `_test` package и обычный package можно сочетать осознанно, а не считать один вариант универсально правильным.

Реальная чистая dependency даёт больше fidelity, чем double, и обычно предпочтительна. Fake полезен для связного stateful поведения, mock — для точной проверки значимого interaction или редкой ошибки; их различие раскрыто в [[20 Бэкенд/Mocks vs fakes|отдельной заметке]]. Mock каждого collaborator ускоряет setup только сначала, а затем закрепляет topology вызовов.

Крупная unit вокруг целого use case лучше показывает предметный outcome, но имеет больше причин отказа. Мелкие tests точнее локализуют algorithmic cases, зато могут перестать защищать композицию. Граница должна совпадать с ответственностью, а не с желанием максимизировать число tests.

## Типичные ошибки

- **Неверное предположение:** unit test обязан проверять один method. **Симптом:** тесты повторяют private call graph и ломаются при extract/inline. **Причина:** unit выбрана по синтаксису, а не по ответственности. **Исправление:** тестировать минимальный observable behavior через устойчивую границу.
- **Неверное предположение:** больше assertions означает хуже. **Симптом:** одно действие разбито на tests с дублирующим setup, а часть outcome не проверена. **Причина:** правило «один assert» принято буквально. **Исправление:** один смысловой outcome может требовать проверки результата, состояния и отсутствия side effect.
- **Неверное предположение:** private state точнее подтверждает корректность. **Симптом:** смена map на slice ломает tests без изменения API. **Причина:** representation принято за contract. **Исправление:** читать состояние через публичный query или проверять сформированный effect.
- **Неверное предположение:** `time.Sleep` делает asynchronous unit предсказуемой. **Симптом:** suite то flaky, то медленный. **Причина:** истечение времени не доказывает наступление события. **Исправление:** fake clock, explicit signal, completion API или deterministic scheduler harness.
- **Неверное предположение:** mock unit доказывает поведение реальной dependency. **Симптом:** repository test проходит, а SQL нарушает инвариант. **Причина:** mock реализовал ожидания автора. **Исправление:** оставить unit для orchestration, а protocol semantics проверить integration test.
- **Неверное предположение:** 100% statement coverage означает полный decision space. **Симптом:** boundary case нарушает инвариант в покрытой ветке. **Причина:** coverage измеряет выполнение, а не качество oracle и комбинации данных. **Исправление:** decision tables, boundary analysis и properties поверх coverage.

## Когда применять

Unit tests — первый выбор для dense decision logic, parsers, policies, state machines и error mapping, потому что дают дешёвый перебор случаев и точную локализацию. Их пишут рядом с изменением поведения и regression defect.

Не нужно насильно превращать тонкий adapter в набор mocks: если его единственный риск — соответствие PostgreSQL, HTTP или broker protocol, более прямое доказательство даёт integration test. Практический критерий: unit test должен объяснять предметное правило, а не имитировать инфраструктуру.

## Источники

- [Package testing](https://pkg.go.dev/testing@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
- [How to Write Go Code — Testing](https://go.dev/doc/code#Testing) — The Go Project, общая веб-документация без release-versioning, проверено 2026-07-18.
- [Testing for Reliability](https://sre.google/sre-book/testing-reliability/) — Google, Site Reliability Engineering, глава 17, определение unit test, проверено 2026-07-18.
- [Test Sizes](https://testing.googleblog.com/2010/12/test-sizes.html) — Google Testing Blog, модель Small tests и требования к isolation, проверено 2026-07-18.
- [Just Say No to More End-to-End Tests](https://testing.googleblog.com/2015/04/just-say-no-to-more-end-to-end-tests.html) — Google Testing Blog, 2015, feedback и failure localization unit tests, проверено 2026-07-18.
