---
aliases:
  - CourseHunter 6593 — lock-free и транзакции
tags:
  - источник/coursehunter
  - язык/go
  - тема/concurrency/lock-free
  - тема/базы-данных/транзакции
статус: проверено
---

# Lock-free, акторы и транзакции

## TL;DR

Чем тоньше синхронизация, тем меньше потенциальный contention и тем дороже доказательство корректности. Lock-free не означает «без ожидания», «быстрее mutex» или «просто заменить запись на CAS». Нужно доказать linearization point, progress guarantee, memory ordering и безопасное освобождение памяти.

2PL и MVCC решают похожую задачу на уровне транзакций: получить допустимый concurrent history. 2PL координирует операции locks, MVCC — видимостью версий и проверкой конфликтов. Конкретный уровень изоляции нельзя вывести только из слов «2PL» или «MVCC».

## Шардирование

Один mutex на всю map создаёт общий serialization point. Sharded map делит keyspace: hash выбирает shard, каждый shard хранит собственные map и lock.

![[90 Вложения/CurseHunter/6593/Кадры/032-sharded-map.jpg|640]]

Интервьюер ждёт обсуждение:

- число shards и распределение hash;
- hot key: шардирование не делит один популярный ключ;
- операции над несколькими keys требуют порядка locks либо отдельного протокола;
- resize количества shards означает миграцию и изменение mapping;
- aggregate operation (`Len`, snapshot, iteration) не бесплатна и может требовать locks всех shards;
- padding может понадобиться против false sharing соседних locks/counters.

## RCU и immutable snapshot

Read-copy-update разделяет read path и update path:

1. readers берут опубликованный immutable snapshot;
2. writer копирует/строит новую версию;
3. атомарно публикует pointer;
4. старая версия освобождается только после grace period, когда прежние readers её больше не используют.

В Go GC упрощает reclamation обычных heap objects, но не доказывает логическую immutable semantics. Если writer меняет map внутри уже опубликованного snapshot, возникает race. RCU хорош при частых reads и редких, допустимо дорогих writes; при большой структуре copy cost и allocation pressure могут перевесить lock.

## Четыре уровня синхронизации linked set

Курс последовательно усложняет sorted set:

### Coarse-grained

Один lock защищает весь list. Доказательство простое, concurrency низкая.

### Fine-grained

Lock-coupling удерживает соседние nodes. Нужно единообразно брать locks по направлению list, повторно проверять links и освобождать в каждом error path. Ошибка порядка даёт deadlock.

### Optimistic

Traversal проходит без долгого удержания locks, затем захватывает нужные nodes и проверяет, что найденный fragment всё ещё достижим и не изменён. Validation failure означает retry.

### Lock-free

Состояние меняется CAS-loop. Logical deletion часто отделяют от physical unlink. Linearizability и reclamation становятся центральной частью решения.

Trade-off формулируют так: coarse lock выигрывает простотой и предсказуемостью; fine/optimistic — при измеренном contention и подходящем workload; lock-free — когда progress property оправдывает существенно более сложный proof и сопровождение.

## Progress guarantees

- **Obstruction-free:** операция завершится, если достаточно долго работает одна.
- **Lock-free:** система в целом делает progress; отдельная goroutine может starvation.
- **Wait-free:** каждая операция завершится за ограниченное число собственных шагов.

Код с mutex не считается lock-free, даже если critical section короткая. CAS-loop тоже не даёт lock-free автоматически, если внутри он ждёт lock или внешний I/O.

## Стек Трайбера и ABA

Treiber stack публикует новый head через CAS. Linearization point успешного `CAS(head, new)`; `Pop` читает head/next и пытается заменить head на next.

ABA:

1. G1 прочитала pointer `A`;
2. G2 сняла `A`, изменила структуру и позже по тому же адресу появился другой node;
3. pointer снова равен `A`, поэтому CAS G1 проходит, хотя логическое состояние уже другое.

![[90 Вложения/CurseHunter/6593/Кадры/031-aba.jpg|720]]

Решения зависят от среды:

- tagged/versioned pointer увеличивает state, сравниваемый CAS;
- hazard pointer объявляет object, который reader ещё может использовать;
- epoch-based reclamation откладывает reuse до завершения старых readers;
- GC уменьшает риск reuse освобождённого Go object, но unsafe pointers, pools, off-heap память и сам алгоритм всё равно требуют отдельного доказательства.

## Очередь Michael–Scott

Очередь хранит dummy node, атомарные head и tail. Enqueue может помочь продвинуть отставший tail; dequeue может помочь tail, если видит промежуточное состояние. На интервью важны не строки pseudocode, а ответы:

- где linearization point enqueue/dequeue;
- зачем dummy node;
- почему tail может отставать и почему helping безопасен;
- как отличить empty от промежуточного состояния;
- как решена reclamation удалённых nodes.

## Actor model

Actor инкапсулирует mutable state и последовательно обрабатывает mailbox; взаимодействие идёт messages. Это уменьшает shared-memory races внутри actor, но не отменяет:

- bounded mailbox и backpressure;
- delivery semantics и дубликаты;
- supervision/restart;
- порядок сообщений между разными senders;
- blocking handler, который останавливает весь actor;
- shutdown и drain mailbox.

![[90 Вложения/CurseHunter/6593/Кадры/035-actor.jpg|720]]

Задача курса — реализовать actor manager по address и executor. Senior+ продолжение: определить, что происходит при неизвестном address, full mailbox, panic executor и конкурентном удалении actor.

## Транзакции и аномалии

Перед выбором алгоритма называют требуемые свойства и допустимые аномалии:

- dirty read;
- non-repeatable read;
- phantom;
- lost update;
- write skew;
- serialization failure и retry.

`ACID` не говорит, какой именно concurrent history разрешён; это задают isolation level и реализация.

## Two-phase locking, 2PL

В growing phase транзакция приобретает locks, в shrinking phase освобождает и уже не приобретает новые. Strict 2PL удерживает write locks до commit/rollback, упрощая recovery и предотвращая чтение незакоммиченного.

Плюсы:

- serializable schedule при корректном protocol;
- понятная блокировка конфликтующих операций;
- нет хранения множества старых versions только ради readers.

Цена:

- readers/writers могут блокировать друг друга;
- deadlock и необходимость detection/timeout/ordering;
- convoy и long transaction удерживают ресурсы;
- lock table и granularity сами становятся частью дизайна.

Курс показывает timeout и wait-for graph как варианты реакции. Практическое правило — единый порядок захвата там, где он возможен, короткие transactions и retry transaction, выбранной victim detector-ом.

![[90 Вложения/CurseHunter/6593/Кадры/037-2pl-deadlocks.jpg|640]]

## MVCC

MVCC хранит несколько versions и выбирает видимую по snapshot/transaction metadata. Reader обычно не блокирует writer только из-за чтения старой committed version, но write-write conflicts и служебные locks остаются.

![[90 Вложения/CurseHunter/6593/Кадры/038-mvcc.jpg|720]]

Упрощение курса «персональная копия данных» нужно заменить точной моделью: snapshot задаёт набор видимых versions; физически вся база для транзакции не копируется.

Snapshot isolation предотвращает часть аномалий, но допускает write skew: две transactions читают общий invariant, меняют разные rows и обе commit. Serializable MVCC требует дополнительного conflict detection/SSI или иной сериализации.

Стоимость MVCC:

- хранение versions;
- vacuum/garbage collection;
- transaction ID и snapshot bookkeeping;
- проверка visibility;
- long-lived snapshots мешают очистке;
- abort/retry при конфликтах.

## 2PL или MVCC

Фраза курса «2PL для пересекающихся, MVCC для непересекающихся данных» — только эвристика. На практике спрашивают:

- конфликтуют reads с writes или главным образом writes между собой;
- нужен ли serializable результат;
- сколько живут transactions;
- какова доля reads;
- допустимы ли abort/retry;
- сколько стоят versions и vacuum;
- какие guarantees реально даёт выбранная СУБД.

PostgreSQL, например, использует MVCC и одновременно table/row/predicate locks; это не взаимоисключающие ярлыки уровня всей системы.

## Закон Амдала

Если доля `P` ускоряется в `S` раз, общий speedup:

$$
Speedup = \frac{1}{(1-P) + \frac{P}{S}}
$$

При `P = 0.9` и `S = 10` максимум равен примерно `5.26`, а не `10`. При бесконечном ускорении parallel part предел равен `1/(1-P) = 10`.

![[90 Вложения/CurseHunter/6593/Кадры/039-amdahl.jpg|720]]

Интервью-применение: в последовательную долю входят coordination, serialization, merge, contention и I/O, которое нельзя распараллелить. Сначала измеряют critical path, затем добавляют workers.

## Банк задач

1. Спроектировать sharded map и определить semantics `Len`, iteration и multi-key transaction.
2. Выбрать число shards и разобрать hot-key workload.
3. Опубликовать immutable cache snapshot через `atomic.Pointer`.
4. Найти мутацию map после RCU publication.
5. Реализовать sorted set сначала с coarse, затем fine-grained locks; сравнить proof.
6. Добавить optimistic validation и показать scenario retry.
7. Назвать progress guarantee предложенного CAS-loop.
8. Реализовать Treiber stack и отметить linearization points.
9. Воспроизвести ABA и выбрать reclamation strategy.
10. Объяснить Michael–Scott queue через dummy node и helping.
11. Провести code review actor с unbounded mailbox и blocking handler.
12. Добавить actor shutdown, supervision и backpressure.
13. Для schedule transactions определить dirty/non-repeatable/phantom/lost update/write skew.
14. Реализовать simplified strict 2PL и wait-for graph.
15. Исправить deadlock единым lock order либо transaction retry.
16. Реализовать snapshot visibility поверх versioned keys.
17. Показать write skew под snapshot isolation.
18. Сравнить 2PL и MVCC для read-heavy, hot-row и long-report workload.
19. Посчитать Amdahl speedup при заданной serial fraction.
20. Объяснить, почему 100 workers могут быть медленнее 10 из-за contention и queueing.

## Источники

- [Код уроков 8 и 9](https://github.com/Balun-courses/concurrency_go/tree/47dfb8919653eb9528bd6fa5b4fadc2d38a56598/lessons) — Balun-courses/concurrency_go, commit `47dfb89`, каталоги `8_lesson_sync_algorithms_and_lock_free` и `9_lesson_concurrency_patterns`, проверено 2026-07-19.
- [Package sync/atomic](https://pkg.go.dev/sync/atomic) — Go standard library, Go `1.26.5`, проверено 2026-07-19.
- [PostgreSQL 18: Concurrency Control](https://www.postgresql.org/docs/18/mvcc.html) — PostgreSQL Global Development Group, версия `18`, проверено 2026-07-19.
- [PostgreSQL 18: Explicit Locking](https://www.postgresql.org/docs/18/explicit-locking.html) — PostgreSQL Global Development Group, версия `18`, проверено 2026-07-19.
- [PostgreSQL 18: Transaction Isolation](https://www.postgresql.org/docs/18/transaction-iso.html) — PostgreSQL Global Development Group, версия `18`, проверено 2026-07-19.
- [Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms](https://www.cs.rochester.edu/research/synchronization/pseudocode/queues.html) — Maged M. Michael и Michael L. Scott, 1996, проверено 2026-07-19.
- [Validity of the Single Processor Approach to Achieving Large Scale Computing Capabilities](https://doi.org/10.1145/1465482.1465560) — Gene M. Amdahl, AFIPS 1967, проверено 2026-07-19.
