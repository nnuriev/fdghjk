---
aliases:
  - "Теоретический вопрос: Distributed cache и KV store"
tags:
  - область/данные
  - тема/кэширование
  - тема/распределённые-данные
  - тип/вопрос
статус: проверено
---

# Distributed cache и KV store

## Вопрос

Объясните тему «Distributed cache и KV store»: какие гарантии даёт механизм и какой ценой для чтения, записи и эксплуатации?

## Короткий ориентир

Distributed cache и distributed key-value store используют похожий data path: key отображается в shard или slot, router находит replica set, операция выполняется на owner. Но failure contract разный. Cache хранит производную, вытесняемую копию: miss, expiry и потеря node нормальны, если authoritative source выдерживает восстановление. KV store может быть source of truth; тогда acknowledged write, replication, durability и consistency входят в контракт данных.

Три решения независимы: **placement** определяет owner key, **replication/consistency** — какие копии участвуют в read/write, **retention** — когда value исчезает из-за TTL или eviction. Добавление replicas не исправляет плохой shard key, consistent hashing не даёт strong consistency, а LRU не определяет freshness.

Горячий read key можно копировать и coalesce. Горячий write key с единым порядком остаётся coordination point после любого hashing. Поэтому систему проектируют по distribution реального workload, а не по среднему QPS и числу nodes.

Полный разбор: [[30 Данные/Distributed cache и KV store|Distributed cache и KV store]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/7091/05 Кеширование и высокая доступность#2. `WATCH/MULTI/EXEC` и concurrency|2. `WATCH/MULTI/EXEC` и concurrency]] — вопрос о границах optimistic Redis transaction.
- [[CurseHunter/7091/05 Кеширование и высокая доступность#7. L1/L2 cache|7. L1/L2 cache]] — вопрос о latency, consistency и memory trade-offs двухуровневого cache.
- [[CurseHunter/7091/05 Кеширование и высокая доступность#8. Redis Cluster, hash slots и Sentinel|8. Redis Cluster, hash slots и Sentinel]] — вопрос о sharding, failover и multi-key constraints.
- «Для точечной подготовки уже существуют Context, deadlines и распространение отмены, Data races, deadlocks и livelocks, Execution trace, B-tree и B+tree и Distributed cache и KV store. Это не делает интервью «аналогом Авито»: MERLION — широкий fundamentals/code-review screen, Авито — набор отдельных algorithm и platform exercises с более глубокой практической постановкой.» — [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Связь с материалами репозитория|Telegram Собесы/MERLION — 2025-07-29 — 300к, раздел «Связь с материалами репозитория»]].

## Источники

- [Redis Open Source 8.8 release notes](https://redis.io/docs/latest/operate/oss_and_stack/stack-with-enterprise/release-notes/redisce/redisos-8.8-release-notes/) — Redis, версия 8.8.0 от мая 2026 года, проверено 2026-07-18.
- [Scale with Redis Cluster](https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/) — Redis, Redis Open Source 8.8.0, проверено 2026-07-18.
- [Redis cluster specification](https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/) — Redis, спецификация синхронизирована с Redis Open Source 8.8.0, проверено 2026-07-18.
- [Redis replication](https://redis.io/docs/latest/operate/oss_and_stack/management/replication/) — Redis, Redis Open Source 8.8.0, проверено 2026-07-18.
- [Key eviction](https://redis.io/docs/latest/develop/reference/eviction/) — Redis, Redis Open Source 8.8.0, проверено 2026-07-18.
- [Dynamo: Amazon’s Highly Available Key-value Store](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf) — Amazon, SOSP 2007, проверено 2026-07-18.
- [Consistent Hashing and Random Trees](https://doi.org/10.1145/258533.258660) — ACM, Proceedings of STOC 1997, проверено 2026-07-18.
- [Features](https://apple.github.io/foundationdb/features.html) — FoundationDB project, FoundationDB 7.3.77, ordered keyspace и range reads, проверено 2026-07-18.
