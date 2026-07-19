---
aliases:
  - Write-ahead log
  - WAL
  - Журнал предзаписи
tags:
  - область/данные
  - тема/внутреннее-устройство-хранилищ
  - механизм/wal
статус: проверено
---

# Write-ahead log (WAL)

## TL;DR

- **Write-ahead logging (WAL)** сначала записывает описание изменения в последовательный журнал и только потом разрешает соответствующей странице данных стать durable.
- У WAL два разных порядка: WAL изменения должен быть durable раньше dirty data page, а WAL commit должен быть durable раньше подтверждения синхронного commit клиенту.
- `write()` обычно лишь копирует данные в page cache ОС. Граница durability появляется после корректного flush (`fsync`, `fdatasync` или эквивалент), если файловая система и устройство честно выполняют контракт.
- WAL позволяет не синхронизировать все data pages на каждый commit: после crash их состояние восстанавливается redo. Общая цена нескольких commits уменьшается через group commit.
- Physical, logical и physiological logging описывают разные уровни записи. PostgreSQL WAL — storage-level записи resource managers с full-page images при необходимости; logical decoding строит логическое представление поверх WAL, но не превращает базовый журнал в «чисто logical».

## Область и версии

Общие правила сопоставлены с ARIES. Конкретные детали приведены для PostgreSQL 18.4 и исходного кода `REL_18_4`, commit `f5cc81719e6da4cbdb1f797c48b693e91018153a`; дополнительно показана роль WAL в RocksDB 11.1.1, tag `v11.1.1`, commit `6cdeb9d9d0630763327f512e6255cab33f6834e7`. Проверено 2026-07-18.

WAL решает локальное восстановление после сбоя. Он сам по себе не обеспечивает consensus, синхронную репликацию или долговременный backup.

## Ментальная модель: два независимых обещания порядка

Пусть изменение страницы `P` описано WAL-записью до LSN `800`, а commit транзакции — записью до LSN `920`.

### Правило WAL-before-data

```text
durable(WAL through pageLSN(P))
                раньше
durable(new contents of P)
```

Если dirty page попадёт на носитель раньше журнала, crash может оставить новое содержимое без инструкции, позволяющей объяснить или восстановить его. Поэтому buffer manager перед записью страницы проверяет её LSN и сначала доводит WAL как минимум до этой позиции.

### Правило commit-before-ack

```text
durable(WAL through commitLSN(T))
                раньше
success returned for synchronous commit T
```

Это уже клиентское обещание durability. Оно не требует немедленно записывать страницы таблиц и индексов: после crash redo построит их из WAL. Асинхронный commit сознательно ослабляет второе правило, но не первое.

Эти два правила нельзя склеивать. Страница с ещё не подтверждённым изменением может быть записана при **steal**-политике; commit может завершиться без записи data pages при **no-force**-политике. WAL/recovery должны корректно обработать оба случая.

## Что именно записывает журнал

### Physical logging

Запись содержит адрес страницы и изменённые байты либо полный образ страницы. Redo прост и тесно привязан к физическому layout. Полный образ дорог по объёму, зато помогает восстановиться после torn page.

### Logical logging

Запись описывает операцию уровня данных: например, «вставить ключ `k` со значением `v`». Она меньше зависит от расположения страниц, но повторение операции должно учитывать состояние структуры, concurrency и идемпотентность.

### Physiological logging

ARIES сочетает физическую идентификацию страницы с логической операцией внутри неё. У страницы есть `pageLSN`, recovery сравнивает его с LSN записи и не повторяет уже применённое изменение. ARIES выполняет analysis, повторяет историю через redo, затем отменяет незавершённые транзакции, фиксируя Compensation Log Records (CLR).

PostgreSQL не следует ARIES буквально. Его WAL records понимают resource managers конкретных структур, а crash recovery преимущественно выполняет redo; физический UNDO незавершённых MVCC-изменений не нужен, потому что видимость кортежей определяется состоянием транзакций. Называть любой WAL «ARIES» только из-за write-ahead правила нельзя.

### PostgreSQL: records и full-page images

В PostgreSQL WAL record может ссылаться на несколько blocks и содержать block-specific data. При `full_page_writes=on` после checkpoint первая WAL-запись, изменяющая страницу, включает её полный образ, если прежний page LSN не новее redo point. После восстановления образ защищает от частично записанной страницы; последующие изменения до следующего checkpoint обычно могут журналировать более компактные данные.

Logical decoding читает storage-level WAL и переводит изменения в логический поток, пригодный для репликации. Для этого нужны достаточные сведения в WAL и правила идентификации строк, но сам recovery journal остаётся ориентирован на внутренние структуры PostgreSQL.

## Write, flush и durable — разные состояния

Упрощённая цепочка выглядит так:

```text
process buffer
  → write()/pwrite()
OS page cache
  → fsync()/fdatasync()/эквивалент
controller/device cache
  → flush/barrier, если требуется
durable media
```

Возврат из `write()` доказывает лишь, что ядро приняло байты. Точная сила `fsync` зависит от OS, filesystem, mount options, контроллера и наличия защищённого power-loss cache. Поэтому [[30 Данные/Durability и fsync|durability и fsync]] нужно проверять на всей цепочке, а не по названию системного вызова.

## Commit, group commit и checkpoints

Один durable flush на каждую транзакцию ограничивает throughput latency устройства. **Group commit** позволяет нескольким транзакциям дождаться одного flush до максимального требуемого LSN. Это уменьшает число flush, не ослабляя обещание: каждая транзакция получает успех только когда её commit record входит в durable prefix.

**Checkpoint** фиксирует точку, от которой recovery должен гарантированно уметь начать redo, и постепенно записывает dirty pages. Он ограничивает время recovery и объём удерживаемого WAL, но не заменяет WAL-before-data. Слишком частые checkpoints увеличивают data I/O и число full-page images; слишком редкие требуют больше WAL и более долгого recovery.

В PostgreSQL 18.4 при `synchronous_commit=off` backend может вернуть успех до локального WAL flush. Документация ограничивает риск потери последних подтверждённых транзакций окном до трёх `wal_writer_delay`; состояние базы при этом остаётся согласованным. Это не эквивалент `fsync=off`: отключение `fsync` после сбоя может привести к невосстановимому corruption.

## Сквозной crash-сценарий

Начальное состояние:

```text
data page P: pageLSN=700, balance=100
```

Транзакция уменьшает balance до `90`:

1. Строится update record с LSN `800`; страница в buffer pool получает `pageLSN=800`.
2. Формируется commit record, заканчивающийся LSN `920`.
3. `write()` отправляет WAL до `920` в OS page cache — это ещё не durability.
4. WAL flush делает prefix до `920` durable.
5. Клиент получает успешный synchronous commit. Страница `P` всё ещё может быть только в памяти.
6. Происходит power loss.
7. Recovery видит durable commit и redo record `800`; если persisted `P.pageLSN < 800`, изменение повторяется.

Наблюдаемый результат: после recovery `balance=90`, хотя data page не была синхронизирована до commit.

Другие точки сбоя:

- crash после шага 3, но до шага 4: при синхронном commit успех ещё не возвращён; транзакция может исчезнуть;
- если успех был возвращён асинхронно после шага 3, транзакция тоже может исчезнуть, но WAL-before-data сохраняет структурную согласованность;
- попытка записать `P` до durable WAL `800` должна сначала инициировать WAL flush; иначе нарушается главный инвариант.

## Trade-offs и альтернативы

### WAL против shadow paging / copy-on-write

WAL меняет страницы на месте, а журнал использует для recovery. Shadow paging и copy-on-write создают новые страницы и атомарно переключают корневую ссылку/метаданные. COW упрощает доступ к старым версиям и избегает redo для уже опубликованного дерева, но может увеличить fragmentation, write amplification и сложность освобождения страниц. WAL требует сложного recovery, зато хорошо сочетается с buffer pool и локальными страничными обновлениями.

### Physical против logical

Physical/physiological WAL обычно даёт точное и быстрое локальное redo той же версии layout. Logical log лучше переносится между схемами или физическими представлениями и удобен для CDC, но может не содержать всех деталей восстановления внутренних страниц. Многие системы используют разные журналы или преобразуют один уровень в другой.

### Sync на каждый commit против group/async commit

- sync на каждый commit минимизирует окно потери, но ограничен flush latency;
- group commit сохраняет гарантию и распределяет один flush между транзакциями;
- async commit снижает latency ценой явно ограниченной потери уже подтверждённых данных;
- `fsync=off` снимает не только клиентскую гарантию, но и предпосылки корректного recovery.

## Типичные ошибки

### Приравнивать `write()` к durability

- **Неверное предположение:** WAL уже на диске, раз системный вызов вернул успех.
- **Симптом:** подтверждённые транзакции пропадают после power loss.
- **Причина:** байты оставались в volatile page/device cache.
- **Исправление:** определить durable boundary и вызвать поддерживаемый flush до ответа.

### Синхронизировать data page раньше WAL

- **Неверное предположение:** порядок двух файлов неважен.
- **Симптом:** recovery видит частично новое состояние без соответствующей записи журнала.
- **Причина:** нарушен WAL-before-data.
- **Исправление:** сравнивать pageLSN с durable WAL LSN и принудительно flush WAL prefix первым.

### Считать checkpoint полной копией базы

- **Неверное предположение:** после checkpoint старый WAL можно удалить независимо от dirty pages и репликации.
- **Симптом:** recovery или replica не находит требуемый segment.
- **Причина:** checkpoint — начало допустимого redo и координационный протокол, а не мгновенный снимок всех страниц.
- **Исправление:** удалять WAL только по правилам recovery, archiving и replica retention конкретного движка.

### Называть WAL исключительно logical или physical

- **Неверное предположение:** один ярлык описывает весь журнал продукта.
- **Симптом:** ошибочная оценка переносимости, объёма и recovery semantics.
- **Причина:** records разных resource managers могут сочетать page identity, deltas и full-page images; CDC строится отдельным decoding layer.
- **Исправление:** изучить формат записей и потребителей WAL конкретной версии.

## Когда применять

WAL нужен движку, который изменяет durable структуры неатомарно и должен быстро подтверждать commit без синхронной записи всех data pages. При проектировании проверьте:

1. какой exact prefix WAL должен быть durable перед page write и commit ack;
2. где хранится `pageLSN` или эквивалент версии;
3. умеет ли redo безопасно повторять запись;
4. нужен ли UNDO и как представлены незавершённые транзакции;
5. что гарантируют checkpoint, full-page images и group commit;
6. как тестируются torn writes, lost flush и crash в каждой точке протокола.

## Источники

- [ARIES: A Transaction Recovery Method Supporting Fine-Granularity Locking and Partial Rollbacks Using Write-Ahead Logging](https://research.ibm.com/publications/aries-a-transaction-recovery-method-supporting-fine-granularity-locking-and-partial-rollbacks-using-write-ahead-logging) — IBM Research, ACM TODS 17(1), DOI `10.1145/128765.128770`, 1992, проверено 2026-07-18.
- [Write-Ahead Logging](https://www.postgresql.org/docs/18/wal-intro.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Asynchronous Commit](https://www.postgresql.org/docs/18/wal-async-commit.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [WAL Configuration](https://www.postgresql.org/docs/18/wal-configuration.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [WAL Internals](https://www.postgresql.org/docs/18/wal-internals.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Logical Decoding Concepts](https://www.postgresql.org/docs/18/logicaldecoding-explanation.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Формирование WAL records и full-page images](https://github.com/postgres/postgres/blob/f5cc81719e6da4cbdb1f797c48b693e91018153a/src/backend/access/transam/xloginsert.c#L533-L760) — PostgreSQL, tag `REL_18_4`, commit `f5cc81719e6da4cbdb1f797c48b693e91018153a`, проверено 2026-07-18.
- [Write path RocksDB](https://github.com/facebook/rocksdb/blob/6cdeb9d9d0630763327f512e6255cab33f6834e7/db/db_impl/db_impl_write.cc#L760-L880) — RocksDB, tag `v11.1.1`, commit `6cdeb9d9d0630763327f512e6255cab33f6834e7`, проверено 2026-07-18.
