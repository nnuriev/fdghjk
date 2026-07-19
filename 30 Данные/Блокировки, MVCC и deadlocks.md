---
aliases:
  - Locking and MVCC
  - Database deadlocks
  - PostgreSQL MVCC
tags:
  - область/данные
  - тема/транзакции
  - механизм/конкурентность
статус: проверено
---

# Блокировки, MVCC и deadlocks

## TL;DR

MVCC хранит несколько row versions и даёт reader snapshot, поэтому обычное чтение не блокирует запись, а запись не блокирует обычное чтение. Блокировки остаются нужны: writers конфликтуют за logical rows, DDL защищает relation structure, foreign keys охраняют referenced keys, а application может брать `FOR UPDATE`.

Deadlock возникает не от долгого ожидания, а от цикла wait-for: T1 ждёт lock T2, а T2 прямо или транзитивно ждёт T1. PostgreSQL обнаруживает цикл и aborts одну transaction. Лечение: одинаковый порядок locks, короткие transactions и полный retry, а не бесконечный timeout.

## Область применимости

- Механизмы и lock modes соответствуют PostgreSQL 18.4, проверено 2026-07-18.
- Термин row lock ниже относится к logical tuple conflict. Table lock modes с `ROW` в имени, например `ROW EXCLUSIVE`, остаются table-level; названия исторические.
- Predicate `SIReadLock` Serializable не блокирует writers и не участвует в deadlocks. Он записывает read/write dependencies для SSI.
- Вне scope: lightweight locks/spinlocks внутри backend, advisory-lock protocols между независимыми ресурсами и distributed deadlocks.
- Двухсессионный пример не исполнялся локально; ожидаемый deadlock подтверждён PostgreSQL documentation.

## Ментальная модель

MVCC отвечает «какую версию можно видеть», lock manager отвечает «кто сейчас имеет право конфликтующим образом менять объект». Это два слоя, а не альтернативы.

Каждая heap row version имеет `xmin` inserting transaction и `xmax`, связанный с deletion/update. Snapshot содержит границы и active transaction IDs; visibility rules решают, считать ли version committed и видимой. `UPDATE` обычно создаёт новую version, а старая остаётся для snapshots, которым она ещё нужна.

## Как устроено

### MVCC и cleanup

Обычный `SELECT` получает snapshot и читает подходящую visible version без row lock, конфликтующего с writer. Concurrent update создаёт новую version; старый reader продолжает видеть прежнюю. Это снижает reader/writer contention, но versions занимают место.

`VACUUM` удаляет dead tuples, когда ни один допустимый snapshot их больше не увидит, и поддерживает visibility map/freeze. Долго живущая transaction тормозит cleanup, если удерживает старый snapshot или XID horizon: например, на Repeatable Read/Serializable, через открытый cursor/exported snapshot либо после получения XID. `idle in transaction` сохраняет transaction-level locks, но read-only Read Committed session между statements без удерживаемого snapshot/XID не обязательно блокирует vacuum horizon.

`ctid` указывает физическое место конкретной version и меняется при update или перемещении. Он не служит logical key. `xmin` описывает creating transaction ID row version; из-за 32-bit wrap и maintenance на него не стоит опирать долгоживущий application identity.

### Table и row locks

Любой query берёт table-level lock. Обычный `SELECT` получает `ACCESS SHARE`; только `ACCESS EXCLUSIVE` блокирует такое чтение. DML получает `ROW EXCLUSIVE`. `CREATE INDEX` без `CONCURRENTLY` получает `SHARE` и блокирует writes; concurrent build использует более слабый режим с дополнительными phases/caveats.

Row-level strengths идут от `FOR KEY SHARE` и `FOR SHARE` к `FOR NO KEY UPDATE` и `FOR UPDATE`. Они различаются тем, какие concurrent changes блокируют. Locks обычно удерживаются до transaction end; rollback к savepoint освобождает locks, полученные после savepoint.

Writer, встретивший concurrent updated row, ждёт. После исхода owner он либо продолжает с подходящей current version по правилам Read Committed, либо получает serialization failure на Repeatable Read/Serializable.

### Deadlock detection

Lock wait сам по себе нормален: owner commit, waiter продолжает. Для проверки deadlock PostgreSQL ждёт `deadlock_timeout` (default 1 second в PostgreSQL 18.4), поскольку построение/check wait graph не бесплатно. Найдя cycle, server aborts одну involved transaction с `deadlock_detected`; её locks освобождаются, остальные продолжают.

Порядок locks должен следовать стабильному total order: например, account IDs по возрастанию. Если заранее неизвестен набор, сначала вычисляют/sort keys без locks, затем блокируют в этом порядке с повторной проверкой assumptions. `lock_timeout` ограничивает любое ожидание и даёт другую ошибку; он не предотвращает cycle.

### Наблюдаемость

`pg_stat_activity.wait_event_type = 'Lock'` показывает waiter. `pg_locks` перечисляет granted/requested locks, а `pg_blocking_pids(pid)` находит blockers. Row locks хранятся в tuple metadata и обычно не показаны как отдельные строки `pg_locks`; waiter часто виден через ожидание transaction ID владельца. Диагностика должна сохранять query, transaction age, application name и lock target. Blocker часто выглядит idle: он уже выполнил statement, но не commit.

## Пример или трассировка

Две transactions обновляют accounts в разном порядке:

```sql
CREATE TABLE account (
    account_id integer PRIMARY KEY,
    balance integer NOT NULL
);
INSERT INTO account VALUES (1, 100), (2, 100);
```

```text
Session T1                                      Session T2
BEGIN;                                          BEGIN;
UPDATE account SET balance=balance-10           UPDATE account SET balance=balance-20
WHERE account_id=1;                             WHERE account_id=2;
-- T1 holds row 1                               -- T2 holds row 2

UPDATE account SET balance=balance+10           UPDATE account SET balance=balance+20
WHERE account_id=2;  -- waits for T2            WHERE account_id=1;  -- waits for T1
```

После `deadlock_timeout` PostgreSQL обнаруживает cycle. Одна session получает:

```text
ERROR: deadlock detected
```

Её transaction надо `ROLLBACK`; другая получает освободившийся lock и может commit. Какая session станет victim, не входит в application contract.

Исправленный protocol всегда блокирует/обновляет меньший `account_id` первым. Для transfer из `2` в `1` business direction не задаёт lock order: код сортирует IDs, берёт locks `1`, затем `2`, а суммы применяет по исходным ролям. Cycle исчезает, хотя ожидание при contention остаётся.

## Trade-offs

- MVCC даёт nonblocking ordinary reads и stable snapshots. Цена: новые row versions, vacuum, visibility metadata и bloat при долгих transactions.
- Pessimistic row lock обнаруживает conflict до дорогой работы и сериализует hot item. Wait time и deadlock surface растут, а throughput hot key ограничен одной критической секцией.
- Table lock проще доказывает широкое правило. Он блокирует несвязанные rows и резко снижает concurrency.
- Более короткий `deadlock_timeout` раньше сообщает cycle, но чаще запускает дорогую проверку на обычных waits. `lock_timeout` ограничивает latency, но способен abort полезную работу без deadlock.
- `SKIP LOCKED` повышает throughput queue consumers. Он намеренно возвращает inconsistent subset и не подходит для общего чтения или проверки invariant.

## Типичные ошибки

- Неверное предположение: MVCC означает отсутствие locks. Симптом: UPDATE ждёт, DDL зависает, foreign-key delete блокируется. Причина: snapshots убирают reader/writer conflict, но writers и schema operations всё равно конфликтуют. Исправление: анализировать оба слоя и lock modes конкретных commands.
- Неверное предположение: `ROW EXCLUSIVE` блокирует отдельные rows. Симптом: неверно читают `pg_locks` и прогнозируют конфликт. Причина: это table-level mode с историческим именем. Исправление: использовать conflict matrix документации и отдельно учитывать tuple locks/waits на transaction IDs.
- Неверное предположение: timeout лечит deadlock. Симптом: операции периодически abort после долгого ожидания. Причина: cycle остаётся, меняется лишь время обнаружения. Исправление: единый lock order и retry всей transaction.
- Неверное предположение: lock освобождается после statement. Симптом: следующая session ждёт, пока первая делает remote call. Причина: transaction-level locks обычно живут до commit/rollback. Исправление: убрать внешнюю работу из boundary и закрывать transaction сразу.
- Неверное предположение: `SELECT FOR UPDATE` всегда блокирует нужный invariant. Симптом: concurrent insert обходит проверку отсутствия строки. Причина: нельзя row-lock строку, которой нет. Исправление: constraint, guard row, stronger table protocol или Serializable predicate protection.
- Неверное предположение: долгая read-only transaction с удерживаемым snapshot бесплатна. Симптом: растёт bloat и vacuum не продвигает cleanup. Причина: old snapshot сохраняет потенциально видимые versions. Исправление: ограничить transaction age, использовать подходящий read replica/exported snapshot protocol и мониторить oldest xmin.

## Когда применять

Полагайтесь на MVCC для обычного чтения и выбирайте explicit locks для конкретного conflict protocol. До добавления `FOR UPDATE` назовите точный lock target, полный набор contenders и единый order. Если target не существует или invariant описывает predicate, [[30 Данные/Уровни изоляции транзакций|Serializable]] часто проще доказать.

В production мониторьте transaction age, lock waits и blockers; отдельно считайте deadlocks. Deadlock error ожидаема в конкурентной системе и должна иметь safe retry. Устойчивый рост таких ошибок указывает на inconsistent order или слишком широкую boundary.

## Источники

- [MVCC Introduction](https://www.postgresql.org/docs/18/mvcc-intro.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Explicit Locking](https://www.postgresql.org/docs/18/explicit-locking.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [System Columns](https://www.postgresql.org/docs/18/ddl-system-columns.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Routine Vacuuming](https://www.postgresql.org/docs/18/routine-vacuuming.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Lock Management](https://www.postgresql.org/docs/18/runtime-config-locks.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Viewing Locks](https://www.postgresql.org/docs/18/monitoring-locks.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [pg_locks](https://www.postgresql.org/docs/18/view-pg-locks.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Lock manager README](https://github.com/postgres/postgres/blob/REL_18_4/src/backend/storage/lmgr/README) — postgres/postgres, tag `REL_18_4`, проверено 2026-07-18.
- [SSI README](https://github.com/postgres/postgres/blob/REL_18_4/src/backend/storage/lmgr/README-SSI) — postgres/postgres, tag `REL_18_4`, проверено 2026-07-18.
- [PostgreSQL 18.4 release notes](https://www.postgresql.org/docs/18/release-18-4.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, release date 2026-05-14, проверено 2026-07-18.
