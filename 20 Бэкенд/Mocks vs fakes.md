---
aliases:
  - Mocks versus fakes
  - Моки и фейки
  - Test doubles
tags:
  - область/бэкенд
  - тема/тестирование
статус: проверено
---

# Mocks vs fakes

## TL;DR

Mock и fake — разные виды test double. Mock получает запрограммированные ответы и expectations о взаимодействиях; test падает, если SUT вызвал его не так. Fake — облегчённая, но работающая реализация того же API: она сама выполняет упрощённую логику и при необходимости хранит состояние, хотя не подходит для production.

Предпочтительный выбор — реальная быстрая dependency, затем проверенный fake, и только затем mock там, где interaction само входит в контракт или нужна точная fault injection. Mock повышает controllability, но легко привязывает test к внутреннему call graph. Fake даёт более реалистичное поведение, но способен тихо разойтись с production implementation.

## Область применимости

Заметка относится к unit и component tests backend-кода. **Test double** — общий термин: кроме mocks и fakes, к нему относят dummy, stub и spy. Stub только выдаёт заданные ответы; spy записывает вызовы для последующей проверки. Framework-generated object не становится mock автоматически: роль определяется тем, проверяет ли test interaction expectations.

Для Go важен design seam: небольшой consumer-owned interface или function dependency вокруг внешнего эффекта. Создавать interface рядом с implementation только ради генерации mocks обычно ухудшает API; сборка зависимостей без framework разобрана в [[50 Проектирование систем/Dependency injection в Go без framework dependency|заметке о dependency injection]].

## Ментальная модель

Различие находится в источнике истины:

```text
mock: test script задаёт ответы и допустимый разговор
fake: implementation задаёт поведение, test — входы и начальное состояние
real: production implementation задаёт поведение и protocol
```

Mock отвечает на вопрос «правильно ли SUT разговаривал по сценарию, который я описал?». Fake отвечает «получился ли правильный outcome в упрощённой модели dependency?». Ни один автоматически не доказывает, что production dependency ведёт себя так же.

Отсюда главный критерий: если значим итоговый state, предпочитают state-based assertion с real/fake. Если значимо само внешнее действие — например, не списать деньги второй раз, не отправить секрет в audit sink или выполнить не более одного network call — interaction/call count может быть частью observable contract и mock уместен.

## Как устроено

### Что делает mock

Test программирует ожидаемые inputs, outputs/errors, допустимое число и иногда порядок вызовов. Mock удобен, когда нужно:

- вернуть timeout, malformed response или редкую ошибку;
- доказать отсутствие необратимого side effect;
- проверить retry budget или call cardinality;
- захватить command, который иначе не наблюдаем внутри unit boundary.

Порядок внутренних calls проверяют только при semantic protocol. Например, `Begin -> Write -> Commit` значим для transaction adapter; порядок `validate -> map -> save` внутри use case обычно является implementation detail.

### Что делает fake

Fake реализует связный набор правил, а stateful fake ещё и хранит состояние: так работают in-memory key-value store, fake clock, fake queue и fake identity provider. Cases настраивают входы и, когда он есть, исходный state, а итог проверяют через тот же API. Один fake переиспользуется многими tests и позволяет исследовать несколько операций без длинного expectation script.

Хороший fake должен:

- реализовывать только поддерживаемый contract, а не удобную фантазию test author;
- быть deterministic и concurrency-safe, если production API это обещает;
- воспроизводить значимые errors, uniqueness и lifecycle;
- иметь conformance suite, который по возможности запускается и против real implementation;
- явно документировать расхождения: transactions, consistency, ordering, limits, time.

In-memory map не является fake PostgreSQL, если не воспроизводит SQL, collation, isolation и constraints. Она может быть хорошим fake repository на более узком domain port.

### Выбирать по fidelity и controllability

1. Использовать реальную implementation, если она быстра, deterministic, локальна и безопасна.
2. Использовать owner-maintained fake, если нужен stateful behavior без дорогой инфраструктуры.
3. Использовать mock/stub, если нужен конкретный interaction или error, который real/fake трудно вызвать.
4. Добавить [[20 Бэкенд/Integration tests|integration/contract test]] на реальную границу, если double не доказывает её semantics.

Это не абсолютная лестница. Fake clock лучше wall clock именно потому, что production time недетерминированно; mock external payment лучше реального charge в unit test. Выбор оптимизирует fidelity относительно проверяемого свойства, а не сходство среды вообще.

### Не расширять seam без необходимости

Чем шире interface, тем больше boilerplate и ложных expectations. Consumer должен объявлять минимальные операции, которые ему нужны. Одна функция может быть лучшим seam для `Now`, `Send` или `Authorize`; связный многооперационный protocol оправдывает interface.

Test double не должен просачиваться в production API как универсальный abstraction layer. Его форма следует domain/effect boundary, а не возможностям mock framework. Это часть общей [[50 Проектирование систем/Testability Go-компонента|testability компонента]].

## Пример или трассировка

Use case `CreateOrder(idempotencyKey, product, qty)` резервирует stock и один раз авторизует платёж. Для test используются fake idempotency store и fake inventory; payment gateway — mock, потому что кратность необратимого внешнего действия является контрактом.

Начальное состояние: stock `5`, key отсутствует, payment mock допускает ровно одну authorization на сумму заказа.

1. Первый вызов с key `k-7`, qty `2` создаёт `order=o-91`; fake inventory меняет stock `5 -> 3`, fake store связывает `k-7 -> o-91`, mock записывает одну authorization.
2. Второй вызов с тем же key возвращает `o-91`; stock остаётся `3`, payment mock не получает второй вызов.
3. Test проверяет итоговые states через fake APIs и expectation `Authorize` exactly once.

Fake здесь лучше двух длинных scripts `Get(k-7) -> missing`, `Put(k-7, o-91)`, затем `Get(k-7) -> o-91`: он выражает stateful semantics повторного вызова. Mock payment оправдан, потому что второй вызов сам является дефектом, даже если локальный order state случайно выглядит корректно.

Но этот test не доказывает uniqueness реального idempotency store, transaction между reserve и save или wire contract payment provider. Для них нужны integration и contract scenarios.

## Trade-offs

Mock создаётся быстро внутри одного case и даёт точную fault injection. Цена — низкая fidelity и coupling к choreography: безопасное объединение двух reads в batch или добавление cache может сломать expectations без изменения результата.

Fake лучше поддерживает state-based tests и часто делает scenarios короче. Цена переносится в отдельную implementation: её нужно проектировать, синхронизировать с real contract и тестировать. Плохой fake опаснее явного stub, потому что выглядит реалистично и создаёт больше уверенности.

Real dependency устраняет semantic drift, но может быть медленной, требовать credentials или иметь необратимые side effects. Testcontainers/sandbox позволяют приблизить real boundary, однако не отменяют необходимость быстрых doubles для exhaustive failure cases.

Strict mock раньше обнаруживает неожиданное interaction, но легко over-specifies порядок. Lenient fake принимает больше допустимых реализаций, зато может не заметить лишний дорогой call. Assertions должны соответствовать риску: call count проверяют там, где он влияет на деньги, latency, quota или side effect.

## Типичные ошибки

- **Неверное предположение:** любой generated double — mock и требует verify всех вызовов. **Симптом:** test повторяет полный call graph. **Причина:** роль double смешана с инструментом создания. **Исправление:** различать stubbed answers, stateful fake и действительно значимые interaction expectations.
- **Неверное предположение:** больше mocks означает лучшую изоляцию. **Симптом:** refactoring без изменения behavior ломает десятки tests. **Причина:** tests закрепили choreography. **Исправление:** проверять outcome, использовать real/fake для стабильных dependencies и mock только внешние effects.
- **Неверное предположение:** in-memory fake эквивалентен production store. **Симптом:** concurrency, transaction или uniqueness defect появляется только production. **Причина:** fake не моделирует protocol semantics. **Исправление:** объявить ограничения fake и запустить conformance/integration suite на real store.
- **Неверное предположение:** fake не нуждается в tests. **Симптом:** suite уверенно подтверждает поведение, которого real implementation не обещает. **Причина:** два implementations эволюционировали независимо. **Исправление:** owner-maintained fake и общий contract/conformance suite.
- **Неверное предположение:** exact call order всегда важен. **Симптом:** оптимизация batch/cache ломает unit suite. **Причина:** implementation detail принят за contract. **Исправление:** проверять порядок только для semantic protocols и irreversible effects.
- **Неверное предположение:** mock timeout означает корректную обработку ambiguous outcome. **Симптом:** unit проходит, retry дублирует production side effect. **Причина:** простой error не моделирует commit-before-timeout. **Исправление:** отдельные states до commit, после commit и unknown; проверить idempotency на более широкой границе.

## Когда применять

Fake выбирают для многократных stateful interactions: repository port, queue, clock, registry или identity model, если нужную semantics можно компактно и честно воспроизвести. Mock выбирают для узкого внешнего effect, call budget, negative interaction и редкой fault injection.

Если test в основном настраивает десятки expectations, это design signal: unit слишком широка, interface слишком велик или проверяемое поведение лучше выразить component test с real/fake dependency. Если fake начинает реализовывать transaction engine, дешевле поднять настоящую dependency и сузить suite.

## Источники

- [Testing on the Toilet: Know Your Test Doubles](https://testing.googleblog.com/2013/07/testing-on-toilet-know-your-test-doubles.html) — Google Testing Blog, 2013, определения stub, mock и fake, проверено 2026-07-18.
- [Increase Test Fidelity By Avoiding Mocks](https://testing.googleblog.com/2024/02/increase-test-fidelity-by-avoiding-mocks.html) — Google Testing Blog, 2024, выбор real implementation, fake и mock, проверено 2026-07-18.
- [How Much Testing is Enough?](https://testing.googleblog.com/2021/06/how-much-testing-is-enough.html) — Google Testing Blog, 2021, mocks/fakes в unit и integration portfolio, проверено 2026-07-18.
- [Go Code Review Comments — Interfaces](https://go.dev/wiki/CodeReviewComments#interfaces) — The Go Project, Go Wiki без release-versioning, рекомендации по consumer-owned interfaces, проверено 2026-07-18.
- [Package testing](https://pkg.go.dev/testing@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
