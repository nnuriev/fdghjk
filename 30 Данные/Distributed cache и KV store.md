---
aliases:
  - Distributed cache
  - Distributed key-value store
  - Распределённый кэш
  - Распределённое key-value хранилище
tags:
  - область/данные
  - тема/кэширование
  - тема/распределённые-данные
статус: проверено
---

# Distributed cache и KV store

## TL;DR

Distributed cache и distributed key-value store используют похожий data path: key отображается в shard или slot, router находит replica set, операция выполняется на owner. Но failure contract разный. Cache хранит производную, вытесняемую копию: miss, expiry и потеря node нормальны, если authoritative source выдерживает восстановление. KV store может быть source of truth; тогда acknowledged write, replication, durability и consistency входят в контракт данных.

Три решения независимы: **placement** определяет owner key, **replication/consistency** — какие копии участвуют в read/write, **retention** — когда value исчезает из-за TTL или eviction. Добавление replicas не исправляет плохой shard key, consistent hashing не даёт strong consistency, а LRU не определяет freshness.

Горячий read key можно копировать и coalesce. Горячий write key с единым порядком остаётся coordination point после любого hashing. Поэтому систему проектируют по distribution реального workload, а не по среднему QPS и числу nodes.

## Область применимости

Redis Open Source 8.8.0 используется как конкретный пример slots, asynchronous replication и eviction. Dynamo SOSP 2007 даёт классическую leaderless KV-модель с partitioning, replication и reconciliation. Универсального поведения «Redis-подобного» продукта нет: перед использованием фиксируют API, acknowledgement и failover semantics конкретной версии.

## Ментальная модель

Data path можно разложить так:

```text
key
  -> logical partition / hash slot
  -> current owner epoch
  -> primary or replica set
  -> read/write protocol
  -> optional TTL / eviction lifecycle
```

Key несёт routing и часто задаёт границу атомарности. Все операции одного key легко сериализовать на одном owner. Multi-key transaction проста лишь при co-location или отдельном coordinator; одинаковые фигурные скобки в client API не отменяют network partition.

Для cache действует инвариант: любое value можно удалить, а система останется корректной, хотя станет медленнее. Для authoritative KV инвариант сильнее: после заявленного acknowledgement данные переживают оговорённый набор отказов и reads соблюдают названную consistency model. Если эти режимы смешаны в одном cluster, memory pressure может превратить «вытеснение кэша» в потерю business state.

## Как устроено

### Key, value и атомарная граница

Hash-partitioned KV API оптимизирован под точный key: `GET(k)`, `PUT(k, v)`, conditional update, increment или compare-and-set. В такой модели secondary queries, joins и range scan по логическому порядку либо отсутствуют, либо требуют отдельного индекса. Ordered KV, напротив, предоставляет range read по упорядоченному keyspace как базовую операцию, но schema обязана выразить нужный prefix/range, а contiguous hot range всё равно способен перегрузить один участок. Выбор между реляционной моделью и key-addressed access разобран в [[30 Данные/SQL или key-value|SQL или key-value]].

Key обычно включает tenant, entity type, stable ID и schema/layout version, например `price:v3:tenant7:sku42`. Namespace упрощает migration и deletion, но сам по себе не авторизует доступ. Value size ограничивают: один большой object удерживает event loop, network buffer и shard memory, а partial update часто переписывает весь value.

Atomicity по одному key не переносится автоматически на два keys. Если операция обязана одновременно проверить quota и записать reservation в разных shards, нужны co-location, транзакционный protocol или другая модель инварианта. Хэш-тег, который насильно кладёт связанные keys в один slot, сохраняет локальную атомарность ценой hotspot и меньшей свободы rebalancing.

### Sharding и routing

[[30 Данные/Consistent hashing|Consistent hashing]] размещает key на ring и уменьшает долю перемещений при изменении числа owners. Другой вариант — фиксированное множество logical slots, которые назначаются nodes. Redis Cluster 8.8.0 использует 16 384 hash slots; topology меняет owner slots, а функция `CRC16(key) mod 16384` остаётся стабильной.

Client-side router хранит slot map и идёт прямо к owner. Proxy скрывает topology и упрощает clients, но добавляет hop и собственный capacity limit. В обоих случаях routing snapshot стареет. Node должен вернуть redirect или version mismatch, client — ограниченно обновить topology и повторить безопасную операцию. Бесконечные redirects между двумя epochs означают control-plane split, а не повод продолжать retry.

Shard key выбирают по workload. Равномерный hash распределяет независимые keys, но теряет range locality. Tenant key сохраняет co-location, однако один крупный tenant перегружает replica set. Один [[30 Данные/Hot partitions и hot keys|hot key]] после любого split остаётся целым: проблему решают cache/replica reads, batching, striping коммутативных writes или честный single writer с admission control.

### Replication и consistency

Primary/replica topology сериализует writes на primary и обычно копирует их followers. Если replication asynchronous, primary может подтвердить write до применения replica. Failover в этом окне теряет acknowledged update; replica read может вернуть старое value. Redis прямо описывает replication как asynchronous по умолчанию. `WAIT` запрашивает acknowledgements replicas и снижает вероятность потери, но не превращает систему автоматически в linearizable store: failover, epochs и read protocol должны давать такую гарантию целиком.

Leaderless KV отправляет операцию нескольким replicas и ждёт `R`/`W` по выбранной policy. Quorum intersection помогает лишь при точных предпосылках о membership, versions и repair; они разобраны в [[30 Данные/Read и write quorums|read и write quorums]]. Concurrent versions требуют detection и reconciliation, как в [[30 Данные/Data repair и reconciliation|data repair]].

Consistency называют наблюдаемой гарантией: linearizable, eventual, read-your-writes, monotonic reads. `replication_factor=3` описывает число copies, а не то, какую версию вернёт GET. Для cache stale read часто приемлем; для permission, lock или ledger — обычно нет. Различия моделей собраны в [[40 Распределённые системы/Strong, eventual, causal и session consistency|strong, eventual, causal и session consistency]].

### Rebalancing и topology epochs

При добавлении node ownership переносится по фазам: выбрать slots/ranges, скопировать snapshot, догнать concurrent writes, опубликовать новый epoch, переключить routing, проверить replicas и только затем очистить donor. Без отдельной catch-up boundary copy уже устаревает к моменту cutover.

[[30 Данные/Rebalancing данных|Rebalancing]] использует те же CPU, network и memory bandwidth, что foreground traffic. Его ограничивают по bytes/s, parallel ranges и p99 impact. Cache допускает более простой вариант: новый owner начинает пустым, а misses постепенно прогревают его. Это дешевле migration, но может обрушить source of truth холодной волной.

Stale clients должны пережить cutover. Donor либо временно проксирует/redirects, либо отвечает topology version. Dual ownership без authority rule опасен для writes: два nodes могут принять разные значения одного key. Cutover epoch и fencing определяют единственного write owner.

### TTL, expiry и eviction

TTL задаёт lifecycle конкретного key. Eviction освобождает memory при достижении limit независимо от бизнес-срока. Redis 8.8.0 поддерживает `noeviction`, all-keys и volatile варианты LRU, LFU, LRM и random; LRU/LFU/LRM реализованы приблизительно, а не как точный глобальный порядок всех keys.

Политика выбирается по цели:

- cache с неодинаковой популярностью часто выигрывает от LRU/LFU;
- keys с обязательным TTL требуют контроля доли non-expiring data, иначе volatile-policy не найдёт кандидатов;
- authoritative store не должен молча evict business values; при memory limit он отказывает writes или масштабируется по заранее выбранному contract.

Expiry не гарантирует одновременное физическое удаление всех replicas и client caches. Он означает, что значение после deadline больше нельзя обслуживать как живое по API. Если TTL участвует в security или lock authority, одной фоновой очистки мало: проверка времени и generation нужна на read/write path.

### Cache-aside, fill и overload

При cache-aside приложение сначала читает cache. На miss оно обращается к owner database, затем записывает derived value с TTL. Read-through скрывает fill внутри cache layer; write-through синхронно обновляет cache вместе с owner path. Эти названия не решают race и consistency — нужно знать, какая система authoritative и что происходит при частичном успехе.

Cache outage способен перегрузить database сильнее обычного traffic. Поэтому origin path имеет собственный concurrency limit, single-flight по hot key, jittered TTL и stale/fallback policy. Cache не считают дополнительной гарантированной capacity: план восстановления включает cold start и массовый failover shards.

Near-cache внутри process уменьшает network latency distributed cache, но добавляет ещё одну stale copy. Invalidation fan-out и TTL должны быть частью contract. Если freshness важнее latency, локальную копию проверяют version/token или не используют.

### Наблюдаемость и безопасность

Для cache измеряют hit/miss по key class, evictions, expirations, fill latency, coalesced waiters и fallback QPS к origin. Для KV добавляются replication lag, acknowledged replicas, failover epochs, stale/repair rate, redirects, slots без owner, rebalance backlog и durability errors. В обоих режимах нужны top keys по QPS/bytes и per-shard p99: среднее скрывает hotspot.

Cluster закрывают network policy, TLS и ACL. Key namespace не заменяет tenant authorization. Dumps, slow logs и debug commands способны раскрыть values и secrets; telemetry хранит hash/redacted key там, где raw ID чувствителен. Administrative operations re-shard/flush отделяют от data clients и аудитируют.

## Пример или трассировка

Сервис цен использует cache-aside. В этом примере key `price:v3:sku42` попадает в условный slot `723`, которым при topology epoch `81` владеет primary `A` с replica `A1`.

1. Client читает key у `A`, получает miss после eviction. Это нормальный cache outcome, не отсутствие товара.
2. Один caller получает single-flight lease, читает authoritative database и записывает value `1050 RUB` с jittered TTL. Остальные callers ждут fill и затем читают ту же копию.
3. Во время rebalancing slot `723` переносится на `B`. После snapshot/catch-up control plane публикует epoch `82`; старый client ещё отправляет GET в `A`.
4. `A` отвечает redirect с новой topology. Client обновляет slot map и повторяет read у `B`. Для write такой repeat допустим только по operation contract и после однозначного отказа старого owner.
5. `B` аварийно теряет memory до полного прогрева. Replica/cache copy тоже отсутствует, поэтому запрос снова становится miss и безопасно восстанавливается из database. Origin concurrency limit не даёт тысячам misses одновременно обрушить database.

Наблюдаемый результат: eviction, reshard и потеря cache node меняют latency и origin load, но не цену товара. Если бы это был authoritative KV без другого source, шаг 5 означал бы потерю данных и требовал иного durability contract.

## Trade-offs

Client-side routing убирает proxy hop и масштабирует routing вместе с callers. Proxy упрощает topology protocol и обновление clients, но становится общей очередью. Для polyglot clients proxy часто дешевле; для высокочастотного однородного стека прямая маршрутизация уменьшает latency.

Больше replicas увеличивает read capacity и failure tolerance, но расходует memory и replication bandwidth. Synchronous acknowledgement уменьшает окно потери, увеличивая write latency и зависимость от медленной replica. Асинхронный режим быстрее, но его RPO не равен нулю.

Cache-aside прост и оставляет database authoritative, зато miss path и stampede живут в приложении. Read-through централизует fill, но cache layer должен понимать loader failures, deadlines и tenant context. Near-cache даёт минимальную latency ценой invalidation и process-local staleness.

LRU реагирует на недавний доступ, LFU удерживает часто используемые keys, random дешевле по metadata. Ни одна policy не знает business value entry. Критичные keys лучше защищать отдельным namespace/pool или не смешивать с best-effort cache.

## Типичные ошибки

### Cache становится единственной копией данных

- **Неверное предположение:** value с TTL не будет удалено раньше срока.
- **Симптом:** eviction или restart навсегда теряет business state.
- **Причина:** disposable retention contract использован как durability contract.
- **Исправление:** authoritative source либо отдельный KV mode без eviction, с проверенной persistence/replication guarantee.

### Failover cache обрушивает database

- **Неверное предположение:** miss path выдержит весь normal traffic.
- **Симптом:** после потери shard растут DB connections, p99 и timeouts каскадом.
- **Причина:** cache скрывал реальный offered load, а fill не ограничен.
- **Исправление:** bounded origin concurrency, single-flight, jitter, staged warm-up и load shedding.

### Добавление nodes лечит hot key

- **Неверное предположение:** hashing делит любой workload равномерно.
- **Симптом:** средняя memory/CPU падает, один shard по-прежнему насыщен.
- **Причина:** один logical key имеет одного owner или replica set.
- **Исправление:** cache/replica reads, coalescing, batching или изменение семантической гранулярности writes.

### Replication factor принимают за consistency

- **Неверное предположение:** три copies всегда возвращают последнюю запись.
- **Симптом:** после failover клиент видит старое value или теряет acknowledged write.
- **Причина:** acknowledgement, read target и failover protocol не определены.
- **Исправление:** назвать consistency/durability guarantee и проверить её сценариями partition/failover.

### Multi-key operation считают локальной

- **Неверное предположение:** одинаковый client API означает одну атомарную транзакцию.
- **Симптом:** один key обновлён, второй потерян при redirect или node failure.
- **Причина:** keys находятся на разных owners без coordinator.
- **Исправление:** co-location, explicit transaction protocol, idempotent workflow или переразбиение инварианта.

### Rebalance запускают без epoch и throttling

- **Неверное предположение:** copy и немедленное удаление donor достаточно.
- **Симптом:** stale clients пишут двум owners, а p99 растёт из-за background transfer.
- **Причина:** не разделены catch-up, authority cutover и cleanup.
- **Исправление:** versioned topology, single write owner, resumable phases и feedback-based limits.

## Когда применять

Distributed cache нужен, когда process-local memory мала или плохо переиспользуется между replicas, а повторный read/compute дорог. Он оправдан, если miss path корректен, origin выдерживает оговорённую cold-cache нагрузку и staleness имеет предел.

Distributed KV выбирают для точного key access, предсказуемой атомарности по key и горизонтального partitioning. До выбора продукта зафиксируйте key distribution, value size, multi-key needs, replication acknowledgement, consistency, durability, TTL/eviction, failover и rebalancing. Если workload требует ad hoc joins, много secondary predicates и multi-row invariants, реляционная модель часто дешевле и надёжнее.

## Источники

- [Redis Open Source 8.8 release notes](https://redis.io/docs/latest/operate/oss_and_stack/stack-with-enterprise/release-notes/redisce/redisos-8.8-release-notes/) — Redis, версия 8.8.0 от мая 2026 года, проверено 2026-07-18.
- [Scale with Redis Cluster](https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/) — Redis, Redis Open Source 8.8.0, проверено 2026-07-18.
- [Redis cluster specification](https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/) — Redis, спецификация синхронизирована с Redis Open Source 8.8.0, проверено 2026-07-18.
- [Redis replication](https://redis.io/docs/latest/operate/oss_and_stack/management/replication/) — Redis, Redis Open Source 8.8.0, проверено 2026-07-18.
- [Key eviction](https://redis.io/docs/latest/develop/reference/eviction/) — Redis, Redis Open Source 8.8.0, проверено 2026-07-18.
- [Dynamo: Amazon’s Highly Available Key-value Store](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf) — Amazon, SOSP 2007, проверено 2026-07-18.
- [Consistent Hashing and Random Trees](https://doi.org/10.1145/258533.258660) — ACM, Proceedings of STOC 1997, проверено 2026-07-18.
- [Features](https://apple.github.io/foundationdb/features.html) — FoundationDB project, FoundationDB 7.3.77, ordered keyspace и range reads, проверено 2026-07-18.
