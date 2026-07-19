---
aliases:
  - Query execution plans
  - EXPLAIN PostgreSQL
  - План запроса
tags:
  - область/данные
  - тема/sql
  - практика/диагностика
статус: проверено
---

# Планы выполнения SQL-запросов

## TL;DR

Planner превращает декларативный SQL в дерево физических operators и выбирает вариант с минимальной оценённой cost. Главный вход выбора: estimated row count на каждом узле. Ошибка cardinality внизу дерева умножается на joins и часто важнее самого типа scan.

Читайте `EXPLAIN ANALYZE` как сравнение гипотезы и наблюдения: `rows` против `actual rows`, затем `loops`, buffers, temp I/O, sort spills и время. Cost не измеряется в миллисекундах, а хороший plan на тестовых десяти строках ничего не доказывает о production distribution.

## Область применимости

- Команды и поля соответствуют PostgreSQL 18.4, проверено 2026-07-18.
- План зависит от statistics, table size, parameter values, prepared-plan mode, configuration, cache, hardware и concurrent load. Текст плана не служит стабильным API между версиями.
- `EXPLAIN ANALYZE` действительно выполняет statement. Для mutating DML side effects происходят; безопасный диагностический запуск требует копии данных или `BEGIN ... ROLLBACK` с учётом внешних эффектов.
- Вне scope: исходный код dynamic programming join search, GEQO, JIT internals и distributed planners.
- Пример не запускался из-за отсутствия PostgreSQL. Plan skeleton ниже ожидаем на representative data после `VACUUM ANALYZE`, но не обещан cost-based planner.

## Ментальная модель

План читается снизу вверх. Каждый node просит строки у children, преобразует их и отдаёт parent. В `Nested Loop` внешний child запускается один раз, внутренний обычно запускается для каждой внешней строки. Поэтому `actual time` и `actual rows` надо интерпретировать вместе с `loops`; узел с быстрым одним loop может стать горячей точкой при ста тысячах повторов.

Planner работает с моделью мира, собранной `ANALYZE`. Executor работает с реальными строками. Диагностика ищет место, где эти два мира впервые расходятся.

## Как устроено

### Что оптимизирует planner

Для каждой relation и join order planner строит допустимые paths: Seq Scan, Index Scan, Index Only Scan, Bitmap path, join algorithms, sorts, aggregates, parallel variants. Cost состоит из startup и total. Startup важен для `LIMIT` и `EXISTS`, где executor может остановиться рано; total важен, когда нужны все строки.

Cost units выводятся из параметров вроде `seq_page_cost`, `random_page_cost`, `cpu_tuple_cost`. Это относительная модель ресурсов, не предсказание wall-clock latency. Снижать cost setting ради одного query опасно: параметр меняет выбор для всей нагрузки.

### Базовые operators

- Seq Scan читает relation последовательно и применяет filter.
- Index Scan получает tuple identifiers из индекса и посещает heap; Index Only Scan пытается читать payload из индекса, но visibility может потребовать heap fetch.
- Bitmap Index Scan объединяет matches, Bitmap Heap Scan посещает подходящие heap pages.
- Nested Loop хорош при малом outer input и дешёвом parameterized inner lookup.
- Hash Join строит hash по одной стороне и probes другой; memory overflow создаёт batches и temp I/O.
- Merge Join требует совместимого порядка и эффективен на отсортированных inputs.
- Sort, HashAggregate, GroupAggregate, WindowAgg, Materialize и Limit меняют порядок, grain, storage или stopping point.

### Cardinality и statistics

`ANALYZE` собирает `null_frac`, `n_distinct`, most-common values, histogram и correlation по одному столбцу. Он не хранит полную distribution. Предикаты `country = 'AM' AND city = 'Yerevan'` зависимы, но независимая оценка может перемножить selectivities и сильно ошибиться.

Extended statistics описывают functional dependencies, multivariate `n_distinct` и most-common combinations. Они помогают оценить predicates и grouping, но не создают индекс и не ускоряют executor напрямую.

Сигналы проблемы:

- отношение `actual rows / estimated rows` далеко от 1 на первом низком node;
- внутренний node имеет неожиданные `loops`;
- Sort пишет на disk;
- Hash использует несколько batches;
- много `Rows Removed by Filter` после дорогого access;
- shared reads велики относительно output;
- Index Only Scan показывает много `Heap Fetches`.

### Измерение без самообмана

Первый запуск может читать storage, второй попасть в OS/shared cache. `EXPLAIN ANALYZE` добавляет instrumentation overhead и не измеряет network serialization клиенту без соответствующей опции. Один fast execution не описывает p95 при concurrency.

Для DML полезны `BUFFERS` и `WAL`; для sorts/hashes нужны memory/disk details. Сравнивайте планы на representative data, после `ANALYZE`, с теми же parameters и session settings, что у приложения.

## Пример или трассировка

Dataset создаёт 1000 заказов для каждого из 100 tenants:

```sql
CREATE TABLE customer_order (
    order_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id integer NOT NULL,
    created_at timestamptz NOT NULL,
    state text NOT NULL,
    amount numeric(12, 2) NOT NULL
);

INSERT INTO customer_order (tenant_id, created_at, state, amount)
SELECT (g % 100) + 1,
       timestamptz '2026-01-01 00:00:00+00' + g * interval '1 minute',
       CASE WHEN g % 3 = 0 THEN 'paid' ELSE 'new' END,
       (g % 1000)::numeric
FROM generate_series(1, 100000) AS g;

CREATE INDEX customer_order_tenant_time_idx
ON customer_order (tenant_id, created_at DESC)
INCLUDE (state, amount);

VACUUM (ANALYZE) customer_order;

EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS, SUMMARY)
SELECT created_at, state, amount
FROM customer_order
WHERE tenant_id = 42
ORDER BY created_at DESC
LIMIT 20;
```

Семантический результат: 20 последних строк tenant `42`, уже в descending order. На такой distribution ожидаемая форма:

```text
Limit
  -> Index Only Scan using customer_order_tenant_time_idx
       Index Cond: (tenant_id = 42)
```

Почему это лишь ожидаемая форма? Planner может выбрать Index Scan, если visibility map требует heap visits, либо другой path при иной distribution/costs. Проверка начинается не с имени node, а с того, что estimate около 1000 строк для tenant до `LIMIT`, node отдаёт 20, sort отсутствует, buffers малы, а `Heap Fetches` после `VACUUM` близок к нулю.

Если estimate равен 10 при actual 1000, смотрят statistics и skew. Если estimate верен, но reads велики, проверяют index shape и visibility. Если plan хорош в одиночку, а latency плох под нагрузкой, причина уже может лежать в locks, I/O saturation или connection concurrency.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| PostgreSQL 17 и ранее | `BUFFERS` в `EXPLAIN ANALYZE` надо было запрашивать отдельно | PostgreSQL 18 включает buffer output автоматически при `ANALYZE` | Диагностический вывод по умолчанию полнее; explicit `BUFFERS` сохраняет намерение в runbook | [Release 18](https://www.postgresql.org/docs/18/release-18.html) |
| PostgreSQL 17 и ранее | Меньше деталей для некоторых operators, integer-like row presentation | PostgreSQL 18 добавил fractional row counts, число index lookups и memory/disk details для Material, WindowAgg и CTE nodes | Сравнение estimates и поиск spill стали точнее; parsers текстового EXPLAIN следует считать version-sensitive | [Release 18](https://www.postgresql.org/docs/18/release-18.html) |

## Trade-offs

- `EXPLAIN` безопасно показывает estimate, но не обнаруживает runtime skew, visibility и spill. `EXPLAIN ANALYZE` даёт actuals ценой выполнения и instrumentation overhead.
- Extended statistics исправляют correlated estimates без нового access structure. Их надо обслуживать `ANALYZE`, а каждый statistics object увеличивает planning/maintenance work.
- Новый индекс может убрать scan/sort. Он добавляет write amplification, WAL и cache footprint, поэтому plan одного SELECT не покрывает полную цену.
- Переписанный query иногда открывает planner transformation. Слишком ручная декомпозиция через forced materialization способна лишить planner свободы.
- Hints или отключение node type быстро меняют plan для эксперимента. Как постоянное лечение они маскируют stale statistics, неверную cost model или missing invariant.

## Типичные ошибки

- Неверное предположение: `cost=100` означает 100 ms. Симптом: выбирается «меньшее число», но wall time не совпадает. Причина: cost использует относительные units. Исправление: сравнивать plans одной модели и подтверждать actual time/buffers под representative workload.
- Неверное предположение: самый медленный по `actual time` верхний node и есть причина. Симптом: оптимизируют Aggregate, хотя explosion случился ниже. Причина: parent включает работу children. Исправление: читать снизу вверх и найти первое cardinality divergence.
- Неверное предположение: index scan всегда хороший знак. Симптом: миллионы random heap reads при большой выборке. Причина: node label ничего не говорит о selectivity и buffers. Исправление: смотреть actual rows, heap fetches и pages; сравнить Seq/Bitmap path экспериментально.
- Неверное предположение: `EXPLAIN ANALYZE UPDATE` ничего не меняет. Симптом: диагностика обновила production rows и вызвала triggers. Причина: `ANALYZE` выполняет statement. Исправление: использовать безопасную копию или transaction с rollback, проверив non-transactional side effects.
- Неверное предположение: `ANALYZE` решает любую estimation error. Симптом: estimate остаётся неверным для correlated columns или expression. Причина: single-column sample не хранит зависимость. Исправление: extended statistics, expression statistics, higher target либо изменение модели.
- Неверное предположение: план с literal равен prepared plan приложения. Симптом: psql быстрый, сервис медленный на skewed parameter. Причина: generic/custom plan и parameter value различаются. Исправление: воспроизвести protocol, parameter и `plan_cache_mode`, сравнить оба плана.

## Когда применять

Диагностируйте по цепочке: воспроизвести query и parameters, зафиксировать output и latency, обновить statistics только если это допустимо, получить `EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS)`, найти первое расхождение rows, затем проверить I/O и spills. Меняйте одну причину за раз.

После исправления измерьте p50/p95 при concurrency и цену writes. Сохранённый plan полезен как evidence конкретного запуска, но не как вечная гарантия: рост таблицы, skew и upgrade PostgreSQL могут законно выбрать другую стратегию.

## Источники

- [Using EXPLAIN](https://www.postgresql.org/docs/18/using-explain.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [EXPLAIN](https://www.postgresql.org/docs/18/sql-explain.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Statistics Used by the Planner](https://www.postgresql.org/docs/18/planner-stats.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [How the Planner Uses Statistics](https://www.postgresql.org/docs/18/planner-stats-details.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Optimizer README](https://github.com/postgres/postgres/blob/REL_18_4/src/backend/optimizer/README) — postgres/postgres, tag `REL_18_4`, проверено 2026-07-18.
- [PostgreSQL 18 release notes](https://www.postgresql.org/docs/18/release-18.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-18.
- [PostgreSQL 18.4 release notes](https://www.postgresql.org/docs/18/release-18-4.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, release date 2026-05-14, проверено 2026-07-18.
