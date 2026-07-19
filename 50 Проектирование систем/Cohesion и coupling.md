---
aliases:
  - Cohesion and coupling
  - Связность и зацепление
tags:
  - область/проектирование-систем
  - тема/проектирование-компонентов
статус: проверено
---

# Cohesion и coupling

## TL;DR

Cohesion показывает, образуют ли элементы компонента одну связную ответственность и меняются ли по одной предметной причине. Coupling показывает, сколько знаний и согласованных изменений пересекает границу. Цель — не максимизировать один числовой показатель, а локализовать ожидаемые изменения: правило меняется в одном понятном месте, а соседние компоненты продолжают работать по устойчивому контракту.

Interface уменьшает только часть compile-time coupling. Общая схема данных, порядок вызовов, shared mutable state, error semantics и lifecycle всё ещё связывают стороны. Поэтому границу проверяют сценариями изменений и отказов, а не количеством imports или methods.

## Ментальная модель

Компонент — change firewall. Внутри него находятся решения, которые нужно понимать и изменять вместе; наружу выходит минимальный контракт, позволяющий остальным рассуждать независимо.

У cohesion и coupling один практический тест: **что обязано измениться одновременно?**

- Высокая cohesion: новая pricing rule затрагивает pricing model и её tests, потому что они вместе обеспечивают один набор инвариантов.
- Низкая cohesion: тот же package одновременно знает VAT, SQL migrations, HTTP rendering и SMTP retries; у его частей нет общей причины меняться.
- Низкий coupling: замена SMTP provider требует изменить adapter и wiring, но не order policy.
- Высокий coupling: изменение поля чужой таблицы заставляет менять domain logic, handler и consumer, потому что все используют одну representation.

Coupling неизбежен: сотрудничающие компоненты должны разделять хотя бы смысл контракта. Полезен не нулевой, а **явный и узкий coupling к стабильному понятию**. Опасен coupling к volatile detail или скрытому protocol.

## Как устроено

### Измерять распространением изменений

Parnas предложил декомпозировать систему вокруг решений, которые вероятнее всего изменятся, и скрывать каждое такое решение за module boundary. Практический review начинается не с диаграммы типов, а с нескольких change scenarios:

1. Где изменится правило расчёта?
2. Что потребуется при замене storage или внешнего provider?
3. Какие части должны выпускаться атомарно?
4. Может ли один component быть понят и протестирован без private knowledge другого?

Если простой предметный change проходит через много технически несвязанных packages, coupling высок. Если один package приходится менять по нескольким независимым причинам, cohesion низка.

### Различать виды coupling

- **Source coupling:** imports, concrete types, shared constants и generated code.
- **Representation coupling:** общий mutable struct, table layout или transport DTO используется как внутренняя модель нескольких компонентов.
- **Behavioral coupling:** caller полагается на undocumented ordering, defaults или error text.
- **Temporal coupling:** методы нужно вызвать в скрытом порядке — `Init`, затем `Start`, затем `Use`, — иначе объект ломается.
- **Resource coupling:** стороны не договорились, кто закрывает stream, goroutine или connection.

Небольшой interface способен убрать concrete import, но оставляет остальные виды. Event bus убирает прямой вызов, однако добавляет schema, delivery, ordering и operational coupling. Поэтому «мы связаны только событиями» не означает независимость.

### Группировать по invariant и языку области

Package должен владеть связным набором понятий и правил. Граница вокруг [[50 Проектирование систем/Domain model и инварианты|domain invariant]] сильнее границы «все DTO здесь» или «все interfaces здесь»: она объясняет, почему элементы должны меняться вместе. Название package входит в язык системы и должно сообщать эту ответственность.

Технические adapters отделяются, когда их изменения ортогональны предметной policy. Orchestration размещается выше: он знает последовательность collaborators, но не переносит их private details в domain package. В Go acyclic import graph принуждает сделать это направление явным; способы разрыва cycles через ownership разобраны в [[60 Go/Пакеты, модули и направление зависимостей|пакетах и направлении зависимостей]].

### Не путать размер с качеством границы

Package на одну type declaration часто снижает cohesion системы: единое понятие дробится, а число cross-package contracts растёт. Большой package тоже допустим, пока он рассказывает одну связную историю и его части меняются вместе. Граница нуждается в пересмотре, когда change history показывает независимые кластеры или когда разные owners постоянно координируют несвязанные изменения.

## Пример или трассировка

Исходный package `orders` содержит:

- расчёт line total и скидки;
- SQL queries и mapping rows;
- HTTP response fields;
- отправку email через конкретный SDK.

Изменение VAT требует поправить calculation, handler и SQL projection, потому что total хранится и передаётся в нескольких независимо изменяемых representations. Замена email provider также затрагивает `orders`, хотя предметное правило заказа не менялось. Package имеет много причин изменения и тянет details нескольких технологий.

После пересмотра границ:

1. Domain package `order` владеет `Money`, `Line`, pricing rule и инвариантом total.
2. Application component `checkout` оркестрирует repository и notifier через минимальные contracts в терминах order.
3. PostgreSQL adapter переводит rows в domain values; HTTP adapter переводит request/response; email adapter переводит domain notification в provider SDK.
4. Wiring выбирает concrete adapters вне domain package.

Наблюдаемый результат по change scenarios:

- новая VAT rule меняет `order` и его tests;
- смена email provider меняет email adapter и wiring;
- новый HTTP field меняет transport adapter;
- изменение самого checkout workflow ожидаемо затрагивает application component и его contracts.

Coupling не исчез: `checkout` по-прежнему знает смысл `Order` и результата notification. Но технологические изменения больше не распространяются через предметную policy, а domain change не требует синхронно менять каждую representation.

## Trade-offs

- **Разделить или оставить вместе.** Split полезен, когда части имеют разные invariants, owners или оси изменения. Merge лучше, когда граница создаёт forwarding, conversion и versioning, но не даёт независимого reasoning.
- **Concrete dependency или interface.** Concrete type честнее и проще для стабильного local collaborator. Interface окупается при реальной подмене или когда consumer должен ограничить знание; преждевременный interface лишь переносит coupling в новый файл.
- **Прямой вызов или событие.** Call даёт явный flow, типизированный result и простой failure propagation. Event позволяет независимое время обработки, но добавляет delivery, ordering, schema evolution и recovery.
- **Общая модель или перевод на границе.** Shared type уменьшает mapping и полезен внутри одного ownership boundary. Между независимо развиваемыми contexts translation защищает semantics ценой дополнительного кода.

## Типичные ошибки

- **Неверное предположение:** package-per-type автоматически повышает cohesion. **Симптом:** один use case прыгает через множество packages и interfaces. **Причина:** единый domain concept разрезан по синтаксическим элементам. **Исправление:** группировать types и behavior вокруг совместного invariant и change reason.
- **Неверное предположение:** `common` или `utils` снижает дублирование без цены. **Симптом:** package импортирует почти вся система, а его изменение имеет большой blast radius. **Причина:** несвязанные понятия получили общий dependency hub. **Исправление:** вернуть поведение владельцу либо выделить узкую устойчивую capability с предметным именем.
- **Неверное предположение:** interface устраняет coupling. **Симптом:** implementations компилируются, но расходятся в ordering, errors или lifecycle. **Причина:** method shape отделён, semantic protocol остался неявным. **Исправление:** уменьшить контракт и зафиксировать behavioral, temporal и ownership guarantees.
- **Неверное предположение:** event-driven означает loosely coupled. **Симптом:** изменение event требует lockstep rollout consumers, а сбой ordering ломает их state. **Причина:** direct call заменён скрытым schema и delivery coupling. **Исправление:** versioned event contract, явные delivery/ordering guarantees и проверка, действительно ли async boundary нужна.
- **Неверное предположение:** низкий coupling важнее предметной целостности. **Симптом:** один invariant обеспечивают несколько services или packages без единой atomic authority. **Причина:** совместное правило разрезали ради формальной независимости. **Исправление:** сначала сохранить consistency boundary, затем уменьшать coupling вокруг неё.

## Когда применять

Проверяйте cohesion и coupling при выделении package/component, росте `common`, появлении import cycle, повторяющихся lockstep changes и перед извлечением service. Используйте реальные changes из roadmap и history: они надёжнее абстрактного подсчёта classes.

Граница хороша, если команда может назвать её invariant, public contract, причины изменения и зависимости, а затем предсказать blast radius нового сценария. Если ответ сводится к «так принято раскладывать файлы», decomposition ещё не объяснена.

## Источники

- [On the Criteria To Be Used in Decomposing Systems into Modules](https://doi.org/10.1145/361598.361623) — D. L. Parnas, Communications of the ACM, 1972, проверено 2026-07-18.
- [Domain-Driven Design Reference: Modules, Aggregates and Conceptual Contours](https://www.domainlanguage.com/wp-content/uploads/2016/05/DDD_Reference_2015-03.pdf) — Eric Evans, 2015, проверено 2026-07-18.
- [Developing and publishing modules: Design and development](https://go.dev/doc/modules/developing) — The Go Project, документация Go modules, проверено 2026-07-18.
- [Use domain analysis to model microservices](https://learn.microsoft.com/en-us/azure/architecture/microservices/model/domain-analysis) — Microsoft Learn, обновлено 2026-02-25, проверено 2026-07-18.
