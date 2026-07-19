---
aliases:
  - Feature flag and configuration service design
  - Проектирование config distribution platform
tags:
  - тип/разбор
  - область/проектирование-систем
  - тема/конфигурация
статус: проверено
---

# Проектирование feature flag и configuration service

## TL;DR

Configuration service хранит и распространяет versioned snapshots, а SDK оценивает feature flags локально. Центральный RPC на каждую evaluation создаёт зависимость в самом чувствительном месте: любой отказ control plane останавливает приложения. Поэтому data plane — last-known-good snapshot в process, детерминированный evaluator и безопасный default; control plane — RBAC, validation, publish, audit и rollback.

Consistency здесь не означает одновременное переключение всей fleet. Реалистичная гарантия — monotonically increasing revision на клиенте и измеряемое propagation window. Если операция требует атомарного глобального cutover, feature flag не тот механизм: нужен совместимый двухфазный rollout или координированный protocol.

## Контекст и ментальная модель

Платформа обслуживает deploy configuration, runtime limits, kill switches, percentage rollout и targeting. Разница между config и flag, safe defaults, secrets и lifecycle уже разобрана в [[20 Бэкенд/Конфигурация и feature flags|базовой заметке]]. В design case важны fan-out, локальная availability и эволюция правил.

Ментальная модель:

- authoring model удобна человеку и может содержать segments/rules;
- compiler превращает её в immutable, canonical snapshot;
- distribution доставляет snapshot/delta и показывает adoption;
- SDK оценивает rule по локальному evaluation context;
- audit связывает решение с flag revision, но не пишет каждую evaluation синхронно.

Snapshot — артефакт. Publish создаёт новую revision, старую не редактируют. Rollback означает публикацию нового snapshot с прежним содержанием и новой revision: monotonicity сохраняется.

## Требования

### Функциональные

- создать flag/config со schema, owner, environment и expiry metadata;
- проверить rule conflicts, type и диапазоны до publish;
- поддержать boolean/string/number/object variants, segments и percentage rollout;
- локально и детерминированно evaluate по context;
- распространять full snapshot и ordered deltas, поддерживать polling fallback;
- показать adoption по regions/SDK versions и выполнить rollback;
- задать emergency kill switch с отдельным rollout path;
- вести audit, approvals и cleanup stale flags;
- экспортировать evaluation events асинхронно для экспериментов.

### Нефункциональные и SLO

| Характеристика | Интервью-цель |
| --- | --- |
| Локальная evaluation | 99,999%; p99 ≤ 1 ms, без network hop |
| Control API | 99,9%; p99 ≤ 300 ms |
| Обычное распространение | 99,9% connected SDKs получают revision ≤ 30 s |
| Emergency path | p99 ≤ 5 s в здоровой сети, с явным degraded fallback |
| Durability publish | RPO 0 после commit в primary region |
| DR control plane | RPO ≤ 1 min, RTO ≤ 30 min |
| Consistency | strong publish order; eventual fleet adoption; monotonic revisions на SDK |

Недоступность control plane не останавливает evaluation. SDK продолжает на last-known-good до max-stale policy. По истечении max-stale выбирается flag-specific default: fail-open, fail-closed или pin old behavior. Один общий fallback для всех flags небезопасен.

### Вне scope

Хранилище секретов, произвольный policy language, статистический движок экспериментов и service discovery остаются вне scope. Evaluation context не служит профилем пользователя или аналитическим warehouse.

## Оценка нагрузки и ёмкости

Интервью-допущения:

- 100 000 процессов/SDK clients;
- каждый выполняет 100 evaluations/s: `100 000 × 100 = 10 млн evaluations/s`;
- evaluations локальны, поэтому сервер не получает эти 10 млн RPC/s;
- 1 млн active flag/config definitions по 4 KB: `4 GB primary`;
- 2 млн revisions в месяц по 4 KB: `8 GB/month` до replication/audit;
- control plane принимает до 100 changes/s peak;
- средний full snapshot процесса — 2 MB.

Одновременный full refresh всей fleet передаст `100 000 × 2 MB = 200 GB`. Поэтому snapshots раздаются через object storage/CDN/regional relays, clients добавляют jitter, а нормальный путь использует deltas. Если 100 changes/s fan-out-ить напрямую 100 000 clients, control plane получит 10 млн deliveries/s; иерархические relays превращают это в межрегиональный stream плюс локальный broadcast.

Capacity планируют по snapshot egress, concurrent streams, delta rate, compiler CPU и reconnect storm. Нужен тест «все SDK переподключились после 10-минутного outage», а не только steady state.

## API и модель данных

```http
PUT /v1/projects/payments/environments/prod/flags/new_risk_engine
If-Match: "revision-184"

{
  "type": "string",
  "default": "old",
  "variants": ["old", "new"],
  "rules": [
    {"segment": "internal", "variant": "new"},
    {"percentage": 5, "bucket_by": "account_id", "variant": "new"}
  ],
  "owner": "risk-platform",
  "expires_at": "2026-10-01T00:00:00Z"
}
```

Publish отделён от draft edit:

```http
POST /v1/environments/prod:publish
GET  /v1/environments/prod/snapshots/latest
GET  /v1/environments/prod/changes?after_revision=184
GET  /v1/environments/prod/adoption/185
```

SDK API следует OpenFeature-подобной модели:

```text
getStringValue("new_risk_engine", default="old", context)
  -> value
getStringDetails(...) -> {value, flag_key, variant, reason, revision, error_code}
```

Модель данных:

- `projects`, `environments` и RBAC bindings;
- `flags(flag_key, type, owner, lifecycle, draft_revision)`;
- `segments(segment_id, version, predicate_ast)`;
- `snapshots(environment, revision, checksum, object_ref, created_by, created_at)`;
- `changes(environment, revision, canonical_delta)`;
- `approvals(change_id, actor, decision)`;
- `client_adoption(client_class, region, sdk_version, revision, last_seen)`;
- `audit_events(actor, action, before_hash, after_hash, revision)`.

Evaluation context содержит только разрешённые атрибуты. Stable bucketing использует `(flag_key, salt, bucket_attribute)`; смена salt или key перераспределит cohort и требует отдельной миграции.

## Архитектура и критические потоки

```text
UI/CLI -> control API -> validator -> consistent metadata store
                              |-> compiler -> signed snapshot -> object storage/CDN
                              |-> change stream -> regional relays -> SDK streams
SDK bootstrap <- full snapshot; steady state <- ordered deltas
SDK local evaluator -> application
evaluation events -> sampled async pipeline -> analytics
```

Control API serializes publish per environment и выдаёт revision. Compiler canonicalizes rule order, resolves segment versions, рассчитывает checksum, подписывает snapshot и сохраняет immutable artifact до смены published pointer. Relay не меняет содержимое; он лишь fan-out-ит bytes и tracks acknowledgements. SDK применяет snapshot атомарно, никогда по одному flag.

### Write path и end-to-end trace

Команда включает `new_risk_engine` для 5% accounts.

1. Author сохраняет draft на основе revision 184. Validator проверяет типы, owner, expiry, отсутствующие segments и запрещённые PII attributes.
2. Approver запускает publish на базе 184. Compiler заранее формирует candidate snapshot 185, подписывает его, загружает immutable object с checksum `C185` и проверяет чтение артефакта.
3. Metadata store одной транзакцией делает CAS `published_revision: 184 → 185` и сохраняет `object_ref`, checksum, audit и outbox event. Только этот commit означает успешный publish. Если CAS проигран, candidate никому не виден и позднее удаляется как orphan.
4. Change stream доставляет committed delta relays. SDK EU получает 185, проверяет signature/base revision 184 и атомарно меняет snapshot.
5. Evaluation для `account_id=A42` вычисляет stable hash локально и возвращает variant `new`, reason `TARGETING_MATCH`, revision 185.
6. SDK US временно offline и остаётся на 184. Adoption dashboard честно показывает 82% fleet на 185; rollout не называют завершённым.
7. Ошибки нового варианта растут. Rollback публикует revision 186 с прежним rule content. SDK не откатывает номер назад, но возвращает old behavior.

Наблюдаемый результат: приложения продолжают работать при разрыве связи; в propagation window разные instances законно принимают разные решения, но каждая evaluation объяснима через revision.

### Read path

Application evaluation читает immutable in-process snapshot и не блокируется на I/O. Bootstrap SDK сначала загружает cached disk snapshot, затем проверяет latest через relay/CDN. Control UI читает metadata store и adoption aggregates; audit/history использует pagination по revision.

## Масштабирование и надёжность

**Storage.** Strongly consistent SQL/KV хранит drafts, publish order и audit. Object storage/CDN раздаёт immutable full snapshots. Event stream переносит ordered deltas. Evaluation events и analytics не делят OLTP с control plane.

**Partitioning.** Control data шардируется по `(project, environment)`, а publish одного environment сериализуется. Большой tenant получает отдельный shard/relay. Segment membership не компилируется в гигантский список, если его можно безопасно вычислить из локального атрибута; server-side dynamic segments требуют отдельного data contract.

**Replication.** Metadata имеет quorum в primary region и follower в DR. Snapshots immutable и реплицируются во все регионы. Relays stateless относительно truth: после потери они восстанавливают latest snapshot и delta cursor.

**Caching.** SDK хранит last-known-good в памяти и на диске с checksum, revision и expiry. CDN cache key — immutable revision, а `latest` имеет короткий TTL/ETag. Negative cache для отсутствующего flag короткий, иначе недавно созданный flag долго не появится.

**Async processing.** Distribution, adoption aggregation, evaluation telemetry, stale-flag reports и experiment export идут вне publish transaction. Audit запись и snapshot reference, напротив, входят в durable publish boundary.

**Multi-region и DR.** Authoring получает один leader на environment либо global consensus. Reads и distribution локальны. При primary loss DR может продолжать раздавать последний snapshot; publish возобновляется только после fenced promotion с новым epoch. Emergency override не обходит audit и подпись: отдельный быстрый путь уменьшает latency, но не safety.

**Cost и ownership.** Главные расходы — egress snapshots/deltas, long-lived connections, audit retention и SDK compatibility matrix. Local evaluation экономит server QPS, но переносит сложность в SDK rollout. Команда владеет schema/compiler, relay fleet, client compatibility, emergency exercise и stale flag cleanup.

## Failure modes

| Отказ | Симптом | Обнаружение | Реакция |
| --- | --- | --- | --- |
| Control plane недоступен | publish невозможен | API SLI | SDK использует last-known-good; changes ждут recovery |
| Relay недоступен | clients stale | heartbeat/adoption lag | polling/CDN fallback с jitter |
| Delta потерян/переставлен | base revision не совпадает | revision gap | не применять частично; скачать full snapshot |
| Повреждён snapshot | signature/checksum fail | SDK validation metric | оставить прежний snapshot, alert и rollback publish |
| Compiler или object storage отказали до CAS | published revision не меняется | publish error, orphan candidate count | повторить сборку/загрузку; orphan удалить после grace period |
| Bad rule валиден синтаксически | рост ошибок приложения | variant metrics | automatic pause/rollback revision, kill switch |
| Reconnect storm | relay/CDN saturation | concurrent connects, egress | exponential backoff+jitter, cached disk snapshot |
| Старый SDK не понимает schema | update rejected | compatibility/error code | compiler downgrade profile или block publish |
| Split-brain authoring | две revision branches | epoch/CAS conflict | single leader/quorum, fenced promotion |
| PII попала в context/events | privacy incident | schema/DLP audit | allowlist attributes, redaction, retention/delete workflow |

## Безопасность

RBAC разделяет draft, approve, publish и emergency rollback. Production changes требуют strong authentication и audit. Snapshot подписан, transport защищён mTLS/TLS, SDK проверяет project/environment binding, чтобы dev config не попала в prod.

Secrets не хранятся во flags/config snapshots. Evaluation context использует allowlist и data minimization; email, token и raw user payload не уходят в evaluation telemetry. Percentage rollout нельзя строить на легко подделываемом client-side attribute для security decision.

## Observability и SLO

Control plane: publish latency/success, validation failures, compiler duration, revision conflicts. Distribution: connected clients, revision adoption percentiles, delta/full ratio, reconnects, bytes egress, stale age. SDK: evaluation latency, default/error reason, snapshot age, signature errors и unknown flag rate.

Application metrics обязательно разрезаются по variant и revision, но с bounded cardinality. Rollout owner заранее задаёт guardrail и rollback condition. Platform on-call имеет runbooks для bad publish, relay outage, corrupted snapshot, stale fleet и compromised signing key.

## Эволюция решения и миграции

1. **Начало:** static config files и deploy-time environment variables.
2. **Control plane:** typed schema, versioned snapshots, polling SDK и audit.
3. **Fleet scale:** local evaluator, regional relays, deltas, adoption и signed artifacts.
4. **Несколько лет:** approvals, policy simulation, SDK compatibility profiles, multi-region authoring и automated flag lifecycle.

Переход со старого provider выполняется dual evaluation: приложение получает решения старого и нового SDK, использует старое, а различия пишет с flag key/revision/reason. После устранения расхождений tenants переключаются canary-группами. Затем old provider становится read-only, snapshots архивируются, а fallback остаётся на ограниченное rollback window.

Rule/schema migration использует expand/contract: новые SDK сначала учатся читать оба формата, compiler продолжает выпускать старый совместимый subset, затем включается новая конструкция. Нельзя публиковать rule, который старая значимая доля fleet трактует иначе.

## Trade-offs и альтернативы

- **Local или remote evaluation.** Local быстрее и переживает control outage, но rules/context попадают в SDK и распространяются eventual. Remote скрывает rules и видит свежие данные, но становится обязательным RPC.
- **Polling или streaming.** Polling проще и устойчив к proxies; freshness ограничена interval. Streaming быстрее, но требует reconnect/backpressure. Практический дизайн поддерживает оба.
- **Full snapshot или deltas.** Snapshot прост и самодостаточен, но дорог при большой fleet. Delta экономит egress, но требует base revision и fallback на full.
- **Flag или config.** Flag временно выбирает поведение и имеет owner/expiry. Operational config живёт дольше и требует schema/range. Универсальный JSON blob теряет оба жизненных цикла.

## Типичные ошибки

### RPC на каждую evaluation

- **Неверное предположение:** control plane всегда рядом и доступен.
- **Симптом:** его outage останавливает request path всех сервисов.
- **Причина:** feature decision стала синхронной сетевой зависимостью.
- **Исправление:** local snapshot/evaluator и flag-specific fallback.

### Rollback уменьшает revision

- **Неверное предположение:** клиенты синхронно увидят возврат.
- **Симптом:** SDK игнорирует «старую» revision или oscillates.
- **Причина:** нарушена monotonicity distribution protocol.
- **Исправление:** публиковать прежнее содержимое как новую revision.

### Процент rollout считается случайно на каждый request

- **Неверное предположение:** 5% запросов равно стабильным 5% users.
- **Симптом:** один пользователь прыгает между variants.
- **Причина:** нет stable bucketing key/salt.
- **Исправление:** детерминированный hash по выбранной identity и закреплённому salt.

## Когда применять

Сервис оправдан, когда deploy и release нужно разделять, fleet велика, а изменение должно наблюдаться и откатываться без redeploy. Для нескольких статических параметров одного сервиса достаточно deploy config. Security authorization нельзя строить на eventual client-side flag без отдельной authoritative проверки.

## Источники

- [OpenFeature Specification](https://github.com/open-feature/spec/tree/7886c6af69a2e77c16c84890bcfb02381e1163cf/specification) — OpenFeature, commit `7886c6af69a2e77c16c84890bcfb02381e1163cf`, проверено 2026-07-18.
- [Flag Evaluation API](https://github.com/open-feature/spec/blob/7886c6af69a2e77c16c84890bcfb02381e1163cf/specification/sections/01-flag-evaluation.md) — OpenFeature, commit `7886c6af69a2e77c16c84890bcfb02381e1163cf`, проверено 2026-07-18.
- [Evaluation Context](https://github.com/open-feature/spec/blob/7886c6af69a2e77c16c84890bcfb02381e1163cf/specification/sections/03-evaluation-context.md) — OpenFeature, commit `7886c6af69a2e77c16c84890bcfb02381e1163cf`, проверено 2026-07-18.
- [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) — Kubernetes, документация v1.36, проверено 2026-07-18.
- [etcd API](https://etcd.io/docs/v3.6/learning/api/) — etcd, документация v3.6, проверено 2026-07-18.
- [Canarying Releases](https://sre.google/workbook/canarying-releases/) — Google SRE Workbook, проверено 2026-07-18.
