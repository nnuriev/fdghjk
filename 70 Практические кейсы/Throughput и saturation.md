---
aliases:
  - Throughput and saturation
  - Пропускная способность и насыщение
  - Capacity knee
tags:
  - область/reliability-performance-operations
  - тема/производительность
  - тема/перегрузка
статус: проверено
---

# Throughput и saturation

## TL;DR

Throughput показывает, сколько работы система завершает за единицу времени. Saturation показывает, насколько исчерпан ограничивающий ресурс. Между ними стоит очередь: когда admitted load устойчиво выше service rate, completed throughput упирается в плато, backlog и [[70 Практические кейсы/p50, p95 и p99 latency|tail latency]] растут, а полезная пропускная способность после timeout и retry способна даже падать.

Capacity сервиса — максимальный устойчивый goodput при выполнении latency/error SLO и сохранении способности восстановиться, а не краткий рекорд RPS перед crash. Для диагностики нужны offered, admitted и completed rates, стоимость единицы работы, queue age/depth и saturation каждого потенциального bottleneck.

## Ментальная модель

Сервис похож на конвейер с несколькими узкими местами:

```text
offered load -> admission -> queue -> service -> completed -> useful result
                    |          |          |
                 rejected    waiting   limiting resource
```

Самый медленный участок задаёт устойчивый throughput. Буфер перед ним не увеличивает capacity, он только переносит отказ из явного reject в задержку и расход памяти.

## Как устроено

### Четыре разных rate

Нужно различать:

- `offered rate`: всё, что клиенты пытались отправить, включая blocked и retry attempts;
- `admitted rate`: работа, которую система приняла после quota/load shedding;
- `completed throughput`: завершённые операции в секунду;
- `goodput`: завершённые вовремя корректные операции, полезные пользователю.

При перегрузке completed throughput может оставаться ровным, пока offered load растёт. График «мы по-прежнему делаем 300 RPS» выглядит здоровым, хотя очередь уже обрекла новые запросы на timeout. Goodput падает ещё раньше, если сервис продолжает вычислять ответы после client deadline.

Единица должна соответствовать работе: requests/s для однородного endpoint, bytes/s для transfer, messages/s или records/s для pipeline, transactions/s для базы. Смешанный API требует cost classes. Один export на 10 GiB и один metadata read не равны, даже если оба считаются одним request.

### Service demand и теоретическая граница

Если один запрос в среднем потребляет `D` секунд конкретного ресурса, а доступно `m` одинаковых единиц этого ресурса, простая верхняя граница:

```text
X_max <= m / D
```

Восемь CPU cores и 20 ms CPU time на запрос дают не больше `8 / 0,020 = 400` requests/s, если CPU остаётся единственным bottleneck. Это ceiling модели, не production target: scheduler, GC, kernel, skew, background work и tail service time требуют headroom.

Для каждого ресурса считают свою границу: CPU seconds, disk IOPS/bytes, network bandwidth, DB connections, lock ownership, external quota. Минимальная определяет текущий bottleneck. После оптимизации одного ресурса bottleneck перемещается, поэтому «CPU снизился» ещё не доказывает рост end-to-end capacity.

### Saturation не равна 100% utilization

Saturation начинается, когда ресурсу приходится откладывать или отклонять работу. Её наблюдаемые формы:

- CPU: runnable queue, throttling, steal time, рост scheduling delay;
- memory: GC share, allocation stalls, reclaim, swap и OOM risk;
- thread/goroutine/connection pool: занятые slots, waiters и wait duration;
- disk: queue depth, I/O latency, IOPS/bandwidth ceiling, low free space;
- network: queue/drop/retransmit, bandwidth ceiling;
- broker/worker: oldest item age, consumer lag и растущий backlog;
- sharded storage: один shard на пределе при свободном среднем cluster utilization.

Ресурс способен деградировать до 100%. CPU-bound service обычно получает queueing задолго до абсолютных 100%, а storage latency может резко вырасти у собственного saturation knee. Поэтому target utilization определяют нагрузочным тестом при нужном p99 и recovery time, а не универсальным числом 70%.

### Очередь и закон Литтла

Для устойчивой стационарной системы с конечными средними закон Литтла связывает среднее число работ `L`, effective arrival rate `λ` и среднее время в системе `W`:

```text
L = λ * W
```

Если сервис завершает 200 requests/s со средним end-to-end временем 50 ms, в системе в среднем находится `200 * 0,05 = 10` запросов. Формула включает очередь и обработку, если `W` измерено от admission до completion.

Когда `λ_admitted > X_completed`, стационарности нет. Backlog растёт примерно со скоростью:

```text
dQ/dt = λ_admitted - X_completed
```

Queue depth сам по себе неоднозначен: batch pipeline способен постоянно держать миллион свежих задач и выполнять freshness SLO. Oldest age, arrival/service rates и deadline miss показывают ущерб лучше.

### Capacity knee и performance cliff

При низкой нагрузке throughput растёт почти линейно, latency меняется мало. Возле bottleneck throughput перестаёт расти, а очередь и p99 ускоряются. После knee появляются timeout, retries, cache churn, lock convoy, GC pressure и context switching; completed throughput иногда снижается. Это performance cliff.

Capacity фиксируют как последний устойчивый уровень, где одновременно выполняются:

- latency, availability и correctness SLO;
- bounded queue age и memory;
- приемлемые reject/timeout rates;
- восстановление после снятия overload без restart;
- работа в течение soak period, а не короткого burst;
- запас для отказа replica и rollout.

Связь с [[50 Проектирование систем/Оценка нагрузки и ёмкости|capacity planning]] двусторонняя: прогноз даёт требуемую нагрузку, load test измеряет capacity одной scale unit, production telemetry проверяет, не изменился ли cost per request.

### Взвешивание работы и skew

QPS перестаёт быть capacity metric, когда запросы различаются по цене. Полезно считать нормализованный resource cost:

```text
work_units = cpu_seconds + weighted_io + weighted_external_cost
```

Точная формула зависит от bottleneck и не обязана объединять несопоставимые ресурсы в одно число. Часто лучше держать несколько budgets: CPU seconds/s, database rows scanned/s, bytes/s, concurrent streams.

Средний cluster utilization скрывает [[30 Данные/Hot partitions и hot keys|hot shard/key]]. Поэтому rates и saturation режут по failure domain: shard, partition, zone, instance и bounded tenant class. На dashboard одновременно нужны сумма demand и максимум/распределение по owners.

### Реакция на saturation

Порядок действий следует причинной цепочке:

1. Ограничить admission до устойчивого goodput, приоритизировать критичный трафик и быстро отклонить doomed work.
2. Остановить retry amplification и background work, которое конкурирует за bottleneck.
3. Упростить ответ или отключить дорогую soft dependency.
4. Перераспределить load, добавить уже прогретую capacity либо устранить hot partition.
5. После стабилизации найти изменение service demand, skew или traffic mix.

[[40 Распределённые системы/Load shedding|Load shedding]] сохраняет полезную часть throughput ценой явных rejects. Без него unbounded queue превращает перегрузку в высокую latency, OOM и cascading failure.

## Пример или трассировка

API имеет восемь cores. Профиль показывает 20 ms CPU time на успешный request, поэтому CPU ceiling модели равен 400 RPS. Load test устанавливает, что при 300 RPS p99 ещё укладывается в 250 ms, а при 330 RPS растут runnable queue и p99. Production capacity одной replica фиксируют как 300 RPS, не как 400.

После запуска новой функции:

```text
offered rate   = 360 RPS
admitted rate  = 360 RPS
completed rate = 300 RPS
backlog slope  = 360 - 300 = 60 requests/s
```

Через две минуты очередь прибавит примерно 7 200 запросов. При service rate 300 RPS один только этот backlog означает около 24 секунд работы. Client deadline равен 2 секундам, значит почти все новые запросы уже бесполезны, хотя completed-throughput graph по-прежнему показывает 300 RPS.

On-call включает admission limit 280 RPS, отклоняет batch class и запрещает retries на overload response. Очередь перестаёт расти, goodput восстанавливается, p99 снижается. Затем profile обнаруживает, что новая функция увеличила CPU demand с 20 до 26 ms. Теоретический CPU ceiling стал `8 / 0,026 ≈ 308 RPS`; это объясняет новый knee и даёт решение: оптимизировать функцию или пересчитать число replicas по измеренной capacity.

## Trade-offs

Большой headroom уменьшает queueing и даёт время пережить отказ, но оплачивается простаивающей capacity. Высокая utilization эффективна для batch, где важен aggregate throughput; интерактивный path обычно покупает slack ради tail latency.

Batching уменьшает per-item overhead и повышает throughput. Первый элемент ждёт заполнения batch, а крупный batch дольше удерживает lock/connection, поэтому latency и fairness могут ухудшиться.

Большая concurrency скрывает I/O wait и повышает throughput до bottleneck. После knee она добавляет memory, scheduling и contention. Bounded concurrency выбирают по измеренному service demand и downstream capacity.

Queue сглаживает короткий burst и развязывает producer и consumer. Длинная очередь принимает работу, которую уже нельзя закончить к deadline. Bounded queue с early reject жёстче для клиента, зато сохраняет ресурс на запросы, которые ещё можно обслужить.

## Типичные ошибки

- **Неверное предположение:** throughput равен incoming RPS. **Симптом:** dashboard показывает рост нагрузки как рост capacity, пока timeout rate уже увеличивается. **Причина:** offered и completed rates смешаны. **Исправление:** отдельно считать offered, admitted, completed и goodput.
- **Неверное предположение:** plateau throughput означает стабильность. **Симптом:** completed RPS ровный, queue age и memory растут. **Причина:** bottleneck работает на пределе, избыток копится. **Исправление:** alert на backlog slope/oldest age и admission control.
- **Неверное предположение:** 60% среднего CPU означает большой запас. **Симптом:** один shard timeout-ится при свободных replicas. **Причина:** aggregation скрыла skew или bottleneck не CPU. **Исправление:** saturation по failure domain и каждому ограничивающему ресурсу.
- **Неверное предположение:** больше queue повышает throughput. **Симптом:** p99 доходит до deadline, затем начинаются retry storm и OOM. **Причина:** buffer перепутан с service capacity. **Исправление:** bounded queue, deadline-aware admission и sizing по burst envelope.
- **Неверное предположение:** capacity равна теоретическому `cores / CPU time`. **Симптом:** production cliff наступает раньше. **Причина:** модель не учла tail cost, GC, locks, kernel и failure headroom. **Исправление:** использовать формулу как upper bound, target получать из realistic load/soak test.
- **Неверное предположение:** одинаковый QPS означает одинаковую нагрузку. **Симптом:** после изменения traffic mix service насыщается без роста requests/s. **Причина:** вырос cost per request. **Исправление:** cost classes, payload/rows/bytes и resource demand на операцию.

## Когда применять

Модель нужна при capacity planning, выборе autoscaling signal, load testing и любом incident с ростом latency или backlog. Сначала находят offered/admitted/completed rates, затем конкретный насыщенный ресурс. Масштабировать по CPU бессмысленно, если bottleneck находится в shared database pool или hot key.

Capacity переснимают после заметного изменения binary, runtime, schema, traffic mix и dependency. Старое значение «replica выдерживает 2 000 RPS» не переносится автоматически даже на тот же instance type.

## Источники

- [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) — Google, Site Reliability Engineering, глава 6, проверено 2026-07-18.
- [Handling Overload](https://sre.google/sre-book/handling-overload/) — Google, Site Reliability Engineering, глава 21, проверено 2026-07-18.
- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering, глава 22, проверено 2026-07-18.
- [A Proof for the Queuing Formula: L = λW](https://doi.org/10.1287/opre.9.3.383) — John D. C. Little, Operations Research 9(3), 1961, проверено 2026-07-18.
- [Service Level Objectives](https://sre.google/sre-book/service-level-objectives/) — Google, Site Reliability Engineering, глава 4, проверено 2026-07-18.
