---
aliases:
  - SQL queries
  - SQL joins and window functions
tags:
  - область/данные
  - тема/sql
  - практика/запросы
статус: проверено
---

# SQL - joins, aggregations, subqueries, CTE и window functions

## TL;DR

SQL описывает требуемое отношение, а не пошаговый алгоритм. `JOIN` формирует пары строк, `WHERE` фильтрует их, aggregation сворачивает группы, subquery вводит зависимое или независимое множество, CTE именует промежуточный результат, window function вычисляет значение по соседним строкам без схлопывания результата.

Главное практическое правило: сначала доказать cardinality каждого промежуточного отношения, потом считать агрегаты. Большинство «неверных сумм» рождается не в `SUM`, а в join, который незаметно размножил исходные строки.

## Область применимости

- Семантика рассматривается по SQL и реализации PostgreSQL 18.4, проверенной 2026-07-18.
- Логический порядок объясняет результат, но optimizer может переставлять joins, проталкивать predicates и inline CTE, если сохраняется семантика.
- В PostgreSQL обычный non-recursive side-effect-free CTE, использованный один раз, обычно можно объединить с parent query; `MATERIALIZED` и `NOT MATERIALIZED` управляют этой границей.
- Вне scope: recursive graph algorithms, `GROUPING SETS`, ordered-set aggregates и vendor-specific query hints.
- Самодостаточный пример статически проверен, но не запускался на PostgreSQL.

## Ментальная модель

Каждый фрагмент запроса принимает relation и возвращает relation. Полезно мысленно выполнять pipeline:

```text
FROM/JOIN -> WHERE -> GROUP BY/HAVING -> window functions
-> SELECT -> DISTINCT -> ORDER BY -> LIMIT
```

Это не описание физического плана. Оно отвечает на вопрос, какие строки доступны каждой конструкции. Например, window function видит строки после группировки, но `WHERE` не может фильтровать по её результату на том же query level: для этого нужен subquery или CTE.

## Как устроено

### Joins и cardinality

`INNER JOIN` оставляет matching pairs. `LEFT JOIN` дополнительно сохраняет каждую unmatched row слева, заполняя правые столбцы `NULL`. `FULL JOIN` сохраняет unmatched rows с обеих сторон. `CROSS JOIN` строит Cartesian product.

Join type не гарантирует «одну строку на объект». Если справа три совпадения, одна левая строка превратится в три. Перед join нужно знать uniqueness join key или сознательно принять fan-out. `NATURAL JOIN` хрупок: новый одноимённый столбец меняет условие без изменения текста запроса. Явные `ON`/`USING` безопаснее.

Predicate в `ON` и `WHERE` эквивалентен для многих inner joins, но различается для outer join. Условие на правую таблицу в `WHERE` отбрасывает null-extended rows и часто превращает `LEFT JOIN` в фактический inner join.

### Aggregations

`GROUP BY` создаёт одну output row на группу. Aggregate читает multiset строк группы. `COUNT(*)` считает строки, `COUNT(expr)` игнорирует `NULL`, а `SUM` по пустому входу возвращает `NULL`, не ноль. `WHERE` фильтрует input rows до группировки, `HAVING` фильтрует готовые группы.

Если два one-to-many отношения присоединить к parent до aggregation, возникает many-to-many multiplication. Надёжный приём: сначала агрегировать каждую detail table до нужного grain, затем соединять результаты.

### Subqueries и CTE

Scalar subquery обязан вернуть не больше одной строки. `EXISTS` проверяет наличие и может остановиться после первой найденной строки. `IN` выражает membership, но `NOT IN` с `NULL` может дать `UNKNOWN` и не вернуть ожидаемые строки; `NOT EXISTS` обычно лучше выражает anti-join.

Correlated subquery ссылается на строку внешнего query. Логически он вычисляется для этой строки, хотя optimizer способен преобразовать его в join или semi-join. CTE не обещает отдельного хранения: в PostgreSQL 18 это либо удобная граница имени, либо materialization boundary, выбранная правилами planner и модификаторами.

### Window functions и frame

Окно сохраняет каждую input row. `PARTITION BY` делит строки, `ORDER BY` задаёт порядок внутри partition, frame выбирает подмножество относительно текущей строки. `row_number`, `rank` и `dense_rank` различаются на ties.

Frame по умолчанию при оконном `ORDER BY` заканчивается последним peer текущей строки. Поэтому `last_value` часто возвращает значение текущей peer group, а не последней строки partition. Для полного окна нужно явно написать `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`.

## Пример или трассировка

Запрос использует CTE как self-contained dataset, join для владельца, correlated subquery для eligibility, aggregation для revenue и window function для победителя региона:

```sql
WITH customers(customer_id, name, region) AS (
    VALUES
        (1, 'Anna', 'east'),
        (2, 'Boris', 'east'),
        (3, 'Chen', 'west')
),
orders(order_id, customer_id, amount, paid) AS (
    VALUES
        (10, 1, 70::numeric, true),
        (11, 1, 50::numeric, true),
        (12, 2, 200::numeric, true),
        (13, 3, 90::numeric, true),
        (14, 3, 10::numeric, true)
),
eligible_totals AS (
    SELECT c.region,
           c.customer_id,
           c.name,
           sum(o.amount) AS paid_total
    FROM customers AS c
    JOIN orders AS o USING (customer_id)
    WHERE o.paid
      AND EXISTS (
          SELECT 1
          FROM orders AS o2
          WHERE o2.customer_id = c.customer_id
          GROUP BY o2.customer_id
          HAVING count(*) >= 2
      )
    GROUP BY c.region, c.customer_id, c.name
),
ranked AS (
    SELECT *,
           row_number() OVER (
               PARTITION BY region
               ORDER BY paid_total DESC, customer_id
           ) AS rn
    FROM eligible_totals
)
SELECT region, customer_id, name, paid_total
FROM ranked
WHERE rn = 1
ORDER BY region;
```

Ожидаемый результат:

```text
region | customer_id | name | paid_total
east   | 1           | Anna | 120
west   | 3           | Chen | 100
```

Boris исключён correlated `EXISTS`: у него один заказ. Aggregation оставляет одну строку на customer. `row_number` нумерует customers внутри region, а внешний query оставляет `rn = 1`. Дополнительный `customer_id` в оконном `ORDER BY` делает выбор детерминированным при одинаковой сумме.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| PostgreSQL 11 и ранее | CTE служил optimization fence и материализовался | Начиная с PostgreSQL 12 side-effect-free non-recursive CTE можно inline; доступны `MATERIALIZED` и `NOT MATERIALIZED` | Старый приём «CTE заставит вычислить один раз» нельзя переносить без явной границы и проверки плана | [WITH Queries](https://www.postgresql.org/docs/18/queries-with.html) |

## Trade-offs

- Join хорошо выражает set relationship и даёт planner свободу менять порядок. Correlated subquery часто яснее для `EXISTS`, но сложная корреляция может ограничить transformations и повторять работу.
- CTE улучшает локальное имя и позволяет один раз вычислить дорогой reusable result. Forced materialization потребляет память или temp I/O и мешает predicate pushdown.
- Window function избегает self-join и сохраняет detail rows. Сортировка partition может быть дорогой; индекс помогает только при совместимом filter/order и выбранном плане.
- `DISTINCT` быстро маскирует accidental fan-out. Он платит sort/hash и скрывает неверный grain, поэтому сначала надо исправить join semantics.
- Один сложный query сохраняет snapshot и отдаёт optimizer всю картину. Несколько простых запросов легче читать, но добавляют network round trips и могут увидеть разные состояния при `READ COMMITTED`.

## Типичные ошибки

- Неверное предположение: `LEFT JOIN` гарантирует все левые строки. Симптом: строки без правого совпадения исчезли. Причина: predicate на правой таблице поставлен в `WHERE`. Исправление: перенести условие сопоставления в `ON` либо явно обработать `NULL`.
- Неверное предположение: сумма считается на исходном grain. Симптом: total завышен в число присоединённых detail rows. Причина: два one-to-many joins образовали произведение. Исправление: агрегировать каждую ветвь до parent key перед join.
- Неверное предположение: `COUNT(column)` равен `COUNT(*)`. Симптом: nullable values не вошли в count. Причина: aggregate игнорирует `NULL` expression. Исправление: выбрать count по требуемой семантике и проверить пустую группу.
- Неверное предположение: `NOT IN (subquery)` безопасен при nullable output. Симптом: запрос возвращает ноль строк. Причина: сравнение с `NULL` даёт `UNKNOWN`. Исправление: `NOT EXISTS` с явной корреляцией или гарантированный `NOT NULL`.
- Неверное предположение: CTE всегда вычисляется отдельно и один раз. Симптом: predicate не push down либо, наоборот, выражение inline и повторено. Причина: materialization зависит от версии, числа ссылок и модификатора. Исправление: указать `MATERIALIZED`/`NOT MATERIALIZED` только после проверки [[30 Данные/Планы выполнения SQL-запросов|плана]].
- Неверное предположение: `last_value` без frame возвращает конец partition. Симптом: функция повторяет текущее значение. Причина: default frame заканчивается текущей peer group. Исправление: задать полный `ROWS` frame.

## Когда применять

Начинайте запрос с требуемого output grain: одна строка на order, customer или day. Для каждого join фиксируйте cardinality и uniqueness keys. После этого выбирайте `EXISTS` для existence, aggregation для смены grain, window function для расчёта без потери строк, CTE для содержательной границы.

Проверяйте результат на пустом наборе, `NULL`, ties и нескольких совпадениях. Семантический тест нужен до tuning; затем `EXPLAIN (ANALYZE, BUFFERS)` покажет, как PostgreSQL физически реализовал тот же запрос.

## Источники

- [Table Expressions](https://www.postgresql.org/docs/18/queries-table-expressions.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Subquery Expressions](https://www.postgresql.org/docs/18/functions-subquery.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [WITH Queries](https://www.postgresql.org/docs/18/queries-with.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Window Functions](https://www.postgresql.org/docs/18/functions-window.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Aggregate Functions](https://www.postgresql.org/docs/18/functions-aggregate.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [PostgreSQL 18.4 release notes](https://www.postgresql.org/docs/18/release-18-4.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, release date 2026-05-14, проверено 2026-07-18.
