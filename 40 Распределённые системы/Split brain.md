---
aliases:
  - Split brain
  - Раздвоение кластера
  - Два активных primary
tags:
  - область/распределённые-системы
  - тема/отказоустойчивость
  - отказ/раздвоение-кластера
статус: проверено
---

# Split brain

## TL;DR

Split brain возникает, когда две изолированные части системы одновременно считают себя полномочными управлять одним singleton-ресурсом: принимать primary writes, монтировать shared disk, назначать задания или выполнять внешний side effect. Network partition создаёт неопределённость, но не обязана приводить к split brain. Если только сторона с quorum продолжает работу, вторая останавливается или ограждается, единственная authority сохраняется.

Защита складывается из разных барьеров. Quorum и пересечение голосов не позволяют двум partition commit-ить независимые решения в одном корректном membership. Witness помогает нечётно разделить голоса, но не становится копией данных и не выключает проигравший узел. Fencing делает это право физически или логически исполнимым: STONITH лишает узел питания/доступа, fencing token заставляет ресурс отвергать stale epoch.

Самая опасная граница находится за пределами consensus group. Старый primary может отправить платёж, письмо или команду устройству даже после потери quorum, если получатель не проверяет authority. Согласованный журнал защищает только участвующее в его протоколе состояние.

## Область применимости

Заметка рассматривает crash-recovery узлы, network partition и устаревшее membership без Byzantine-атак. Сопоставляются два класса систем: replicated state machine с majority quorum и HA-кластер, управляющий внешними ресурсами. Для первого опорой служит Raft 2014, для второго — Pacemaker 3.0.1.

## Ментальная модель

У singleton-ресурса должен существовать один проверяемый «паспорт власти»:

```text
membership = {A, B, W}
epoch      = 12
authority  = B
evidence   = quorum {B, W}
fence      = A power-off или downstream max_epoch=12
```

Quorum отвечает, какая partition вправе принять следующее решение. Epoch отличает новую власть от старой. Fencing гарантирует, что проигравшая сторона не обойдёт решение через shared disk или внешний API.

Отсюда важное различие: два процесса могут временно думать, что они primary, и всё же не создать два committed history, если старый не соберёт quorum. Operational split brain начинается там, где обе стороны продолжают реальные несовместимые действия. Смотреть нужно не на label `leader`, а на commit и side effects.

## Как устроено

### Как появляется раздвоение

Типичная цепочка выглядит так:

1. `A` — active primary, `B` — standby.
2. Между ними пропадает связь. Тайм-аут не позволяет отличить crash `A` от partition.
3. `B` повышается до primary, чтобы сохранить availability.
4. `A` жив, всё ещё обслуживает часть клиентов или пишет в shared storage.
5. После восстановления связи обнаруживаются два журнала либо уже выполненные внешние действия.

Ошибка находится в шаге 3: повышение выполнено без доказательства новой исключительной authority или без ограждения старой. CAP формализует сам конфликт для linearizable service: при partition нельзя одновременно гарантировать ответ каждой стороне и один real-time-consistent результат. «Пусть обе продолжают, потом сольём» допустимо лишь там, где заранее определена multi-writer semantics. [[40 Распределённые системы/Multi-leader replication|Multi-leader replication]] проектирует concurrent writes как норму; split brain случайно создаёт двух owners там, где операции рассчитаны на одного.

### Quorum и пересечение

При фиксированном составе majority quorum гарантирует пересечение любых двух решающих множеств. В Raft voter отдаёт один голос в term, а commit требует большинство. Поэтому partition с меньшинством может читать локальную память и слать пакеты, но не вправе подтверждать новые log entries.

Quorum защищает только при корректных предпосылках:

- все участники согласны с membership и epoch;
- голоса и terms устойчиво сохраняются;
- reconfiguration не допускает независимые old/new majorities;
- действие действительно ждёт quorum, а не отвечает после локальной записи.

Двухузловый кластер особенно неудобен: при потере связи каждый видит один голос из двух. Если один всё равно продолжит, появляется риск split brain; если оба остановятся, теряется availability. Третий полноценный voter либо quorum witness даёт нечётный голос. В Pacemaker лёгкий qdevice может учитываться в quorum, не запуская ресурсы кластера.

Witness — арбитр голосования, а не запасная реплика. Он не хранит полный журнал приложения, не восстанавливает потерянные данные и не спасает, если его failure domain совпадает с одной из сторон. Его собственный протокол обязан не выдавать решающий голос двум partition одной эпохи.

### Почему quorum недостаточно

Узел, потерявший quorum, должен остановить resource. Но network partition может одновременно отрезать команду `stop`, зависший kernel может её не исполнить, а старый database process продолжит писать на общий диск. Pacemaker предупреждает: если fencing отключён, unresponsive node сразу считают не выполняющим resources, хотя он может сохранять доступ к shared storage; результатом бывает потеря данных.

Поэтому новый primary запускают после успешного fencing старого. STONITH через независимый power controller выключает или перезагружает target. Fabric fencing отзывает доступ к storage или сети. Критичен порядок: сначала подтверждённая изоляция `A`, потом start `B`. Timeout fencing не равен успеху; fail-safe поведение оставляет новый resource остановленным.

Quorum и fencing дополняют друг друга. Quorum решает, кто вправе ограждать. Fencing превращает решение в физический факт. В Pacemaker partition обычно может инициировать fencing при наличии quorum; документация отдельно описывает исключения и опасные политики вроде игнорирования quorum.

### Logical fencing и внешние side effects

Для API или storage, способного сравнить эпоху, вместо выключения всего узла применяют [[40 Распределённые системы/Leases, distributed locks и fencing tokens|fencing token]]. Новый primary получает generation `12`, ресурс сохраняет `max_generation=12`, запрос старого primary с `11` отвергается. Chubby sequencer реализует эту схему через lock generation, имя и режим lock.

Если внешний получатель token не поддерживает, quorum внутренней БД его не защищает. Уже отправленный HTTP request не исчезает после demotion. [[40 Распределённые системы/Transactional outbox и Change Data Capture|Transactional outbox]] связывает локальный commit с намерением отправить событие, а стабильный idempotency key помогает получателю подавить повтор; ни один механизм не позволяет автоматически отменить два разных бизнес-решения, уже принятых двумя primary. Для необратимого эффекта authority должна проверяться на стороне эффекта либо failover должен ждать physical fencing.

### Возвращение проигравшей стороны

После heal старый узел не возвращают сразу в write pool. Сначала проверяют membership epoch, отзывают stale sessions, переводят узел в follower/standby и восстанавливают его из авторитетного committed history. Uncommitted хвост можно отбросить только после классификации внешних эффектов: запись в локальном журнале могла не стать committed, а соответствующее письмо уже ушло.

Автоматический двусторонний merge опасен для singleton-инвариантов. Два выданных номера заказа или два списания не превращаются в одно корректное действие выбором «последней» строки.

## Пример или трассировка

Есть data nodes `A`, `B` и witness `W`. Всего три голоса; `A` обслуживает shared volume в `epoch=11`.

1. `A` теряет связь с `B` и `W`, но process и storage path остаются живы. Один голос не образует majority.
2. `B` и `W` видят друг друга и получают два голоса. Они выбирают новую authority `epoch=12`.
3. До монтирования volume на `B` cluster manager просит независимый controller выключить `A`. Только подтверждённый fencing разрешает start.
4. Если power fencing подтверждён, `B` становится единственным узлом с доступом. Если fencing завершился тайм-аутом, `B` остаётся остановленным: availability проиграна, данные не отданы двум writers.
5. Для отдельного object storage `B` посылает writes с token `12`. Поздний request от `A` с `11` отвергается на стороне storage.
6. После возвращения `A` входит как standby, сверяет epoch и догоняет авторитетное состояние `B`.

Без witness ни одна сторона не имела бы majority. Без STONITH `A` мог бы продолжать писать в volume, хотя голосование законно выбрало `B`. Без downstream token он мог бы менять внешний object storage. Каждый слой закрывает отдельную дыру.

## Trade-offs

Quorum останавливает меньшинство и тем самым жертвует availability при partition. Разрешить writes обеим сторонам быстрее для пользователя, но тогда нужны данные и операции, рассчитанные на конфликты, а не singleton failover под другим именем.

Полноценный третий replica хранит данные и голосует, но стоит дороже. Witness дешевле, однако добавляет failure domain управления.

STONITH универсален для legacy/shared resources и даёт сильную изоляцию. Цена — отдельное оборудование или control plane, более долгий failover и риск выключить здоровый узел при ошибочной настройке. Logical token точнее и быстрее, зато требует изменений каждого downstream и durable compare.

Автоматический failover сокращает RTO при проверенном fencing. Ручной медленнее, но может быть разумнее, когда внешний эффект нельзя оградить или стоимость ошибочного promotion выше допустимого простоя.

## Типичные ошибки

- **Неверное предположение:** ping timeout означает, что peer выключен. **Симптом:** оба узла становятся primary. **Причина:** partition принят за crash. **Исправление:** quorum плюс подтверждённый fencing.
- **Неверное предположение:** witness хранит третью копию данных. **Симптом:** после потери обоих data nodes восстановиться не из чего. **Причина:** голос смешан с replica. **Исправление:** отдельно считать data durability и quorum votes.
- **Неверное предположение:** потеря quorum физически остановила старый process. **Симптом:** shared disk получает записи после promotion. **Причина:** команда остановки не дошла или не исполнилась. **Исправление:** STONITH, fabric fencing или downstream generation check.
- **Неверное предположение:** reconnect безопасно сольёт две ветки. **Симптом:** нарушены uniqueness, balance или ordering. **Причина:** merge не знает внешних эффектов и бизнес-инвариантов. **Исправление:** выбрать authoritative history, отдельно расследовать и компенсировать side effects.
- **Неверное предположение:** active-active всегда означает split brain. **Симптом:** архитектура запрещает допустимые concurrent operations. **Причина:** запланированная multi-writer semantics смешана с двумя случайными singleton owners. **Исправление:** явно определить conflict model и write authority для каждого ресурса.

## Когда применять

Защиту от split brain проектируют для database failover, shared storage, schedulers, control planes и multi-region promotion. В runbook должны быть зафиксированы membership, quorum calculation, место witness, epoch, fencing target и независимый путь управления, условие «fence succeeded», правила rejoin и перечень внешних эффектов.

Проверка должна моделировать потерю cluster network при сохранённом client/storage network, зависший process, недоступный witness, отказ fencing device и возврат старого primary. Здоровый результат теста иногда означает остановку сервиса. Это ожидаемая цена: без доказательства единственной authority автоматическое продолжение работы превращает failover в риск порчи данных.

## Источники

- [Brewer’s Conjecture and the Feasibility of Consistent, Available, Partition-Tolerant Web Services](https://groups.csail.mit.edu/tds/papers/Gilbert/Brewer6.pdf) — Seth Gilbert, Nancy Lynch, ACM SIGACT News 33(2), 2002, проверено 2026-07-18.
- [In Search of an Understandable Consensus Algorithm](https://raft.github.io/raft.pdf) — Diego Ongaro, John Ousterhout, расширенная версия USENIX ATC 2014, проверено 2026-07-18.
- [Pacemaker Explained](https://clusterlabs.org/projects/pacemaker/doc/3.0/Pacemaker_Explained/pdf/Pacemaker_Explained.pdf) — ClusterLabs, Pacemaker 3.0.1, разделы Cluster-Wide Configuration, Nodes и Fencing, проверено 2026-07-18.
- [The Chubby Lock Service for Loosely-Coupled Distributed Systems](https://research.google.com/archive/chubby-osdi06.pdf) — Google, OSDI 2006, проверено 2026-07-18.
