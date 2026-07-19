---
aliases:
  - rebalancing данных
  - ребалансировка данных
  - data rebalancing
tags:
  - область/данные
  - тема/распределённые-данные
  - механизм/rebalancing
статус: проверено
---

# Rebalancing данных

## TL;DR

Rebalancing — контролируемое изменение placement после добавления, удаления, отказа или изменения capacity узлов. Здесь есть две разные реальности: **ownership** отвечает, кто имеет право обслуживать range в topology epoch, а **movement** копирует его bytes. Старый узел может физически хранить данные, но уже не быть owner; новый может быть будущим owner, пока snapshot ещё догружается.

Безопасный протокол разводит этапы: запланировать новую карту, передать snapshot, догнать конкурентные записи, проверить полноту, атомарно опубликовать новую epoch и лишь затем очистить старую копию. Порядок можно реализовать иначе — например, ранним cutover с forwarding, — но инвариант один: ни одна подтверждённая запись не должна попасть в промежуток между владельцами.

## Область применимости и версии

Заметка описывает online rebalance replicated shards/ranges. Конкретные примеры сверены с Dynamo 2007, Bigtable 2006, Spanner 2012 и Apache Cassandra 5.0.8, включая bootstrap/decommission и `nodetool cleanup`; проверено 2026-07-18. Команды и переходы Cassandra не являются универсальным протоколом для другой СУБД.

## Ментальная модель

Ребалансировку удобно рассматривать как перенос полномочий, сопровождаемый копированием состояния:

```text
topology e:   range X -> old replica group
data plane:  snapshot + change stream -> new replica group
topology e+1: range X -> new replica group
```

Ownership — утверждение control plane. Оно определяет routing, quorum membership и право отвечать. Movement — работа data plane: чтение, сеть, запись, compaction и checksum. Завершение одного не доказывает завершение другого.

Отсюда четыре инварианта:

1. В каждый момент существует авторитетная epoch для записи.
2. Перед cutover новый owner содержит базовый snapshot и все изменения до согласованной границы.
3. Replica placement после перехода всё ещё выдерживает требуемые failure domains; нельзя одновременно перенести все копии range.
4. Старые bytes удаляются только после проверки нового владельца и истечения окна, в котором старые routers или repairs ещё могут обратиться к прежней карте.

## Как устроено

### Причины и единица переноса

Rebalance запускают не только при изменении числа серверов. Причиной бывают неравные bytes/QPS, уход диска, добавление зоны, смена replication factor или разделение слишком крупной partition. Единицей может быть tablet, shard, directory, token range или vnode. Чем она мельче, тем точнее балансировка и короче одна попытка, но тем больше metadata и фоновых задач.

[[30 Данные/Consistent hashing|Consistent hashing]] уменьшает объём логического remapping при смене состава, но не копирует ни одного байта. Bigtable динамически делит tablets и распределяет их между tablet servers; Spanner может перемещать directory между Paxos groups. В обоих случаях mapping и transfer управляются системой отдельно от ключа приложения.

### Безопасная последовательность

Один из практических вариантов выглядит так:

1. **Plan:** контроллер вычисляет topology `e+1`, но routers продолжают использовать `e`. План ограничивает одновременные moves и не перемещает сразу несколько replicas одного range.
2. **Seed:** receiver копирует snapshot с donor или другой здоровой реплики. Операция имеет устойчивый идентификатор и checkpoint, чтобы продолжиться после рестарта.
3. **Catch up:** записи после snapshot доставляются через журнал изменений, временную dual routing/forwarding схему или повторное сравнение. Граница snapshot и delta не должна оставлять gap.
4. **Validate:** сравниваются row counts, диапазоны, checksums/Merkle trees и replica placement. Проверка должна обнаруживать не только недостающие живые значения, но и tombstones.
5. **Publish:** metadata service публикует `e+1`; старый owner отклоняет запись новой эпохи или перенаправляет её. Clients обновляют routing.
6. **Cleanup:** после safety window и проверки receiver donor удаляет лишние bytes. До этого копия — страховка, а не равноправный owner.

Некоторые системы публикуют нового owner раньше seed и временно читают/форвардят со старого. Это допустимый альтернативный порядок, если протокол явно задаёт источник истины и закрывает concurrent writes. Опасен не конкретный момент cutover, а неописанное состояние, где оба owners считают себя единственными или каждый считает ответственным другого.

### Ограничение воздействия

Rebalance конкурирует с пользовательским workload за disk bandwidth, cache, network, WAL/commit log и compaction budget. Поэтому скорость задают по наблюдаемому headroom, а не по максимальной пропускной способности копирования. Практические предохранители:

- лимит bytes/sec и числа параллельных ranges на donor/receiver;
- пауза при росте p95/p99, replication lag, pending compactions или error rate;
- приоритет маленьких безопасных moves либо ranges, снимающих hotspot;
- отдельный лимит между zones, где сеть дороже и уже;
- resumability и идемпотентность, чтобы временный отказ не начинал terabyte copy заново.

Dynamo подчёркивает, что transient failure не должен автоматически менять membership: иначе короткий сетевой сбой вызывает дорогое и потенциально опасное перемещение. В Cassandra 5.0.8 bootstrap стримит назначенные ranges и может быть продолжен через `nodetool bootstrap resume`; decommission/removenode передают ranges другим репликам. Данные, которые узел больше не должен хранить, автоматически не исчезают: `cleanup` выполняют после того, как новые owners здоровы.

### Наблюдаемость и отмена

План должен показывать для каждого move: старую и новую replica set, bytes remaining, snapshot position, delta lag, checksum state, topology epoch и разрешённость cleanup. Остановить streaming безопаснее, чем откатывать уже опубликованное ownership. После cutover rollback — ещё один контролируемый transfer, если старый owner не получал новые записи.

## Пример или трассировка

В ring из заметки о consistent hashing range `(50,65]` переносится с `C` на новый узел `D`.

1. В epoch `7` router всё ещё отправляет чтения и записи `C`. Контроллер записывает намерение `C -> D`.
2. `D` копирует snapshot range до позиции журнала `LSN=1000`. В это время `C` подтверждает запись ключа `h=60` на `LSN=1001`.
3. Change stream доставляет `1001` на `D`; `D` сообщает `caught_up=1001`. Checksums snapshot и последующих изменений сходятся.
4. Контроллер публикует epoch `8`: owner range — `D`. `C`, получив запрос с epoch `8`, не применяет его локально как авторитетный, а возвращает redirect.
5. Старый client с epoch `7` пишет в `C`. `C` знает о переходе и форвардит/отклоняет запрос с новой картой; запись не остаётся только в старой копии.
6. После обновления routers и проверки `D` запускается cleanup на `C`.

Наблюдаемый результат: ownership меняется один раз, после того как движение достигло известной позиции; запись `LSN=1001` присутствует на `D`. Если опубликовать epoch `8` между шагами 1 и 2 без forwarding, `D` закономерно ответит `not found`. Если очистить `C` до шага 3, rollback и восстановление недостающего delta станут невозможны.

Отказ `D` на середине snapshot не требует менять ownership: epoch остаётся `7`, а transfer продолжается с checkpoint. Это и есть преимущество разделения control plane и data plane.

## Trade-offs

| Выбор | Что выигрываем | Риск или цена |
|---|---|---|
| Быстрый bulk transfer | Короткое окно дисбаланса | Удар по latency, cache и compaction |
| Throttled transfer | Предсказуемый пользовательский SLO | Дольше живёт неравномерность и двойное хранение |
| Мелкие ranges/vnodes | Точный баланс, маленький retry | Metadata и orchestration overhead |
| Крупные shards | Простая карта | Долгий move и грубое распределение |
| Автоматический planner | Быстрая реакция на skew | Oscillation и cascading moves без hysteresis |
| Ручной запуск | Контроль риска | Медленная реакция и человеческие ошибки |

Ближайшая альтернатива movement — изменить routing или capacity без переноса: добавить read replicas, кэш, admission control или временно повысить ресурсы. Это подходит для краткого пика. Если bytes или устойчивый write workload действительно принадлежат перегруженному owner, отсрочка лишь маскирует необходимость split/move.

## Типичные ошибки

- **Неверное предположение:** новая карта означает, что данные уже на месте. **Симптом:** `not found` сразу после topology change. **Причина:** ownership переключили раньше seed/catch-up. **Исправление:** иметь явные состояния move и проверяемую границу cutover.
- **Неверное предположение:** лишняя копия после move безопасно удаляется сразу. **Симптом:** потеря данных после отказа receiver или обращение старого router к пустому donor. **Причина:** cleanup смешали с передачей ownership. **Исправление:** cleanup делать отдельной подтверждаемой фазой после safety window.
- **Неверное предположение:** кратко недоступный узел надо немедленно удалить из topology. **Симптом:** кластер непрерывно стримит ranges при сетевом flapping. **Причина:** failure detector превратили в membership authority. **Исправление:** различать transient unavailability и явное изменение состава.
- **Неверное предположение:** копирование можно запускать на полной скорости. **Симптом:** p99 и compaction backlog растут сильнее исходного дисбаланса. **Причина:** background transfer использует те же bottlenecks. **Исправление:** feedback-based throttling и лимиты параллельности.
- **Неверное предположение:** средняя заполненность кластера показывает безопасность. **Симптом:** donor переполняется или receiver не принимает временную вторую копию. **Причина:** не учтены peak per-node и scratch space. **Исправление:** планировать по worst-case node, размеру range и запасу на compaction.

## Когда применять

Rebalancing нужен при устойчивом перекосе ownership или нагрузки, при плановом изменении topology и после безопасно подтверждённого ухода узла. Для мгновенного transient spike сначала дешевле load shedding или cache: перенос может закончиться уже после пика.

Перед запуском фиксируют причину, целевое placement, максимальный blast radius, лимиты, rollback point и критерий завершения. После него проверяют не только равенство bytes, но и replicas по zones, read/write latency, repair state и отсутствие ranges без владельца или с двумя авторитетными owners. Хороший rebalance заканчивается доказательством корректности, а не сообщением «streaming completed».

## Источники

- [Dynamo: Amazon’s Highly Available Key-value Store](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf) — Amazon, SOSP 2007, проверено 2026-07-18.
- [Adding, replacing, moving and removing nodes](https://cassandra.apache.org/doc/5.0.8/cassandra/managing/operating/topo_changes.html) — Apache Cassandra, документация 5.0.8, проверено 2026-07-18.
- [Dynamo architecture](https://cassandra.apache.org/doc/5.0.8/cassandra/architecture/dynamo.html) — Apache Cassandra, документация 5.0.8, проверено 2026-07-18.
- [Bigtable: A Distributed Storage System for Structured Data](https://research.google.com/archive/bigtable-osdi06.pdf) — Google, OSDI 2006, проверено 2026-07-18.
- [Spanner: Google’s Globally-Distributed Database](https://research.google.com/archive/spanner-osdi2012.pdf) — Google, OSDI 2012, проверено 2026-07-18.
