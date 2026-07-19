---
aliases:
  - Two-phase commit
  - 2PC
  - Двухфазный commit
tags:
  - область/распределённые-системы
  - тема/распределённые-транзакции
  - механизм/двухфазный-коммит
статус: проверено
---

# Two-phase commit

## TL;DR

**Two-phase commit (2PC)** — протокол атомарного commit между несколькими transactional resources. В фазе `prepare` каждый participant обещает, что сможет commit позднее, и делает это обещание durable. Coordinator выбирает единственное решение: `COMMIT`, только если все проголосовали `YES`, иначе `ABORT`. Во второй фазе решение доставляется участникам.

2PC обеспечивает atomicity финального решения, но не одновременную видимость на всех participants и не глобальную isolation. Классический протокол может блокироваться: participant, уже ответивший `YES`, не вправе самовольно abort, пока не узнает решение coordinator. Подготовленная транзакция удерживает locks и другие ресурсы. Поэтому 2PC подходит для небольшого числа надёжно управляемых ресурсов с bounded recovery, но плохо сочетается с долгими бизнес-процессами, WAN partitions и внешними API.

## Область применимости

Заметка рассматривает классический atomic commit и реализацию prepared transactions в PostgreSQL 18.4, проверено 2026-07-18. **Two-phase locking (2PL)** — отдельный concurrency-control протокол; сходство названий не делает его фазой 2PC. 2PC отвечает «все commit или все abort», но isolation каждого participant и порядок конкурентных транзакций задаются отдельно.

## Ментальная модель

Coordinator не спрашивает «хотите ли вы commit прямо сейчас». Он просит каждого участника перейти в состояние, из которого обе стороны соглашения соблюдены:

```text
ACTIVE -> PREPARED --global COMMIT--> COMMITTED
                  \--global ABORT---> ABORTED
```

Ответ `YES` означает: participant записал prepare state в durable log, сохранил необходимые locks и сможет выполнить `COMMIT` даже после restart. После unanimous `YES` coordinator записывает global `COMMIT` durably. С этого момента commit — решение, даже если его доставка задержалась.

Инварианты:

- ни один correct participant не commit, если другой обязан abort;
- после durable global decision recovery не меняет его;
- до решения любой `NO` или timeout на prepare ведёт к abort, но после `YES` participant не может безопасно угадывать.

## Как устроено

### Фаза 1: prepare и голосование

Coordinator рассылает `PREPARE(transaction_id)`. Participant завершает локальные проверки — constraints, conflict detection, наличие ресурсов — и записывает prepared state в WAL. После ответа `YES` он сохраняет locks и готовность пережить crash. Если подготовиться нельзя, он отвечает `NO` и локально abort.

Coordinator ждёт все голоса. Любой `NO` даёт решение `ABORT`. Unanimous `YES` позволяет записать `COMMIT` в собственный stable log. Timeout до получения `YES` от участника можно трактовать как отсутствие согласия и abort; timeout после того, как участник отправил `YES`, для самого участника уже неоднозначен.

### Фаза 2: доставка решения

Coordinator рассылает `COMMIT` или `ABORT`. Participants применяют решение, освобождают locks и подтверждают завершение. Повторная доставка безопасна: решение адресуется стабильному transaction ID, а terminal state не меняется.

После crash coordinator восстанавливает durable decision и переотправляет его. Participant в `PREPARED` ищет coordinator или других авторитетных носителей решения. Если все они недоступны, он блокируется. Самостоятельный abort мог бы нарушить atomicity, если global `COMMIT` уже был записан.

### Что хранится durably

Coordinator должен записать transaction identity, список участников и global decision. Participant хранит prepared transaction, enough redo/undo information и локальные ресурсы. Удалять эти записи можно только после подтверждённого завершения по recovery protocol.

В PostgreSQL `PREPARE TRANSACTION` отделяет подготовку от `COMMIT PREPARED` или `ROLLBACK PREPARED`. Prepared transactions сохраняются на disk и переживают crash. Документация прямо рекомендует внешнему transaction manager завершать их быстро; иначе они продолжают удерживать locks и мешают `VACUUM`. Параметр `max_prepared_transactions=0` по умолчанию отключает возможность prepare, а для primary/standby значение должно быть совместимо.

### 2PC и consensus

Классический 2PC предполагает особую роль coordinator и ради safety допускает блокировку при его недоступности. Consensus решает выбор значения при отказах участников через quorum; его safety и liveness устроены иначе. Gray и Lamport показывают transaction commit как отдельную задачу и строят Paxos Commit, где решения resource managers реплицируются через Paxos, уменьшая зависимость от одного coordinator. Это не превращает обычный 2PC в consensus.

## Пример или трассировка

Нужно атомарно списать 100 в базе `Accounts` и создать проводку в базе `Ledger`.

1. Coordinator открывает локальные транзакции `tx=91` в обеих базах.
2. `Accounts` уменьшает доступный баланс, `Ledger` вставляет запись. Ни один результат ещё не виден как commit.
3. Coordinator посылает `PREPARE 91`. Обе базы записывают prepared state, удерживают locks и отвечают `YES`.
4. Coordinator durably пишет `COMMIT 91`, отправляет решение `Accounts`, затем падает до доставки `Ledger`.
5. `Accounts` commit. `Ledger` остаётся `PREPARED`: он не может abort только из-за timeout, потому что commit уже является глобальным решением.
6. Coordinator восстанавливается из log и повторяет `COMMIT 91`; `Ledger` commit и освобождает ресурсы.

После recovery обе базы следуют одному финальному решению. Однако между шагами 4 и 6 `Accounts` уже может показать commit независимому reader, пока `Ledger` ещё остаётся `PREPARED`: 2PC не делает visibility одновременной. Часть ресурсов в это время заблокирована. Если log coordinator утрачен без реплики и никто не может доказать решение, ручной выбор становится рискованным восстановлением, а не нормальной веткой протокола.

## Trade-offs

2PC связывает participants единым финальным commit/abort decision, когда все ресурсы поддерживают prepare. Но global isolation и atomic read нескольких ресурсов требуют отдельного протокола: во время доставки решения visibility может расходиться. Цена — дополнительные round trips, WAL flushes, held locks, общий failure domain и сложная operational recovery.

[[40 Распределённые системы/Transactional outbox и Change Data Capture|Transactional outbox]] выбирает локальную атомарность и eventual delivery: он не блокирует бизнес-транзакцию на broker, но допускает временное расхождение и дубликаты. Saga разбивает долгий workflow на локальные commits и compensations; она лучше сохраняет автономность, но не даёт isolation и настоящего rollback уже видимых эффектов.

Consensus-backed commit или replication coordinator уменьшает single point of recovery, но добавляет quorum и не отменяет недоступность participant, который хранит уникальные подготовленные данные.

## Типичные ошибки

- **Неверное предположение:** timeout после prepare позволяет безопасно rollback. **Симптом:** одна база abort, другая commit. **Причина:** global decision мог быть записан, но не доставлен. **Исправление:** держать prepared state до авторитетного recovery decision.
- **Неверное предположение:** 2PC автоматически даёт serializability. **Симптом:** атомарная транзакция видит isolation anomaly внутри участника. **Причина:** atomic commit и concurrency control смешаны. **Исправление:** отдельно выбрать и проверить isolation level каждого resource.
- **Неверное предположение:** prepared transaction — нормальная долгосрочная очередь. **Симптом:** блокировки, рост старых версий и остановка обслуживания. **Причина:** фаза между prepare и decision длится минуты или часы. **Исправление:** bounded timeout, мониторинг in-doubt transactions и автоматизированный recovery.
- **Неверное предположение:** любой SaaS или broker поддержит XA/prepare. **Симптом:** один side effect остаётся вне transaction. **Причина:** гетерогенные ресурсы не имеют общего atomic-commit API. **Исправление:** outbox, idempotency и saga с явно принятой eventual consistency.

## Когда применять

Используйте 2PC, когда атомарность нескольких ACID resources обязательна, каждый участник надёжно поддерживает prepare, число участников невелико, latency ограничена одной инфраструктурной зоной, а команда умеет находить и завершать in-doubt transactions.

Не выбирайте 2PC для human-in-the-loop процессов, межрегиональных workflows с высокой partition probability, email, платёжных API без prepare и операций, которые могут жить часами. Перед внедрением проверьте recovery coordinator, durable transaction IDs, лимит prepared state, мониторинг возраста и процедуру решения при утрате метаданных.

## Источники

- [Consensus on Transaction Commit](https://www.microsoft.com/en-us/research/publication/consensus-on-transaction-commit/) — Jim Gray и Leslie Lamport, ACM TODS 31(1), 2006, проверено 2026-07-18.
- [PostgreSQL 18: Two-Phase Transactions](https://www.postgresql.org/docs/18/two-phase.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [PostgreSQL 18: `PREPARE TRANSACTION`](https://www.postgresql.org/docs/18/sql-prepare-transaction.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [PostgreSQL 18: `max_prepared_transactions`](https://www.postgresql.org/docs/18/runtime-config-resource.html#GUC-MAX-PREPARED-TRANSACTIONS) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
