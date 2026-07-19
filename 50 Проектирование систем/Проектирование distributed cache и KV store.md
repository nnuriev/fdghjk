---
aliases:
  - Distributed cache and KV store design
  - Проектирование распределённого кэша и KV
tags:
  - тип/разбор
  - область/проектирование-систем
  - тема/хранилища
статус: проверено
---

# Проектирование distributed cache и KV store

## TL;DR

Distributed cache и authoritative key-value store похожи API, но различаются контрактом отказа. Cache вправе вытеснить значение и потерять недавнюю запись: источник истины находится ниже. Durable KV обязан сохранить подтверждённую запись и определить consistency. Поэтому платформа даёт два явных профиля и физически разные data planes: `cache` с TTL/eviction и асинхронной репликацией, `kv` с consensus group, WAL/snapshot и linearizable CAS.

Общий router, control plane и client library экономят эксплуатацию. Общий storage cluster был бы опасной экономией: пользователь легко примет cache semantics за durable guarantee. Это граница дизайна, которую нельзя прятать в одном необязательном флаге.

## Контекст и ментальная модель

Cache ускоряет чтение и снижает нагрузку на source of truth. Его correctness определяется стратегией cache-aside/write-through и поведением при miss. KV store сам хранит configuration, coordination metadata, sessions или небольшие агрегаты.

Два профиля:

| Профиль | Потеря записи | Eviction | Consistency | Типичный эффект отказа |
| --- | --- | --- | --- | --- |
| `cache` | допустима по контракту | да | eventual/primary-local | больше misses и нагрузка на source |
| `kv` | недопустима после ack | только явный TTL/delete | linearizable per key | операция блокируется без quorum |

Смысл [[40 Распределённые системы/Strong, eventual, causal и session consistency|моделей consistency]] здесь практический: read replica cache может вернуть старое значение и всё ещё выполнить контракт, а stale lease record в KV может дать двум владельцам право на один ресурс.

## Требования

### Функциональные

- `GET`, `MGET`, `PUT`, `DELETE`, TTL и conditional write;
- namespace с неизменяемым service profile `cache` либо `kv`;
- cache-aside primitives: `add-if-absent`, soft TTL, request coalescing;
- KV primitives: compare-and-swap, monotonically increasing revision, transaction в пределах shard, watch с resume token;
- quotas по keys, bytes, QPS и value size;
- online resharding, replica replacement и backup/restore для KV;
- tenant isolation, audit административных операций и encryption.

### Нефункциональные и SLO

| Характеристика | Cache | Durable KV |
| --- | --- | --- |
| Доступность | 99,99% | 99,99% для quorum-healthy shards |
| Latency в регионе | GET p99 ≤ 2 ms | linearizable GET p99 ≤ 10 ms; PUT p99 ≤ 20 ms |
| Durability | не обещается; source обязан пережить miss | RPO 0 внутри региона после quorum ack |
| Consistency | eventual, read-after-write только через primary route | linearizable per key/CAS |
| DR | cold/warm rebuild из source | RPO ≤ 1 min cross-region, RTO ≤ 15 min |

Для cache availability выше freshness: stale значение допустимо до hard TTL, если домен это разрешает. Для KV safety выше availability: minority partition не принимает writes.

### Вне scope

Полнотекстовые запросы, joins, scan всего keyspace как обычный API, значения в сотни мегабайт и cross-key serializable transaction между произвольными shards остаются вне scope.

## Оценка нагрузки и ёмкости

Интервью-допущения для cache:

- 10 млн GET/s в среднем, 25 млн/s peak, 1 млн writes/s peak;
- 2 млрд resident keys;
- средний value 512 B, key/metadata/allocator overhead принят равным 128 B;
- primary footprint: `2 000 000 000 × 640 B = 1,28 TB`;
- две copies и 50% headroom: `1,28 × 2 × 1,5 = 3,84 TB RAM`.

Для KV:

- 1 млн GET/s в среднем, 3 млн/s peak, 100 000 writes/s peak;
- 200 млн keys по 1 250 B вместе с metadata;
- primary footprint: `200 000 000 × 1 250 B = 250 GB`;
- три replicas и 50% headroom: `250 × 3 × 1,5 = 1,125 TB` без WAL/snapshots.

Memory footprint не определяет число nodes в одиночку. План берёт максимум из usable RAM при целевой occupancy, network packets/s, single-thread/shard CPU, replication traffic и recovery bandwidth. До выбора node size нужен benchmark на реальном value distribution: маленькие keys упираются в packets/CPU, большие — в network и memory bandwidth.

Hot-key сценарий обязателен: один key может получить 1 млн reads/s при низком среднем на shard. Равномерный synthetic benchmark эту проблему скрывает.

## API и модель данных

```http
PUT /v1/namespaces/profile-cache/keys/user%3A42
If-None-Match: *
X-TTL-Seconds: 300

GET /v1/namespaces/profile-cache/keys/user%3A42
```

```text
KV.Put(namespace, key, value, expected_revision?, ttl?)
  -> {revision, commit_index}
KV.Get(namespace, key, consistency=linearizable|serializable)
KV.Watch(namespace, prefix, after_revision)
Cache.GetOrLease(namespace, key, soft_ttl)
Cache.PutIfVersionAtLeast(namespace, key, value, version, refresh_lease)
Cache.InvalidateAtLeast(namespace, key, min_valid_version)
```

`MGET` гарантирует отдельный результат по каждому key, но не единый snapshot между shards. Cross-shard transaction не маскируется под batch API.

Запись cache содержит `(namespace, key, value, created_at, soft_expiry, hard_expiry, version, min_valid_version, size)`. Если value отсутствует, короткоживущий tombstone всё равно сохраняет `min_valid_version`, чтобы запоздалый fill не воскресил старую версию. Запись KV — `(namespace, key, value, revision, create_revision, lease_id?, checksum)`. Namespace metadata фиксирует profile, value limit, TTL policy, replica count и region placement. Profile нельзя поменять in-place: переход cache→KV требует новой namespace и миграции.

## Архитектура и критические потоки

```text
client library -> shard-map cache -> router/control endpoint
                    |                         |
                    |                         -> namespace catalog / placement
                    |-> cache shard primary -> async replica
                    |-> KV consensus group (leader + quorum replicas) -> WAL/snapshot
source DB <-> cache-aside caller
```

Client кэширует mapping virtual slots→nodes и следует redirect только после проверки epoch. Control plane управляет membership и rebalance, но не участвует в каждом request. Техника [[30 Данные/Consistent hashing|consistent hashing]] уменьшает объём перемещения при изменении membership, однако virtual slots удобнее для управляемого балансирования и hot-shard split.

### Cache read/write path и end-to-end trace

1. API читает `user:42`; local L1 miss, distributed cache miss.
2. `GetOrLease` атомарно выдаёт одному caller короткий refresh lease. Остальные либо ждут bounded time, либо получают stale value до hard TTL.
3. Владелец lease читает source DB и получает value с `version=917`, но задерживается до conditional put.
4. DB update коммитит version 918 и публикует invalidation через outbox. Cache consumer атомарно повышает `min_valid_version` до 918 и удаляет value с version `<918`. Tombstone сохраняется, пока не записана value с version не ниже 918 и не истекли старые fill leases; минимальный TTL покрывает максимальный fill lease и bounded window переупорядочивания invalidations.
5. Каждый fill делает conditional put: `version >= min_valid_version`. Если invalidation уже обработана, запоздалая запись version 917 отвергается, caller перечитывает source и кладёт 918. Если fill успел до invalidation, consumer позднее удаляет 917.
6. Soft TTL запускает refresh и определяет начало stale-while-revalidate, но не ограничивает staleness сам по себе. Верхнюю границу выдачи старого value задаёт hard TTL; если cache потерян, источник остаётся корректным.

Наблюдаемый результат: stampede схлопывается до одного source read, поздняя invalidation не удаляет уже более новую запись, а invalidation, пришедшая раньше fill, не позволяет воскресить старую версию.

### KV write/read path

Router направляет `PUT` leader-у consensus group. Leader добавляет запись в replicated log; ack приходит после quorum commit и применения CAS к revision. Linearizable `GET` подтверждает актуальность leader относительно quorum; serializable follower read быстрее, но может быть stale. Watch доставляет committed revisions по порядку, однако медленный consumer после compaction обязан перечитать snapshot и продолжить с новой revision.

## Масштабирование и надёжность

**Storage.** Cache использует RAM и при желании локальный restart snapshot, который не меняет guarantee. KV применяет WAL, checksums, snapshots и backup в object storage. Выбор между SQL и KV для бизнес-данных отдельно разобран в [[30 Данные/SQL или key-value|заметке о storage choice]].

**Partitioning.** Virtual slots распределяются по `hash(namespace, key)`. Ключи одного atomic transaction используют hash tag и попадают в один shard; это осознанно создаёт риск hot partition. Large tenant получает отдельные slot ranges. Размер, QPS и network учитываются независимо при placement.

**Replication.** Cache primary асинхронно обновляет replica: failover может потерять acknowledged cache write, что допустимо. KV consensus group обычно имеет нечётное число voting members; write требует quorum, поэтому minority не обслуживает изменения. Число replicas выбирается по failure domains и recovery, а не как магическая «тройка».

**Caching внутри клиента.** L1 уменьшает network, но удлиняет staleness. Namespace задаёт max L1 TTL и invalidation mode. Negative caching получает короткий TTL. Для security/permission data stale-while-revalidate обычно запрещён.

**Async processing.** Cache invalidations, access sampling, backup, snapshot, compaction и rebalance идут отдельно. При lag invalidation consumer система переключает affected namespace на более короткий TTL или bypass, а не продолжает выдавать бесконечно stale values.

**Hot keys.** Read hot key реплицируют, кэшируют в process и coalesce-ят refresh. Write hot key нельзя вылечить consistent hashing: один сериализуемый key остаётся у одного leader. Нужно изменить модель — sharded counters, batching либо более слабая consistency. Failure mode подробно связан с [[30 Данные/Hot partitions и hot keys|hot partitions]].

**Multi-region и DR.** Cache строится отдельно в каждом регионе и прогревается из source; глобальная синхронная cache invalidation редко оправдана. Durable KV имеет home region на namespace/shard. Follower region обслуживает stale reads и получает log async; promote повышает epoch и fencing. Для truly global linearizable writes latency включает межрегиональный quorum, поэтому такой режим включают только по требованию.

**Cost и ownership.** Cache платит за RAM, но экономит DB/QPS; польза измеряется avoided origin cost, а не hit ratio в вакууме. KV платит за replicas, fsync, backup и on-call correctness. Команда владеет eviction tuning, hot-key response, restore drill, data repair и capacity forecast.

## Failure modes

| Отказ | Симптом | Обнаружение | Реакция |
| --- | --- | --- | --- |
| Cache cluster потерян | miss storm на source | hit ratio, origin QPS | request coalescing, load shedding, progressive warm-up |
| Hot key | p99 одного shard растёт | per-key heavy hitters | L1/replicas для reads; remodel для writes |
| Cache invalidation отстала | stale values | invalidation lag, version mismatch | short TTL/bypass, replay outbox |
| Cache failover потерял write | старое/отсутствующее значение | replica offset | прочитать source; не считать cache authoritative |
| KV leader умер | короткая пауза writes | election duration | quorum elects leader, clients retry с same CAS/idempotency |
| KV потерял quorum | writes недоступны | quorum health | fail closed, не принимать divergent writes |
| Rebalance перегружает сеть | latency и eviction растут | migration bandwidth, p99 | rate-limit moves, one range at a time, headroom |
| Watch consumer отстал за compaction | resume token устарел | compacted revision error | full snapshot, затем watch с новой revision |
| Bit rot/backup повреждён | checksum mismatch/restore fail | scrub и restore drill | replica repair, immutable backup, проверка restore |

## Безопасность

Namespace-level RBAC ограничивает data и admin operations. mTLS связывает client identity с tenant; key prefix от клиента не заменяет авторизацию. Values шифруются в transit и at rest, backups используют отдельные keys и retention policy.

Key names, metrics и logs не должны раскрывать PII. Запрещены безлимитные scans, giant values и unbounded watches. Cache poisoning предотвращают server-side namespace, typed serialization, version/checksum и запрет записывать данные от одного tenant в ключ другого.

## Observability и SLO

Cache: hit ratio по namespace и request class, origin saved QPS, eviction reason, memory fragmentation, hot keys, stale serves, fill latency и stampede waiters. KV: commit latency/index, leader changes, quorum health, WAL fsync, snapshot/compaction, watch lag, revision conflicts, backup age и restore duration.

Общие SLO dashboards показывают user-visible latency и errors, а не только node health. Cache hit ratio может быть высоким при нулевой пользе, если hits относятся к дешёвым origin reads.

## Эволюция решения и миграции

1. **L1/cache-aside:** библиотека и один региональный managed cache.
2. **Sharded cache:** virtual slots, replicas, per-tenant limits, stampede protection.
3. **Отдельный durable KV:** consensus groups, CAS/watch, backup и explicit namespace profiles.
4. **Multi-region:** regional cache rebuild, KV home regions и tested failover epochs.

Online resharding сначала добавляет replica нового владельца, копирует snapshot, догоняет change log, затем атомарно меняет slot epoch. Старый owner некоторое время пересылает requests, но rejects writes со старым epoch после cutover.

Миграция приложения идёт dual-read с source verification, затем shadow-write. Для cache divergence лишь измеряется. Для KV сравниваются revisions/checksums, а cutover требует остановить старого writer или fencing; вечный dual write без общей транзакции создаёт два источника истины.

## Trade-offs и альтернативы

- **Client-side routing или proxy.** Client экономит hop и масштабируется вместе с callers, но усложняет обновление SDK. Proxy упрощает клиенты и централизует policy, зато добавляет latency и capacity tier.
- **Async replication или quorum.** Async даёт быстрый cache и возможную потерю. Quorum сохраняет durable KV, но снижает availability при partition.
- **TTL или explicit invalidation.** TTL прост и ограничивает staleness. Invalidation быстрее обновляет, но сама требует надёжной доставки; вместе они надёжнее, чем любой вариант отдельно.
- **Одна платформа или два продукта.** Общий control plane удобен. Раздельные clusters делают guarantees видимыми и не дают cache workload вытеснить consensus state.

## Типичные ошибки

### Cache стал скрытым source of truth

- **Неверное предположение:** replica и snapshot делают cache durable.
- **Симптом:** после flush данные восстановить неоткуда.
- **Причина:** business write никогда не попал в authoritative storage.
- **Исправление:** durable write first/outbox либо явный KV profile с другим SLO.

### Consistent hashing «решает» hot key

- **Неверное предположение:** больше nodes делит один key.
- **Симптом:** один shard перегружен после масштабирования cluster.
- **Причина:** hash распределяет keys, но один key остаётся единицей маршрутизации.
- **Исправление:** replicate/cache reads или изменить data model writes.

### `MGET` принимают за snapshot transaction

- **Неверное предположение:** один batch означает одну revision.
- **Симптом:** связанные keys видны в разных состояниях.
- **Причина:** запрос fan-out-ится в независимые shards.
- **Исправление:** co-locate invariant либо хранить aggregate одним value/version.

## Когда применять

Distributed cache нужен, когда повторные чтения дороги и source выдержит controlled misses. Durable KV подходит для небольших values, point access, CAS/watch и ясной partition key. Если запросы требуют joins, вторичных индексов и произвольных транзакций, реляционная БД обычно проще.

## Источники

- [Dynamo: Amazon's Highly Available Key-value Store](https://www.amazon.science/publications/dynamo-amazons-highly-available-key-value-store) — Amazon, SOSP 2007, проверено 2026-07-18.
- [etcd API](https://etcd.io/docs/v3.6/learning/api/) — etcd, документация v3.6, проверено 2026-07-18.
- [etcd API guarantees](https://etcd.io/docs/v3.5/learning/api_guarantees/) — etcd, версия документации v3.5; гарантии KV и Watch, проверено 2026-07-18.
- [Redis Cluster Specification](https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/) — Redis Open Source, specification для Redis Cluster 3.0+, проверено 2026-07-18.
- [Scaling Memcache at Facebook](https://www.usenix.org/system/files/conference/nsdi13/nsdi13-final170_update.pdf) — Facebook/USENIX, NSDI 2013, проверено 2026-07-18.
- [Consistent Hashing and Random Trees](https://dl.acm.org/doi/10.1145/258533.258660) — Karger et al., STOC 1997, проверено 2026-07-18.
