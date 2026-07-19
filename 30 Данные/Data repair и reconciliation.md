---
aliases:
  - data repair
  - reconciliation данных
  - восстановление согласованности реплик
tags:
  - область/данные
  - тема/распределённые-данные
  - практика/repair-и-reconciliation
статус: проверено
---

# Data repair и reconciliation

## TL;DR

Data repair обнаруживает расхождения реплик и переносит недостающие версии. Reconciliation решает, какая версия побеждает или как слить конкурирующие изменения. Это разные задачи: checksum доказывает различие, но не знает предметной истины; last-write-wins выбирает победителя, но не гарантирует, что все replicas его получили.

Read repair исправляет только данные, затронутые чтением, hinted handoff доставляет временно пропущенные mutations, anti-entropy repair систематически сравнивает ranges. Удаление должно участвовать как tombstone с версией. Если tombstone очистить раньше, чем отставшая replica увидела delete, её старое живое значение может остаться единственной известной версией и воскреснуть.

## Область применимости и версии

Заметка описывает eventual convergence replicated stores. Механизмы и конфликтующие версии сверены с Dynamo 2007; конкретные read repair, hints, anti-entropy и tombstones — с Apache Cassandra 5.0.8. В этой версии Auto Repair доступен как opt-in backport CEP-37 и требует отдельного включения; проверено 2026-07-18. Политики другого движка могут отличаться по granularity, version metadata и безопасной очистке deletes.

## Ментальная модель

Конвергенция состоит из трёх последовательных вопросов:

1. **Detection:** какие replicas/ranges различаются?
2. **Reconciliation:** является ли одна версия потомком другой, какая новее, или нужен semantic merge?
3. **Propagation:** как выбранный результат попадёт всем owners и будет подтверждён?

Простой pipeline:

```text
compare digests/versions -> fetch differing values -> choose/merge -> write back -> verify
```

Его инварианты:

- metadata порядка относится к той же логической mutation, что payload;
- repair работает по согласованной topology epoch и всем нужным replicas;
- повторная передача идемпотентна;
- absence не интерпретируется как delete без versioned tombstone;
- scheduled coverage заканчивается раньше срока, после которого delete evidence можно удалить.

Repair возвращает replicas к выбранному состоянию, но не исправляет ошибочную бизнес-операцию. Если authoritative version неверна, repair лишь быстрее её размножит; для этого нужны audit/backup и отдельная компенсирующая mutation.

## Как устроено

### Hinted handoff

В Cassandra coordinator сохраняет hint для недоступной естественной replica и позже воспроизводит исходную mutation с её timestamp. Это сокращает окно расхождения; повтор идемпотентен относительно более новой mutation. Но hints имеют ограниченное окно/ресурсы, могут быть потеряны вместе с coordinator и являются best effort. Документация Cassandra 5.0.8 прямо не считает их заменой anti-entropy repair.

Hint знает конкретную пропущенную write, зато не обнаруживает silent disk corruption, operator loss или старое расхождение, для которого hint уже исчез. Это delivery optimization, а не полное доказательство равенства.

### Read repair

При чтении coordinator сравнивает ответы/digests реплик, участвующих в запросе. Если версии различаются, он получает данные, выполняет reconciliation и записывает выбранное значение отставшим участникам. Преимущество — самые читаемые keys чинятся быстрее.

Ограничения следуют из trigger: непрочитанный key не ремонтируется, а replicas вне конкретного read set могут остаться stale. В Cassandra 5.0.8 режим `BLOCKING` завершает foreground repair до ответа и поддерживает monotonic quorum reads в документированной модели, но выборочное чтение части partition может нарушить partition-level write atomicity. Режим `NONE` избегает blocking read repair и сохраняет соответствующий trade-off в пользу partition write atomicity, но не даёт той же monotonic quorum read guarantee.

### Anti-entropy repair

Anti-entropy систематически обходит token ranges. Dynamo и Cassandra используют Merkle trees: replicas строят иерархические hashes, сравнивают root и спускаются только в отличающиеся ветви, чтобы локализовать ranges без передачи всего набора. После этого различающиеся rows/partitions стримятся и reconciled.

Merkle tree уменьшает compare traffic, но repair остаётся тяжёлым: scan, hashing, network streaming, disk writes и compaction. Его режут по ranges, ограничивают параллельность и запускают чаще, чем максимально безопасное окно расхождения. Full repair сравнивает все относящиеся данные; incremental repair уменьшает повторную работу, отслеживая repaired/unrepaired state, но требует последовательной эксплуатации и понимания compaction взаимодействия.

### Reconciliation policy

**Last-write-wins (LWW)** выбирает mutation с максимальным timestamp. Cassandra использует timestamped mutations. Правило детерминировано, но физические часы не отражают причинность: узел с clock в будущем способен надолго подавить реальные новые writes.

**Causal versions/siblings** сохраняют параллельные ветви. Dynamo использует vector clocks, чтобы отличить descendant от concurrent versions; concurrent siblings сливает application или клиент. Это не теряет конфликт молча, но усложняет API, хранение и предметный merge.

**Semantic merge** использует свойства домена: set union, max observed sequence, commutative counter или ручное решение. Он безопасен только при доказанных algebraic свойствах и tombstone semantics. Например, union без remove metadata воскресит удалённый элемент.

Reconciliation обязана быть одинаковой в read path, streaming repair и background consumer. Два разных tie-breaker создадут oscillation: каждый проход будет «исправлять» результат предыдущего.

### Tombstones и zombie data

Физическое отсутствие значения не содержит информации, было ли оно удалено или никогда не существовало. Поэтому delete записывается как tombstone с logical timestamp и реплицируется как обычная новая версия. Read подавляет более старое live value, а repair распространяет delete evidence.

В Cassandra `gc_grace_seconds` задаёт минимальный возраст, после которого tombstone **может** быть удалён compaction при выполнении остальных условий. Это окно должно покрывать недоступность replica и успешный repair. Если узел отсутствовал дольше grace и delete до него не дошёл, очистка tombstone лишает здоровые replicas доказательства удаления; старое значение на вернувшемся узле становится zombie. Настройка `only_purge_repaired_tombstones` связывает очистку с repaired state, но не отменяет необходимость корректного repair schedule.

TTL имеет ту же фундаментальную проблему: expiration должно быть представлено так, чтобы отставшая replica не вернула просроченную версию после очистки metadata.

## Эволюция и версии

В классической эксплуатации Cassandra repair планировался внешним orchestration. В Apache Cassandra 5.0.8 Auto Repair из CEP-37, первоначально введённый в 6.0, backported в ветку 5.0. Для 5.0.8 требуется запустить узлы с JVM property `-Dcassandra.autorepair.enable=true`; это создаёт schema elements, а само расписание всё равно отдельно включается в `cassandra.yaml` или через JMX. Включение property для schema описано как необратимое.

Практический эффект: утверждение «Cassandra никогда сама не планирует repair» для 5.0.8 уже неточно. Но наличие scheduler не делает workload безопасным по умолчанию: repair types выключены до конфигурации, а intervals, range sizes, retries, disk headroom и compaction backpressure остаются ответственностью оператора.

## Пример или трассировка

У ключа `k` на `A`, `B`, `C` хранится `value=x, ts=10`.

1. `C` недоступна. Delete с `ts=20` достигает `A` и `B`; там появляется tombstone, который подавляет `x`.
2. Hints не доживают до возвращения `C`, а anti-entropy repair диапазона не выполняется.
3. Проходит `gc_grace_seconds`; compaction на `A` и `B` при допустимых условиях удаляет tombstone и скрытое старое value. Там остаётся физическое отсутствие.
4. `C` возвращается с живым `x, ts=10`.
5. Repair сравнивает replicas. У `A/B` уже нет версии `ts=20`, поэтому отсутствие не может победить сохранённое `x`; live value стримится обратно.

Наблюдаемый результат: удалённые данные воскресают. Repair сработал механически правильно по доступным версиям — ошибкой была преждевременная потеря delete evidence.

Если repair диапазона прошёл на шаге 2, `C` получила бы tombstone `ts=20`; после этого все replicas знали delete, и последующая безопасная compaction не оставила бы старой версии. Альтернатива для слишком долго отсутствующего узла — не возвращать его старые данные в ring, а заменить/rebootstrap из актуальных replicas.

## Trade-offs

| Механизм | Где выигрывает | Что не покрывает |
|---|---|---|
| Hinted handoff | Короткая временная недоступность известной replica | Silent corruption, истёкшее hint window |
| Read repair | Горячие читаемые keys | Холодные keys и неучаствующие replicas |
| Full anti-entropy | Полное покрытие ranges | Высокие disk/network/compaction costs |
| Incremental repair | Меньше повторной работы | Сложнее state и необходимость регулярности |
| LWW | Дешёвый детерминированный выбор | Clock skew и потеря concurrent intent |
| Siblings + merge | Явные concurrent conflicts | Сложность API и business merge |

Увеличить [[30 Данные/Read и write quorums|`R/W`]] — не альтернатива repair. Оно сокращает вероятность невидимого расхождения на foreground path, но replicas всё равно могут пропустить writes, повредить данные или долго не участвовать в запросах. Repair закрывает историю, а quorum задаёт текущую границу ответа.

## Типичные ошибки

- **Неверное предположение:** hinted handoff гарантирует eventual consistency. **Симптом:** вернувшийся после долгого outage узел остаётся stale. **Причина:** hints best effort и имеют ограниченное окно. **Исправление:** плановый anti-entropy repair и контроль coverage.
- **Неверное предположение:** read repair со временем исправит всё. **Симптом:** холодные данные расходятся месяцами. **Причина:** ключи не читаются или часть replicas не попадает в read set. **Исправление:** обходить все ranges независимо от user reads.
- **Неверное предположение:** отсутствие строки эквивалентно delete. **Симптом:** zombie после compaction/repair. **Причина:** tombstone удалён до распространения. **Исправление:** repair-before-grace, безопасная purge policy и rebootstrap слишком старых replicas.
- **Неверное предположение:** LWW знает последнюю бизнес-операцию. **Симптом:** старая запись с будущими часами подавляет новую. **Причина:** wall-clock timestamp принят за causal order. **Исправление:** clock discipline и границы LWW либо causal versions/semantic merge.
- **Неверное предположение:** успешный repair равен semantic correctness. **Симптом:** все replicas одинаково хранят ошибочное значение. **Причина:** repair проверяет сходимость, не бизнес-истину. **Исправление:** отдельно validation, audit и restore/compensation.

## Когда применять

Repair нужен всегда, когда [[30 Данные/Репликация данных|реплики]] могут расходиться: из-за partial writes, downtime, asynchronous delivery, disk loss или topology changes. Механизмы наслаиваются: hints сокращают короткое окно, read repair чинит hot set, anti-entropy даёт плановое покрытие, reconciliation задаёт смысл конфликта.

Расписание выводят из `gc_grace_seconds`, максимальной недоступности и фактического времени полного repair cycle. Мониторят не только последнюю успешную команду, но и oldest unrepaired range, bytes pending, failed sessions, streaming/compaction pressure и replicas вне topology. Периодически проверяют controlled divergence: удалить/обновить данные при выключенной replica, вернуть её до и после допустимого окна и подтвердить ожидаемый результат.

## Источники

- [Dynamo: Amazon’s Highly Available Key-value Store](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf) — Amazon, SOSP 2007, проверено 2026-07-18.
- [Repair](https://cassandra.apache.org/doc/5.0.8/cassandra/managing/operating/repair.html) — Apache Cassandra, документация 5.0.8, проверено 2026-07-18.
- [Read repair](https://cassandra.apache.org/doc/5.0.8/cassandra/managing/operating/read_repair.html) — Apache Cassandra, документация 5.0.8, проверено 2026-07-18.
- [Hints](https://cassandra.apache.org/doc/5.0.8/cassandra/managing/operating/hints.html) — Apache Cassandra, документация 5.0.8, проверено 2026-07-18.
- [Compaction overview](https://cassandra.apache.org/doc/5.0.8/cassandra/managing/operating/compaction/overview.html) — Apache Cassandra, документация 5.0.8, проверено 2026-07-18.
- [Auto Repair](https://cassandra.apache.org/doc/5.0.8/cassandra/managing/operating/auto_repair.html) — Apache Cassandra, документация 5.0.8, проверено 2026-07-18.
