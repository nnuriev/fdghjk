---
aliases:
  - Payment system and ledger design
  - Проектирование платежей и бухгалтерской книги
tags:
  - тип/разбор
  - область/проектирование-систем
  - тема/платежи
статус: проверено
---

# Проектирование платёжной системы и ledger

## TL;DR

Платёжная система координирует неоднозначный внешний процесс, а ledger хранит внутреннюю финансовую истину. Это разные state machines. API принимает idempotency key и создаёт payment intent; connector вызывает PSP; callbacks и reconciliation уточняют внешний статус; ledger атомарно добавляет сбалансированные immutable postings. Исправление делается reversal/compensating transfer, не `UPDATE amount`.

Главный приоритет — safety: нельзя дважды списать, потерять подтверждённую проводку или показать деньги, которых ledger не зафиксировал. Во время network partition система вправе отложить новый write. Multi-region строится как active-active между непересекающимися account shards, но single-writer с fencing для одного account/ledger partition.

## Контекст и ментальная модель

Система обслуживает merchant payments, refunds и внутренние transfers. Внешний PSP может принять запрос и потерять ответ, повторить webhook или прислать события не по порядку. Поэтому `timeout` означает «результат неизвестен», а не «платёж не прошёл».

Полезно разделить четыре слоя:

- **payment intent** описывает желаемую бизнес-операцию и её state machine;
- **attempt** фиксирует конкретный вызов PSP и внешний reference;
- **ledger transaction** атомарно перемещает value между accounts;
- **reconciliation** сравнивает внутренние записи с независимым отчётом PSP/банка.

Double-entry даёт инвариант: сумма debit postings равна сумме credit postings внутри одной currency и ledger transaction. Баланс — производная от неизменяемых проводок плюс проверяемый snapshot, а не поле, которое можно исправить вручную.

## Требования

### Функциональные

- создать payment intent, авторизовать, capture, cancel и refund;
- безопасно повторить клиентский запрос по idempotency key;
- маршрутизировать попытку в PSP и хранить provider reference;
- принимать подписанные webhooks, дедуплицировать и упорядочивать state transitions;
- вести double-entry ledger, holds/pending и posted balances;
- отдавать status, transaction history и versioned balance;
- публиковать business events через outbox;
- сверять settlements/fees/chargebacks и создавать repair case;
- поддерживать manual review с полным audit trail.

### Нефункциональные и SLO

| Характеристика | Интервью-цель |
| --- | --- |
| Доступность create/status API | 99,99% за 30 дней |
| Внутренняя latency create intent | p99 ≤ 300 ms без времени внешнего PSP |
| End-to-end authorization | deadline 3 s; timeout переводит attempt в `unknown` |
| Ledger commit | p99 ≤ 100 ms в primary region |
| Durability | RPO 0 для acknowledged ledger transaction внутри региона |
| DR | RPO ≤ 1 min и RTO ≤ 15 min при asynchronous cross-region copy; RPO 0 требует WAN quorum |
| Consistency | serializable/linearizable transition account shard; eventual для search/reporting |
| Correctness | ни одной несбалансированной posted transaction; duplicate business effect = 0 |

Latency и availability не перекрывают correctness. Быстрый `200` с неизвестным фактическим статусом хуже честного `202 pending`.

### Вне scope

FX pricing, card network protocols, credit scoring, бухгалтерская отчётность конкретной юрисдикции и custody реальных ключей остаются вне scope. Дизайн не заменяет анализ PCI DSS и финансового регулирования.

## Оценка нагрузки и ёмкости

Все числа — интервью-допущения:

- 1 000 новых payments/s в среднем, 10 000/s peak;
- на payment приходится в среднем 10 workflow/audit events по 300 B;
- ledger создаёт в среднем 4 postings по 200 B;
- financial history хранится 7 лет;
- idempotency record размером 1 KB хранится 30 дней.

```text
events: 1 000 × 10 × 300 B × 86 400 = 259,2 GB/day
events за 7 лет = 259,2 × 365 × 7 = 662,3 TB primary

postings: 1 000 × 4 × 200 B × 86 400 = 69,12 GB/day
postings за 7 лет = 176,6 TB primary

idempotency: 1 000 × 1 KB × 86 400 × 30 = 2,592 TB primary
```

Hot OLTP не держит семь лет в одном индексе. Закрытые time partitions архивируются в immutable object storage, а online history сохраняет срок, нужный для support и chargeback. Регуляторный срок — входное требование конкретного бизнеса; семь лет здесь лишь capacity scenario.

Peak ledger writes выше payment TPS из-за postings, callbacks, refunds и reconciliation. Планирование использует worst-case postings per operation и PSP retry burst. Capacity проверяют на serializable contention одного hot merchant/account, а не только на равномерный throughput.

## API и модель данных

```http
POST /v1/payment_intents
Idempotency-Key: merchant-17/order-8841/pay

{
  "merchant_id": "merchant-17",
  "order_id": "order-8841",
  "amount_minor": 1250,
  "currency": "EUR",
  "payment_method_token": "pm_tok_..."
}
```

```http
POST /v1/payment_intents/{id}:capture
POST /v1/payment_intents/{id}:cancel
POST /v1/payments/{id}/refunds
GET  /v1/payment_intents/{id}
GET  /v1/accounts/{id}/balance?at_revision=...
```

Amount хранится целым числом minor units вместе с currency/scale contract; floating point запрещён. Повтор idempotency key сравнивает canonical request hash. Тот же key с другим amount возвращает conflict.

Основные сущности:

- `payment_intents(id, merchant_id, order_id, amount, currency, state, revision)`;
- `payment_attempts(id, intent_id, provider, provider_ref, state, request_hash, last_error)`;
- `idempotency_keys(scope, key_hash, request_hash, resource_id, response_ref, expires_at)`;
- `ledger_accounts(id, owner, currency, account_type, shard_id, status)`;
- `ledger_transactions(id, business_key, state, effective_at, created_at, reversal_of?)`;
- `postings(transaction_id, account_id, side, amount, currency, sequence)`;
- `outbox(id, aggregate_id, revision, event_type, payload)`;
- `provider_events(provider, event_id, provider_ref, received_at, payload_hash)`;
- `reconciliation_cases(id, provider_ref, expected, observed, status)`.

Уникальные ограничения стоят на `(merchant, idempotency_key)`, provider event id, provider reference и business key ledger transaction. Posted transaction immutable; correction ссылается на исходную через `reversal_of`.

## Архитектура и критические потоки

```text
client -> API/auth -> payment orchestrator -> payment DB
                               |                |-> outbox -> events/webhooks
                               |-> PSP connector <-> external PSP
                               |-> ledger service -> serializable ledger store
PSP webhooks -> verified inbox -> orchestrator
settlement reports -> reconciliation -> repair/manual review
```

Payment DB хранит orchestration state; ledger service один владеет проводками. PSP call не выполняется внутри DB transaction: внешняя сеть не умеет участвовать в локальном commit. Вместо этого применяется [[40 Распределённые системы/Saga|saga]] с явными промежуточными состояниями и reconciliation.

### Write path и end-to-end trace

Покупатель оплачивает `12,50 EUR`.

1. API получает idempotency key `merchant-17/order-8841/pay`, атомарно создаёт intent `P1` в состоянии `created` и idempotency record.
2. Orchestrator создаёт attempt `A1`, отправляет PSP запрос с собственным idempotency/business reference. PSP авторизует платёж, но HTTP-ответ теряется.
3. Deadline истекает. Система не ставит `failed`, а переводит attempt в `unknown` и отвечает клиенту `202 pending` со стабильным `P1`.
4. Client повторяет create. Idempotency record возвращает `P1`; новый PSP call не создаётся.
5. Подписанный webhook `authorized` приходит дважды. Inbox unique key сохраняет один provider event. State transition CAS меняет `unknown → authorized`.
6. При capture ledger атомарно создаёт сбалансированную transaction: debit provider receivable, credit merchant payable на `1250 EUR`. В той же транзакции пишется outbox.
7. Settlement report позже подтверждает amount/fee. Расхождение создаёт reconciliation case, но не переписывает старые postings.

Наблюдаемый результат: потерянный ответ и двойной webhook не создают второй charge или вторые postings. Статус между шагами 3 и 5 честно остаётся неизвестным.

### Read path

Point read intent идёт в authoritative payment shard. Balance read использует ledger revision: materialized balance ускоряет ответ, но сверяется с последней applied posting sequence. Search по клиенту и отчёты читают replica/warehouse и возвращают watermark; они не используются для решения «можно ли списать».

## Масштабирование и надёжность

**Storage.** Payment state и idempotency подходят SQL с unique constraints. Ledger требует serializable transactions, append-only postings и строгих invariants; специализированный ledger store допустим, но контракт важнее продукта. Object storage хранит закрытые отчёты и provider artifacts. Search/warehouse строятся из outbox/CDC.

**Partitioning.** Начинать стоит с одного логического ledger до доказанного bottleneck: cross-shard money movement значительно сложнее. При шардировании accounts получают стабильный shard по owner/account. Transfer внутри shard атомарен. Cross-shard transfer проходит через clearing accounts и state machine либо отдельный coordinator; пользователю не показывают два независимых «успешных» half-transfer.

**Replication.** В primary region ledger коммитится синхронным quorum. Read replicas не принимают money writes. Payment events/outbox доставляются at-least-once, consumers дедуплицируют по `(aggregate, revision)`.

**Caching.** Кэшируются immutable transaction details, public metadata и короткоживущий payment status по revision. Available balance для authorization не берётся из eventual cache. Cache invalidation lag не может разрешить overdraft.

**Async processing.** PSP calls, webhook handling, outbox publication, receipts, reconciliation и reporting идут асинхронно. Очереди имеют deadlines и business retry keys. [[40 Распределённые системы/Transactional outbox и Change Data Capture|Transactional outbox]] связывает ledger commit с событием без dual write.

**Multi-region и DR.** Клиенты читают локально, но account shard имеет один write region и owner epoch. Failover требует quorum decision/fencing старого writer; DNS-переключения недостаточно. Active-active работает между разными shards. Синхронный global quorum даёт RPO 0 при потере региона, но добавляет WAN latency; альтернативой служит warm standby с ненулевым RPO и обязательной provider reconciliation.

**Operational ownership.** Команда отвечает за provider certification, key rotation, reconciliation SLA, manual repair dual control, restore drills и доказательство ledger invariants. Главные расходы — replicated OLTP, длительное immutable хранение, PSP/network fees и человеческая обработка mismatches. Экономить на reconciliation обычно дороже, чем на storage.

## Failure modes

| Отказ | Симптом | Обнаружение | Реакция |
| --- | --- | --- | --- |
| PSP принял запрос, ответ потерян | attempt `unknown` | timeout + lookup/webhook | не повторять вслепую; запросить status, ждать event, reconcile |
| Duplicate client request | риск второго intent | idempotency unique conflict | вернуть прежний resource/response |
| Duplicate/out-of-order webhook | state пытается откатиться | event dedup, invalid transition | inbox unique key, monotonic state machine, lookup PSP |
| Ledger quorum недоступен | capture не коммитится | DB/quorum errors | fail closed, не публиковать success |
| Outbox publisher умер | ledger есть, event задержан | oldest unpublished row | restart/replay; consumer dedup |
| Несбалансированная transaction | invariant violation | DB constraint/pre-commit check | reject целиком, page on-call |
| Settlement mismatch | внутренний и provider totals расходятся | reconciliation job | case, hold/reversal по процедуре, audit |
| Региональный split brain | два writers account shard | epoch/fence conflict | остановить minority, promote через quorum, reconcile provider |
| Утечка payment data | security incident | DLP/audit/anomaly | revoke keys, isolate, incident response и обязательные уведомления |

## Безопасность

Card data заменяется provider token-ом до попадания в основную систему, чтобы сузить PCI DSS scope. TLS/mTLS, encryption at rest, least privilege, network segmentation и rotation обязательны. Secrets и PAN не попадают в logs, traces, idempotency keys или event payloads.

Операции refund, manual posting, limit change и failover требуют RBAC, strong authentication, approval/dual control и immutable audit. Webhooks проверяют signature, timestamp/replay window и provider event id. Fraud controls работают до PSP call, но их решение тоже versioned и наблюдаемо.

## Observability и SLO

Технические SLI: API success/latency, ledger commit latency, DB conflicts, outbox age, queue age, webhook verification failures, provider latency/error по route, unknown attempts, failover epoch. Бизнес-инварианты важнее CPU:

- count/amount accepted, authorized, captured, refunded;
- duplicate suppression;
- доля attempts в `unknown` старше threshold;
- reconciliation unmatched count и amount;
- debit-credit imbalance, всегда ноль для posted transactions;
- balance snapshot lag по sequence.

Alerts разделяют provider degradation, внутренний ledger отказ и reconciliation breach. Runbooks запрещают «починить баланс UPDATE-ом» и ведут оператора через reversal, evidence и approval.

## Эволюция решения и миграции

1. **Начало:** один PSP, SQL payment state, double-entry tables, idempotency и ежедневная reconciliation.
2. **Рост:** connector abstraction, outbox, separate ledger service, per-merchant limits и immutable archive.
3. **Шардирование:** account placement, clearing model, explicit cross-shard workflow и tenant isolation.
4. **Multi-region:** read replicas, single-writer account shards, fenced failover и региональные PSP routes.

Миграция с mutable balance на ledger начинается с append нового ledger в shadow mode. Пока legacy остаётся source of truth, каждая его mutation атомарно пишет outbox, а consumer создаёт postings с единым business key. Backfill преобразует исторические операции в balanced transactions с provenance, после чего dual calculation сравнивает balances по account/currency на каждом cut.

До cutover запускается идемпотентная ledger→legacy projection: она применяет committed postings по порядку и хранит `applied_ledger_revision`. Для merchant прямые legacy writers сначала блокируются fencing-ом, затем projection догоняет cutover revision, а reconciliation подтверждает равенство balances. Только после этого reads и writes переключаются на ledger.

Rollback остаётся безопасным для денег: application/API можно откатить только за compatibility adapter, а прямые credentials старого приложения к balance tables остаются отозванными. Adapter направляет mutations в ledger с тем же business key и обслуживает legacy read только при `applied_ledger_revision >= required_revision`. При lag projection adapter fail-closed и читает ledger напрямую, поэтому stale balance не становится результатом rollback. Projection и reconciliation работают всё rollback window; новые postings не удаляются. После окна legacy balance становится read-only, а дальнейшая миграция данных идёт только вперёд.

Schema rollout — expand/contract: сначала nullable/new columns и readers, затем writers, backfill и constraints. Большая таблица postings мигрируется по partitions без долгой блокировки.

## Trade-offs и альтернативы

- **Один SQL ledger или специализированный store.** SQL проще эксплуатировать и связывать с payment state. Специализированный ledger усиливает invariant/performance, но добавляет продукт и интеграционную границу.
- **Синхронный PSP call или async orchestration.** Синхронный UX проще, пока ответ приходит в deadline. Durable state machine всё равно нужна для unknown, webhook и retry.
- **Global active-active или single writer.** Active-active уменьшает latency, но cross-region order одного account требует consensus. Single writer проще защищает деньги.
- **Точный real-time report или warehouse.** OLTP точен для point balance; аналитический warehouse дешевле для scans, но eventual и не участвует в authorization.

## Типичные ошибки

### Timeout трактуют как decline

- **Неверное предположение:** нет ответа значит нет эффекта.
- **Симптом:** повтор создаёт второй charge.
- **Причина:** request outcome неоднозначен после отправки во внешнюю систему.
- **Исправление:** состояние `unknown`, provider idempotency/reference, lookup и reconciliation.

### Баланс хранится одним изменяемым числом

- **Неверное предположение:** audit можно восстановить из application logs.
- **Симптом:** невозможно доказать происхождение расхождения.
- **Причина:** исправления уничтожили историю.
- **Исправление:** immutable double-entry postings, reversal и derived balance.

### Event stream называют ledger

- **Неверное предположение:** наличие append-only log гарантирует бухгалтерский инвариант.
- **Симптом:** события есть, но debit и credit применились в разных состояниях.
- **Причина:** broker ordering не заменяет atomic balanced transaction.
- **Исправление:** отдельный ledger commit; stream публикуется после него.

## Когда применять

Дизайн подходит для системы, которая сама координирует payment lifecycle и обязана объяснить каждую денежную величину. Если приложение лишь перенаправляет пользователя на hosted checkout и не хранит balances, большая часть ledger-платформы не нужна, но idempotency, webhook inbox и reconciliation всё равно остаются.

## Источники

- [Financial Accounting](https://docs.tigerbeetle.com/coding/financial-accounting/) — TigerBeetle, официальная документация double-entry model, проверено 2026-07-18.
- [Data Modeling](https://docs.tigerbeetle.com/coding/data-modeling/) — TigerBeetle, официальная документация, проверено 2026-07-18.
- [PostgreSQL Transaction Isolation](https://www.postgresql.org/docs/18/transaction-iso.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Stripe API v2 overview: Idempotency](https://docs.stripe.com/api-v2-overview#idempotency) — Stripe, API v2; `POST`/`DELETE`, scope и 30-day replay semantics, проверено 2026-07-18.
- [Stripe API v1: Idempotent requests](https://docs.stripe.com/api/idempotent_requests) — Stripe, API v1; `POST` и минимум 24-hour key retention, проверено 2026-07-18.
- [PCI DSS Document Library](https://www.pcisecuritystandards.org/document_library/?class=pcidss&doc=pci_dss) — PCI Security Standards Council, PCI DSS v4.0.1, проверено 2026-07-18.
