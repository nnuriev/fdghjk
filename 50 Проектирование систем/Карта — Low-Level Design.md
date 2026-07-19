---
aliases:
  - Low-Level Design
  - Object-Oriented Design
  - LLD/OOD
tags:
  - тип/карта
  - область/проектирование-систем
  - тема/low-level-design
статус: черновик
---

# Low-Level Design / Object-Oriented Design [Core для Amazon/Microsoft, часто JD]

## Назначение

Карта подготовки к проектированию одного программного компонента: от предметной модели и публичного API до конкурентной безопасности, тестируемости и реализации типовых in-process механизмов на Go. Здесь Low-Level Design (LLD) отвечает на вопрос, какие типы, операции, состояния и зависимости делают локальный компонент корректным и изменяемым. Распределение нагрузки, репликация, durability и сетевые отказы остаются в [[50 Проектирование систем/Карта — Проектирование систем|High-Level System Design]].

Amazon относит object-oriented design к темам подготовки SDE, а на официальной странице подготовки SDE III отдельно перечисляет high-level и low-level design. Microsoft называет design, coding и testing частями технического интервью, но не использует на этой странице термины OOD или LLD. Поэтому название карты сохраняет практический приоритет из плана подготовки, не превращая его в обещание одинакового формата интервью во всех командах.

## Входные знания

- Базовая семантика Go по [[60 Go/Карта — Go|карте Go]].
- Контракты и ошибки внешнего API по [[20 Бэкенд/Карта — Бэкенд|карте бэкенда]].
- Граница между локальным компонентом и системой по [[50 Проектирование систем/Методика System Design интервью|методике System Design интервью]].

## Маршрут

- [[01 Маршруты/Backend — от основ к архитектуре|Backend — от основ к архитектуре]]

## Программа

- Domain model и invariants.
- Public API компонента.
- Structs, interfaces и composition в Go.
- Cohesion и coupling.
- Dependency inversion.
- Extensibility без преждевременной абстракции.
- Concurrency safety.
- State transitions.
- Error handling.
- Testability.
- Dependency injection без framework dependency.
- Практическое применение Strategy, Adapter, Factory, Decorator, Observer, State.
- Design и реализация cache, rate limiter, scheduler, worker pool, pub/sub, in-memory KV.
- Code review и refactoring существующего решения.

## Готовые заметки

- [[50 Проектирование систем/Domain model и инварианты]]
- [[50 Проектирование систем/Public API компонента]]
- Structs, interfaces и composition в Go: [[60 Go/Структуры, указатели и методы|structs]], [[60 Go/Интерфейсы и неявная реализация|interfaces]], [[60 Go/Embedding и composition|composition]].
- [[50 Проектирование систем/Cohesion и coupling]]
- [[50 Проектирование систем/Dependency inversion]]
- [[50 Проектирование систем/Extensibility без преждевременной абстракции]]
- Error handling: [[60 Go/Обработка ошибок]].
- [[60 Go/Worker pool, fan-in, fan-out и bounded concurrency]]
- [[50 Проектирование систем/Code review и refactoring LLD-решения в Go]]
- [[50 Проектирование систем/Code readability]]
- [[50 Проектирование систем/Maintainability]]

## План заметок

Содержание страниц ниже заполнено и сверено с первичными источниками, но их исполняемые Go-примеры не удалось запустить без локальной Go toolchain. По правилам vault они остаются черновиками до compile/test и `go test -race` там, где проверяется concurrency.

- [[50 Проектирование систем/Concurrency safety Go-компонента]]
- [[50 Проектирование систем/State transitions и конечный автомат]]
- [[50 Проектирование систем/Testability Go-компонента]]
- [[50 Проектирование систем/Dependency injection в Go без framework dependency]]
- [[50 Проектирование систем/Паттерны Strategy, Adapter, Factory, Decorator, Observer и State в Go]]
- [[50 Проектирование систем/Проектирование и реализация in-memory cache в Go]]
- [[50 Проектирование систем/Проектирование и реализация локального rate limiter в Go]]
- [[50 Проектирование систем/Проектирование и реализация in-process scheduler в Go]]
- [[50 Проектирование систем/Проектирование и реализация in-process pub-sub в Go]]
- [[50 Проектирование систем/Проектирование и реализация in-memory KV store в Go]]

## Связанные карты

- [[50 Проектирование систем/Карта — Проектирование систем|High-Level System Design]]
- [[60 Go/Карта — Go|Go]]
- [[20 Бэкенд/Карта — Бэкенд|Бэкенд]]
- [[20 Бэкенд/Карта — Testing, Debugging и Code Quality|Testing, Debugging и Code Quality]]
- [[70 Практические кейсы/Карта — Практические кейсы|Практические кейсы]]

## Источники

- [Software development interview topics](https://www.amazon.jobs/content/en/how-we-hire/interview-prep/software-development-topics) — Amazon Jobs, официальная страница подготовки SDE, проверено 2026-07-18.
- [SDE III/Sr. SDE Interview Prep](https://www.amazon.jobs/content/en/how-we-hire/sde-iii-interview-prep) — Amazon Jobs, официальная страница подготовки Senior SDE, проверено 2026-07-18.
- [Technical interviewing](https://careers.microsoft.com/v2/global/en/hiring-tips/technical-interviewing.html/) — Microsoft Careers, официальные рекомендации по техническому интервью, проверено 2026-07-18.
