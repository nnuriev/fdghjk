---
aliases:
  - "Теоретический вопрос: Multi-region architecture"
tags:
  - область/распределённые-системы
  - тема/мультирегиональность
  - архитектура/размещение
  - тип/вопрос
статус: проверено
---

# Multi-region architecture

## Вопрос

Как работает «Multi-region architecture»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

**Multi-region architecture** размещает части системы в независимых географических failure domains ради меньшей пользовательской latency, доступности при потере региона, data locality или disaster recovery. Копия compute в двух местах ещё не делает систему мультирегионально корректной: отдельно проектируют traffic steering, write authority, replication, межрегиональные зависимости, failover/failback, control plane и наблюдаемость.

Главный trade-off задаёт состояние. Синхронный межрегиональный commit уменьшает потерю данных и упрощает единый порядок, но платит WAN latency и может остановиться при partition. Асинхронная репликация оставляет регион автономным и быстрым, зато допускает lag, потерю последних подтверждённых writes при failover или конфликт нескольких writers. Архитектура должна привязать эти последствия к RPO/RTO и бизнес-инвариантам, а не к общему ярлыку `active-active`.

Полный разбор: [[40 Распределённые системы/Multi-region architecture|Multi-region architecture]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Uber — proximity search, single-winner acceptance, tracking и reconciliation. База: геопоиск, ingestion, state machine, линеаризуемое принятие заказа, multi-region.» — [[Авито/roadmap#4. System design|Авито/roadmap, раздел «4. System design»]].

## Источники

- [Spanner: Google’s Globally-Distributed Database](https://research.google.com/archive/spanner-osdi2012.pdf) — Google, OSDI 2012, проверено 2026-07-18.
- [Highly available multi-region web application](https://learn.microsoft.com/en-us/azure/architecture/web-apps/guides/multi-region-app-service/multi-region-app-service?tabs=paired-regions) — Microsoft Azure Architecture Center, актуальная архитектура, проверено 2026-07-18.
- [Use multiple Availability Zones and AWS Regions](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/use-multiple-availability-zones-and-aws-regions.html) — Amazon Web Services, Well-Architected Reliability Pillar, проверено 2026-07-18.
- [Disaster recovery scenarios for applications](https://docs.cloud.google.com/architecture/dr-scenarios-planning-guide) — Google Cloud Architecture Center, проверено 2026-07-18.
