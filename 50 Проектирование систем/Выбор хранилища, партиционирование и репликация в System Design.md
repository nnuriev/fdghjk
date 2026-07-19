---
aliases:
  - Выбор storage
  - Partitioning и replication в System Design
  - Storage selection
tags:
  - область/проектирование-систем
  - тема/выбор-хранилища
статус: проверено
---

# Выбор хранилища, партиционирование и репликация в System Design

## TL;DR

Storage выбирают по инвариантам, access patterns, размеру, SLO и recovery, а не по ярлыку SQL/NoSQL. Сначала определяют canonical data и границу атомарности. Затем проверяют форму ключей и запросов, write/read amplification, retention, rebuild и операционные навыки команды.

Partitioning отвечает, кто владеет конкретным key/range и как меняется ownership. Replication отвечает, какие копии участвуют в commit и чтении, что произойдёт при lag, partition и failover. Эти решения связаны, но решают разные задачи: три replicas одного hot partition не распределяют его write load, а sharding без replicas не даёт redundancy.

## Ментальная модель

У хранилища четыре контракта:

1. **model:** какие факты и операции оно выражает;
2. **placement:** где находится каждый факт;
3. **agreement:** какие копии подтверждают и какую версию можно читать;
4. **recovery:** как обнаружить и исправить потерю, lag, corruption и ошибочную запись.

Продукт подходит, только если все четыре контракта совпадают с требованиями. Высокий benchmark point read не компенсирует отсутствие нужной atomic conditional write.

## Выбор storage

### Инварианты и atomicity

Если операция должна атомарно проверить уникальность и изменить несколько связанных строк, естественный baseline — SQL transaction и constraints по [[30 Данные/Транзакции и ACID|ACID-контракту]]. Key-value store удобен, когда aggregate адресуется полным ключом и single-key boundary совпадает с бизнес-инвариантом. Их сравнение разобрано в [[30 Данные/SQL или key-value|SQL или key-value]].

Нельзя рассчитывать на «eventual repair» для инварианта, нарушение которого создаёт необратимый внешний эффект. Ledger, reservation и idempotency record требуют atomic decision в выбранной authority. Derived index и recommendation cache обычно допускают асинхронную сверку.

### Access patterns

Составьте таблицу операций: key/predicate, cardinality, sort/range, expected rows, frequency, consistency и mutation rate. Хранилище обязано поддержать критичный путь без непредсказуемого full scan или глобального fan-out.

- [[30 Данные/Document store|Document store]] удобен для aggregate с меняющимся вложенным payload, если cross-document invariants ограничены.
- [[30 Данные/Wide-column store|Wide-column store]] обслуживает заранее известные partition/range queries и высокий распределённый write throughput; новую форму чтения приходится материализовать.
- [[30 Данные/Time-series database|Time-series database]] оптимизирует append, time-range scans, retention и downsampling.
- [[30 Данные/Object и blob storage|Object storage]] хранит крупные immutable bytes отдельно от metadata/transactions.
- [[30 Данные/Search index|Search index]] строит derived inverted/vector structures, но обычно не становится authority бизнес-состояния.
- [[30 Данные/OLTP и OLAP|OLTP и OLAP]] разделяют короткие конкурентные transactions и сканы больших исторических наборов.

Несколько хранилищ оправданы разными workload, но увеличивают число контрактов, migrations, backups и on-call playbooks. Начальный default — минимальный набор технологий, который выдерживает SLO.

### Durability и write path

Уточните, когда write acknowledged: после process memory, local WAL, zone quorum или remote region. [[30 Данные/Durability и fsync|Локальная durability]] и replication ack должны совпасть с RPO. Backup остаётся отдельным слоем: он защищает от логического удаления и массового corruption, которые replicas способны послушно размножить.

## Partitioning

Partition key должен одновременно:

- маршрутизировать частые операции без scatter-gather;
- распределять storage и throughput;
- удерживать нужную atomicity/order в одной boundary;
- допускать split, move и rebalancing;
- не создавать unbounded partition.

Hash partitioning обычно выравнивает много независимых keys, но усложняет range scan. Range partitioning делает диапазоны локальными, зато sequential key создаёт горячий край. Composite key часто добавляет time bucket или salt, но заставляет read path знать несколько buckets.

[[30 Данные/Hot partitions и hot keys|Hot key]] не исчезает от consistent hashing: один логический owner по-прежнему получает его writes. Возможные решения различаются по semantics: cache/fan-out replicas помогают reads, key splitting помогает associative counters, а strict ordered writes иногда требуют выделенного leader и admission limit.

Rebalancing — пользовательский workload. Перед move нужны extra network, disk и CPU headroom, throttling и контроль изменения ownership. Protocol обязан не потерять write между старым и новым owner; варианты включают epoch/fencing, handoff log и временный dual routing.

## Replication

Leader/follower упрощает единый порядок writes, но failover требует определить, какие writes committed и как fence-ить старого leader. Multi-leader повышает local write availability, зато конфликты становятся частью data model. Leaderless quorum даёт tunable read/write coordination, но `R + W > N` само по себе не гарантирует linearizability при sloppy quorum, concurrent writes и repair.

Полные модели описаны в [[30 Данные/Репликация данных|репликации]], [[30 Данные/Read и write quorums|quorums]] и [[40 Распределённые системы/Multi-leader replication|multi-leader replication]]. На System Design схеме нужно назвать:

- replica placement по failure domains;
- synchronous/async path и ack count;
- read source и session guarantees;
- lag bound и stale behavior;
- election/failover/fencing;
- repair, backup, failback и RPO/RTO.

Read replicas масштабируют reads, только если workload допускает lag и bottleneck не находится в primary write, WAL bandwidth или hot rows. Синхронная replica снижает RPO, но добавляет самый медленный обязательный round trip в write latency.

## Сквозной пример: история сообщений

Требования: сообщения append-only, порядок нужен внутри conversation, история читается страницами назад по времени, 200 тыс. writes/s global, участник должен видеть своё acknowledged сообщение сразу. Global order не нужен.

Модель:

```text
messages(
  conversation_id,
  bucket,
  sequence,
  message_id,
  sender_id,
  payload_ref,
  created_at
)
```

Partition key `(conversation_id, bucket)` удерживает локальный ordered range, bucket ограничивает размер partition. Conversation sequencer/leader назначает `sequence`; обычные rooms распределяются, celebrity room получает отдельную capacity и rate policy. Большие attachments уходят в object storage, а row хранит immutable reference/checksum.

Write acknowledged после quorum в домашнем регионе. Session token с `sequence` не позволяет read path автора обратиться к replica, которая ещё не применила write. Асинхронная cross-region replication снижает latency, но задаёт ненулевой regional RPO; если требование меняется на RPO = 0, нужен synchronous remote quorum либо промежуточный статус до global commit.

Search index строится из durable log. Его lag не блокирует message acceptance, измеряется freshness SLI и лечится replay. Это derived store, поэтому backup canonical messages важнее snapshot индекса.

## Trade-offs

SQL сохраняет гибкость запросов и invariants, пока один cluster выдерживает workload. Ранний application sharding переносит joins, transactions, migrations и rebalancing в код. Wide-column/KV выигрывает при зрелых key-based paths и большом распределённом throughput, но новая выборка требует новой projection.

Hash partitioning лучше балансирует произвольные keys; range partitioning сохраняет locality. Replication factor повышает redundancy и read capacity, но умножает storage/write traffic. Erasure coding экономит холодное storage, зато read/repair сложнее и дороже по CPU/network.

Managed storage сокращает operational toil и ускоряет старт, но вводит quotas, pricing и exit cost. Self-managed cluster даёт контроль topology, однако команда становится владельцем upgrades, backups, repair и инцидентов.

## Типичные ошибки

- **Неверное предположение:** NoSQL автоматически масштабируется. **Симптом:** один partition перегружен при свободном cluster. **Причина:** плохой key или skew. **Исправление:** моделировать top keys, buckets и split до выбора продукта.
- **Неверное предположение:** replication равна backup. **Симптом:** ошибочное удаление исчезает на всех replicas. **Причина:** replicated state не имеет независимой history. **Исправление:** isolated versioned backups и restore tests.
- **Неверное предположение:** read replica всегда безопасна. **Симптом:** клиент не видит только что созданный объект. **Причина:** replica lag нарушил session guarantee. **Исправление:** version fence, primary/session routing или bounded-staleness contract.
- **Неверное предположение:** sharding нужен при первом прогнозе роста. **Симптом:** обычная transaction превращается в workflow задолго до capacity limit. **Причина:** оптимизация воображаемого bottleneck. **Исправление:** зафиксировать trigger и подготовить shard-friendly IDs/schema без раннего split.
- **Неверное предположение:** derived index можно обновить best effort. **Симптом:** пропущенная запись остаётся невидимой навсегда. **Причина:** отсутствуют replay position и reconciliation. **Исправление:** durable change stream, idempotent projection и rebuild.

## Когда применять

Decision table заполняют после API/data model и capacity estimates. В design review выбор считается завершённым, когда можно пройти normal write/read, failover, restore, rebalancing и schema evolution, а команда понимает пределы и стоимость конкретной версии продукта.

## Источники

- [PostgreSQL 18: Concurrency Control](https://www.postgresql.org/docs/18/mvcc.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Dynamo: Amazon's Highly Available Key-value Store](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf) — Amazon, SOSP 2007, проверено 2026-07-18.
- [Apache Cassandra Architecture](https://cassandra.apache.org/doc/5.0/cassandra/architecture/overview.html) — Apache Cassandra, документация 5.0, проверено 2026-07-18.
- [The Google File System](https://research.google/pubs/the-google-file-system/) — Google, SOSP 2003, проверено 2026-07-18.
