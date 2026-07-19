---
aliases:
  - Dependency inversion principle
  - Принцип инверсии зависимостей
tags:
  - область/проектирование-систем
  - тема/проектирование-компонентов
  - тема/зависимости
статус: проверено
---

# Dependency inversion

## TL;DR

Dependency inversion principle (DIP) направляет source dependencies к policy, а не к volatile details. Компонент с предметным решением формулирует минимальную abstraction, которая ему нужна; database, broker или provider adapter зависит от этого контракта и реализует его. Composition root знает обе стороны и соединяет object graph.

Runtime flow при этом не разворачивается: policy всё ещё вызывает repository, а repository — database. Инвертируется compile-time knowledge. Dependency injection передаёт выбранную implementation в component, но сама по себе не доказывает DIP: можно явно inject широкий vendor client и сохранить всю прежнюю связанность.

## Ментальная модель

Нужно держать в голове два графа.

**Runtime graph:**

```text
use case → repository adapter → database
```

**Source dependency graph:**

```text
use case owns Repository contract ← adapter implements it → database driver
composition root imports and connects both
```

High-level policy — правило, которое придаёт приложению смысл и должно переживать замену технического механизма. Low-level detail — конкретный способ чтения, отправки, хранения или измерения. Abstraction принадлежит policy не потому, что «interfaces всегда наверху», а потому что она формулирует потребность consumer в его языке.

В Go неявная реализация позволяет объявить маленький interface рядом с consumer: producer не обязан заранее знать всех callers. Это языковой механизм из [[60 Go/Интерфейсы и неявная реализация|модели интерфейсов]], а не требование создавать interface для каждой concrete type.

## Как устроено

### Отделить policy от mechanism

Сначала назовите решение, которое должно оставаться стабильным, и details, которые меняются независимо. Если application rule говорит «после успешного выпуска invoice зафиксировать его», ему нужна операция сохранения invoice, а не методы `BeginTx`, `ExecContext` и SQL rows. Эти низкоуровневые primitives полезны внутри adapter, но протекание наружу заставляет policy знать storage protocol.

Контракт должен быть минимальным и связным. Один method можно передать function value. Несколько операций, образующих единый protocol, — маленьким interface. Большой `Repository` на все entities связывает consumers с методами, которые им не нужны, и делает любую эволюцию общей.

### Разместить abstraction у consumer

Consumer-owned interface фиксирует только реально используемое поведение. Concrete implementation может иметь более широкий API и обслуживать других consumers через другие interfaces. Это снижает риск того, что abstraction повторит vendor SDK или заранее перечислит все возможные use cases.

Package layout должен сохранять acyclic imports: policy не импортирует adapters; adapters импортируют policy types/contracts, а `main` или другой composition root импортирует обе стороны. Общие правила package graph и способы разрыва cycles описаны в [[60 Go/Пакеты, модули и направление зависимостей|направлении зависимостей]].

### Перевести semantics, а не только methods

Работа adapter не заканчивается вызовом API. Он переводит domain values в representation detail и обратно, а также нормализует errors. Если policy проверяет `sql.ErrNoRows`, Redis status или HTTP code конкретного provider, detail по-прежнему является частью abstraction, хотя method принимает interface.

Substitutability также поведенческая. Все implementations обязаны одинаково трактовать identity, not-found, duplicate, cancellation, retry safety и ownership. Compile-time assertion подтверждает method set, но не доказывает эти promises; нужны contract tests на каждую implementation.

### Собрать dependencies явно

Constructor injection делает required dependencies видимыми в signature. Composition root выбирает concrete implementations, валидирует configuration, создаёт resources в dependency order и затем передаёт их component. Этот ручной wiring и есть обычный Go-код; framework для DIP не нужен.

Service locator, global registry или скрытый `init` меняют место поиска dependency, но не дают component явного contract. Ошибка обнаруживается позже, lifecycle расплывается, а тесту приходится менять global state.

### Не инвертировать всё подряд

DIP нужен там, где policy должна быть независима от volatile detail или где boundary имеет самостоятельный смысл. Stable value types, стандартные операции и local concrete collaborators можно использовать напрямую. Interface вокруг `time.Time`, `strings.Builder` или каждого struct увеличит число contracts без отдельной оси изменения.

## Пример или трассировка

Billing component выпускает invoice и отправляет receipt.

Исходный вариант импортирует concrete SQL client и SDK почтового provider. Метод use case сам строит SQL, проверяет vendor error codes и отправляет email. Замена provider требует менять package с billing policy; unit test обязан собирать детали обоих SDK.

После inversion:

1. Package `billing` владеет contracts `InvoiceStore.Save(invoice) error` и `ReceiptSender.Send(receipt) error`, сформулированными в domain terms.
2. PostgreSQL adapter реализует `InvoiceStore`, скрывает SQL и переводит duplicate constraint в документированный `billing.ErrAlreadyIssued`.
3. Email adapter реализует `ReceiptSender` и нормализует provider errors в согласованные категории.
4. Composition root создаёт pool, adapters и billing service, затем передаёт dependencies через constructor.
5. Для перехода с email API на очередь добавляются новый adapter и wiring. Billing policy и её tests не меняются.

Наблюдаемый результат: source change локализован в detail. Но DIP не делает две операции атомарными. Если invoice сохранён, а receipt не отправлен, workflow всё равно нуждается в retry/outbox или reconciliation. Принцип управляет направлением зависимостей, а не заменяет [[40 Распределённые системы/Transactional outbox и Change Data Capture|протокол надёжной доставки]].

## Trade-offs

- **Concrete dependency или inverted boundary.** Concrete type проще читать и диагностировать; выбирайте его для стабильного local detail. Interface + adapter окупаются, когда policy должна переживать замену implementation или ограничить vendor semantics.
- **Function value или interface.** Function подходит одной операции и даёт минимальный seam. Interface лучше выражает cohesive protocol, но его method set и поведение становятся отдельным contract.
- **Consumer-owned или provider-owned interface.** Consumer-owned interface узок и допускает разные views одной implementation. Provider-owned interface нужен, если сам provider намеренно публикует extension ecosystem, но тогда он обязан version и поддерживать контракт внешних implementations.
- **Явный wiring или locator/framework.** Ручная сборка даёт compile-time types и прозрачный lifecycle, но растёт вместе с object graph. Tooling может сократить boilerplate, однако не должно скрывать source direction и ownership.
- **Domain translation или протекание detail.** Translation добавляет mapping code. Прямой возврат vendor type короче сегодня, но привязывает policy, callers и tests к чужой модели изменений.

## Типичные ошибки

- **Неверное предположение:** любой interface реализует DIP. **Симптом:** business package принимает `SQLExecutor`, строит SQL и разбирает driver errors. **Причина:** abstraction повторяет mechanism, а не потребность policy. **Исправление:** назвать capability в domain terms и перенести protocol detail в adapter.
- **Неверное предположение:** dependency injection и dependency inversion — одно и то же. **Симптом:** concrete vendor client передаётся через constructor, но его types пронизывают policy. **Причина:** изменился способ создания object, не направление knowledge. **Исправление:** сначала определить policy-owned contract, затем inject его implementation.
- **Неверное предположение:** один общий interface уменьшает число зависимостей. **Симптом:** изменение метода storage ломает unrelated consumers и mocks. **Причина:** независимые capabilities склеены в dependency hub. **Исправление:** объявлять минимальные interfaces у конкретных consumers.
- **Неверное предположение:** совпадение signatures гарантирует подменяемость. **Симптом:** новая implementation иначе трактует not-found, retry или ownership и ломает workflow. **Причина:** semantic contract не зафиксирован. **Исправление:** документировать guarantees и запускать общий набор contract tests для implementations.
- **Неверное предположение:** global registry — удобный composition root. **Симптом:** dependency появляется только во время вызова, tests влияют друг на друга, shutdown order неясен. **Причина:** required graph и ownership скрыты. **Исправление:** explicit constructor parameters и сборка resources в одной видимой точке.

## Когда применять

Применяйте DIP на границах domain policy с database, clock, queue, external provider, filesystem и другими details, если их изменения не должны распространяться в policy. До извлечения interface покажите concrete consumer, сформулируйте минимальную capability, перечислите semantic guarantees и определите composition root.

Не применяйте принцип механически к каждой функции. Если abstraction не уменьшает knowledge, не изолирует ось изменения и не позволяет независимое reasoning, direct concrete dependency честнее. Цель — направить важные зависимости, а не добиться максимального числа interfaces.

## Источники

- [The Dependency Inversion Principle](https://objectmentor.com/resources/articles/dip.pdf) — Robert C. Martin, C++ Report, 1996, проверено 2026-07-18.
- [Go Code Review Comments: Interfaces](https://go.dev/wiki/CodeReviewComments#interfaces) — The Go Project, состояние страницы на 2026-07-18, проверено 2026-07-18.
- [The Go Programming Language Specification: Interface types](https://go.dev/ref/spec#Interface_types) — The Go Project, спецификация Go, проверено 2026-07-18.
- [Compile-time Dependency Injection With Go Cloud's Wire](https://go.dev/blog/wire) — The Go Project, публикация 2018-10-09, проверено 2026-07-18.
- [Domain-Driven Design Reference: Layered Architecture](https://www.domainlanguage.com/wp-content/uploads/2016/05/DDD_Reference_2015-03.pdf) — Eric Evans, 2015, проверено 2026-07-18.
