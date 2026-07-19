---
aliases:
  - Поддерживаемость кода
  - Maintainable software
tags:
  - область/проектирование-систем
  - тема/качество-кода
  - тема/поддерживаемость
статус: проверено
---

# Maintainability

## TL;DR

Maintainability, или поддерживаемость, — способность безопасно анализировать, изменять и проверять систему при известной цене. Читаемость помогает понять текущий фрагмент; maintainability проверяется изменением: сколько границ, команд, данных и rollout-шагов придётся согласовать, чтобы поменять одно правило и не сломать старый контракт.

Универсального «maintainability score» нет. Полезнее наблюдать change lead time, blast radius, долю связанных дефектов, сложность проверки и возможность отката, а затем объяснять их конкретной архитектурной причиной. Метрика без модели легко поощряет косметику: функцию разрезали, число строк упало, а invariant теперь размазан по пяти packages.

## Ментальная модель

Система поддерживаема, когда вероятное изменение локализовано. Module действует как change firewall: внутри него можно заменить representation, снаружи сохраняется узкий устойчивый contract. Эта идея следует из information hiding Парнаса: декомпозицию строят вокруг решений, которые вероятнее всего изменятся, а не вокруг шагов текущего алгоритма.

Для любого change scenario задайте пять вопросов:

1. Где живёт правило и кто им владеет?
2. Какие contracts или persisted data оно пересекает?
3. Можно ли проверить изменение на узком seam?
4. Можно ли выпустить и откатить его независимо?
5. Какие знания потребуются следующему инженеру?

Если ответ «нужно синхронно менять всё», проблема не в скорости набора кода. Система потеряла границы изменения.

## Как устроено

### Локализовать причины изменения

Высокая cohesion собирает один invariant и его операции вместе. Низкий, явный coupling не означает отсутствие зависимостей: стороны всё равно разделяют смысл contract, error semantics, ordering и lifecycle. Цель — связаться с устойчивым понятием и не протащить через границу volatile detail. Механика разобрана в [[50 Проектирование систем/Cohesion и coupling|заметке о cohesion и coupling]].

Shared transport DTO, database row или mutable map часто экономят mapping сегодня, но связывают будущие изменения representations. Перевод на ownership boundary добавляет код, зато позволяет внутренним моделям эволюционировать независимо. Цена оправдана между разными contexts или release contracts; внутри одного cohesive component лишний mapping только мешает.

### Сохранить analysability

Изменение начинается с поиска owner, callers, data flow и tests. Явное направление dependencies, предметные package names и отсутствие скрытой регистрации сокращают этот поиск. В Go acyclic import graph помогает увидеть compile-time direction, но runtime coupling через callbacks, globals, database schema и events всё равно нужно документировать.

Наблюдаемость тоже часть analysability. Для production-only failure нужны stable error identity, correlation, metrics и traces, иначе модуль локален в исходниках, но непрозрачен в эксплуатации. При этом telemetry contract должен быть ограничен: labels с высокой cardinality и logging внутреннего state создают новую цену поддержки.

### Сделать изменение проверяемым

Testability появляется, когда side effects, clock, randomness и concurrency имеют управляемые seams, а observable contract можно проверить без копирования implementation. Это не требует interface на каждый struct. [[50 Проектирование систем/Testability Go-компонента|Testability Go-компонента]] показывает, как отделить policy от effects и сохранить production invariants в test doubles.

Regression suite уменьшает риск изменения, но сама требует поддержки. Tests, привязанные к private call order и exact internal representation, блокируют безопасный refactoring. Contract tests и boundary checks должны защищать обещания, а unit tests — локальные invariants и сложные ветви.

### Эволюционировать маленькими обратимыми шагами

Маленький coherent change легче review, rollout и rollback. Для persisted schema и public API этого недостаточно: нужен совместимый промежуточный state, иногда dual-read/dual-write и явное завершение migration. Правило «маленький diff» не отменяет системный blast radius.

Refactoring отделяют от intentional behavior change. Сначала фиксируют observable contract, затем меняют структуру и только потом удаляют compatibility layer. Для публичных Go modules требования совместимости разобраны в [[60 Go/Пакеты, модули и направление зависимостей|заметке о packages и modules]].

## Пример или трассировка

Сценарий: нужно добавить правило «VIP-заказ не получает promotional discount при просроченной оплате».

В первом дизайне discount вычисляется в HTTP handler, background invoice job и SQL report. Все три читают общую таблицу и по-разному трактуют `status`. Изменение требует трёх реализаций, согласованного deploy и проверки несвязанных paths. Один consumer забыли: отчёт продолжает показывать старую сумму. Симптом — business invariant зависит от entry point.

После локализации `DiscountPolicy` владеет предметным решением, а handler, job и report получают зафиксированный результат либо вызывают один application contract. Migration проходит так:

1. Добавить новый policy и characterization tests старых состояний.
2. Перевести один caller, сравнивая старый и новый result в shadow mode.
3. Перевести остальные callers и наблюдать mismatch counter.
4. После нулевого расхождения удалить дублирующие вычисления.

Наблюдаемый результат: новое правило меняет один owner и его tests; integrations проверяют, что callers передают payment state и используют result. Для rollback сохраняется прежний path до окончания migration. Поддерживаемость проявилась не в количестве interfaces, а в меньшем change radius и проверяемом переходе.

## Эволюция и версии

ISO/IEC 25010:2011 объединял product quality и quality-in-use models в одном документе. В ноябре 2023 года ISO выпустила вторую редакцию ISO/IEC 25010 как product quality model, а quality-in-use вынесла в ISO/IEC 25019:2023. Для практики это означает, что ссылки на «актуальный ISO 25010» нужно проверять: старая восьмихарактеристическая схема 2011 года больше не текущая редакция product quality model.

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| ISO/IEC 25010:2011 | Один стандарт описывал system/software product quality и quality in use | Редакция отозвана | Старые схемы и названия нельзя автоматически приписывать текущей редакции | [ISO/IEC 25010:2011](https://www.iso.org/standard/35733.html) |
| ISO/IEC 25010:2023 и ISO/IEC 25019:2023 | — | Product quality model и quality-in-use model опубликованы отдельно | Требования maintainability нужно связывать с текущим product quality model, а outcome использования — с отдельным quality-in-use model | [ISO/IEC 25010:2023](https://www.iso.org/standard/78176.html), [ISO/IEC 25019:2023](https://www.iso.org/standard/78177.html) |

## Trade-offs

- Abstraction локализует подтверждённую variation, но каждый новый layer создаёт contract, navigation и debugging cost. [[50 Проектирование систем/Extensibility без преждевременной абстракции|Extensibility]] должна следовать реальному change scenario.
- Duplication сохраняет различия видимыми и иногда дешевле общей abstraction. Она опасна, когда копии обеспечивают один критичный invariant и уже расходятся.
- Стабильный public API защищает consumers, но compatibility layers увеличивают внутреннюю сложность. Версионная политика должна иметь migration и removal plan.
- Один module упрощает atomic refactoring; несколько modules дают независимые release contracts, но требуют versioning и cross-module compatibility tests.
- Больше observability ускоряет анализ production failure, зато увеличивает runtime cost, data governance и число поддерживаемых telemetry contracts.
- Жёсткие quality gates ловят известный класс дефектов. Если metric становится целью, команда начинает оптимизировать число, а не change safety; gate должен быть связан с конкретным риском.

## Типичные ошибки

- **Неверное предположение:** maintainability равна малому числу строк. **Симптом:** короткий generic engine управляется flags и callbacks, но никто не может локально доказать behavior. **Причина:** physical size принят за conceptual size. **Исправление:** измерять change scenario, invariants и contracts.
- **Неверное предположение:** interface автоматически снижает будущую цену. **Симптом:** один change требует обновить interface, все mocks и forwarding layers. **Причина:** volatile detail опубликован как abstraction. **Исправление:** interface у consumer, минимальный semantic contract и реальное основание для подмены.
- **Неверное предположение:** zero duplication — самостоятельная цель. **Симптом:** несвязанные cases объединены flags, а исправление одного ломает другой. **Причина:** синтаксическое сходство приняли за общий invariant. **Исправление:** терпеть небольшое duplication до появления устойчивой общей модели.
- **Неверное предположение:** высокий unit coverage гарантирует безопасное изменение. **Симптом:** tests зелёные, но rollout ломает schema или чужого consumer. **Причина:** проверена implementation, а не boundary и migration state. **Исправление:** добавить contract/integration tests и rollout observability под реальный risk.
- **Неверное предположение:** крупный cleanup можно смешать с feature. **Симптом:** review не отделяет behavior change, rollback возвращает и feature, и refactoring. **Причина:** потеряна обратимость. **Исправление:** последовательность небольших coherent changes с сохранением contract.
- **Неверное предположение:** старый code всегда нужно переписать под новый style guide. **Симптом:** огромный churn без изменения риска или поведения. **Причина:** consistency стала важнее стабильности. **Исправление:** улучшать затронутую область постепенно и отдельно от функционального diff.

## Когда применять

Формулируйте maintainability как quality requirement для ожидаемых изменений: «новый payment provider затрагивает adapter и wiring», «schema migration допускает rolling deploy N/N+1», «правило тарифа проверяется без реального PSP». Такая формулировка проверяема; «код должен быть чистым» — нет.

На review выберите один ближайший change scenario и проследите его через code, data, deployment и tests. После delivery сравните прогноз с фактом: какие файлы, contracts и команды действительно пришлось менять, где возник rework, можно ли было откатиться. Так maintainability превращается из вкусовой оценки в инженерную обратную связь.

## Источники

- [ISO/IEC 25010:2011](https://www.iso.org/standard/35733.html) — ISO/IEC, System and software quality models, edition 1, опубликовано 2011-03, статус withdrawn, проверено 2026-07-18.
- [ISO/IEC 25010:2023](https://www.iso.org/standard/78176.html) — ISO/IEC, Product quality model, edition 2, опубликовано 2023-11, проверено 2026-07-18.
- [ISO/IEC 25019:2023](https://www.iso.org/standard/78177.html) — ISO/IEC, Quality-in-use model, edition 1, опубликовано 2023-11, проверено 2026-07-18.
- [On the Criteria To Be Used in Decomposing Systems into Modules](https://doi.org/10.1145/361598.361623) — D. L. Parnas, Communications of the ACM, 1972, проверено 2026-07-18.
- [The Standard of Code Review](https://google.github.io/eng-practices/review/reviewer/standard.html) — Google Engineering Practices, официальный стандарт code health и continuous improvement, проверено 2026-07-18.
- [What to look for in a code review](https://google.github.io/eng-practices/review/reviewer/looking-for.html) — Google Engineering Practices, design, complexity, tests, naming и comments, проверено 2026-07-18.
- [Go Style Guide](https://google.github.io/styleguide/go/guide) — Google, нормативные принципы clarity, simplicity и maintainability для Go, проверено 2026-07-18.
- [Keeping Your Modules Compatible](https://go.dev/blog/module-compatibility) — The Go Project, публикация 2020-07-07, проверено 2026-07-18.
