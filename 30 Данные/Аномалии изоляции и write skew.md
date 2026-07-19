---
aliases:
  - Isolation anomalies
  - Dirty read
  - Non-repeatable read
  - Phantom read
  - Write skew
tags:
  - область/данные
  - тема/транзакции
  - механизм/аномалии
статус: проверено
---

# Аномалии изоляции и write skew

## TL;DR

Dirty read читает uncommitted write, non-repeatable read повторно получает другое значение той же строки, phantom read повторяет predicate query и получает другой набор rows. Write skew устроен глубже: две transactions читают общий invariant, пишут разные rows и обе commit, хотя совместный результат не соответствует ни одному serial order.

Три classical phenomena не полностью характеризуют isolation. PostgreSQL Repeatable Read предотвращает все три, но допускает write skew. Для защиты нужен Serializable SSI либо explicit protocol, который заставляет contenders конфликтовать на общем lock target.

## Область применимости

- Определения classical phenomena сопоставлены с SQL и работой Berenson et al.; serialization graph terminology опирается на Adya.
- Примеры реализации относятся к PostgreSQL 18.4. Dirty read в нём невозможен на любом доступном уровне; Repeatable Read реализует Snapshot Isolation.
- Write skew ниже требует, чтобы transactions изменяли разные rows. Если обе пишут одну row version, PostgreSQL обнаружит write/write conflict, и это другой сценарий.
- Вне scope: distributed consistency anomalies, replica lag, read-your-writes между sessions и strict serializability.
- Двухсессионный SQL не исполнялся локально; финальные состояния и SSI abort сверены с документацией и PostgreSQL SSI paper.

## Ментальная модель

История (history) чередует операции transactions. Serial history выполняет одну transaction целиком, затем другую. Serializable history может быть конкурентной физически, но её effect совпадает с некоторым serial order.

Аномалия появляется не из-за «старых данных» вообще, а из-за цикла зависимостей. В write skew каждая transaction читает значение, которое другая затем меняет. Получаются две направленные read/write anti-dependencies; ни одну transaction нельзя поставить первой без изменения прочитанного результата.

## Как устроено

### Classical phenomena

**Dirty read**: `T1` пишет `x`, `T2` читает новое `x` до commit `T1`. Если `T1` aborts, `T2` уже приняла решение по несуществовавшему committed state.

**Non-repeatable read**: `T1` читает row `x`, `T2` меняет и commits `x`, повторное чтение `T1` видит другое значение. Это свойство двух reads одной logical row.

**Phantom read**: `T1` повторяет predicate query, а concurrent commit добавил, удалил или изменил membership rows, поэтому result set изменился. Блокировка уже найденных rows не защищает gap/predicate, где новая row ещё отсутствует.

**Dirty write**, хотя его нет в исходной тройке SQL-92 phenomena, означает overwrite uncommitted write другой transaction. Такое поведение ломает recovery и multi-object invariants; PostgreSQL не разрешает concurrent writers молча перезаписывать одну row version.

### Почему phenomena недостаточно

Berenson et al. показали, что ambiguous broad/narrow interpretations SQL-92 phenomena не описывают ряд реальных isolation models. Отсутствие dirty/non-repeatable/phantom reads не доказывает serializability: история может содержать dependency cycle другого вида.

Write skew типичен для Snapshot Isolation:

1. `T1` и `T2` получают один committed snapshot.
2. Обе проверяют aggregate/predicate invariant.
3. `T1` меняет row A, `T2` меняет row B.
4. Write sets не пересекаются, поэтому first-committer-wins check не видит write/write conflict.
5. Обе commit, а общий invariant нарушен.

Это не lost update. При lost update две operations логически меняют одно значение и одна затирает вклад другой. При write skew обе записи сохраняются; ошибка возникает из их комбинации.

### Как PostgreSQL предотвращает аномалии

Read Committed запрещает dirty reads, но допускает changing snapshots. Repeatable Read фиксирует snapshot и aborts update row, изменённой после snapshot, однако разные rows не конфликтуют. Serializable добавляет nonblocking predicate `SIReadLock` и отслеживает read/write dependencies. Dangerous structure приводит к `SQLSTATE 40001`; приложение повторяет transaction.

Explicit locking работает, если invariant materialized. Например, обе transactions могут `SELECT ... FOR UPDATE` одну строку `shift`, содержащую policy/counter, или заблокировать все doctor rows в согласованном порядке. Lock только «своего» doctor оставляет write sets раздельными и не лечит skew.

## Пример или трассировка

В смене всегда должен оставаться хотя бы один дежурный врач:

```sql
CREATE TABLE doctor_on_call (
    doctor_id integer PRIMARY KEY,
    on_call boolean NOT NULL
);
INSERT INTO doctor_on_call VALUES (1, true), (2, true);
```

History на PostgreSQL Repeatable Read:

```text
Session T1                                      Session T2
BEGIN ISOLATION LEVEL REPEATABLE READ;          BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM doctor_on_call             SELECT count(*) FROM doctor_on_call
WHERE on_call;  -- 2                            WHERE on_call;  -- 2

UPDATE doctor_on_call                           UPDATE doctor_on_call
SET on_call = false WHERE doctor_id = 1;        SET on_call = false WHERE doctor_id = 2;

COMMIT;                                         COMMIT;
```

Обе transactions меняют разные rows и успешно commit. Финальный запрос возвращает `count = 0`, invariant нарушен. Ни один serial order не дал бы тот же результат, если каждая transaction снимает своего врача только после чтения `count > 1`: вторая по serial order увидела бы `1` и отказалась.

Если заменить уровень обеих transactions на `SERIALIZABLE`, PostgreSQL отслеживает две read/write dependencies. Одна transaction commit, вторая на update/commit получает `could not serialize access due to read/write dependencies among transactions` с `40001`. После полного retry она видит `count = 1` и не снимает последнего врача.

Альтернатива: обе transactions сначала блокируют общий shift row или весь набор doctors `FOR UPDATE` в одном порядке. Это превращает логический predicate conflict в физический lock conflict ценой ожидания.

## Trade-offs

- Serializable SSI защищает произвольные прочитанные predicates без ручного перечисления lock targets. Tracking потребляет память, Seq Scan даёт coarse relation-level SIReadLock, а conflicts вызывают retries.
- Explicit row locks aborts заменяют ожиданием и подходят при ясном общем объекте. Неполный lock set пропускает anomaly, широкий снижает concurrency и создаёт deadlock risk.
- Materialized counter или guard row упрощает conflict. Он становится hot key и требует доказательства, что каждый writer обновляет его атомарно.
- Unique/exclusion constraint дешевле общего protocol, когда invariant выражается конфликтом keys/ranges. Aggregate «минимум один остаётся» обычным row-level constraint не выразить.
- Repeatable Read удобен для стабильного report. Для invariant-preserving writes его надо дополнять, если решение зависит от нескольких rows или отсутствия row.

## Типичные ошибки

- Неверное предположение: нет dirty, non-repeatable и phantom reads, значит уровень Serializable. Симптом: write skew commit без ошибок. Причина: classical phenomena не покрывают dependency cycles. Исправление: анализировать concrete history и serializability, использовать SSI или complete locking protocol.
- Неверное предположение: write skew равен lost update. Симптом: ищут version column одной строки, хотя transactions пишут разные rows. Причина: перепутаны write/write и read/write conflicts. Исправление: выписать read set, write set и invariant для каждой transaction.
- Неверное предположение: `FOR UPDATE` на найденных rows защищает отсутствие новой row. Симптом: concurrent insert создаёт duplicate booking или превышает limit. Причина: gap/predicate не materialized lock target. Исправление: unique/exclusion constraint, guard row, table/range protocol либо Serializable.
- Неверное предположение: retry `40001` можно делать без idempotency. Симптом: внешний charge или письмо выполняется дважды. Причина: DB transaction abort не отменил внешний effect. Исправление: вынести effect через outbox или дать ему стабильный idempotency key.
- Неверное предположение: invariant можно проверить после commit и «починить позже». Симптом: другой reader успевает принять решение по недопустимому state. Причина: consistency boundary смещена за наблюдаемость. Исправление: предотвращать commit либо явно проектировать eventual invariant с quarantine и reconciliation.

## Когда применять

Для каждой business rule постройте минимальную историю из двух transactions. Выпишите initial state, reads, writes, commit order и final state. Если final state не получается ни при одном serial order, найден serialization anomaly.

Используйте database constraint, если rule выражается локально. Для predicate-based multi-row rule выбирайте Serializable с общим retry layer или материализуйте conflict и блокируйте его. Тестируйте orchestration двумя connections; обычный параллельный тест без barriers редко воспроизводит нужный порядок.

## Источники

- [A Critique of ANSI SQL Isolation Levels](https://doi.org/10.1145/223784.223785) — ACM, Hal Berenson et al., SIGMOD 1995, проверено 2026-07-18.
- [Weak Consistency: A Generalized Theory and Optimistic Implementations for Distributed Transactions](https://pmg.csail.mit.edu/papers/adya-phd.pdf) — MIT, Atul Adya, PhD thesis, 1999, проверено 2026-07-18.
- [Transaction Isolation](https://www.postgresql.org/docs/18/transaction-iso.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Serializable Snapshot Isolation in PostgreSQL](https://arxiv.org/abs/1208.4179) — PVLDB / arXiv, Dan R. K. Ports, Kevin Grittner, 5(12), 2012, проверено 2026-07-18.
- [Data Consistency Checks at the Application Level](https://www.postgresql.org/docs/18/applevel-consistency.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [PostgreSQL 18.4 release notes](https://www.postgresql.org/docs/18/release-18-4.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, release date 2026-05-14, проверено 2026-07-18.
