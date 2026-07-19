---
aliases:
  - OLTP vs OLAP
  - Online transaction processing и online analytical processing
tags:
  - область/данные
  - тема/выбор-хранилища
статус: проверено
---

# OLTP и OLAP

## TL;DR

OLTP (online transaction processing) обслуживает много коротких конкурентных операций над небольшим числом rows: point lookup, insert/update, проверка invariants и быстрый commit. OLAP (online analytical processing) сканирует большие диапазоны, читает несколько columns, делает joins/aggregations и ценит throughput одного запроса больше, чем latency единичной mutation.

Различие задаёт workload, а не SQL syntax. Row-oriented heap и B-tree естественны для OLTP; columnar storage, compression, vectorized execution и data skipping — для OLAP. Одна система может поддерживать оба режима, но одновременно тяжёлый scan и latency-sensitive transactions конкурируют за CPU, memory и I/O. Часто дешевле разделить контуры и принять измеряемый freshness lag.

## Область применимости

TPC-C 5.11.0 используется как формальная модель OLTP workload, TPC-H 3.0.1 — decision-support/OLAP workload. Это benchmark specifications, а не универсальные production SLO. Row-layout trace относится к PostgreSQL 18.4; column-oriented принципы подтверждаются C-Store и MonetDB/X100 papers. Конкретные isolation, update и ingest возможности аналитических продуктов различаются.

SQL-фрагмент ниже иллюстрирует форму workload и не исполнялся: локальной PostgreSQL и benchmark dataset нет. Заметка не заявляет собственных performance measurements.

## Ментальная модель

OLTP отвечает на вопрос «можно ли сейчас корректно провести эту операцию?». OLAP отвечает «что произошло со всем набором данных и почему?».

Эти вопросы двигают физический дизайн в разные стороны:

```text
OLTP: найти несколько rows -> проверить invariant -> изменить -> commit
OLAP: отфильтровать blocks -> прочитать нужные columns -> агрегировать batches
```

Оптимизировать один путь заодно для другого удаётся лишь до определённой нагрузки. Потом компромисс проявляется в layout, indexes, concurrency control и resource scheduling.

## Как устроено

### OLTP path

Row store держит значения одной tuple рядом. Lookup по primary/secondary B-tree находит heap row; transaction locks/MVCC согласуют concurrent writers; WAL делает commit recoverable. Такой layout хорошо возвращает весь order и меняет его status. Тяжёлый aggregate всё равно читает множество pages, включая columns, которые запросу не нужны.

TPC-C моделирует mix New-Order, Payment, Order-Status, Delivery и Stock-Level с concurrent terminals и transactional consistency requirements. Смысл не в конкретном benchmark score, а в коротких state-changing operations и contention за актуальные records.

### OLAP path

Column store располагает values одного column вместе. Query `SUM(amount) GROUP BY region` читает `amount` и `region`, не вытаскивая address, payload и десятки других fields. Однородные blocks лучше кодируются; operators обрабатывают vectors/batches, а min/max или sparse metadata пропускает blocks до decompression.

TPC-H задаёт business-oriented ad hoc queries и concurrent query streams по большой decision-support schema. Updates поступают refresh functions крупнее обычной OLTP mutation. Это отражает приоритет scan/aggregation throughput.

### Разделение контуров

Primary OLTP database commit-ит бизнес-факт. CDC/outbox переносит изменения в analytical model, где schema может быть star/wide table, а данные сортируются под scans. [[40 Распределённые системы/Transactional outbox и Change Data Capture|CDC]] не даёт нулевой lag: dashboard показывает версию до некоторого source position. Freshness SLO, deduplication, delete handling и rebuild входят в контракт.

HTAP/hybrid engine может обслужить оба workload без внешнего pipeline, но тогда нужно доказать resource isolation, update behavior и recovery на своей смеси запросов. Ярлык HTAP не отменяет физику bytes и contention.

## Сквозной пример

Checkout проводит операцию:

```text
read inventory item 9
verify available >= 2
insert order 42 and two order lines
decrement inventory
commit
```

Это OLTP: несколько rows, invariant «не продать больше остатка», concurrent writers и latency ответа пользователю. Индексы ускоряют point lookups; transaction делает результат целым.

Dashboard запускает:

```sql
SELECT region, date_trunc('day', created_at), sum(total)
FROM orders
WHERE created_at >= current_date - interval '365 days'
GROUP BY region, date_trunc('day', created_at);
```

Это OLAP: scan года, два dimensions и aggregate по множеству orders. На row-store запрос читает heap/index pages и конкурирует с checkout за buffer cache/I/O. В columnar copy достаточно нужных columns и blocks.

При разделении checkout commit-ит в OLTP в `12:00:00.000`; CDC доставляет change в OLAP в `12:00:02.300`. Наблюдаемый результат: пользователь сразу видит order в transactional API, dashboard отстаёт на 2.3 s. Это не «потеря consistency», если freshness contract явно допускает такой lag и pipeline контролирует source offset.

## Trade-offs

| Свойство | OLTP | OLAP |
| --- | --- | --- |
| Типичный scope | Несколько rows/keys | Большой range или весь fact set |
| Operations | Point reads, inserts, updates, short transactions | Scans, joins, group by, window/aggregate |
| Приоритет | p95/p99 transaction latency и correctness | Query throughput, bytes scanned, concurrency classes |
| Layout | Чаще row-oriented + B-tree | Чаще columnar + compression/skipping |
| Writes | Малые concurrent mutations | Batch/append/merge, updates зависят от engine |
| Свежесть | После commit согласно isolation | Зависит от ingest/refresh position |

### Один engine или два

Один engine проще: нет CDC, дублирования schema и reconciliation. Два изолируют resource peaks и позволяют каждому layout соответствовать workload. Цена второго — pipeline, lag, duplicate handling, security и две операционные системы. Разделять стоит после измеримого конфликта или требования, которое primary engine не закрывает.

### Предвычисление или ad hoc

Materialized views/rollups ускоряют повторяемые dashboards и переносят compute на ingest. Ad hoc OLAP сохраняет flexibility, но требует больше scan capacity. Выбор зависит от query diversity и freshness, а не от размера красивого dashboard.

## Типичные ошибки

- **Неверное предположение:** read replica автоматически становится OLAP database. **Симптом:** тяжёлый query создаёт replica lag, WAL retention и failover risk. **Причина:** layout и execution engine остались OLTP, изменилась только копия. **Исправление:** ограничить workload или выгрузить в layout, рассчитанный на analytics.
- **Неверное предположение:** columnar означает быстрый любой запрос. **Симптом:** point lookup/частые single-row updates имеют высокий overhead. **Причина:** columnar blocks и batch execution не соответствуют мелкой mutation. **Исправление:** оставить serving state в OLTP или проверить специализированные indexes/row cache конкретного engine.
- **Неверное предположение:** dashboard читает «текущую истину». **Симптом:** цифра не совпадает с API сразу после операции. **Причина:** CDC/refresh lag и другая snapshot boundary. **Исправление:** показывать freshness watermark, alert по lag и сверять counts/checksums.
- **Неверное предположение:** средняя latency скрывает отсутствие interference. **Симптом:** редкий report ломает checkout p99. **Причина:** scan вытесняет hot pages и забирает CPU/I/O. **Исправление:** workload isolation, statement limits, replicas или отдельный OLAP contour; измерять совместный workload.

## Когда применять

Проектируйте OLTP для order/user/inventory/payment state, где операция меняет небольшой working set и должна защищать invariants. Проектируйте OLAP для BI, product analytics, historical reporting и exploration, где queries агрегируют большие ranges.

Сначала измерьте на одном engine: объём scan, columns touched, concurrency, p99 transactions и acceptable freshness. Разделяйте, когда analytical load нарушает OLTP SLO, columnar layout даёт существенный выигрыш или retention/schema аналитики расходятся с operational model. После разделения source of truth остаётся явным, а lag и reconciliation становятся такими же production metrics, как transaction latency.

## Источники

- [TPC Current Specifications](https://www.tpc.org/tpc_documents_current_versions/current_specifications5.asp?mode=tpc-member) — Transaction Processing Performance Council, TPC-C 5.11.0 и TPC-H 3.0.1, проверено 2026-07-18.
- [TPC-C Standard Specification](https://www.tpc.org/TPC_Documents_Current_Versions/pdf/tpc-c_v5.11.0.pdf) — Transaction Processing Performance Council, версия 5.11.0, проверено 2026-07-18.
- [TPC-H Standard Specification](https://www.tpc.org/TPC_Documents_Current_Versions/pdf/tpc-h_v3.0.1.pdf) — Transaction Processing Performance Council, версия 3.0.1, проверено 2026-07-18.
- [PostgreSQL: Database Page Layout](https://www.postgresql.org/docs/18/storage-page-layout.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [C-Store: A Column-oriented DBMS](https://www.cs.umd.edu/~abadi/papers/vldb.pdf) — Stonebraker et al., VLDB 2005, проверено 2026-07-18.
- [MonetDB/X100: Hyper-Pipelining Query Execution](https://www.cidrdb.org/cidr2005/papers/P19.pdf) — Boncz, Zukowski и Nes, CIDR 2005, проверено 2026-07-18.
