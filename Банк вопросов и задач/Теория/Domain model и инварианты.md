---
aliases:
  - "Теоретический вопрос: Domain model и инварианты"
tags:
  - область/проектирование-систем
  - тема/проектирование-компонентов
  - тема/моделирование
  - тип/вопрос
статус: проверено
---

# Domain model и инварианты

## Вопрос

Как раскрыть на System Design интервью тему «Domain model и инварианты»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

Domain model — намеренно ограниченная система понятий, состояний и операций, с помощью которой программа решает задачи предметной области. Это не копия таблиц, JSON-схемы или объектов реального мира: модель оставляет только различия, влияющие на решения внутри конкретного bounded context.

Инвариант (invariant) — утверждение, которое обязано быть истинным во всех наблюдаемых состояниях модели. Граница компонента проверяет вход и не допускает частичного перехода: успешная операция сохраняет инварианты, отклонённая не меняет состояние. Если правило охватывает конкурентные записи или несколько процессов, одного объекта в памяти недостаточно — последнюю гарантию даёт соответствующая транзакционная граница хранения.

Полный разбор: [[50 Проектирование систем/Domain model и инварианты|Domain model и инварианты]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Domain model и инварианты → границы сервисов → state transitions.» — [[Telegram Собесы/VK Tech — 2025-09-12 — 350к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/VK Tech — 2025-09-12 — 350к, раздел «Минимальный маршрут по vault»]].
- «Кандидат передал общую установку «business model должен диктовать design, а не database/framework», но не смог назвать Dependency Rule. Он перепутал два связанных, но разных понятия: ubiquitous language — общий язык внутри модели, bounded context — явная граница, внутри которой эта модель и язык имеют определённый смысл. Для подготовки подходят domain model, границы сервисов, dependency inversion и направление package dependencies.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Architecture experience, EventStorming, DDD и Clean Architecture — `00:36:08–00:40:54`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Architecture experience, EventStorming, DDD и Clean Architecture — `00:36:08–00:40:54`»]].

## Источники

- [Domain-Driven Design Reference](https://www.domainlanguage.com/wp-content/uploads/2016/05/DDD_Reference_2015-03.pdf) — Eric Evans, 2015, проверено 2026-07-18.
- [Use tactical DDD to design microservices](https://learn.microsoft.com/en-us/azure/architecture/microservices/model/tactical-domain-driven-design) — Microsoft Learn, обновлено 2026-02-26, проверено 2026-07-18.
- [Design validations in the domain model layer](https://learn.microsoft.com/en-us/dotnet/architecture/microservices/microservice-ddd-cqrs-patterns/domain-model-layer-validations) — Microsoft Learn, .NET Architecture, проверено 2026-07-18.
