---
aliases:
  - Wide-column database
  - Column-family store
  - Ширококолоночное хранилище
tags:
  - область/данные
  - тема/выбор-хранилища
статус: проверено
---

# Wide-column store

## TL;DR

Wide-column store моделирует таблицу вокруг заранее известного запроса. Partition key выбирает узел и локальную partition, clustering columns задают порядок строк внутри неё. Поэтому lookup по полной partition key и range scan по clustering order быстры и предсказуемы, а join или фильтр без подходящего access path либо запрещён, либо превращается в дорогой scatter/gather.

Это не columnar OLAP: «wide-column» описывает sparse, partitioned row model, а не хранение каждого столбца отдельным аналитическим файлом. Apache Cassandra сочетает такую модель с Dynamo-подобным распределением и LSM storage engine.

## Область применимости

Заметка опирается на Apache Cassandra 5.0.8 и CQL. Ветка 5.0 ввела BTI SSTable format и Unified Compaction Strategy; конкретные defaults и рекомендации меняются между версиями. Общая mental model применима к Bigtable-подобным системам, но их transactions, consistency и secondary indexes нужно проверять отдельно.

Cassandra и `cqlsh` в локальной среде отсутствуют. DDL ниже не исполнялся; синтаксис primary key и clustering order сверены с документацией Cassandra 5.0.8.

## Ментальная модель

Таблица Cassandra — материализованный ответ на один access pattern. Вы сначала записываете запрос словами, затем выбираете partition key, которая локализует его, и clustering order, который позволяет прочитать нужный диапазон последовательно.

SQL обычно спрашивает: «какие relations описывают факты?» Wide-column design спрашивает: «какой query должен укладываться в одну bounded partition?» Поэтому одна business entity закономерно дублируется в нескольких query tables.

## Как устроено

### Partition key

Первая часть CQL primary key хешируется partitioner-ом и определяет ownership данных в cluster. Все rows одной partition лежат вместе с точки зрения распределения. Хороший key одновременно:

- равномерно распределяет traffic и bytes;
- позволяет одному запросу назвать partition без cluster scan;
- ограничивает рост partition во времени.

Key `tenant_id` может быть слишком широким для крупного tenant. Key `(tenant_id, day)` добавляет time bucket и делает размер предсказуемее, но запрос за месяц читает до 31 partitions.

### Clustering columns

Оставшиеся компоненты primary key сортируют rows внутри partition. Условие equality по предыдущим clustering columns и range по следующей совпадает с физическим порядком; произвольный фильтр по позднему полю уже не имеет того же cost. Query shape встроен в schema.

### Денормализованные query tables

Cassandra не поддерживает реляционные joins и foreign keys. Для двух access patterns обычно создают две tables и записывают нужные поля в обе. Это ускоряет reads, но делает fan-out write и восстановление расхождений частью приложения. Batch не следует воспринимать как общий способ сделать распределённую операцию дешёвой: сначала проверяют partition и atomicity semantics конкретной версии.

### Write и read path

Mutation попадает в commit log и memtable, затем flush создаёт immutable SSTable. Read собирает версии из memtable и подходящих SSTables, используя indexes и Bloom filters, а [[30 Данные/Compaction в LSM-хранилищах|compaction]] позднее объединяет файлы и очищает устаревшие версии/tombstones. Такая [[30 Данные/LSM-tree|LSM-модель]] поддерживает высокий sequential write throughput ценой background I/O и возможного read amplification.

## Сквозной пример

Нужен запрос: «события устройства за один день, начиная с timestamp, от новых к старым».

```sql
CREATE TABLE events_by_device_day (
    device_id text,
    day date,
    ts timestamp,
    event_id timeuuid,
    kind text,
    payload text,
    PRIMARY KEY ((device_id, day), ts, event_id)
) WITH CLUSTERING ORDER BY (ts DESC, event_id DESC);
```

Запрос на `device_id='sensor-7'` и `day='2026-07-18'` маршрутизируется в одну partition; range по `ts` идёт по её clustering order. `event_id` разрывает одинаковые timestamps и делает row identity уникальной.

Запрос «все события kind=`overheat` по всем устройствам» эта таблица не обслуживает. Правильный ответ — отдельная table с подходящей partition strategy или поисково-аналитический индекс, а не `ALLOW FILTERING` как постоянный production design.

Наблюдаемый результат: latency первого запроса ограничена одной bounded partition. Цена — явный day bucketing и отдельный write path для второго запроса.

## Trade-offs

### Wide-column или relational

Wide-column выигрывает при огромном объёме однообразных writes, известных access paths и необходимости распределить данные по commodity nodes. SQL удобнее, когда queries меняются, relations требуют joins/constraints, а multi-row transaction важнее availability и линейного scale-out.

### Wide-column или key-value

Key-value обычно адресует одно value полным key. Wide-column добавляет ordered rows внутри partition, поэтому естественно обслуживает bounded range по clustering columns. За эту выразительность платят более строгим data modeling и сложной storage maintenance.

### Wide-column или columnar OLAP

Cassandra оптимизирует operational reads/writes по partition key. Columnar OLAP engine сканирует несколько columns по множеству rows и агрегирует в vectorized batches. Для dashboard по миллиардам событий лучше [[30 Данные/OLTP и OLAP|OLAP-контур]], даже если источник событий хранится в Cassandra.

## Типичные ошибки

- **Неверное предположение:** primary key нужен только для уникальности. **Симптом:** одна partition растёт без границы или один node перегружен. **Причина:** partition key одновременно задаёт distribution и locality. **Исправление:** проектировать его из query и capacity model, добавить bucket только с рассчитанным fan-out.
- **Неверное предположение:** любой CQL filter будет эффективен. **Симптом:** query отклоняется, читает много partitions или даёт нестабильный p99. **Причина:** условие не совпало с primary-key access path. **Исправление:** новая query table/index с осознанным cost; `ALLOW FILTERING` не считать индексом.
- **Неверное предположение:** дублированные tables обновятся сами. **Симптом:** один экран показывает новое значение, другой старое. **Причина:** fan-out writes имеют несколько failure points. **Исправление:** idempotent mutations, retry/outbox, version stamps и [[30 Данные/Data repair и reconciliation|reconciliation]].
- **Неверное предположение:** delete сразу освобождает место. **Симптом:** tombstone-heavy reads и disk usage держатся после удаления. **Причина:** immutable SSTables сохраняют старые values до безопасной compaction. **Исправление:** согласовать TTL, repair, grace и compaction strategy; наблюдать tombstones и pending compaction.

## Когда применять

Wide-column store уместен для telemetry, event timelines, counters/materialized views и других потоков, где queries известны, данные естественно bucket-ятся, а каждая операция затрагивает ограниченное число partitions. До выбора выпишите все queries, ожидаемый размер и rate каждой partition, replication/consistency level, TTL/delete policy и число fan-out writes.

Не берите его ради слова «масштабирование», если dataset помещается в одну SQL-СУБД или product постоянно добавляет новые ad hoc-запросы. Сложность проявится в schema proliferation, repair, compaction и rebalancing, даже если CQL синтаксически напоминает SQL.

## Источники

- [Data Modeling: Introduction](https://cassandra.apache.org/doc/5.0.8/cassandra/developing/data-modeling/intro.html) — Apache Cassandra, версия 5.0.8, query-driven modeling и primary key, проверено 2026-07-18.
- [Storage Engine](https://cassandra.apache.org/doc/5.0.8/cassandra/architecture/storage-engine.html) — Apache Cassandra, версия 5.0.8, commit log, memtable, SSTable и BTI, проверено 2026-07-18.
- [Dynamo](https://cassandra.apache.org/doc/5.0.8/cassandra/architecture/dynamo.html) — Apache Cassandra, версия 5.0.8, partitioning и replication model, проверено 2026-07-18.
- [Compaction overview](https://cassandra.apache.org/doc/5.0.8/cassandra/managing/operating/compaction/overview.html) — Apache Cassandra, версия 5.0.8, проверено 2026-07-18.
- [Unified Compaction Strategy](https://cassandra.apache.org/doc/5.0.8/cassandra/managing/operating/compaction/ucs.html) — Apache Cassandra, версия 5.0.8, проверено 2026-07-18.
- [Bigtable: A Distributed Storage System for Structured Data](https://research.google/pubs/bigtable-a-distributed-storage-system-for-structured-data/) — Google, OSDI 2006, проверено 2026-07-18.
