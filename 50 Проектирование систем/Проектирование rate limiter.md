---
aliases:
  - Rate limiter system design
  - Проектирование distributed rate limiter
tags:
  - тип/разбор
  - область/проектирование-систем
  - тема/устойчивость
статус: проверено
---

# Проектирование rate limiter

## TL;DR

Rate limiter ставится до дорогой работы и принимает решение по серверной identity, scope, policy version и cost. Быстрый путь и управление политиками разделены: control plane хранит и распространяет versioned policies, а data plane использует локальные token buckets и лишь для общего бюджета обращается к regional allocator.

Точный глобальный счётчик на каждый запрос превращает limiter в синхронную зависимость всего API. Практичный L5-компромисс — иерархические бюджеты: глобальный владелец выдаёт регионам и instances ограниченные leases на tokens. Решение остаётся локальным, а возможный overshoot заранее ограничен суммой ещё не потраченных leases. Для операций, где превышение недопустимо даже на один unit, нужен сериализованный authoritative reservation path с более низкой availability.

## Контекст и ментальная модель

Система защищает multi-tenant API от abuse, случайных spikes и исчерпания downstream capacity. Она поддерживает short-term rate, burst, долгую quota и concurrent limits. Алгоритмы token bucket, fixed/sliding window и различие `429`/`503` уже разобраны в [[20 Бэкенд/Rate limiting и quotas|базовой заметке]]. Здесь вопрос шире: как сохранить единый policy contract при миллионах решений в секунду и частичных отказах.

Limiter выдаёт permits. Ключ решения выглядит как:

```text
(tenant, principal, API group, resource class, region, policy revision)
```

Request count не всегда отражает стоимость. Экспорт может стоить 100 units, cache hit — 1, а streaming request дополнительно занимает concurrency permit до завершения.

## Требования

### Функциональные

- создать, проверить, опубликовать и откатить versioned policy;
- принять решение `allow/deny` по identity, scope и cost;
- поддержать token bucket, quota и concurrent permits;
- вернуть `Retry-After`, policy identifier и operational hint;
- задать fail-open/fail-closed policy по route class;
- зарезервировать строгий budget для финансовых или лицензионных операций;
- отдать usage/audit асинхронно без блокировки decision path;
- перераспределять leased budgets между регионами и shards.

### Нефункциональные и SLO

| Характеристика | Интервью-цель |
| --- | --- |
| Локальное решение | 99,99%; p99 ≤ 1 ms внутри proxy/process |
| Региональное shared-решение | 99,99%; p99 ≤ 5 ms |
| Распространение обычной policy | 99,9% data-plane instances ≤ 30 s |
| Emergency revoke | p99 ≤ 5 s при здоровом control channel |
| Долговечность policies и quotas | RPO 0 после publish в primary region |
| Consistency | linearizable CAS и publish order в control plane; bounded-stale decisions во время распространения; revisions на proxy монотонны |
| Overshoot | не больше явно выданных, но ещё не отозванных tokens |

Отказ limiter трактуется по классу ресурса. Public read может fail-open с аварийным process cap. Создание дорогого export — fail-closed. Внутренний health check не должен блокироваться тем же limiter, который он диагностирует.

### Вне scope

L3/L4 DDoS mitigation, WAF rule engine, биллинг и доказуемо справедливое глобальное распределение между недоверенными регионами остаются вне scope.

## Оценка нагрузки и ёмкости

Интервью-допущения:

- edge принимает 1 млн requests/s в среднем и 3 млн/s в пике;
- 95% решений покрываются local buckets;
- 5% пикового потока требует regional shared state: `3 000 000 × 0,05 = 150 000 decisions/s`;
- за сутки активны 50 млн state keys;
- один bucket с metadata занимает в среднем 128 B.

```text
50 000 000 × 128 B = 6,4 GB primary state
6,4 GB × 3 replicas × 2 headroom = 38,4 GB
```

Policy catalog мал по сравнению с state: даже 1 млн policies по 4 KB — около 4 GB primary. Ограничивает систему не storage, а remote decisions/s, один горячий tenant и fan-out обновлений. Network hop на каждый из 3 млн requests/s исключён design-ом; иначе latency и availability API наследуют limiter целиком.

Capacity проверяют на peak cost units, а не только requests/s. Нужны отдельные тесты для uniform keys, Zipf distribution с hot key, максимального числа live concurrency permits и скорости их expiry, массового policy publish и восстановления регионального allocator после backlog.

## API и модель данных

Control plane:

```http
PUT /v1/policies/{policy_id}
If-Match: "revision-41"

{
  "scope": ["tenant", "route"],
  "algorithm": "token_bucket",
  "capacity": 1000,
  "refill_per_second": 200,
  "failure_mode": "fail_closed"
}
```

Data plane использует компактный RPC:

```text
CheckRate(key, cost, request_id, policy_revision)
  -> {allowed, remaining_hint, retry_after, decision_id, served_revision}

AcquireLease(scope, requested_units, ttl, allocator_epoch)
AcquireConcurrency(key, cost, request_id, policy_revision, ttl)
  -> {allowed, permit_id?, lease_until?, fence?, retry_after, served_revision}
RenewConcurrency(permit_id, fence, ttl)
  -> {lease_until, fence}
ReleaseConcurrency(permit_id, fence)
  -> {released}
```

`remaining_hint` не обещает последующий allow: другой запрос может потратить budget раньше. Повтор `AcquireConcurrency` с тем же `request_id` возвращает тот же живой permit и не занимает capacity второй раз. Permit — lease с server-side `lease_until`: потерянный `ReleaseConcurrency` удерживает capacity только до TTL. Holder ставит локальный deadline и прекращает либо закрывает работу не позднее `lease_until`, если `Renew` не подтвердил новую аренду. `Renew` увеличивает fence, поэтому запоздалый release со старым fence не закрывает актуальную аренду; downstream, который владеет ограничиваемым ресурсом, проверяет этот fence на переходах состояния. Если внешний эффект нельзя прервать или fence-ить, concurrency limit остаётся soft: дизайн обязан назвать максимальный overlap после expiry, а не обещать строгую единственность. `ReleaseConcurrency` с текущим fence идемпотентен.

Модель данных:

- `policies(policy_id, tenant, matcher, algorithm, limits, failure_mode, revision, status)`;
- `bucket_state(key_hash, tokens, last_refill_at, revision, expires_at)`;
- `concurrency_permits(permit_id, request_id, key_hash, holder, cost, lease_until, fence, revision, status)`;
- `budget_leases(lease_id, parent_scope, holder, units, consumed, expires_at, epoch)`;
- `quota_usage(scope, period, committed_units, revision)`;
- `decision_audit(decision_id, sampled_fields, outcome, reason)`.

Policy publish — compare-and-swap, затем immutable snapshot. Bucket state для неактивного ключа истекает после времени, достаточного для полного refill; иначе cardinality будет расти без границы.

## Архитектура и критические потоки

```text
policy API -> strongly consistent store -> compiler -> signed snapshots
                                           -> regional relays -> proxies/SDKs

request -> edge proxy -> local bucket -> allow
                            | miss/shared
                            v
                     regional allocator shards -> global budget owner
decision events -> async stream -> quota aggregation / audit / billing export
```

Identity и cost вычисляются до limiter из проверенного credential и route metadata. Пользовательский header не может выбрать более дешёвый класс. Proxy держит compiled matcher и local state. Regional allocator шардируется по hash full scope key; virtual nodes позволяют переносить часть ключей без полного remap.

### Write path: публикация policy

1. Operator меняет policy с `If-Match: revision-41`.
2. Control plane проверяет schema, диапазоны, пересечения и наличие safe default, затем коммитит revision 42.
3. Compiler создаёт подписанный immutable snapshot. Regional relays распространяют delta.
4. Proxy атомарно меняет весь snapshot, отмечает `served_revision=42` и не смешивает matcher 42 с limits 41.
5. Метрики adoption показывают долю fleet на каждой revision. Rollback не уменьшает номер: control plane публикует содержимое revision 41 как новую revision 43, compiler создаёт для неё snapshot, и proxies принимают revision монотонно.

### Read/decision path и end-to-end trace

Tenant `acme` имеет глобальный refill 200 000 units/s и burst 1 000 000. Region EU получил lease на 100 000 units до `12:00:01`.

1. Request с cost 5 приходит в proxy. Его local sublease содержит 20 units, поэтому решение `allow` принимается без сети и остаётся 15.
2. После четырёх запросов sublease пуст. Proxy одним RPC получает ещё 1 000 units у regional allocator, а не делает 200 отдельных checks.
3. EU теряет связь с global owner. Уже выданные leases продолжают действовать до expiry; новые не выдаются.
4. Максимальный дополнительный расход ограничен outstanding leases. После `12:00:01` дорогой route fail-closed, дешёвый read переключается на аварийный local cap.

Наблюдаемый результат: partition не создаёт бесконечный расход. Цена — bounded overshoot и временно неидеальная fairness между регионами.

## Масштабирование и надёжность

**Storage.** Policies и строгие quotas требуют согласованного SQL/KV. Ephemeral token state держится в memory-oriented KV с atomic update/CAS. Audit и usage идут в event stream; аналитика не выполняется на decision store.

**Partitioning и replication.** Key hash включает tenant и scope. Hot enterprise tenant получает subshards по route/resource, но изменение partitioning не должно менять логический лимит. Regional allocator имеет leader/replicas либо consensus group; local buckets не реплицируются и восстанавливаются из нового lease.

**Caching.** Immutable policy snapshots кэшируются в proxies. Negative lookup имеет короткий TTL. Состояние bucket — не обычный cache: потеря меняет результат, поэтому восстановление выбирает консервативный empty bucket или новый fenced lease, а не «полный bucket по умолчанию».

**Async processing.** Usage aggregation, anomaly detection, quota reporting и audit sampling не входят в latency path. Если stream отстаёт, decision продолжается, но billing-grade quota не должна опираться только на этот eventual consumer.

**Multi-region.** Policies реплицируются во все регионы. Для глобального бюджета есть два режима: single home-region owner с remote latency либо leased regional shares с bounded overshoot. При failover новый owner увеличивает allocator epoch; старые leases предыдущего epoch принимаются только до заранее заданного срока или немедленно отзываются для strict routes.

**DR.** Control plane восстанавливает policy catalog и publish history. Data plane переживает его краткий отказ на last-known-good snapshot. Потеря ephemeral buckets допустима только по документированной conservative recovery policy. Строгие quota counters входят в backup/PITR и DR drills.

**Capacity и cost.** Основные затраты — memory state, cross-zone replication, RPC на cache miss и distribution fan-out. Более крупные leases уменьшают coordination cost, но увеличивают overshoot и время несправедливого распределения. Owner регулярно пересматривает hot keys, decision error budget, snapshot adoption, lease utilization и headroom.

## Failure modes

| Отказ | Симптом | Обнаружение | Реакция |
| --- | --- | --- | --- |
| Policy store недоступен | нельзя публиковать policy | control API errors | data plane использует last-known-good; publish fail-closed |
| Regional allocator недоступен | shared keys не получают budget | allocator RPC errors | использовать действующий lease, затем route-specific fail mode |
| Hot key | один shard достигает CPU/lock limit | per-key contention, shard p99 | hierarchical split, local leases, cost-aware batching |
| Snapshot частично применён | разные proxies решают по разным rules | revision adoption | атомарные snapshots, rollback, reject incompatible delta |
| Clock jump | refill или lease ошибочны | monotonic/wall-clock divergence | monotonic elapsed для refill, server expiry и bounded skew |
| Replica promoted без последней записи | budget «возвращается» | epoch mismatch, reconciliation | consensus для strict state либо conservative reduction |
| Usage stream отстал | dashboards/quota report stale | consumer lag | decision path не блокировать; показать watermark, replay |
| Client потерял `ReleaseConcurrency` | permit временно занимает capacity после завершения request | expired permits, lease utilization | дождаться server TTL; для долгих операций требовать `Renew`, release оставить идемпотентным |
| Holder потерял связь после `AcquireConcurrency` | старая работа продолжается после выдачи нового permit | work after `lease_until`, fence rejects | local deadline закрывает работу; downstream проверяет fence; иначе учитывать bounded overlap как soft limit |
| Mass retry после `Retry-After` | повторный spike | cohort traffic | jitter, tokenized retry budget, load shedding |

## Безопасность

Control API требует RBAC, approval для global policy и неизменяемый audit. Snapshots подписываются; data plane проверяет signature и monotonically increasing revision. Tenant не управляет identity key через header, а policy compiler ограничивает regex и сложность matcher.

Decision logs не должны содержать raw credentials или персональные identifiers. Abuse traffic иногда дешевле молча drop-нуть на периметре: RFC 6585 прямо не требует отвечать `429` каждому запросу во время атаки.

## Observability и SLO

Измеряются allow/deny по reason, decision latency, local-hit ratio, allocator RPC rate, outstanding lease units, bounded overshoot estimate, policy revision adoption, fail-open/fail-closed count, hot-key skew и state eviction. `429` отделяется от `503`: первый показывает contract клиента, второй — нехватку capacity сервиса.

Synthetic checks проверяют известную policy во всех регионах. Burn-rate alert использует decision availability и latency; отдельный safety alert срабатывает на overshoot и stale revision даже при формально быстрых ответах.

## Эволюция решения и миграции

1. **Старт:** local token bucket в API gateway, статические policies.
2. **Shared limits:** regional sharded state для tenants, которым нужен общий budget.
3. **Иерархия:** global owner выдаёт regional и instance leases; control/data plane разделены.
4. **Несколько лет:** cost units, adaptive admission по downstream pressure, policy simulation и per-tenant isolation.

Миграция начинается в shadow mode: новый limiter вычисляет решение, но не блокирует. Сравниваются allow/deny, причина и estimated overshoot. Затем включается canary для внутренних tenants, после — для low-risk reads. Для каждого route заранее определён kill switch и old-path fallback. Состояние counters не dual-write бесконечно: на cutover policies получают новую epoch, а старые buckets естественно истекают.

## Trade-offs и альтернативы

- **Exact global counter или leases.** Exact counter проще объяснить, но добавляет coordination к каждому request. Leases быстрее и доступнее, оплачиваются bounded overshoot.
- **Fail-open или fail-closed.** Fail-open сохраняет availability и рискует downstream. Fail-closed защищает ресурс и рискует отказом здоровым клиентам.
- **Token bucket или sliding log.** Token bucket компактен и допускает burst. Точный sliding log лучше отражает rolling window, но хранит события и дороже на hot key.
- **Gateway или application limiter.** Gateway видит общий ingress. Приложение лучше знает business cost. Практически coarse limit ставят на edge, cost/concurrency — ближе к ресурсу.

## Типичные ошибки

### Remote counter на каждом request

- **Неверное предположение:** быстрый KV не меняет availability path.
- **Симптом:** краткий отказ KV останавливает весь API.
- **Причина:** limiter стал обязательной сетевой зависимостью.
- **Исправление:** local budgets, batching/leases и явный failure mode.

### «Глобальный лимит» умножается на replicas

- **Неверное предположение:** одинаковая config создаёт общий bucket.
- **Симптом:** autoscaling увеличивает разрешённый трафик.
- **Причина:** state локален, scope описан неверно.
- **Исправление:** назвать scope, распределить global budget или честно задокументировать per-instance cap.

### После потери state bucket становится полным

- **Неверное предположение:** availability важнее safety для любого route.
- **Симптом:** restart создаёт бесплатный burst.
- **Причина:** recovery выдаёт новые permits без учёта старых.
- **Исправление:** empty start, fenced lease либо persisted strict counter.

## Когда применять

Система нужна, когда независимые replicas должны соблюдать tenant fairness и защищать общий downstream. Для одного процесса достаточно local token bucket. Для бухгалтерской месячной quota нужен authoritative usage ledger: rate limiter остаётся admission layer, а не финансовым источником истины.

## Источники

- [RFC 6585: Additional HTTP Status Codes](https://www.rfc-editor.org/rfc/rfc6585.html) — IETF, RFC 6585, апрель 2012, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RateLimit header fields for HTTP](https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-ratelimit-headers-11) — IETF HTTPAPI Working Group, Internet-Draft `-11` от мая 2026 года, не RFC, проверено 2026-07-18.
- [Local rate limit](https://www.envoyproxy.io/docs/envoy/v1.38.3/configuration/http/http_filters/local_rate_limit_filter) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Request throttling for the Amazon EC2 API](https://docs.aws.amazon.com/ec2/latest/devguide/ec2-api-throttling.html) — Amazon Web Services, официальная документация EC2 API, проверено 2026-07-18.
