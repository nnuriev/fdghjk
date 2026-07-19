---
aliases:
  - Component public API
  - Публичный API компонента
tags:
  - область/проектирование-систем
  - тема/проектирование-компонентов
  - тема/api
статус: проверено
---

# Public API компонента

## TL;DR

Public API компонента — весь набор обещаний, на которых может строить код потребителя: импортируемый package, exported names и signatures, но также error semantics, ownership переданных значений, допустимый порядок вызовов, blocking и cancellation, concurrency safety, lifecycle и совместимость поведения. Список методов без этих условий — неполный контракт.

Хороший API минимален не по числу символов, а по числу независимых обязательств. Он выражает намерение предметными операциями, скрывает representation, не заставляет клиента собирать валидное состояние вручную и оставляет реализацию расширяемой там, где уже известна реальная ось изменения.

## Ментальная модель

Public API — бюджет обещаний. Пока функция или тип внутренние, их можно изменить вместе со всеми callers. После публикации каждая наблюдаемая деталь способна стать зависимостью: компиляционной, поведенческой или операционной.

Полезно рассматривать контракт в пяти слоях:

1. **Shape:** имена, types, methods и signatures.
2. **Meaning:** preconditions, postconditions, invariants и стабильные категории ошибок.
3. **Ownership:** кто может менять slice, map, pointer или callback после передачи и кто владеет освобождением ресурса.
4. **Time:** может ли вызов блокироваться, как отменяется, разрешены ли повтор и вызов после `Close`.
5. **Concurrency:** какие операции допустимы одновременно и какой результат они линеаризуют или упорядочивают.

Сокрытие полей само по себе не завершает контракт. Клиенту всё равно нужно уметь предсказать наблюдаемый результат, не читая реализацию. Это и есть intention-revealing interface: имя сообщает эффект и цель, а документация фиксирует условия и исключения.

## Как устроено

### Начать со сценариев потребителя

Сначала выпишите минимальные операции, нужные реальному caller, и состояния, которые тот должен различать. `SubmitOrder` лучше пары `SetStatus`/`Save`, потому что первая операция может атомарно обеспечить [[50 Проектирование систем/Domain model и инварианты|инварианты модели]], а вторая заставляет клиента знать внутренний protocol.

Exported representation увеличивает поверхность обещаний. Public fields позволяют клиенту создавать комбинации, которые constructor не проверял, и привязывают его к layout. Unexported state плюс constructor и intention-revealing methods оставляют одну контролируемую точку создания и mutation. Constructor нужен, если zero value не может быть полезным и безопасным; когда [[60 Go/Zero values, семантика значений и копирование|zero value]] естественен, его поддержка часто делает API проще.

### Выбрать тип границы

В Go реализация обычно возвращает concrete type, а consumer принимает минимальный interface, если ему действительно нужна подмена. Это позволяет producer добавлять методы concrete type без поломки чужих implementations. Подробная механика разобрана в [[60 Go/Интерфейсы и неявная реализация|интерфейсах и неявной реализации]].

Exported interface — особенно дорогое обещание: добавление метода ломает все внешние types, которые его реализуют. Такой interface оправдан, когда внешняя реализация является частью намеренного extension contract. Интерфейс «на всякий случай» или только ради mock фиксирует угаданную абстракцию раньше use case.

### Зафиксировать ownership и aliasing

Передача slice, map или pointer не означает автоматическую передачу независимой копии. API должен выбрать одно из трёх: скопировать данные, передать ownership либо разрешить совместное изменение по документированному protocol. То же относится к возврату: если `Stats()` отдаёт внутренний map, caller способен менять state в обход invariants и одновременно создать data race.

Безопасный default для value-like результата — immutable value или snapshot. Для больших buffers копирование может быть слишком дорогим; тогда ownership contract и lifetime должны быть явными, а экономию подтверждают измерением.

### Описать ошибки, время и lifecycle

Machine-readable error contract задают sentinel, typed error, predicate или документированное wrapping. Как показано в [[60 Go/Обработка ошибок|обработке ошибок]], `%w` раскрывает underlying error для `errors.Is`/`errors.As` и тем самым может сделать detail зависимости частью вашего API. Текст ошибки оставляют для человека.

Если операция способна ждать I/O, lock или очередь, контракт определяет deadline/cancellation и то, какой side effect возможен после отмены. Resource-owning component задаёт владельца `Close`, повторяемость вызова, поведение concurrent operations во время shutdown и результат методов после закрытия. Фраза «thread-safe» без перечня операций и lifecycle слишком расплывчата.

### Проектировать совместимое развитие

Для опубликованного Go module v1+ изменение function signature несовместимо даже тогда, когда старые call sites выглядят допустимыми: функцию могли сохранить как value точного function type. Добавление метода к public interface также ломает implementations. Обычная стратегия — добавить новую function/method или opt-in configuration, сохранив старый путь.

Options struct полезен, когда уже есть несколько действительно необязательных параметров с устойчивыми defaults. Functional options дают другой синтаксис, но добавляют exported names, правила конфликтов и validation. Не стоит платить эту цену для constructor с одним обязательным argument.

API-совместимость шире компиляции. Изменение default, ordering, error category, aliasing, blocking или concurrency semantics способно сломать caller при неизменной signature. Поэтому contract tests проверяют observable behavior, а не private fields.

## Пример или трассировка

Проектируется отдельный copy-owning вариант in-memory cache со значениями `[]byte`. Это не API generic LRU из [[50 Проектирование систем/Проектирование и реализация in-memory cache в Go|практической заметки]]: там caller владеет содержимым `V`, а отсутствие фоновых goroutines осознанно убирает `Close`.

1. `New(Config{Capacity: 100})` проверяет capacity и возвращает concrete `*Cache`. При недопустимой configuration объект не создаётся.
2. `Put("a", input)` обещает сохранить значение key `a`. Реализация копирует `input`, поэтому последующая mutation caller не меняет cache скрытно.
3. `Get("a")` возвращает `(value, found)`. Отсутствие не кодируется пустым slice, потому что пустое значение допустимо. Возвращённый slice — отдельная копия; caller не получает внутреннюю representation.
4. Документация разрешает concurrent `Get` и `Put`, но запрещает новые операции после завершившегося `Close`. `Close` повторяем и ждёт только ресурсы, которыми владеет cache.
5. Позже нужен metrics snapshot. Поскольку constructor вернул concrete type, добавляется метод `Stats() Stats` без изменения существующих signatures и без требования к чужим implementations.

Наблюдаемый результат: клиент может предсказать отсутствие aliasing, корректно отличает miss от пустого value, знает lifecycle и не зависит от внутреннего `map`, eviction algorithm или lock. Если бы constructor возвращал public `Cache` interface, добавление `Stats` потребовало бы нового interface или сломало бы implementers.

## Trade-offs

- **Concrete return или public interface.** Concrete type проще развивать и оставляет полный API caller. Public interface скрывает множество намеренно взаимозаменяемых implementations, но превращает method set в жёсткую compatibility boundary.
- **Полезный zero value или constructor.** Zero value уменьшает ceremony и облегчает embedding. Constructor нужен для обязательных dependencies, validation и состояний, которые невозможно безопасно представить нулями.
- **Копирование или borrowed data.** Копия упрощает ownership, concurrency и invariants ценой памяти и CPU. Borrowed buffer может быть оправдан в измеренном hot path, но требует строгого lifetime contract.
- **Options struct или functional options.** Struct легче валидировать целиком и документировать defaults. Functional options удобны для редких параметров, но создают дополнительный namespace и неоднозначность повторяющихся options.
- **Совместимое добавление или новая major version.** Additive API снижает migration cost, но бесконечные варианты размывают концепцию. Если contract потерял focus, честный новый major или новый package может быть дешевле вечного compatibility layer.

## Типичные ошибки

- **Неверное предположение:** public API — это только exported declarations. **Симптом:** обновление не ломает compilation, но меняет ordering, error handling или blocking и вызывает production regression. **Причина:** semantic и temporal contracts остались неявными. **Исправление:** документировать и тестировать observable shape, meaning, ownership, time и concurrency.
- **Неверное предположение:** interface всегда слабее связывает стороны. **Симптом:** любое новое capability требует менять десятки mocks и implementations. **Причина:** provider опубликовал широкий interface до реального consumer contract. **Исправление:** возвращать concrete type и объявлять маленький interface у потребителя при возникшей потребности.
- **Неверное предположение:** возврат map или slice — read-only по договорённости. **Симптом:** caller меняет внутреннее состояние или получает race. **Причина:** mutable representation пересекла границу без ownership protocol. **Исправление:** immutable value, snapshot/copy либо явно ограниченный borrowed lifetime.
- **Неверное предположение:** constructor с options автоматически делает API расширяемым. **Симптом:** невозможные combinations, неясные defaults и конфликтующие options. **Причина:** speculative parameters заменили предметные операции. **Исправление:** сначала минимальный required contract; добавлять configuration только по доказанной оси вариативности.
- **Неверное предположение:** `Close` понятен без документации. **Симптом:** double close panic, новые операции принимаются во время shutdown или фоновые workers остаются жить. **Причина:** lifecycle не включили в API. **Исправление:** определить ownership, idempotency, concurrent shutdown и post-close behavior.

## Когда применять

Такой разбор нужен для любого package или component, который имеет больше одного независимого caller, публикуется как module либо владеет mutable state, goroutines, files или connections. До реализации сформулируйте минимальные use cases, invariants, ownership, errors, cancellation, concurrency и lifecycle; затем проверьте API со стороны caller, не обращаясь к private representation.

Для короткой internal function полный versioning plan не нужен. Но и внутренняя граница выигрывает от ясного ownership и error contract: эти свойства предотвращают реальные ошибки, а не только облегчают будущую публикацию.

## Источники

- [Developing and publishing modules: Design and development](https://go.dev/doc/modules/developing) — The Go Project, документация Go modules, проверено 2026-07-18.
- [Keeping Your Modules Compatible](https://go.dev/blog/module-compatibility) — The Go Project, публикация 2020-07-07, проверено 2026-07-18.
- [Go 1 and the Future of Go Programs](https://go.dev/doc/go1compat) — The Go Project, compatibility policy Go 1, проверено 2026-07-18.
- [Go Code Review Comments: Interfaces](https://go.dev/wiki/CodeReviewComments#interfaces) — The Go Project, состояние страницы на 2026-07-18, проверено 2026-07-18.
- [Domain-Driven Design Reference: Intention-Revealing Interfaces and Assertions](https://www.domainlanguage.com/wp-content/uploads/2016/05/DDD_Reference_2015-03.pdf) — Eric Evans, 2015, проверено 2026-07-18.
