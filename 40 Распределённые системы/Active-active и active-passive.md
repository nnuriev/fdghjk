---
aliases:
  - Active-active
  - Active-passive
  - Active-standby
  - Активно-активная и активно-пассивная архитектура
tags:
  - область/распределённые-системы
  - тема/мультирегиональность
  - архитектура/отказоустойчивость
статус: проверено
---

# Active-active и active-passive

## TL;DR

**Active-active** означает, что несколько площадок одновременно обслуживают production traffic. **Active-passive** — одна площадка обслуживает трафик, а standby готовится принять его после failover. Эти термины неполны без слоя: active-active stateless compute может писать в один active database primary; два read-active региона не обязательно являются multi-writer.

Active-active лучше использует capacity и может дать локальную latency, но требует маршрутизации, независимости failure domains и ясной семантики concurrent writes. Active-passive проще сохраняет единственного writer, зато standby capacity простаивает или используется ограниченно, а readiness и failover нужно постоянно проверять. Выбор делают по state model, RPO/RTO и допустимому operational complexity, а не по престижности топологии.

## Ментальная модель

Разложите систему по плоскостям:

| Слой | Active-active вариант | Active-passive вариант |
| --- | --- | --- |
| Traffic/compute | A и B принимают requests | только A, B ждёт promotion |
| Reads | обе площадки читают local replicas | B не обслуживает production |
| Writes | оба региона имеют authority либо маршрутизируют owner | один primary A |
| Control plane | независим или replicated | может активировать B |

Слово `active` описывает использование, но не гарантии данных. Ключевой вопрос: кто вправе подтвердить конкретный write во время partition?

## Как устроено

### Active-active compute с одним writer

Global routing отправляет пользователей в A и B, stateless services работают локально, но write requests идут в home/primary region. Это active-active на compute и active-passive на write path. Плюс — нет конфликтов multi-writer; минус — удалённая write latency и зависимость от primary.

Reads из local asynchronous replica уменьшают latency, но могут не видеть только что подтверждённый write. Session routing, read-your-writes token или чтение primary нужны там, где пользователь ожидает monotonic experience.

### Multi-writer active-active

Оба региона подтверждают writes автономно. Синхронный consensus/quorum может дать единый порядок, оплачивая WAN latency и availability требованиями quorum. Асинхронный [[40 Распределённые системы/Multi-leader replication|multi-leader]] оставляет local writes доступными при partition, но concurrent versions и conflict resolution становятся нормальной веткой.

AWS DynamoDB Global Tables описывает multi-Region, multi-active replicas: приложение читает и пишет regional replica, а изменения распространяются между регионами. В current version 2019.11.21 режим MREC реплицирует асинхронно и принимает RPO больше нуля, тогда как MRSC синхронно реплицирует между регионами и заявляет RPO ноль ценой большей write latency. Сам ярлык active-active не выбирает один из этих контрактов и не доказывает корректность для предметного инварианта.

### Active-passive: cold, warm, hot

Passive площадка может быть:

- **cold** — только backups/configuration, инфраструктуру создают при аварии;
- **warm** — уменьшенный работающий stack, который масштабируют и повышают;
- **hot standby** — почти полная capacity и постоянно обновляемое состояние, но production traffic не обслуживается либо обслуживается только health/checks.

Чем горячее standby, тем ниже достижимый RTO и выше постоянная стоимость. Но неиспользуемый standby склонен к configuration drift: credentials истекли, quota не поднята, schema несовместима. Read-only traffic или регулярные game days дают доказательство readiness, не превращая write authority в multi-writer.

### Promotion и fencing

Failover должен менять epoch write authority. Перед promotion B система по возможности доказывает, что A больше не пишет, или fencing на storage/lock service отклоняет старую epoch. Одного health timeout недостаточно: A может быть жив и изолирован только от monitor.

Последовательность обычно такова: объявить incident → оценить replication position/RPO → fence A → promote B → переключить routing → проверить критические journeys → reconciliation неизвестных операций. При автоматизации нужны те же invariants; скорость не заменяет корректность.

### Capacity и failure independence

В active-active каждая площадка часто работает при `N+1` capacity, чтобы оставшиеся приняли трафик после потери одной. Если A и B загружены на 70%, исчезновение A удвоит нагрузку B и вызовет каскад. Traffic shedding и деградированный режим должны быть рассчитаны заранее.

Active-passive standby тоже требует quota, data transfer bandwidth и warm caches. «100% provisioned» не означает немедленную производительность: connection pools, JIT, indexes и caches прогреваются под реальным потоком.

## Пример или трассировка

Приложение работает active-active в A и B, но database primary находится в A, replica — в B.

1. Пользователь в B читает catalog локально, а `CreateOrder` маршрутизируется в A. Значит compute active-active, write data path single-active.
2. A изолируется от B и global router, но всё ещё видит часть clients. Monitor B не должен просто повысить replica: A может продолжать подтверждать writes.
3. Coordinator отзывает storage lease/выдаёт новую fencing epoch B. Старые writes A получают отказ на общем ресурсе.
4. B повышается на известной replication position. Routing переносит traffic; retries несут прежние idempotency keys.
5. После восстановления A не становится active writer автоматически. Его пересобирают из B и возвращают как replica.

Если storage не умеет fencing, автоматический failover двух узлов при partition не может одновременно обещать availability обоих и одного writer. Нужен quorum/witness либо manual decision с операционным риском.

## Trade-offs

Active-active использует все площадки и постоянно проверяет data plane реальным трафиком. Цена — сложнее routing, capacity reserve, consistency и blast-radius control. Symmetric deployments могут одновременно получить bad release, поэтому независимый rollout всё равно нужен.

Active-passive упрощает reasoning об authority и конфликтами, подходит stateful legacy системам. Цена — оплаченный резерв, drift и обычно больший RTO. Warm standby часто практичнее крайностей: достаточно быстро восстанавливается и дешевле полного hot duplicate.

Multi-writer снижает local write latency; single-writer сохраняет простой порядок. Выбор можно делать per domain: preferences multi-writer, ledger single-writer, analytics read-active everywhere.

## Типичные ошибки

- **Неверное предположение:** active-active application означает active-active database. **Симптом:** диаграмма обещает local writes, а запросы ходят через океан к одному primary. **Причина:** слои не названы. **Исправление:** маркировать active/passive отдельно для traffic, reads, writes и control plane.
- **Неверное предположение:** passive готов, раз deployment зелёный. **Симптом:** failover упирается в quota, stale secret или медленный restore. **Причина:** standby не проверялся end-to-end. **Исправление:** регулярный traffic probe/game day и измерение фактического RTO.
- **Неверное предположение:** health timeout доказывает смерть primary. **Симптом:** оба региона принимают writes. **Причина:** partition принят за crash. **Исправление:** quorum и fencing authority до promotion.
- **Неверное предположение:** active-active не требует spare capacity. **Симптом:** surviving region падает сразу после evacuation. **Причина:** steady-state загрузка не оставила headroom. **Исправление:** N+1 capacity, priority shedding и проверка резкого traffic shift.

## Когда применять

Active-active выбирают ради local traffic, высокого utilisation или непрерывной проверки обеих площадок, когда state protocol и команда выдерживают дополнительную сложность. Active-passive подходит, если write authority должна быть единственной, failover может занять оговорённое время, а резерв регулярно тестируется.

В design doc запрещено писать только «active-active». Укажите слой, unit of routing, write owner при норме и partition, replication mode, capacity после потери площадки, promotion/fencing и failback.

## Источники

- [How DynamoDB global tables work](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/V2globaltables_HowItWorks.html) — Amazon Web Services, Global Tables version 2019.11.21, режимы MREC и MRSC, проверено 2026-07-18.
- [Use multi-region writes in Azure Cosmos DB](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-multi-master) — Microsoft, Azure Cosmos DB, проверено 2026-07-18.
- [Highly available multi-region web application](https://learn.microsoft.com/en-us/azure/architecture/web-apps/guides/multi-region-app-service/multi-region-app-service?tabs=paired-regions) — Microsoft Azure Architecture Center, проверено 2026-07-18.
- [Disaster recovery options in the cloud](https://docs.aws.amazon.com/wellarchitected/2022-03-31/framework/rel_planning_for_recovery_disaster_recovery.html) — Amazon Web Services, Well-Architected Framework, редакция 2022-03-31, проверено 2026-07-18.
