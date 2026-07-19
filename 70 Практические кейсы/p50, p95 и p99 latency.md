---
aliases:
  - p50 p95 p99 latency
  - Percentile latency
  - Перцентили задержки
tags:
  - область/reliability-performance-operations
  - тема/производительность
  - тема/latency
статус: проверено
---

# p50, p95 и p99 latency

## TL;DR

`p50`, `p95` и `p99` описывают точки распределения latency: 50%, 95% и 99% наблюдений не превышают соответствующее значение. `p50` показывает типичный запрос, `p95` и `p99` делают видимым хвост. Они не объясняют максимум, не складываются между сервисами и не агрегируются усреднением готовых percentile по instances.

Полезный latency SLO фиксирует operation, population, measurement boundary, окно и условие успеха. Для распределённого сервиса нужен end-to-end histogram с buckets вокруг SLO boundary, отдельные разрезы по контролируемым классам запросов и проверка load generator на coordinated omission.

## Ментальная модель

Percentile отвечает на вопрос «какая граница покрывает заданную долю запросов?»:

```text
p50 = граница для типичной половины
p95 = граница для 19 из 20 запросов
p99 = граница для 99 из 100 запросов
```

Это карта распределения, не причина задержки. Два сервиса могут иметь одинаковый p99 при разных формах хвоста, максимумах и числе пострадавших пользователей.

## Как устроено

### Определение percentile

Для эмпирической функции распределения `F(t)` percentile порядка `φ` можно определить как минимальное `t`, для которого `F(t) >= φ`:

```text
pφ = inf { t : F(t) >= φ }
```

В nearest-rank методе `N` наблюдений сортируют и берут элемент с индексом `ceil(φ * N)`, считая с единицы. Библиотеки используют разные правила интерполяции, поэтому на маленькой выборке результаты способны отличаться. Сравнивать числа можно только при одинаковом quantile definition или при погрешности, для которой различие методов несущественно.

`p99 = 900 ms` означает, что примерно 99% измеренных операций уложились в 900 ms, а примерно 1% были медленнее. Это не означает, что самый медленный запрос занял 900 ms. Не означает и того, что каждый пользователь увидел медленный ответ ровно в 1% случаев: активный tenant, регион или hot shard может получить большую часть хвоста.

### Measurement boundary и population

Сначала задают начало и конец:

- client click до usable response;
- edge receive до last byte;
- server handler start до response write;
- queue enqueue до durable completion;
- dependency RPC send до result.

Server-side latency не видит client network, DNS, queue перед proxy и rendering. Client-side measurement ближе к user experience, но включает сеть и устройства, которыми сервис не управляет. Обычно [[50 Проектирование систем/SLO в System Design|SLO]] измеряют на пользовательской границе, а внутренние histograms делят бюджет по причинным этапам.

Population включает operation, payload/size class, region и outcome. Быстрые ошибки способны искусственно улучшить общий percentile, поэтому успешные и failed операции показывают раздельно, сохраняя timeout как плохое событие availability/latency SLI. Raw URL, user ID и request ID в labels не используют: cardinality растёт без границы.

### Хвост и fan-out

На p50 часто попадает прогретый cache и незагруженный shard. Хвост формируют queueing, locks, GC, cold cache, page fault, network retransmission, noisy neighbor, hot key и редкий большой payload.

Fan-out усиливает хвост. Если каждый из 20 независимых shard calls укладывается в локальную границу с вероятностью 99%, то вероятность, что все уложатся, равна:

```text
0,99^20 ≈ 0,818
```

Запрос, который ждёт все shards, встретит хотя бы один медленный ответ примерно в 18,2% случаев. Поэтому `p99(A) + p99(B)` не даёт p99 цепочки, а component p99 не гарантирует end-to-end p99. Нужен histogram конечного user journey; component distributions помогают найти причину.

### Histogram, summary и агрегация

Среднее хранит `sum/count` и почти ничего не говорит о форме хвоста. Histogram хранит counts по buckets; из объединённых counts можно оценить percentile для всего fleet. Bucket около SLO boundary важнее красивого набора `p50/p95/p99`: SLO обычно спрашивает точную долю запросов быстрее `T`, и histogram считает её без интерполяции, если `T` совпадает с границей bucket.

Для classic histogram в Prometheus агрегированный p95 выглядит так:

```promql
histogram_quantile(
  0.95,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)
```

Для native histogram:

```promql
histogram_quantile(
  0.95,
  sum(rate(http_request_duration_seconds[5m]))
)
```

`avg(instance_p95)` статистически неверен: instance с десятью запросами получает тот же вес, что instance с миллионом, а готовый quantile не содержит исходного распределения. Prometheus summary вычисляет quantiles в приложении и удобен для локального stream, но предвычисленные quantiles нельзя осмысленно сложить между replicas. Histogram выбирают, когда нужна fleet aggregation и смена query percentile после instrumenting.

Histogram возвращает оценку. В classic histogram погрешность ограничивает ширина bucket, в native histogram разрешение схемы. Широкий bucket `[0.1s, 1s]` способен нарисовать p99 по интерполяции далеко от реального значения. Bucket layout проверяют по рабочему диапазону и SLO threshold.

### Окно, объём выборки и редкие quantiles

Percentile всегда относится к окну. Короткое окно быстрее ловит regression, но p99 скачет при малом числе наблюдений. Длинное окно стабильно, зато смешивает разные rollout versions и долго удерживает старый incident.

При 100 запросах p99 определяется одним из самых крайних наблюдений. Для p99.9 нужны существенно большие выборки, иначе единичный запрос меняет результат целиком. Вместе с percentile показывают count и, для сравнения canary, доверие к объёму выборки. Low-traffic path часто лучше защищать пороговым SLI «доля операций <= T» плюс synthetic checks, чем графиком шумного p99.

### Coordinated omission

Closed-loop load generator отправляет следующий запрос лишь после предыдущего ответа. Когда service завис на секунду, generator тоже замолчал и не создал запросы, которые реальные независимые пользователи прислали бы за эту секунду. Из выборки исчезает очередь, а p99 выглядит лучше.

Open-loop или constant-arrival-rate test планирует arrivals независимо от response time и измеряет latency с момента запланированной отправки. При перегрузке он сохраняет queueing delay и missed starts. Это особенно важно при поиске saturation knee; иначе тест измеряет саморегулирующуюся нагрузку, а не заявленный offered load.

## Пример или трассировка

Пусть измерены 20 успешных end-to-end запросов в миллисекундах:

```text
10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
20, 21, 22, 23, 24, 25, 26, 27, 100, 1000
```

По nearest-rank:

```text
p50: ceil(0,50 * 20) = 10-й элемент = 19 ms
p95: ceil(0,95 * 20) = 19-й элемент = 100 ms
p99: ceil(0,99 * 20) = 20-й элемент = 1000 ms
```

Сумма наблюдений равна `1433 ms`, поэтому среднее составляет `1433 / 20 = 71,65 ms`, хотя 18 из 20 запросов быстрее 28 ms. Оно завышает типичную latency и одновременно скрывает, что один запрос занял целую секунду. p50 показывает основной кластер, p95 захватывает первый tail event, p99 на столь маленькой выборке совпадает с максимумом по nearest-rank и нестабилен.

Теперь сервис запускает canary. Общий p99 за час остаётся 400 ms, но разрез по version даёт 220 ms для control и 900 ms для canary. Общая агрегация скрыла regression из-за малого веса canary. Rollout gate должен сравнивать одинаковые operation/region/payload classes, учитывать sample count и проверять абсолютный SLO, а не только относительную разницу.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| Prometheus 2.40.0, ноябрь 2022 | Native histograms отсутствовали в стабильной модели | Появились как experimental feature за feature flag | Можно было собирать mergeable exponential histograms, но нельзя было считать контракт стабильным | [Native Histograms](https://prometheus.io/docs/specs/native_histograms/) |
| Prometheus 3.8.0 | Feature оставалась experimental | Native histograms получили stable status; scraping всё ещё включается явно через `scrape_native_histograms` | Миграцию можно планировать на стабильный формат, но одного upgrade недостаточно для ingestion | [Native Histograms](https://prometheus.io/docs/specs/native_histograms/) |
| Prometheus 3.13.1, 2026-07-10 | Предыдущие minor/LTS версии имели свои support windows | 3.13.1 опубликована как актуальная LTS на дату проверки | Версионные инструкции и поведение нужно сверять с 3.13, не с примерами эпохи 2.x | [Download](https://prometheus.io/download/) |

## Trade-offs

Высокий percentile защищает редкий хвост, но требует больше samples, точнее histogram и дороже инфраструктурно. p50 стабилен и полезен для базовой эффективности, зато не видит небольшую группу сильно пострадавших запросов. Обычно публикуют пару SLO thresholds или percentile: один для основной массы, второй для хвоста.

Более мелкие buckets уменьшают quantile error, но увеличивают series/storage cost у classic histograms. Native histogram хранит sparse buckets эффективнее и допускает merge совместимых схем, однако требует поддержки exporter, ingestion, remote write и query path.

Hedged requests снижают tail latency, отправляя дополнительную попытку после задержки. Цена состоит в дополнительной нагрузке, которая при saturation способна ухудшить тот же хвост. Сначала устраняют queueing и hot spots, затем вводят hedging с budget, cancellation и проверкой общей нагрузки.

## Типичные ошибки

- **Неверное предположение:** p99 равен максимуму. **Симптом:** единичные минутные зависания не видны в SLO. **Причина:** percentile отбрасывает верхний 1% распределения. **Исправление:** показывать timeout/error SLI, max для диагностики и несколько tail thresholds по цене ущерба.
- **Неверное предположение:** percentile можно усреднить между instances. **Симптом:** fleet p95 выглядит лучше или хуже реального. **Причина:** quantile потерял counts и форму распределения. **Исправление:** суммировать histogram buckets/counts, затем вычислять percentile.
- **Неверное предположение:** component p99 складывается в end-to-end p99. **Симптом:** каждый dependency выполняет target, user path нет. **Причина:** quantiles нелинейны, fan-out повышает шанс tail event. **Исправление:** измерять end-to-end distribution и распределять latency budget по dependencies.
- **Неверное предположение:** общий p99 показывает каждого пользователя. **Симптом:** один region или tenant постоянно медленный при зелёном global graph. **Причина:** большой здоровый поток маскирует failure domain. **Исправление:** bounded slicing по region/version/operation и отдельный SLO для критичного класса.
- **Неверное предположение:** любой histogram точно восстанавливает p99. **Симптом:** p99 скачет внутри широкого bucket и не совпадает с raw samples. **Причина:** interpolation и неподходящие границы. **Исправление:** buckets вокруг SLO boundary, достаточное разрешение и сравнение с trace/log samples.
- **Неверное предположение:** closed-loop benchmark честно измеряет overload. **Симптом:** p99 остаётся низким, хотя production queue растёт. **Причина:** generator перестаёт посылать traffic, пока ждёт медленный ответ. **Исправление:** constant-arrival-rate test и latency от scheduled arrival.

## Когда применять

Percentiles нужны для интерактивных API, queues, storage operations и любых workflow с несимметричным распределением времени. Перед выбором p95 или p99 определяют цену медленного события и объём трафика. Percentile без count, окна и population непригоден для решения.

При диагностике сопоставляют p50, p95, p99, throughput, queue age и saturation. Если p50 стабилен, а p99 растёт, ищут локальный contention, hot shard и редкие pauses. Если все percentiles растут вместе, вероятнее общий service-time regression или системная очередь.

## Источники

- [Service Level Objectives](https://sre.google/sre-book/service-level-objectives/) — Google, Site Reliability Engineering, глава 4, проверено 2026-07-18.
- [Histograms and summaries](https://prometheus.io/docs/practices/histograms/) — Prometheus, документация для 3.x, проверено 2026-07-18.
- [Native Histograms](https://prometheus.io/docs/specs/native_histograms/) — Prometheus, stable начиная с 3.8.0, проверено 2026-07-18.
- [The Tail at Scale](https://research.google/pubs/the-tail-at-scale/) — Google Research, Jeffrey Dean и Luiz André Barroso, Communications of the ACM 56, 2013, проверено 2026-07-18.
- [wrk2 README](https://github.com/giltene/wrk2/blob/44a94c17d8e6a0bac8559b53da76848e430cb7a7/README.md) — `giltene/wrk2`, commit `44a94c17d8e6a0bac8559b53da76848e430cb7a7`, проверено 2026-07-18.
