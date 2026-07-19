---
aliases:
  - Extensibility without premature abstraction
  - Расширяемость без преждевременной абстракции
tags:
  - область/проектирование-систем
  - тема/проектирование-компонентов
  - тема/эволюция
статус: проверено
---

# Extensibility без преждевременной абстракции

## TL;DR

Extensibility — способность внести ожидаемое изменение с локальным и предсказуемым blast radius. Она не измеряется количеством interfaces, options и plugin hooks. Часто самый расширяемый первый дизайн — concrete implementation со скрытой representation, ясными invariants и tests: когда появляется второй реальный вариант, из двух случаев можно извлечь правильную общую capability.

Преждевременная abstraction имеет собственную стоимость: её нужно понять, тестировать и поддерживать совместимой; она разрешает часть комбинаций и запрещает другие ещё до того, как известна настоящая ось изменения. YAGNI не запрещает refactoring, testability или защиту необратимой public boundary — эти практики как раз делают отложенное решение безопасным.

## Ментальная модель

Расширяемость — не «никогда не менять старый код», а **менять его в месте, которое владеет соответствующим решением**. Локальная правка cohesive component нормальна. Плохо, когда одно новое требование распространяется по несвязанным packages или требует нарушить опубликованные promises.

Перед созданием extension point разделите будущие изменения на три группы:

1. **Уже нужны:** есть два поведения, provider или policy. Их variation можно выразить контрактом на основе фактов.
2. **Известны и дороги для изменения позже:** public API, persisted format, security/consistency boundary. Здесь заранее фиксируют compatibility envelope и migration path, но не реализуют несуществующую feature.
3. **Гипотетические:** неизвестны caller, semantics и lifecycle. Их выгоднее отложить, оставив код пригодным к refactoring.

У решения две цены: будущий refactoring без abstraction и постоянная carry cost abstraction, созданной заранее. Вторую часто недооценивают, хотя каждый caller вынужден понимать ещё один indirection и набор допустимых combinations.

## Как устроено

### Начать с concrete и скрыть необратимое

Первая implementation может быть concrete, но не обязана раскрывать fields, global state или vendor types. Unexported representation, явные dependencies и узкий [[50 Проектирование систем/Public API компонента|public API]] сохраняют свободу внутреннего refactoring без speculative polymorphism.

Простой `switch` по небольшому закрытому набору вариантов иногда честнее Strategy interface. Function parameter подходит одной меняющейся операции. Interface появляется, когда несколько implementations уже разделяют устойчивое поведение и consumer действительно должен быть независим от выбора.

### Искать ось изменения по фактам

Roadmap, второй use case, incident history и repeated changes дают доказательство лучше фразы «может пригодиться». Сравните конкретные cases:

- какие inputs и outputs совпадают по смыслу;
- какие preconditions и errors обязаны быть одинаковыми;
- какие configuration и lifecycle различаются;
- должен ли caller выбирать implementation или это внутренняя policy.

Извлекайте минимальную общую capability, а не union всех методов implementations. В Go interface обычно объявляет consumer после появления usage; официальные Code Review Comments прямо предостерегают от interface до реального use case и от producer interface только ради mocks.

### Сохранять возможность дешёвого refactoring

Отложенное решение безопасно, когда:

- behavior проверяется через observable contract;
- [[50 Проектирование систем/Cohesion и coupling|cohesion локализует change]];
- dependencies явны и нет process-wide registry;
- representation не пересекает boundary без необходимости;
- migrations отделены от одномоментного изменения кода.

Это не speculative feature. Tests и refactoring уменьшают стоимость будущего знания, не утверждая заранее, каким окажется требование.

### Планировать действительно необратимые seams

После публикации function signature нельзя совместимо изменить, а метод нельзя безболезненно добавить в interface, который реализуют внешние users. Поэтому Go API чаще возвращает concrete type и принимает маленькие consumer interfaces. Если нужны новые capabilities, additive method/function или новый interface позволяют старым clients мигрировать постепенно.

Persisted data и network contracts требуют version marker, tolerant reader или staged migration раньше, чем появится новая implementation. Но «возможен новый формат» не означает, что уже нужен generic plugin runtime, registry, discovery protocol и compatibility SDK.

### Удалять неудачную abstraction

Abstraction — гипотеза о том, какие различия несущественны. Если implementations постоянно требуют type assertions, optional methods, flags и исключения, гипотеза не подтвердилась. Верните concrete behavior, разделите contracts по consumers либо найдите более глубокое общее понятие. Поддерживать ложную универсальность только потому, что она уже существует, дороже controlled refactoring.

## Пример или трассировка

Компонент экспорта records сначала поддерживает только JSON.

1. Первая версия содержит concrete JSON encoder с unexported details. Public operation принимает records и возвращает bytes/error; никакого registry форматов нет.
2. Появляется подтверждённое требование CSV. Теперь видны две реализации и общий consumer need: «закодировать records». Consumer объявляет минимальную capability `Encode(records)`, а JSON и CSV adapters реализуют её. Выбор implementation остаётся в composition root.
3. Третий built-in format добавляется новой implementation без изменения consumer workflow. Это подтверждает выбранную ось.
4. Идея «когда-нибудь принимать сторонние plugins» пока не имеет требований к discovery, versioning, sandbox, configuration и lifecycle. Команда не добавляет dynamic registry и plugin SDK.
5. Если external plugins становятся реальной product feature, это проектируется как отдельная public protocol boundary с compatibility и security policy, а не как ещё одна строка во внутреннем map.

Наблюдаемый результат: первый release не несёт стоимость неиспользуемой plugin architecture; второй use case приводит к маленькому контракту, основанному на фактическом сходстве. При этом private representation и tests позволяют выполнить extraction без изменения поведения callers.

## Trade-offs

- **Небольшое дублирование или ранняя abstraction.** Два коротких concrete cases могут показать настоящие различия; раннее объединение иногда скрывает их flags. Дублирование опасно, если уже расходятся критичные invariants — тогда общий владелец нужен раньше.
- **`switch` или polymorphism.** `switch` прозрачен для малого закрытого набора вариантов и exhaustive review. Interface/strategy выигрывает, когда implementations добавляются независимо и consumer не должен меняться; цена — новый semantic contract и indirection.
- **Internal seam или public extension point.** Internal interface можно refactor атомарно с callers. Public interface требует versioning, documentation и поддержки чужих implementations, поэтому evidence threshold для него выше.
- **Options или отдельные types.** Options удобны для ортогональных параметров с ясными defaults. Если combinations имеют разные invariants и lifecycle, отдельные constructors/types делают недопустимые состояния менее выразимыми.
- **Подготовить migration или feature.** Version field, opaque persisted representation и additive API могут дёшево сохранить путь изменения. Реализация всего будущего workflow заранее создаёт carry cost и задерживает текущую ценность.

## Типичные ошибки

- **Неверное предположение:** interface нужен до первой implementation, чтобы система была расширяемой. **Симптом:** contract повторяет concrete methods, а новый use case требует его сломать. **Причина:** abstraction создана без consumer evidence. **Исправление:** оставить concrete return и извлечь минимальный consumer contract после реального variation.
- **Неверное предположение:** Open/Closed означает запрет менять существующий код. **Симптом:** новый behavior проходит через registries, flags и forwarding layers, хотя принадлежит одному component. **Причина:** локальный refactoring ошибочно принят за design failure. **Исправление:** разрешать cohesive owner меняться; extension point вводить только для независимой оси.
- **Неверное предположение:** generic type делает разные concepts одной abstraction. **Симптом:** constraints, callbacks и flags сложнее concrete implementations, а invariants всё равно различаются. **Причина:** синтаксическое сходство принято за общее поведение. **Исправление:** разделить concepts или найти semantic contract, который действительно нужен consumer.
- **Неверное предположение:** functional options безопасно резервируют любое будущее. **Симптом:** options конфликтуют, порядок влияет на результат, появляются невозможные configurations. **Причина:** неизвестные состояния закодированы раньше правил. **Исправление:** вводить options для подтверждённых ортогональных параметров и валидировать итоговую configuration целиком.
- **Неверное предположение:** YAGNI оправдывает отсутствие tests и refactoring. **Симптом:** при втором use case extraction слишком рискован, поэтому команда копирует код или добавляет flag. **Причина:** отложили не feature, а здоровье design. **Исправление:** поддерживать self-testing cohesive code; откладывать speculative capability, а не возможность безопасно меняться.
- **Неверное предположение:** опубликованную abstraction всегда нужно сохранять внутри. **Симптом:** реализация обрастает type assertions и optional protocols. **Причина:** ложная abstraction стала самоцелью. **Исправление:** сохранить внешний compatibility adapter на migration window, а внутреннюю модель упростить или разделить.

## Когда применять

Используйте этот подход при проектировании plugin points, strategies, provider abstractions, configuration APIs и generic libraries. Перед extension point назовите реального consumer, минимум две implementations или другое сильное доказательство variation, общий semantic contract, lifecycle и стоимость будущей несовместимости.

Если evidence нет, сохраняйте concrete design, скрывайте representation, пишите behavior tests и фиксируйте известные irreversible boundaries. Это не отказ от архитектуры, а evolutionary design: решение принимается тогда, когда данных достаточно, а структура кода позволяет внести его локально.

## Источники

- [Yagni](https://martinfowler.com/bliki/Yagni.html) — Martin Fowler, публикация 2015-05-26, проверено 2026-07-18.
- [Go Code Review Comments: Interfaces](https://go.dev/wiki/CodeReviewComments#interfaces) — The Go Project, состояние страницы на 2026-07-18, проверено 2026-07-18.
- [Keeping Your Modules Compatible](https://go.dev/blog/module-compatibility) — The Go Project, публикация 2020-07-07, проверено 2026-07-18.
- [Domain-Driven Design Reference: Supple Design and Conceptual Contours](https://www.domainlanguage.com/wp-content/uploads/2016/05/DDD_Reference_2015-03.pdf) — Eric Evans, 2015, проверено 2026-07-18.
- [On the Criteria To Be Used in Decomposing Systems into Modules](https://doi.org/10.1145/361598.361623) — D. L. Parnas, Communications of the ACM, 1972, проверено 2026-07-18.
