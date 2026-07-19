---
aliases:
  - Transactions and ACID
  - ACID
  - Database transactions
tags:
  - область/данные
  - тема/транзакции
  - механизм/надёжность
статус: проверено
---

# Транзакции и ACID

## TL;DR

Транзакция объединяет несколько чтений и записей в одну commit boundary. Atomicity запрещает частичный commit, consistency означает сохранение заявленных инвариантов, isolation ограничивает наблюдаемые эффекты конкуренции, durability связывает успешный commit с восстановлением после crash.

ACID не расширяет границу автоматически. Внешний HTTP-вызов, очередь без общей транзакции, cache и sequence живут по своим правилам. Гарантия точна только после ответа: какие данные входят в транзакцию, какой выбран [[30 Данные/Уровни изоляции транзакций|уровень изоляции]] и какие durability settings/устройства считаются надёжными.

## Область применимости

- Модель ACID опирается на работу Härder и Reuter 1983 года; реализация рассматривается на PostgreSQL 18.4.
- По умолчанию PostgreSQL выполняет каждый statement в неявной транзакции. `BEGIN`/`COMMIT` объединяют statements; `SAVEPOINT` откатывает часть работы, но не создаёт независимо durable вложенную транзакцию.
- Durability ниже предполагает `fsync=on`, `full_page_writes=on` и обычный local `synchronous_commit=on` на storage, честно выполняющем flush. Иные настройки меняют обещание.
- Вне scope: two-phase commit, consensus replication, distributed transactions и business sagas.
- SQL-пример статически проверен, но не исполнялся локально.

## Ментальная модель

До commit транзакция строит кандидат на новое состояние. Другие sessions видят его по правилам isolation, а crash recovery ещё не обязана сохранить результат. Commit ставит точку: СУБД решает, что версия может стать видимой и что нужная WAL information достигла требуемой durability boundary.

Четыре буквы отвечают на разные сбои:

- A: что произойдёт, если statement или transaction завершится ошибкой посередине;
- C: какие состояния считаются допустимыми;
- I: что увидят concurrent transactions;
- D: что останется после process, OS или power failure в заявленной fault model.

## Как устроено

### Atomicity

PostgreSQL хранит изменения в MVCC-версиях и transaction status. Если transaction aborts, её версии не становятся видимыми как committed. Ошибка statement переводит обычную transaction в aborted state; до `ROLLBACK` последующие команды отвергаются. Savepoint позволяет откатиться к более ранней точке и продолжить.

Atomicity базы не откатывает письмо, уже отправленное через SMTP, или списание во внешнем PSP. Для связи базы с broker/service нужен отдельный protocol, например [[40 Распределённые системы/Transactional outbox и Change Data Capture|transactional outbox]], idempotency и reconciliation.

### Consistency

Consistency не означает «база знает все бизнес-правила». Она означает: если transaction начинает с допустимого состояния и корректно реализует transition, commit оставляет состояние допустимым. `PRIMARY KEY`, `FOREIGN KEY`, `CHECK`, `NOT NULL`, exclusion constraints и triggers делают часть доказательства общей для всех writers.

Инвариант между несколькими строками может потребовать `SERIALIZABLE` или явных locks. При слабой isolation две по отдельности корректные transactions способны совместно нарушить правило.

### Isolation

Isolation не бинарна. PostgreSQL предлагает Read Committed, Repeatable Read и Serializable; Read Uncommitted отображается в Read Committed. Каждый уровень определяет snapshots, конфликты и необходимость retries. Atomic multi-statement transaction на Read Committed всё ещё может прочитать разные committed states в двух statements.

### Durability и WAL

Правило write-ahead logging: WAL records, описывающие изменение page, должны быть flushed раньше самой data page. На commit PostgreSQL обычно flushes WAL до commit record; dirty heap/index pages можно записать позже. После crash recovery повторяет committed changes из WAL начиная с checkpoint.

`synchronous_commit=off` разрешает сообщить success до local WAL flush. Недавняя transaction может потеряться при crash, хотя consistency storage сохраняется. `fsync=off` снимает обязательные flushes и при OS/power failure рискует потерей последних commits и повреждением кластера. Репликация добавляет отдельный вопрос: ждёт ли commit remote write, flush или apply.

### Границы и исключения

Sequence changes видимы другим transactions сразу и не откатываются при abort. Это нормально для генератора уникальных значений: gaps не нарушают identity. DDL в PostgreSQL в основном transactional, но внешние процессы, filesystem effects user-defined functions и network calls могут не подчиняться rollback.

Длинная transaction удерживает snapshot и locks, мешает vacuum удалять dead tuples, увеличивает bloat и усложняет retry. Commit boundary должна охватывать ровно один invariant-preserving transition, без пользовательского ожидания и медленных remote calls внутри.

## Пример или трассировка

Перевод денег и ledger должны commit вместе:

```sql
CREATE TABLE account (
    account_id bigint PRIMARY KEY,
    balance numeric(12, 2) NOT NULL CHECK (balance >= 0)
);

CREATE TABLE ledger_entry (
    entry_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_account bigint NOT NULL REFERENCES account,
    to_account bigint NOT NULL REFERENCES account,
    amount numeric(12, 2) NOT NULL CHECK (amount > 0)
);

INSERT INTO account VALUES (1, 100.00), (2, 50.00);

BEGIN;
UPDATE account SET balance = balance - 80.00 WHERE account_id = 1;
UPDATE account SET balance = balance + 80.00 WHERE account_id = 2;
INSERT INTO ledger_entry (from_account, to_account, amount)
VALUES (1, 2, 80.00);
COMMIT;
```

После commit balances равны `20.00` и `130.00`, ledger содержит одну строку. Следующая transaction нарушает `CHECK`:

```sql
BEGIN;
UPDATE account SET balance = balance - 30.00 WHERE account_id = 1;
UPDATE account SET balance = balance + 30.00 WHERE account_id = 2;
INSERT INTO ledger_entry (from_account, to_account, amount)
VALUES (1, 2, 30.00);
COMMIT;
```

Первый `UPDATE` получает `check_violation`, transaction переходит в aborted state, `COMMIT` не фиксирует частичный перевод. После `ROLLBACK` balances остаются `20.00` и `130.00`, ledger по-прежнему содержит одну строку. Пример доказывает atomicity и constraint, но не корректность двух конкурентных переводов: её надо отдельно проверить на выбранной isolation и locking strategy.

## Trade-offs

- Короткая transaction уменьшает lock time, snapshot retention и retry cost. Слишком узкая boundary разделяет invariant на несколько commits и открывает промежуточное состояние.
- `synchronous_commit=on` ждёт как минимум local durable WAL и повышает commit latency; при настроенной synchronous replication граница может включать standby. `off` возвращает ответ до local WAL flush: последующий фоновый flush может амортизировать несколько commits, но недавние acknowledged transactions допустимо потерять при crash ОС или питания.
- Сильнее isolation упрощает рассуждение о multi-row rules. Цена: monitoring dependencies, blocking или serialization failures, которые приложение обязано retry целиком.
- Constraints централизуют consistency и защищают от всех writers. Сложный trigger скрывает work, увеличивает lock surface и труднее версионируется; часто лучше изменить модель или использовать явный transaction protocol.
- Большой batch amortizes commit overhead. Он дольше удерживает resources, генерирует burst WAL и дороже повторяется после conflict.

## Типичные ошибки

- Неверное предположение: ACID означает Serializable. Симптом: write skew нарушает бизнес-правило внутри успешно committed transactions. Причина: isolation level слабее serializable. Исправление: выбрать уровень по invariant, добавить retries или явные locks.
- Неверное предположение: успешный DB commit включает message broker и HTTP. Симптом: заказ записан, событие потеряно либо внешняя операция повторена после rollback. Причина: разные atomicity boundaries. Исправление: outbox/CDC, idempotency key и reconciliation вместо фиктивной общей транзакции.
- Неверное предположение: sequence gaps означают нарушенную atomicity. Симптом: пытаются переиспользовать numbers и создают contention. Причина: sequence не transactional и обещает генерацию, а не плотную нумерацию. Исправление: считать gaps нормой; юридическую последовательность моделировать отдельно.
- Неверное предположение: `COMMIT` всегда означает сохранность после любого сбоя. Симптом: acknowledged rows потеряны после crash при `synchronous_commit=off` или ненадёжном storage. Причина: durability boundary настроена слабее ожиданий. Исправление: зафиксировать fault model, settings и flush guarantees, проверить recovery.
- Неверное предположение: transaction может ждать пользователя или remote API сколько угодно. Симптом: bloat, lock waits и исчерпание pool. Причина: долго живут snapshot и locks. Исправление: вынести ожидание, сократить boundary, установить timeouts и сделать retry безопасным.
- Неверное предположение: rollback отменяет любой side effect функции. Симптом: файл или сетевой вызов остаётся после abort. Причина: внешний ресурс не участвует в WAL/transaction manager. Исправление: запретить такие effects внутри transaction либо добавить компенсацию и idempotency.

## Когда применять

Объединяйте в одну transaction все DB-изменения, без которых invariant оказался бы частично выполнен. До кода запишите precondition, writes, constraints, isolation, conflict outcome и retry boundary. Для каждой внешней системы отдельно определите delivery semantics и repair.

Проверяйте durability не названием продукта, а настройками и fault model: process crash, OS crash, power loss, disk loss, primary loss. WAL решает recovery одного кластера в заявленной конфигурации; backup и replication отвечают на другие классы потерь.

## Источники

- [Principles of Transaction-Oriented Database Recovery](https://doi.org/10.1145/289.291) — ACM, Theo Härder, Andreas Reuter, ACM Computing Surveys 15(4), 1983, проверено 2026-07-18.
- [Transactions](https://www.postgresql.org/docs/18/tutorial-transactions.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Transaction Isolation](https://www.postgresql.org/docs/18/transaction-iso.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Write-Ahead Logging](https://www.postgresql.org/docs/18/wal-intro.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [WAL Configuration](https://www.postgresql.org/docs/18/wal-configuration.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Asynchronous Commit](https://www.postgresql.org/docs/18/wal-async-commit.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Constraints](https://www.postgresql.org/docs/18/ddl-constraints.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [PostgreSQL 18.4 release notes](https://www.postgresql.org/docs/18/release-18-4.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, release date 2026-05-14, проверено 2026-07-18.
