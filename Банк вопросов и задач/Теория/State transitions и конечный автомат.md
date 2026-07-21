---
aliases:
  - "Теоретический вопрос: State transitions и конечный автомат"
tags:
  - область/проектирование-систем
  - область/go
  - тема/объектное-проектирование
  - тип/вопрос
статус: черновик
---

# State transitions и конечный автомат

## Вопрос

Как раскрыть на System Design интервью тему «State transitions и конечный автомат»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

Конечный автомат (finite state machine, FSM) задаёт допустимые пары `текущее состояние + событие`, guards и атомарный результат перехода. Его ценность не в enum, а в закрытом пути изменения: caller не ставит `Paid` напрямую, а отправляет `Pay`; компонент проверяет исходное состояние и предусловия, затем меняет все связанные поля одной операцией.

Сильный контракт гарантирует: недопустимое событие не меняет state, terminal state не имеет исходящих переходов, guard проверяется до mutation, а внешний side effect не выполняется под lock или посередине незавершённого перехода.

Полный разбор: [[50 Проектирование систем/State transitions и конечный автомат|State transitions и конечный автомат]].

Канонический разбор пока имеет статус `черновик`; эта карточка сохраняет ту же степень проверенности.

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Domain model и инварианты → границы сервисов → state transitions.» — [[Telegram Собесы/VK Tech — 2025-09-12 — 350к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/VK Tech — 2025-09-12 — 350к, раздел «Минимальный маршрут по vault»]].
- «Uber — proximity search, single-winner acceptance, tracking и reconciliation. База: геопоиск, ingestion, state machine, линеаризуемое принятие заказа, multi-region.» — [[Авито/roadmap#4. System design|Авито/roadmap, раздел «4. System design»]].
- «Spotify — playlists, stable shuffle queue и продолжение воспроизведения между устройствами. База: модель данных, state transitions, ordering, session consistency, active-active.» — [[Авито/roadmap#4. System design|Авито/roadmap, раздел «4. System design»]].

## Источники

- [State Machine Workflows](https://learn.microsoft.com/en-us/dotnet/framework/windows-workflow-foundation/state-machine-workflows) — Microsoft, официальная документация Windows Workflow Foundation, проверено 2026-07-18.
- [Unified Modeling Language 2.5.1](https://www.omg.org/spec/UML) — Object Management Group, UML 2.5.1, декабрь 2017, проверено 2026-07-18.
- [Tactical Domain-Driven Design](https://learn.microsoft.com/en-us/azure/architecture/microservices/model/tactical-domain-driven-design) — Microsoft, Azure Architecture Center, проверено 2026-07-18.
- [Package sync](https://pkg.go.dev/sync@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
