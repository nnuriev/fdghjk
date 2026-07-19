---
aliases:
  - hot partitions
  - hot keys
  - горячие партиции и ключи
tags:
  - область/данные
  - тема/распределённые-данные
  - механизм/hot-keys
статус: проверено
---

# Hot partitions и hot keys

## TL;DR

Hot partition — shard/tablet/replica group, чей суммарный workload превысил локальную ёмкость. Hot key — одно логическое значение, на которое приходится непропорциональная доля обращений. Это не синонимы: горячую partition из множества независимых ключей можно split/move, а один key после любого range split всё равно попадает одному owner.

Сначала локализуют дефицит по ключу и операции: bytes, read QPS, write QPS, CPU, lock contention, network или compaction. Затем исправляют причину. Для hot partition помогают границы и placement; для hot read key — cache, replication и request coalescing; для hot write key обычно приходится менять семантическую гранулярность, агрегировать записи или принять сериализацию.

## Область применимости и версии

Заметка относится к horizontally partitioned storage. Поведение range tablets опирается на Bigtable OSDI 2006, а placement Cassandra — на Apache Cassandra 5.0.8; проверено 2026-07-18. Конкретные лимиты размера partition, split policy и способность обслуживать replica reads зависят от продукта и consistency level, поэтому числовых «универсальных порогов» здесь нет.

## Ментальная модель

Равномерная средняя загрузка кластера ничего не говорит о самом нагруженном owner. Для partition `p` полезно мыслить бюджетом:

```text
load(p) = sum(load(key_i)) + maintenance(p)
headroom(p) = capacity(owner(p)) - load(p)
```

Hot partition возникает, когда сумма по многим ключам или один член суммы съедает headroom. Во втором случае partition hot **из-за hot key**, но лечение split не меняет член `load(key_hot)`.

Ключевой диагностический вопрос: если разделить текущий range ровно пополам, разойдётся ли нагрузка по двум owners? Если да, проблема в агрегации независимых ключей или границе. Если обе половины почти пусты, а один логический ключ остаётся горячим, нужна прикладная декомпозиция или другой read/write path.

## Как устроено

### Откуда берётся hot partition

- **Монотонный range key.** При partitioning по времени или последовательному ID все новые записи идут в последний range. Старая история холодна, крайний tablet принимает весь write stream.
- **Skew значения.** `tenant_id` хорошо co-locates транзакции, пока один tenant не создаёт половину workload.
- **Низкая кардинальность.** Разбиение по `country` или `status` создаёт несколько очень разных по размеру buckets.
- **Слишком крупная единица.** Один shard содержит много независимых keys, но система не умеет или не успевает split/move.
- **Фоновая работа.** Compaction, repair или backfill делает partition горячей даже без роста пользовательского QPS.

Bigtable хранит строки в сортированном порядке и динамически делит tablets по диапазонам row key. Это помогает, когда heat распределён между несколькими rows: после split halves можно назначить разным tablet servers. Но row — единица атомарности и адресации; один чрезмерно популярный row не превращается в два только от tablet split.

В Cassandra 5.0.8 partition key хешируется в token, а все строки одной partition размещаются в одном replica set. Дополнительные узлы распределяют другие tokens, но не делят один partition key. Clustering columns меняют устройство строк внутри partition, а не её owner.

### Hot key: чтение и запись требуют разных решений

**Hot read key** можно размножить без изменения значения: in-process/distributed cache, CDN для объектов, follower/replica reads при допустимой свежести. Request coalescing объединяет сотни одновременных cache misses в один backend read; jittered TTL не даёт копиям истечь одновременно. Цена — invalidation, staleness и риск cache stampede.

**Hot write key** сложнее. Если все изменения должны образовывать один строгий порядок — например, остаток с запретом ухода ниже нуля, — одна coordination point является следствием инварианта, а не недостатком hash function. Варианты зависят от семантики:

- batch/combining собирает несколько commutative increments в одну запись;
- striping создаёт `counter#0..k-1`, а чтение суммирует stripes, если допустимы eventual aggregation и более слабая атомарность;
- reservation/escrow заранее распределяет части лимита между owners, сохраняя глобальную границу по отдельному протоколу;
- single writer с admission control честно ограничивает поток, если операция неразложима;
- append-only events убирают update contention, но чтению нужен materialized aggregate.

Реплики могут масштабировать чтение, но не произвольно параллелят конфликтующие записи: их всё равно надо упорядочить или согласовать.

### Salting и составной ключ

Salting добавляет распределяющий компонент, например `tenant_id#bucket` или `timestamp_bucket#hash(entity_id)`. Он превращает один физический range в несколько partitions. Это работает только если приложение умеет:

1. выбрать bucket при записи без конфликта;
2. найти нужные buckets при чтении;
3. объединить результат;
4. жить без прежней атомарности всей группы либо реализовать её отдельно.

Случайная соль равномернее пишет, но point lookup без сохранённого bucket превращается в fan-out. Time bucket ограничивает размер и хорошо подходит временным рядам, но текущий bucket всё ещё может быть горячим. Число buckets — часть layout: его изменение требует [[30 Данные/Online backfill|migration/backfill]] или чтения нескольких поколений ключей.

### Диагностика до лечения

Нужны распределения, а не averages:

- top partitions и top keys по QPS/bytes/CPU/latency;
- read/write split и размер одной операции;
- cache hit ratio и concurrent misses для конкретного ключа;
- throttling, queue time, locks, compaction/repair backlog на owners;
- доля одного tenant/key и прогноз после hypothetical split;
- replica skew по zones и сетевые hops.

Если telemetry агрегирована только по узлу, несколько горячих keys выглядят как «медленный сервер», и перенос всего shard лишь перемещает проблему.

## Пример или трассировка

Replica group `S0` выдерживает `10 000` операций/с, а текущая partition получает `12 000`.

### Горячая partition из множества ключей

`9 000` операций распределены примерно поровну между ключами диапазона `a..m`, ещё `3 000` — между `n..z`.

1. Система делит range на `a..m` и `n..z`.
2. Вторую половину перемещает на `S1`.
3. После cutover `S0` обслуживает около `9 000`, `S1` — около `3 000` операций/с.

Наблюдаемый результат: оба owner ниже локального лимита. Split помог, потому что нагрузка принадлежала разным keys.

### Горяч один key

Теперь `key=celebrity` создаёт `9 000` операций, а все остальные вместе — `3 000`.

1. Range делят по границе рядом с `celebrity`.
2. Этот key целиком оказывается в одной половине.
3. Её owner по-прежнему принимает не меньше `9 000` операций/с; следующий split повторяет картину.

Наблюдаемый результат: перемещение может освободить соседние keys, но не делит потолок hot key. Для `9 000` reads помогает cache/replica serving. Для `9 000` non-commutative writes нужен batching, другая модель состояния или capacity одной coordination point.

## Trade-offs

| Приём | Что снимает | Новая цена |
|---|---|---|
| Split/move range | Heat многих независимых keys | Rebalance traffic, не лечит один key |
| Hash/salting | Последовательный или tenant skew | Fan-out, потеря range locality и атомарности |
| Cache/replica reads | Hot reads | Staleness, invalidation, stampede |
| Request coalescing | Одновременные одинаковые reads | Один медленный fill задерживает группу |
| Sharded counter | Commutative hot writes | Дороже read, eventual aggregate |
| Single writer + batching | Строгий порядок | Локальный throughput ceiling и queueing |

Автоматический adaptive splitting полезен при плавном skew многих ключей. При hot key он может создавать всё более мелкие пустые ranges, увеличивая metadata без выигрыша. Поэтому planner должен учитывать heat distribution внутри диапазона, а не только общий QPS.

## Типичные ошибки

- **Неверное предположение:** добавить узлы достаточно. **Симптом:** средняя загрузка падает, p99 одного shard не меняется. **Причина:** ключ или partition остаётся на одном replica set. **Исправление:** доказать, можно ли split workload, и менять key model или hot path.
- **Неверное предположение:** высокая кардинальность partition key исключает hotspot. **Симптом:** один tenant перегружает кластер. **Причина:** распределение частоты имеет тяжёлый хвост. **Исправление:** проектировать по top-value frequency и изолировать «китов».
- **Неверное предположение:** соль бесплатна. **Симптом:** point/range read сканирует сотни buckets, а транзакция теряет атомарность. **Причина:** routing information удалено из исходного ключа. **Исправление:** хранить bucket locator, ограничивать fan-out и явно пересмотреть invariants.
- **Неверное предположение:** cache решает hot writes. **Симптом:** backend lock/leader остаётся перегружен. **Причина:** cache копирует reads, но не упорядочивает mutations. **Исправление:** batching, commutative decomposition или admission control.
- **Неверное предположение:** hotspot всегда пользовательский. **Симптом:** QPS стабилен, а disk/latency растут. **Причина:** repair, compaction или backfill конкурирует с запросами. **Исправление:** разнести telemetry по foreground/background и throttle maintenance.

## Когда применять

Сначала нужно понять, нагрета вся partition или один key. Если heat складывается из независимых keys, выбирают split, более равномерный partition key или [[30 Данные/Rebalancing данных|rebalancing]]. Если доминирует один key, решение выбирают по его семантике: копируемые reads, коммутативные writes, декомпозируемый лимит или неизбежный единый порядок.

Перед изменением layout полезно replay/simulate реальное распределение: сколько QPS и bytes получит каждый новый bucket, как изменится fan-out и где окажется атомарная граница. После миграции проверяют top-key долю и p99 владельца; равномерная token map сама по себе успех не доказывает.

## Источники

- [Bigtable: A Distributed Storage System for Structured Data](https://research.google.com/archive/bigtable-osdi06.pdf) — Google, OSDI 2006, проверено 2026-07-18.
- [Data Definition](https://cassandra.apache.org/doc/5.0.8/cassandra/developing/cql/ddl.html) — Apache Cassandra, документация 5.0.8, проверено 2026-07-18.
- [Dynamo architecture](https://cassandra.apache.org/doc/5.0.8/cassandra/architecture/dynamo.html) — Apache Cassandra, документация 5.0.8, проверено 2026-07-18.
- [Consistent Hashing and Random Trees: Distributed Caching Protocols for Relieving Hot Spots on the World Wide Web](https://doi.org/10.1145/258533.258660) — ACM, Proceedings of STOC 1997, проверено 2026-07-18.
