---
aliases:
  - Horizontal scaling
  - Vertical scaling
  - Горизонтальное и вертикальное масштабирование
tags:
  - область/reliability-performance-operations
  - тема/масштабирование
статус: проверено
---

# Horizontal и vertical scaling

## TL;DR

Vertical scaling увеличивает ресурсы одной единицы: CPU, memory, IOPS или размер узла. Horizontal scaling добавляет параллельные единицы и распределяет между ними работу. Вертикальный путь обычно проще и быстрее до жёсткого предела; горизонтальный повышает ceiling и позволяет пережить потерю экземпляра, но требует partitionable workload, routing, координации и управления состоянием.

Масштабировать надо насыщаемый ресурс, а не график, который случайно с ним коррелирует. Новая capacity полезна только после provisioning, startup, warm-up и включения в routing, поэтому autoscaling остаётся запаздывающим control loop и не заменяет headroom.

## Ментальная модель

Для stateless serving layer грубая верхняя граница выглядит так:

```text
available capacity = ready units * useful capacity per unit
safe capacity = available capacity - failure reserve - variance reserve
```

Vertical scaling меняет второй множитель. Horizontal scaling меняет первый. Формула перестаёт быть линейной, если единицы конкурируют за shared database, lock, network link или hot shard. Тогда добавление replicas переносит bottleneck вниз по цепочке и иногда ухудшает его дополнительными соединениями и fan-out.

## Как устроено

### Vertical scaling

Процессу дают больше CPU/memory, database переезжает на более мощный узел, disk получает больше IOPS. Приложение и модель данных часто не меняются. Это сильный первый шаг, когда workload плохо делится, а предел машины далёк.

Но прирост редко линейный. Один lock не ускоряется от дополнительных cores; heap побольше удлиняет некоторые GC cycles; NUMA и memory bandwidth меняют cost. Resize может потребовать restart, а отказ одной большой единицы сохраняет крупный blast radius. Есть физический и продуктовый ceiling.

### Horizontal scaling

Работа распределяется между replicas, workers, partitions или cells. Stateless requests требуют load balancing и shared либо внешнего state. Stateful слой дополнительно требует partition key, replication, membership, rebalancing и правила consistency. Horizontal read replicas не увеличивают write capacity одного лидера; добавление consumers не ускорит одну partition, если ordering запрещает параллельную обработку.

Главный инвариант: два экземпляра не должны одновременно владеть неделимым side effect без coordination. Session affinity, local cache и in-memory queue превращают якобы stateless instance в владельца состояния и осложняют scale-in.

### Autoscaling работает с задержкой

Контур состоит из пяти шагов:

```text
measure -> aggregate -> decide -> provision -> become ready and warm
```

Метрика должна предсказывать дефицит capacity. CPU подходит для однородного CPU-bound workload. Queue age или backlog per consumer лучше для async processing. Concurrency полезнее RPS, если cost запроса сильно меняется. Для memory leak масштабирование по memory лишь размножает утечку.

Нужны min/max, target utilization, cooldown/stabilization, лимит скорости scale-up/down и capacity floor на отказ. Scale-in обязан дождаться drain: иначе прерываются requests, теряются локальные buffers или начинается rebalance storm.

### Два уровня масштабирования надо согласовать

Replica autoscaler добавляет pods/processes, node autoscaler даёт им место. Если первый сработал раньше второго, replicas остаются pending. Если каждый новый pod открывает 50 DB connections, горизонтальный рост с 20 до 100 pods потребует до 4 000 дополнительных connections и способен исчерпать database раньше CPU.

[[40 Распределённые системы/Backpressure и queue buildup|Backpressure]] и admission control нужны даже при autoscaling: demand может расти быстрее provisioning или превысить max capacity. [[50 Проектирование систем/Оценка нагрузки и ёмкости|Capacity plan]] задаёт floor и headroom, autoscaler адаптирует supply внутри проверенного диапазона.

## Пример или трассировка

Один экземпляр с 4 vCPU выдерживает 200 RPS при целевом p99. Peak должен вырасти до 700 RPS, рабочий target равен 70% измеренной capacity.

Вертикальный тест с 16 vCPU даёт 620 RPS, а не 800: shared lock и memory bandwidth ограничили прирост. Одного узла всё равно недостаточно для 700 RPS и нет запаса на его отказ.

При горизонтальном варианте безопасная ёмкость одного 4-vCPU экземпляра равна:

```text
200 RPS * 0,70 = 140 RPS
```

Пять ready replicas дают 700 RPS, но потеря одной снижает supply до 560 RPS. Для N+1 нужны шесть: после отказа останутся пять и сохранят 700 RPS. Это 24 vCPU против 16 vCPU у vertical-варианта, зато failure domain меньше.

Новый экземпляр становится ready и прогревает cache за 90 секунд, а всплеск приходит за 30 секунд. Reactive autoscaling не успеет. Наблюдаемый результат: minimum надо поднять до шести перед известным peak либо масштабироваться по опережающему сигналу. После события scale-in идёт постепенно с connection drain, иначе экономия вызовет churn и p99 spike.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| Kubernetes v1.35, проверено 2026-07-18 | Изменение CPU/memory работающего Pod обычно связывали с пересозданием; механизмы зависели от autoscaler | In-place Pod resize получил статус stable и включён по умолчанию; VPA при этом остаётся отдельным add-on со своими версиями и режимами обновления | Стабильность Pod API сама по себе не делает любой vertical autoscaling безрестартным: нужно проверить версию и `updateMode` конкретного VPA | [Autoscaling Workloads](https://kubernetes.io/docs/concepts/workloads/autoscaling/) |
| VPA v1.7.0, проверено 2026-07-18 | Более старая обзорная страница Kubernetes, обновлённая 2025-11-23, ещё утверждает, что VPA не поддерживает in-place resize | VPA v1.7.0 добавил alpha-режим `InPlace`; актуальная профильная документация также описывает `InPlaceOrRecreate`, который при невозможности resize пересоздаёт Pod, и `InPlace`, который не делает eviction, а откладывает изменение и повторяет попытку. Для `InPlace` нужны Kubernetes >= 1.33 и feature gates | Поведение зависит не от слова «VPA», а от версии и режима: `InPlaceOrRecreate` допускает disruption, а `InPlace` сохраняет Pod ценой потенциально долгого ожидания resize | [Vertical Pod Autoscaling](https://kubernetes.io/docs/concepts/workloads/autoscaling/vertical-pod-autoscale/), [VPA v1.7.0 release](https://github.com/kubernetes/autoscaler/releases/tag/vertical-pod-autoscaler-1.7.0) |

## Trade-offs

| Подход | Выигрыш | Цена и предел |
| --- | --- | --- |
| Vertical | Меньше изменений в приложении, нет распределения requests/state | Жёсткий ceiling, крупный failure domain, resize/restart и нелинейный прирост |
| Horizontal replicas | Elasticity, rolling replacement, N+1 и меньшая единица отказа | Routing, duplicated caches/connections, coordination и shared bottlenecks |
| Partitioning/cells | Масштабирует state и ограничивает blast radius | Выбор key, hot partitions, rebalancing, cross-partition operations |
| Static headroom | Мгновенно принимает burst и отказ | Постоянная стоимость idle capacity |
| Reactive autoscaling | Снижает idle cost при предсказуемом control loop | Detection/provisioning lag, oscillation и max-capacity boundary |

Практическая последовательность обычно такая: сначала убрать очевидный bottleneck и разумно увеличить единицу, затем горизонтально масштабировать независимую работу. Преждевременное шардирование дороже нескольких более крупных узлов; бесконечный vertical путь откладывает, но не устраняет потолок.

## Типичные ошибки

- **Неверное предположение:** replicas дают линейный throughput. **Симптом:** frontend CPU падает, DB latency растёт. **Причина:** bottleneck общий для всех replicas. **Исправление:** строить resource graph и тестировать end-to-end.
- **Неверное предположение:** CPU autoscaler видит любой дефицит. **Симптом:** queue age растёт при низком CPU. **Причина:** workers ждут I/O, lock или quota. **Исправление:** сигнал по ограничивающему ресурсу или backlog-age.
- **Неверное предположение:** autoscaler реагирует мгновенно. **Симптом:** SLO сгорает до появления ready capacity. **Причина:** aggregation, provisioning и warm-up lag. **Исправление:** headroom, scheduled/predictive floor и ранний сигнал.
- **Неверное предположение:** scale-in симметричен scale-out. **Симптом:** оборванные запросы и rebalance storm. **Причина:** удалены владельцы state и connections без drain. **Исправление:** termination protocol, disruption budget и ограниченная скорость уменьшения.
- **Неверное предположение:** vertical resize лечит leak. **Симптом:** OOM происходит позже, но на более дорогом узле. **Причина:** расход ресурса растёт со временем, а не с полезной нагрузкой. **Исправление:** профиль/heap evidence и устранение причины до изменения limit.

## Когда применять

Vertical scaling выигрывает для single-writer database, legacy процесса и ранней стадии, когда простота важнее предельной elasticity. Horizontal scaling нужен, когда workload делится, требуется N+1, независимый rollout или рост вышел за предел одной единицы. Stateful horizontal scaling начинают только после выбора partition key и проверки cross-partition invariants.

В production фиксируют не «автомасштабирование включено», а диапазон: signal, target, min/max, полный reaction time, warm capacity, downstream budget и поведение после max. Этот контракт проверяют load/spike test, включая потерю одной единицы.

## Источники

- [Horizontal Pod Autoscaling](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/) — Kubernetes, документация v1.36, HPA control loop и metrics APIs, проверено 2026-07-18.
- [Autoscaling Workloads](https://kubernetes.io/docs/concepts/workloads/autoscaling/) — Kubernetes, документация v1.36, horizontal/vertical scaling и stable in-place Pod resize начиная с v1.35; страница обновлена 2025-11-23 и не отражает появление VPA v1.7.0, проверено 2026-07-18.
- [Vertical Pod Autoscaling](https://kubernetes.io/docs/concepts/workloads/autoscaling/vertical-pod-autoscale/) — Kubernetes, документация v1.36, режимы VPA `InPlaceOrRecreate` и alpha `InPlace` для VPA v1.7.0, проверено 2026-07-18.
- [VPA v1.7.0 release](https://github.com/kubernetes/autoscaler/releases/tag/vertical-pod-autoscaler-1.7.0) — kubernetes/autoscaler, tag `vertical-pod-autoscaler-1.7.0`, добавление режима `InPlace`, проверено 2026-07-18.
- [Handling Overload](https://sre.google/sre-book/handling-overload/) — Google, Site Reliability Engineering, глава 21, capacity и overload protection, проверено 2026-07-18.
- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering, глава 22, headroom, slow startup и overload, проверено 2026-07-18.
