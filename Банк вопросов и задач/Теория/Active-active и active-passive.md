---
aliases:
  - "Теоретический вопрос: Active-active и active-passive"
tags:
  - область/распределённые-системы
  - тема/мультирегиональность
  - архитектура/отказоустойчивость
  - тип/вопрос
статус: проверено
---

# Active-active и active-passive

## Вопрос

Как работает «Active-active и active-passive»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

**Active-active** означает, что несколько площадок одновременно обслуживают production traffic. **Active-passive** — одна площадка обслуживает трафик, а standby готовится принять его после failover. Эти термины неполны без слоя: active-active stateless compute может писать в один active database primary; два read-active региона не обязательно являются multi-writer.

Active-active лучше использует capacity и может дать локальную latency, но требует маршрутизации, независимости failure domains и ясной семантики concurrent writes. Active-passive проще сохраняет единственного writer, зато standby capacity простаивает или используется ограниченно, а readiness и failover нужно постоянно проверять. Выбор делают по state model, RPO/RTO и допустимому operational complexity, а не по престижности топологии.

Полный разбор: [[40 Распределённые системы/Active-active и active-passive|Active-active и active-passive]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Spotify — playlists, stable shuffle queue и продолжение воспроизведения между устройствами. База: модель данных, state transitions, ordering, session consistency, active-active.» — [[Авито/roadmap#4. System design|Авито/roadmap, раздел «4. System design»]].

## Источники

- [How DynamoDB global tables work](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/V2globaltables_HowItWorks.html) — Amazon Web Services, Global Tables version 2019.11.21, режимы MREC и MRSC, проверено 2026-07-18.
- [Use multi-region writes in Azure Cosmos DB](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-multi-master) — Microsoft, Azure Cosmos DB, проверено 2026-07-18.
- [Highly available multi-region web application](https://learn.microsoft.com/en-us/azure/architecture/web-apps/guides/multi-region-app-service/multi-region-app-service?tabs=paired-regions) — Microsoft Azure Architecture Center, проверено 2026-07-18.
- [Disaster recovery options in the cloud](https://docs.aws.amazon.com/wellarchitected/2022-03-31/framework/rel_planning_for_recovery_disaster_recovery.html) — Amazon Web Services, Well-Architected Framework, редакция 2022-03-31, проверено 2026-07-18.
