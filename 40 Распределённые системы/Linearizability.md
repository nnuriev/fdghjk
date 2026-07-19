---
aliases:
  - Linearizability
  - Линеаризуемость
  - Atomic consistency
tags:
  - область/распределённые-системы
  - тема/согласованность
статус: проверено
---

# Linearizability

## TL;DR

Linearizability, или линеаризуемость, требует, чтобы каждая операция выглядела выполненной атомарно в некоторой точке между invocation и response. Завершённые операции и те pending invocations, которым completion добавляет response, складываются в legal sequential history; остальные pending invocations можно отбросить. Порядок непересекающихся операций совпадает с реальным временем: если `A` завершилась до начала `B`, переставить `B` перед `A` нельзя.

Гарантия относится к поведению объекта, а не к физической синхронности реплик. Для неё не нужны глобально синхронизированные часы, но протокол обязан не выдавать результат из состояния, которое нельзя встроить в такой порядок. Linearizability не обещает availability, durability, multi-key transaction или атомарность клиентского `read → compute → write`.

## Область применимости

Основная модель — concurrent history typed object по Herlihy–Wing 1990. Для распределённой реализации использованы atomic register ABD 1995 и replicated log Raft 2014; связь с CAP сверена с Gilbert–Lynch 2002. Проверено 2026-07-18.

Заметка говорит об одной операции объекта. Для транзакций ближайший аналог real-time serial order — strict serializability. Обычная serializability требует эквивалентность некоторому последовательному выполнению транзакций, но может не сохранять их внешний real-time order.

## Ментальная модель

У операции есть интервал:

```text
invocation ---------------- response
                 ^
          linearization point
```

Linearization point — элемент доказательства, а не обязательный timestamp в журнале. Для каждой завершённой операции должна существовать точка внутри её интервала. Если интервалы не пересекаются, их порядок уже задан временем. Если пересекаются, спецификация и возвращённые значения могут допускать несколько порядков.

Проверка истории задаёт два вопроса:

1. Можно ли получить legal sequential history согласно спецификации объекта?
2. Сохранился ли real-time precedence всех непересекающихся операций?

Sequential consistency отвечает только на первый вопрос вместе с program order клиентов. Поэтому она слабее; различия моделей собраны в [[40 Распределённые системы/Strong, eventual, causal и session consistency|заметке о consistency models]].

## Как устроено

### Формальная граница истории

History содержит события invocation и response. Herlihy–Wing разрешают дополнить её ответами для части pending invocations, затем удалить остальные незавершённые операции. Полученная complete history должна быть эквивалентна legal sequential history и сохранять real-time order исходной history.

Отсюда следует неприятное, но практичное правило: timeout оставляет неизвестный исход. Операция без ответа могла линеаризоваться и потерять только response. Клиент не вправе считать её неслучившейся; retry требует стабильного operation ID или [[20 Бэкенд/Ключи идемпотентности и дедупликация запросов|дедупликации]].

Linearizability локальна, то есть compositional: если каждый объект линеаризуем относительно своей sequential specification, их композиция тоже линеаризуема. Это не превращает две отдельные операции над разными объектами в одну атомарную транзакцию.

### Как протокол создаёт допустимый порядок

Один процесс может сериализовать операции lock или atomic primitive. После репликации нужны полномочия и устойчивый порядок:

- leader-based consensus подтверждает запись только после protocol commit; чтение должно доказать, что отвечает актуальный лидер и его состояние включает нужный committed prefix;
- quorum atomic register хранит монотонную logical version; классический ABD read получает версии от большинства, выбирает максимальную и выполняет write-back, чтобы последующие quorum reads пересеклись с этой версией;
- fencing term или epoch ограждает полномочия, только если каждый компонент, принимающий запись, отклоняет устаревший token.

Одного replication factor или условия `R + W > N` мало. Геометрия пересечения, membership, version order и read protocol разобраны в [[30 Данные/Read и write quorums|заметке о кворумах]]. Leader/follower и leaderless границы подтверждения описаны в [[30 Данные/Репликация данных|репликации данных]].

### Чтение сложнее, чем кажется

Записи могут идти через consensus leader, а чтения — с followers. Без проверки версии follower вернёт старое состояние после уже завершённой записи, и система перестанет быть линейризуемой. Безопасный read path обычно делает одно из следующего:

- читает у лидера, чьи полномочия подтверждены текущим quorum/term;
- выполняет quorum или read-index protocol;
- использует lease только при доказанных предпосылках о времени и fencing;
- для follower read сначала получает safe read index/barrier после invocation от актуального leader/quorum, затем ждёт, пока выбранная replica применит этот index; одного session token с ранее известной позицией недостаточно.

Кэш перед линейризуемым хранилищем тоже входит в контракт. Stale cache hit нарушает гарантию, даже если база реализована правильно.

### Чего linearizability не даёт

- **Durability:** linearizability сама по себе не задаёт crash-recovery persistence. Если post-recovery reads входят в тот же заявленный contract, потеря completed write нарушит его; failure scope и durable medium фиксируют отдельно.
- **Availability:** во время partition безопасная сторона может не собрать quorum и остановиться; эту границу объясняет [[40 Распределённые системы/CAP и PACELC|CAP]].
- **Multi-operation atomicity:** два раздельных вызова допускают вмешательство конкурента между ними.
- **Справедливость и latency bound:** safety property запрещает плохие histories, но не обещает, что операция когда-либо завершится.

## Пример или трассировка

Register `x` изначально равен `0`.

### Непересекающиеся операции

```text
t0  A: write(x, 1) invoke
t1  A: write(x, 1) -> OK
t2  B: read(x) invoke
t3  B: read(x) -> 0
```

History не linearizable. Write завершилась до начала read, поэтому real-time order требует `write(1) < read()`. Legal register после такой записи должен вернуть `1`, а не `0`.

### Пересекающиеся операции

```text
t0  A: write(x, 1) invoke
t1  B: read(x) invoke
t2  B: read(x) -> 0
t3  A: write(x, 1) -> OK
```

Здесь интервалы пересекаются. Read можно линеаризовать до write, поэтому ответ `0` допустим. Ответ `1` тоже мог бы быть допустим при обратном порядке linearization points.

### Timeout и неизвестный исход

```text
t0  A: write(x, 2) invoke
t1  client deadline expired; object response не получен
    write остаётся pending в history H
t2  B: read(x) invoke
t3  B: read(x) -> 2
```

Pending write можно дополнить потерянным response и линеаризовать до read. Наблюдаемый `2` доказывает, что считать timeout отменой было бы неверно. Повтор не должен второй раз применять неидемпотентный effect.

## Trade-offs

| Выбор | Выигрыш | Цена |
| --- | --- | --- |
| Linearizable single-object operations | Простая reasoning model, CAS и уникальные решения относительно актуального состояния | Координация, quorum/leader dependency, меньшая partition availability |
| Sequential consistency | Один общий порядок без требования real-time | После завершённой операции другой клиент может наблюдать историю, переставленную относительно wall-clock |
| Causal или session consistency | Локальная latency и сохранение нужных зависимостей без global total order | Нет единственного «последнего» состояния для concurrent operations |
| Stale follower/cache reads | Низкая latency и больше read capacity | Ответ выходит из linearizable contract; нужен явный более слабый режим |

Scope можно сузить до ключа или shard, но тогда cross-key invariant не защищён. Глобальный linearizable order упрощает семантику, однако один coordination path повышает latency и ограничивает throughput. Часто полезнее сделать linearizable только операции, меняющие право владения или уникальный инвариант.

## Типичные ошибки

### Majority автоматически означает linearizability

- **Неверное предположение:** любое чтение и запись большинства создают atomic register.
- **Симптом:** после завершённой записи quorum read выбирает старую версию либо два membership epochs принимают несовместимые решения.
- **Причина:** нет монотонных версий, write-back/read protocol или безопасной смены состава.
- **Исправление:** проверить полный алгоритм, а не название consistency level.

### Записи у лидера, чтения где угодно

- **Неверное предположение:** followers лишь немного отстают, значит система остаётся linearizable.
- **Симптом:** пользователь получает старое значение после подтверждённого update.
- **Причина:** follower не достиг committed position к началу read.
- **Исправление:** leader/read-index/quorum read либо честно назвать чтение stale/session-consistent.

### Linearizable reads защищают read-modify-write

- **Неверное предположение:** два клиента могут прочитать `0`, вычислить `1` и записать `1`, потому что каждый вызов linearizable.
- **Симптом:** два increment дают итог `1`.
- **Причина:** linearization points существуют для четырёх отдельных операций; между read и write разрешено вмешательство.
- **Исправление:** atomic increment, compare-and-set или transaction с подходящей изоляцией.

### Timeout трактуется как abort

- **Неверное предположение:** отсутствие response означает отсутствие linearization point.
- **Симптом:** retry удваивает платёж или increment.
- **Причина:** pending invocation могла успеть изменить объект.
- **Исправление:** idempotency key, query operation status и явная модель unknown outcome.

### Linearizability смешивают с serializability

- **Неверное предположение:** linearizable key-value API делает multi-row transaction serializable.
- **Симптом:** отдельные reads/writes корректны, а межключевой invariant нарушается.
- **Причина:** единицей спецификации был один object operation, а не transaction.
- **Исправление:** назвать transaction boundary и требуемую isolation/strict serializability отдельно.

## Когда применять

Linearizability нужна там, где решение должно учитывать все завершённые операции: compare-and-set, выдача уникального владельца, смена конфигурации, fencing state, lock service и критичный metadata register. Она полезна и как локальный building block, даже если остальная система работает eventual или causal.

Если stale value безопасен, конфликт имеет предметный merge, а локальная latency важнее единого real-time order, более слабая модель дешевле. Решение фиксируют через counterexample history: какой конкретно старый или переставленный ответ нарушит invariant, для какого объекта и во время какого отказа.

## Источники

- [Linearizability: A Correctness Condition for Concurrent Objects](https://www.cs.cmu.edu/~wing/publications/HerlihyWing90.pdf) — Maurice Herlihy и Jeannette Wing, ACM TOPLAS 12(3), 1990, formal definition, locality и сравнение с sequential/strict serializability, проверено 2026-07-18.
- [How to Make a Multiprocessor Computer That Correctly Executes Multiprocess Programs](https://www.microsoft.com/en-us/research/publication/make-multiprocessor-computer-correctly-executes-multiprocess-programs/) — Leslie Lamport, IEEE Transactions on Computers, 1979, sequential consistency, проверено 2026-07-18.
- [Sharing Memory Robustly in Message-Passing Systems](https://groups.csail.mit.edu/tds/papers/Attiya/TM-423.pdf) — Hagit Attiya, Amotz Bar-Noy и Danny Dolev, technical report 1990; журнальная версия JACM 42(1), 1995, atomic register ABD, проверено 2026-07-18.
- [In Search of an Understandable Consensus Algorithm](https://raft.github.io/raft.pdf) — Diego Ongaro и John Ousterhout, расширенная версия USENIX ATC 2014, replicated log и commit rules, проверено 2026-07-18.
- [Brewer's Conjecture and the Feasibility of Consistent, Available, Partition-Tolerant Web Services](https://groups.csail.mit.edu/tds/papers/Gilbert/Brewer6.pdf) — Seth Gilbert и Nancy Lynch, ACM SIGACT News 33(2), 2002, исходная статья и formal proof для asynchronous network model, проверено 2026-07-18.
