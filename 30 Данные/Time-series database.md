---
aliases:
  - TSDB
  - Time-series DB
  - База данных временных рядов
tags:
  - область/данные
  - тема/выбор-хранилища
статус: проверено
---

# Time-series database

## TL;DR

Time-series database (TSDB) оптимизирует append-heavy данные, где timestamp задаёт главный порядок, series identity повторяется, queries читают time ranges и агрегируют по окнам, а старые данные имеют retention/downsampling lifecycle. Она выигрывает за счёт time partitioning, compression одинаковых series и специализированных range/aggregation paths.

Главный предел часто задаёт не число samples, а cardinality series. Если каждый `request_id` становится label, система создаёт новый индексируемый ряд почти на каждый запрос и теряет locality/compression. Event log с уникальными payload и metrics time series — разные workload, хотя обе записи имеют timestamp.

## Область применимости

Конкретный storage trace относится к Prometheus 3.11.3 local TSDB. Prometheus хранит labels plus timestamped samples, использует WAL и initial two-hour blocks, затем compact-ит их в более крупные blocks. Это monitoring-oriented single-node storage; долгосрочное распределённое хранение обычно добавляет remote system. Иные TSDB могут быть SQL/columnar, clustered или object-storage based, поэтому limits late data, transactions и consistency сверяют отдельно.

Prometheus server в workspace отсутствует. Sample trace не исполнялся; data model и storage lifecycle сверены с документацией и tag `v3.11.3`.

## Ментальная модель

Один ряд (series) — функция времени, идентифицированная стабильным набором labels:

```text
series = metric name + {label=value, ...}
sample = (timestamp, value)
```

Labels отвечают «какой это ряд?», timestamp — «где точка внутри ряда?». Storage группирует соседние timestamps одного ряда, а query engine режет данные по time range. Если в identity попадает уникальное событие, вместо длинных рядов получаются миллионы рядов из одной точки. Это худший обмен: дорогой индекс и почти никакой compression.

## Как устроено

### Ingest и идентичность

Writer нормализует label set и находит series ID, затем добавляет sample по времени. Повторяющиеся labels не сохраняются целиком рядом с каждой точкой; samples одного series можно кодировать блоками и сжимать через близкие timestamps/values. Цена — in-memory index и metadata на каждую активную series.

### Time partitioning и blocks

Prometheus сначала пишет новые samples в mutable head и WAL для crash recovery. Persisted blocks покрывают time ranges и содержат chunks, index и metadata. Начальные двухчасовые blocks позже объединяются background compaction; размер blocks растёт до ограничений retention policy. Query за последние пять минут читает head/последние chunks, а годовой range затрагивает много blocks и намного больше bytes.

Time partitioning упрощает retention: старые целые blocks удаляются дешевле, чем отдельные rows. Но disk capacity должен учитывать WAL, head chunks, compaction overlap и delayed deletion, а не только итоговые compressed samples.

### Aggregation, rollup и retention

Типичные операции — rate, sum/avg/max по окну, grouping по небольшому набору labels и downsampling. Raw resolution нужна недолго, aggregated series — дольше. Retention не равна backup: удаление по времени исполняет lifecycle, но не защищает от повреждения или ошибочного delete.

### Late и out-of-order data

Append path проще, когда timestamps близки к текущему времени и монотонны внутри series. Late samples заставляют менять уже закрытые time ranges или держать отдельный reconciliation path; точный допустимый window зависит от продукта. Перед выбором нужно знать lateness distribution, clock policy и semantics duplicate timestamp.

## Сквозной пример

Собираем CPU с 1000 devices:

```text
device_cpu_usage{device_id="sensor-7",region="am"} 0.73 @ 2026-07-18T12:00:00Z
device_cpu_usage{device_id="sensor-7",region="am"} 0.78 @ 2026-07-18T12:00:15Z
```

`device_id` и `region` стабильны, поэтому 15-секундные samples дописываются в тот же series. Query среднего CPU по region за пять минут читает ограниченный time range и агрегирует рядовые chunks.

Если добавить label `request_id`, каждая точка создаст отдельную series:

```text
device_cpu_usage{device_id="sensor-7",region="am",request_id="9f..."} 0.73
```

Наблюдаемый результат: число samples почти не изменилось, а число series выросло до числа requests. Индекс, head memory и query fan-out растут, compression ухудшается. `request_id` нужно отправить в logs/traces либо хранить как event field в другой системе.

Crash trace Prometheus другой: samples, чьи записи сохранились в WAL, при рестарте восстанавливаются в head; позже block persistence и compaction меняют физическое размещение, не series identity. Сам факт acknowledgment не стоит трактовать как гарантию пережить power loss без отдельно подтверждённой flush boundary конкретной версии и конфигурации. Поэтому monitoring включает WAL corruption/replay time, block compaction и retention, а не только ingest rate.

## Trade-offs

### TSDB или обычный SQL

PostgreSQL подходит для умеренного объёма, rich relations и transactions рядом с measurements; time partitioning и indexes можно добавить постепенно. Специализированная TSDB выигрывает при постоянном ingest, time-window queries, compression и lifecycle старых данных. Цена — более узкая модель и ограничения на updates/joins.

### TSDB или wide-column

[[30 Данные/Wide-column store|Wide-column store]] хорошо хранит `entity + time bucket -> ordered events`, особенно если payload нужен по key/range. TSDB добавляет series index, time functions, rollups и monitoring query language. High-cardinality events могут оказаться естественнее в wide-column/OLAP, чем в metrics TSDB.

### TSDB или OLAP

TSDB оптимизирует time-first ingest и bounded time windows. [[30 Данные/OLTP и OLAP|OLAP engine]] сильнее для широких scans, joins и многомерной аналитики по большому historical corpus. Многие архитектуры держат recent operational metrics в TSDB, а долгую историю экспортируют в columnar/object storage.

## Типичные ошибки

- **Неверное предположение:** любой timestamped event — time series. **Симптом:** cardinality и memory растут быстрее samples. **Причина:** уникальные IDs превращены в labels. **Исправление:** разделить stable dimensions и event attributes; задать cardinality budget до ingest.
- **Неверное предположение:** retention гарантирует сохранность. **Симптом:** после ошибки или corruption восстановить series нечем, хотя retention был 90 дней. **Причина:** retention управляет удалением, а не резервной копией. **Исправление:** отдельный backup/remote replication contract и проверка restore.
- **Неверное предположение:** средний ingest rate описывает capacity. **Симптом:** scrape burst, WAL replay или compaction насыщают disk и p99. **Причина:** background I/O и head cardinality не попали в расчёт. **Исправление:** моделировать peak samples/s, active series, bytes, compaction headroom и recovery time.
- **Неверное предположение:** late data примется как обычный append. **Симптом:** samples отклоняются или historical aggregates расходятся. **Причина:** продукт ограничивает out-of-order window/closed blocks. **Исправление:** измерить lateness, синхронизировать clocks, выбрать backfill path и пересчёт rollups.

## Когда применять

TSDB подходит для metrics, sensor telemetry, market observations и других потоков, где series identity стабильна, writes в основном append, чтение ограничено временем, а retention/rollups — часть продукта. До выбора посчитайте samples/s, active series, churn, label cardinality, raw retention, query windows, late-arrival window и restore objective.

Если запросы в основном ищут отдельные события по произвольным полям, нужен [[30 Данные/Search index|search index]] или log store. Если аналитика делает широкие joins и многомерные scans по годам, сравните columnar OLAP. TSDB не освобождает от workload model, она лишь делает time-first workload дешевле.

## Источники

- [Storage](https://prometheus.io/docs/prometheus/latest/storage/) — Prometheus project, Prometheus 3.11.3, WAL, blocks, compaction и retention, проверено 2026-07-18.
- [Data model](https://prometheus.io/docs/concepts/data_model/) — Prometheus project, Prometheus 3.11.3, series labels и samples, проверено 2026-07-18.
- [Naming metrics and labels](https://prometheus.io/docs/practices/naming/) — Prometheus project, Prometheus 3.11.3, проверено 2026-07-18.
- [Prometheus 3.11.3 release](https://github.com/prometheus/prometheus/releases/tag/v3.11.3) — prometheus/prometheus, tag `v3.11.3`, commit `eb173f5`, проверено 2026-07-18.
- [Prometheus TSDB format](https://github.com/prometheus/prometheus/blob/v3.11.3/tsdb/docs/format/README.md) — prometheus/prometheus, tag `v3.11.3`, формат blocks/WAL, проверено 2026-07-18.
