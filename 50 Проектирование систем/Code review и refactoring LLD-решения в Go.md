---
aliases:
  - Code review LLD Go
  - Refactoring LLD solution
  - Ревью объектного дизайна в Go
tags:
  - область/проектирование-систем
  - область/go
  - тема/ревью-кода
статус: проверено
---

# Code review и refactoring LLD-решения в Go

## TL;DR

LLD-review начинается с поведения: requirements, invariants, public API, state transitions, concurrency и error semantics. Лишь после этого имеет смысл обсуждать names и расположение методов. Самый дорогой дефект часто выглядит аккуратно, но оставляет invalid state после ошибки либо запускает goroutine без owner.

Refactoring меняет внутреннюю структуру без намеренного изменения observable behavior. Исправление бага, новый error contract и смена callback ordering — отдельные behavior changes. Сначала риск фиксируют тестом и маленьким изменением, затем упрощают структуру под зелёными tests.

## Область применимости

- Версия Go: 1.26; стабильная toolchain Go 1.26.5, проверено 2026-07-18.
- Объекты review: package API, structs/interfaces, mutable state, goroutines, errors, constructors и tests.
- GOOS и GOARCH: учитываются, если решение зависит от scheduling, filesystem, networking или atomics.
- Вне scope: организационная политика approvals и конкретный hosting UI.

## Ментальная модель

Review идёт по убыванию риска:

1. **Contract:** какую задачу решает component и что обещает caller.
2. **Invariants:** какие состояния запрещены; что остаётся неизменным при error.
3. **API и ownership:** кто создаёт, меняет, закрывает и владеет aliases.
4. **State/concurrency/lifecycle:** linearization points, transitions, blocking и shutdown.
5. **Errors и dependencies:** машинно-читаемая semantics, direction и test seams.
6. **Complexity:** можно ли локально доказать поведение и безопасно изменить его.
7. **Readability/style:** names, comments и idioms.

Комментарий review должен содержать наблюдаемый сценарий: precondition, вызов, outcome, нарушенный contract и минимальное направление исправления. «Мне не нравится этот interface» слабее, чем «добавление метода сломает внешних implementers; interface объявлен producer-ом до consumer need».

## Как устроено

### Восстановить contract

Прочитайте public API, tests и callers. Запишите happy path, один rejected path и один lifecycle/failure path. Если требования двусмысленны, не маскируйте это stylistic refactor. Для mutable component отдельно выпишите invariants и момент commit по [[50 Проектирование систем/Concurrency safety Go-компонента|модели concurrency safety]].

### Смотреть дизайн в контексте

Оцените package boundary, а не только изменённую function. В Go особенно проверяют:

- interface объявлен у consumer и не шире его потребности;
- constructor не оставляет invalid partial object;
- mutex не копируется, mutable map/slice не утекает наружу alias-ом;
- callback/I/O не исполняется под lock без явной причины;
- goroutine имеет owner, cancellation и completion;
- context приходит первым argument и не хранится в struct для request calls;
- caller различает ошибки через documented identity/type, а не текст;
- public API совместим или breaking change назван явно.

### Разделить fix и refactoring

Перед структурным изменением добавьте characterization tests существующего contract. Для обнаруженного бага нужен regression test желаемого поведения, который падает до fix. Сначала внесите минимальный behavior change. После зелёного результата делайте небольшие behavior-preserving transformations: rename, extract function, move responsibility, narrow interface. Tests запускаются после каждого логического шага.

Google рекомендует маленькие self-contained changes и обычно отделять refactoring от feature/bugfix. Это сокращает пространство причин: reviewer видит, где поменялось поведение, а где только форма.

## Код

Ниже не executable Go, а trace review существующего `ReservationBook`:

```text
Initial: available=5, leases={"x": 2}

Reserve("x", 3):
  1. available -= 3          // available=2
  2. duplicate? yes
  3. return ErrDuplicate

Snapshot():
  return internal leases map

Notify():
  lock
  observer(event)            // observer calls Snapshot
  unlock
```

Findings:

- **P0:** rejected `Reserve` меняет `available`; нарушен invariant «error leaves state unchanged».
- **P1:** observer повторно входит в `Snapshot` под тем же non-reentrant mutex; возможен deadlock.
- **P1:** `Snapshot` отдаёт mutable alias, поэтому caller обходит synchronization и invariants.

Минимальная последовательность исправлений:

1. regression test: duplicate сохраняет полный snapshot;
2. проверить duplicate и capacity до mutation, затем commit полей в одной critical section;
3. копировать map для snapshot;
4. сформировать immutable event под lock, вызвать observer после unlock и явно зафиксировать новую ordering semantics;
5. после bugfix вынести validation/commit helpers, только если это уменьшает proof surface.

## Ожидаемый результат

После шага 2 rejected operation сохраняет `available=5` и `leases={"x": 2}`. После шага 3 caller не меняет внутренние leases. После шага 4 observer может вызвать `Snapshot` без self-deadlock; при этом review отдельно проверяет допустимость изменения state между unlock и завершением observer.

Для такого trace toolchain не нужна: достаточно пошагово пройти операции и проверить invariants. Технические тезисы подтверждены источниками ниже, поэтому концептуальная заметка имеет статус `проверено`.

## Trade-offs

- Маленький change легче review и rollback, но boundary должен оставаться deployable: tests идут вместе с production change.
- Characterization test защищает неизвестное legacy behavior, но может закрепить баг. Отделяйте наблюдаемое текущее поведение от нормативного invariant.
- Extract interface улучшает seam, если consumer использует узкую способность. Если цель только «удобнее mock», concrete fake или function часто проще.
- Большой rewrite быстрее меняет форму, зато одновременно меняет слишком много assumptions. Серия малых transformations сохраняет локальную доказуемость.

## Типичные ошибки

- **Неверное предположение:** review равен поиску style violations. **Симптом:** код красив, но нарушает invariant. **Причина:** локальная форма проверена раньше behavior. **Исправление:** risk order из ментальной модели.
- **Неверное предположение:** «refactoring» может попутно чинить semantics. **Симптом:** regression трудно связать с конкретным решением. **Причина:** behavior и structure смешаны. **Исправление:** отдельный failing test и bugfix, затем refactor.
- **Неверное предположение:** больше abstraction означает лучше design. **Симптом:** call chain длиннее, axis of change не назван. **Причина:** abstraction создана по предположению. **Исправление:** показать текущую variation point или оставить прямой код.
- **Неверное предположение:** успешный test доказывает concurrency. **Симптом:** rare race/deadlock в production. **Причина:** один interleaving. **Исправление:** invariants, `-race`, controlled synchronization и stress.

## Когда применять

На интервью сначала проговорите top risks и докажите один finding trace-ом. Затем предложите минимальный patch, тест, который отличает старое поведение от нового, и следующий безопасный refactoring. В production review разделяйте blocking defects, design debt и optional nits; иначе важный invariant теряется в списке косметики.

## Источники

- [What to look for in a code review](https://google.github.io/eng-practices/review/reviewer/looking-for.html) — Google Engineering Practices, проверено 2026-07-18.
- [Small CLs](https://google.github.io/eng-practices/review/developer/small-cls.html) — Google Engineering Practices, проверено 2026-07-18.
- [Refactoring](https://www.refactoring.com/) — Martin Fowler, определение и дисциплина refactoring, проверено 2026-07-18.
- [Refactoring Catalog](https://refactoring.com/catalog/) — Martin Fowler, каталог behavior-preserving transformations, проверено 2026-07-18.
- [Go Code Review Comments](https://go.dev/wiki/CodeReviewComments) — The Go Project, проверено 2026-07-18.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, редакция 2022-06-06, применима к Go 1.26, проверено 2026-07-18.
