---
aliases:
  - CAP theorem
  - Теорема CAP
  - PACELC
tags:
  - область/распределённые-системы
  - тема/согласованность
статус: проверено
---

# CAP и PACELC

## TL;DR

CAP — условный impossibility result, а не меню «выбери любые два свойства». В модели Gilbert–Lynch сервис с atomic/linearizable read-write register не может во время network partition одновременно гарантировать корректный ответ и availability каждого non-failing node. Если связь обязательна для решения, одна сторона должна ждать или отказать; если обе стороны отвечают независимо, linearizability в общем случае теряется.

Буква `C` в CAP означает atomic consistency, то есть [[40 Распределённые системы/Linearizability|linearizability]] в формальной модели, а не `C` из ACID и не расплывчатое «данные согласованы». `A` — liveness guarantee на каждый запрос, а не годовой SLA. `P` описывает отказ связи, который система обязана учитывать.

PACELC добавляет второй вопрос: `if Partition, Availability or Consistency; Else, Latency or Consistency`. Это полезная taxonomy для реплицированных хранилищ в штатном режиме, но не теорема той же силы, что proof Gilbert–Lynch, и не полная классификация продукта.

## Область применимости

Формальная граница CAP взята из Gilbert–Lynch 2002 и их последующего изложения: asynchronous message-passing system, read/write atomic register и коммуникационные отказы. PACELC соответствует формулировке Daniel Abadi 2012. Проверено 2026-07-18.

Реальный datastore может давать разные гарантии для reads, writes, ключей и регионов. Поэтому CAP/PACELC применяют к конкретной операции и failure scope, а не навешивают один ярлык на весь продукт.

## Ментальная модель

Во время partition узел видит только свою component. Отсутствующий message не сообщает, потерян ли он навсегда или сильно задержан. Если в другой component могла завершиться запись, локальный узел не знает, какое значение теперь correct.

У него остаются две безопасно описываемые политики:

- **сохранить C:** не отвечать там, где нельзя подтвердить актуальное состояние; availability по CAP потеряна;
- **сохранить A:** ответить из локального состояния или принять локальную запись; некоторые допустимые executions перестают быть linearizable.

Разделение проявляется только для операций, которым нужна координация. Вычислить константу или прочитать immutable blob можно в обеих components без конфликта; CAP не запрещает это.

PACELC продолжает рассуждение после восстановления сети:

```text
partition?  yes -> availability  или consistency
            no  -> lower latency или stronger consistency
```

Во второй ветке синхронная межрепличная координация ждёт network path. Асинхронное локальное подтверждение отвечает быстрее, но разрешает staleness или conflict window. Точная модель согласованности всё равно должна быть названа по правилам [[40 Распределённые системы/Strong, eventual, causal и session consistency|consistency models]].

## Как устроено

### Что означают C, A и P

**Consistency.** Для atomic register существует legal total order операций; каждая выглядит выполненной в одной точке между request и response, а real-time precedence сохранён.

**Availability.** Каждый request, полученный non-failing node, в конце концов получает допустимый для операции response: read value или write acknowledgement. Согласованность этого ответа с atomic history задаёт отдельное свойство `C`. Формальная модель не задаёт latency bound, хотя в эксплуатации слишком поздний ответ уже бесполезен. Для total register operation `503`, redirect в недостижимую component или бесконечное ожидание не считаются её завершением.

**Partition tolerance.** Сеть может разделить nodes на components: сообщения между ними задерживаются без известной границы или теряются. Это условие среды. Если архитектура обязана переживать такой отказ, «не выбирать P» нельзя; нужно описать поведение каждой component.

### Почему возникает невозможность

Register `x` реплицирован на nodes `A` и `B`, начальное значение `0`. Сеть разделилась. Клиент записал `x=1` через `A` и получил `OK`, затем другой клиент запросил `read(x)` у исправного `B`.

Для `B` неразличимы две executions:

```text
E0: в A не было новой записи, correct answer = 0
E1: A завершил write(x, 1), correct answer = 1
```

Ни один message из `A` не приходит. Если `B` обязан ответить, один и тот же локальный state вынуждает его выбрать одинаковый ответ в `E0` и `E1`, значит в одной execution ответ нарушит atomic consistency. Если `B` ждёт различающую информацию, availability перестаёт быть гарантированной. Дополнительный timeout не создаёт знания о другой component.

### Что на практике называют CP и AP

В consistent branch только component с подтверждёнными полномочиями, обычно quorum/leader side, продолжает критичные операции. Minority отказывает или ждёт. Такой режим может иметь очень высокий обычный uptime, но формальную `A` во время partition не сохраняет.

В available branch каждая component обслуживает операцию локально. Для concurrent writes нужны version metadata и [[30 Данные/Data repair и reconciliation|reconciliation]] после восстановления. Eventual convergence — дополнительное свойство; из `AP` оно автоматически не следует.

Один сервис может сегментировать решения. Например, просмотр уже сохранённого профиля допускает stale response, а захват username требует quorum. Gilbert–Lynch отдельно отмечают, что подсистемы могут выбирать разные точки trade-off.

### Что добавляет PACELC

CAP ограничивает поведение при communication failure. Abadi обратил внимание на постоянный trade-off репликации без partition:

- synchronous write в удалённые replicas или чтение с quorum повышает цену latency, зато уменьшает окно stale state;
- local acknowledgement и asynchronous replication снижают latency, но удалённая replica отстаёт, а failover может увеличить RPO;
- routing к единственному leader сохраняет порядок, однако удалённый клиент платит WAN latency;
- multi-leader/local writes убирают этот hop ценой concurrent conflicts.

Запись `PA/EL`, `PC/EC` или `PC/EL` — сокращение выбранных trade-offs, не formal guarantee. У системы бывают настраиваемые consistency levels, разные read/write paths и baseline слабее linearizability. Сам Abadi предупреждает: `PC` в такой taxonomy может означать «не ослаблять исходную consistency во время partition», а не полную linearizability.

## Пример или трассировка

Два региона `A` и `B` хранят `x=0`. Между ними пропала связь.

### Consistency branch

1. Quorum остаётся у `A`; epoch подтверждает его право записи.
2. `A` принимает `write(x,1)` и отвечает `OK` после protocol commit.
3. `B` отклоняет write и linearizable read, потому что не может подтвердить актуальные полномочия.
4. После восстановления `B` догоняет committed log.

Наблюдаемый результат: единственный порядок сохранён, но клиенты `B` потеряли availability критичной операции.

### Availability branch

1. `A` принимает `write(x,1) -> OK`.
2. Одновременно `B` принимает `write(x,2) -> OK`.
3. Локальные reads возвращают `1` и `2`.
4. После восстановления replicas обмениваются версиями и применяют заранее выбранный merge.

Наблюдаемый результат: обе components отвечали, но два completed writes нельзя объяснить одним register state, которое сразу видели все последующие reads. Merge восстанавливает convergence, а не задним числом linearizability.

### Else branch PACELC

Сеть здорова. Если `A` ждёт synchronous acknowledgement от `B`, write latency включает межрегиональный путь, зато read в `B` можно обслужить из подтверждённого состояния при полном протоколе. Если `A` отвечает после локального commit, latency ниже, но `B` некоторое время читает `x=0`. Это уже PACELC-вопрос, не следствие partition.

## Trade-offs

| Политика | Что сохраняется | Чем платим |
| --- | --- | --- |
| Stop minority / require quorum | Linearizable order при корректных epoch и read protocol | Часть клиентов получает отказ или ждёт до восстановления связи |
| Accept in every component | Локальная доступность reads/writes | Staleness, conflicts, reconciliation; строгие cross-component invariants недоступны |
| Synchronous WAN replication | Меньше staleness и RPO, проще свежие remote reads | WAN RTT на write path, зависимость от slow replica/quorum |
| Asynchronous replication | Низкая local latency и изоляция от удалённой задержки | Lag, stale reads и риск потери acknowledged tail при failover |

CAP не выбирает бизнес-политику. Для inventory иногда лучше отклонить заказ, чем продать отсутствующий товар; для реакции в социальной ленте разумнее принять обе локальные записи и слить счётчик. Решение зависит от цены неверного результата и цены отказа.

## Типичные ошибки

### «Выбрать любые два из трёх»

- **Неверное предположение:** свойства независимы и P можно отключить настройкой.
- **Симптом:** архитектура объявлена `CA`, но не определено поведение при потере связи.
- **Причина:** partition — failure condition, а trade-off C/A возникает именно внутри неё.
- **Исправление:** назвать failure scope и политику каждой component для каждой операции.

### CAP consistency принимают за ACID `C`

- **Неверное предположение:** CAP доказывает невозможность constraints или валидного schema state.
- **Симптом:** eventual replication объявляют несовместимой с любыми бизнес-инвариантами.
- **Причина:** в theorem `C` означает atomic/linearizable register.
- **Исправление:** разнести consistency model, transaction isolation и application invariants.

### `AP` автоматически означает eventual consistency

- **Неверное предположение:** доступные components сами сойдутся после восстановления.
- **Симптом:** replicas навсегда выбирают разные concurrent versions.
- **Причина:** CAP ничего не задаёт о delivery, merge и repair.
- **Исправление:** отдельно проектировать convergence и conflict resolution.

### Majority автоматически даёт `C`

- **Неверное предположение:** `R + W > N` достаточно для linearizability.
- **Симптом:** sloppy quorum, stale membership или неверный timestamp возвращают старую версию.
- **Причина:** пересечение не задаёт version order и operation protocol.
- **Исправление:** проверить предпосылки из [[30 Данные/Read и write quorums|read/write quorums]].

### PACELC используют как постоянный ярлык продукта

- **Неверное предположение:** база всегда `PA/EL` независимо от настройки и операции.
- **Симптом:** design review игнорирует consistency level, leader placement и разные read paths.
- **Причина:** taxonomy сжала многомерный контракт до двух буквенных выборов.
- **Исправление:** описать отдельно partition policy и normal-path acknowledgement/read policy.

## Когда применять

CAP полезен, когда команда разбирает конкретный network partition: какие nodes остаются non-failing, где лежит authority, кто обязан ответить и какой bad history запрещён. PACELC добавляют при выборе географии лидера, synchronous/asynchronous replication и read path в штатном режиме.

Практическая запись решения содержит: объект и операцию; точную consistency model; failure domain; доступные components во время partition; conflict policy; normal-path latency budget; границу acknowledgement. Формула `CP` или `AP` без этих пунктов почти ничего не предсказывает.

## Источники

- [Brewer's Conjecture and the Feasibility of Consistent, Available, Partition-Tolerant Web Services](https://groups.csail.mit.edu/tds/papers/Gilbert/Brewer6.pdf) — Seth Gilbert и Nancy Lynch, ACM SIGACT News 33(2), 2002, исходная статья и formal proof для asynchronous network model, проверено 2026-07-18.
- [Linearizability: A Correctness Condition for Concurrent Objects](https://www.cs.cmu.edu/~wing/publications/HerlihyWing90.pdf) — Maurice Herlihy и Jeannette Wing, ACM TOPLAS 12(3), 1990, atomic/linearizable history, проверено 2026-07-18.
- [Consistency Tradeoffs in Modern Distributed Database System Design](https://www.cs.umd.edu/~abadi/papers/abadi-pacelc.pdf) — Daniel J. Abadi, IEEE Computer 45(2), 2012, формулировка PACELC, проверено 2026-07-18.
- [Dynamo: Amazon's Highly Available Key-value Store](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf) — Giuseppe DeCandia et al., SOSP 2007, optimistic replication и reconciliation, проверено 2026-07-18.
