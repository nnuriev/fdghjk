---
aliases:
  - Пагинация API
  - Offset и cursor pagination
tags:
  - область/бэкенд
  - тема/api
статус: проверено
---

# Пагинация offset, cursor и continuation token

## TL;DR

Пагинация — протокол обхода упорядоченного множества, которое может меняться между запросами. Offset хранит позицию в текущем результате и удобен для перехода к номеру страницы, но дорог на большой глубине и даёт gaps/duplicates при concurrent writes. Cursor привязывает продолжение к последней sort tuple; он быстрее и устойчивее к изменениям перед границей, но требует стабильного полного порядка.

Continuation token — opaque wire-контракт. Он может содержать cursor, snapshot/revision, normalized query и срок действия либо ссылаться на server-side state. Token обязан быть связан с filter, sort, tenant и authorization context, но сам не выдаёт доступ к данным.

## Область применимости

- Общий API pattern соответствует AIP-158 с changelog до 2025-07-08.
- SQL-поведение проверяется по PostgreSQL 18 documentation.
- GraphQL-модель соответствует GraphQL Cursor Connections Specification, проверенной 2026-07-18.
- DynamoDB Query используется как официальный пример continuation и пустой страницы с непустым `LastEvaluatedKey`.
- Вне scope: бесконечный event stream, search relevance ranking и distributed snapshot implementation конкретной базы.

## Ментальная модель

List endpoint не «режет массив». Он продолжает traversal после ранее наблюдавшейся границы.

Offset говорит: «пропусти первые N элементов результата на момент этой выборки». Если перед ними вставили или удалили запись, позиция N сдвинулась.

Cursor говорит: «продолжи после элемента с sort key K в том же порядке». Вставка перед K не сдвигает boundary. Но если sort key не уникален или query semantics изменились, слово «после» становится неоднозначным.

Continuation token добавляет server context: «продолжи тот же traversal с такими filter/order/snapshot после этой boundary». Клиент переносит token как opaque string и не строит из него запрос вручную.

## Как устроено

### Общий контракт

Paginated operation определяет:

- default и maximum `page_size`; requested size — верхняя граница, а не обещание;
- deterministic ordering и правила `NULL`, collation, tie-breaker;
- `page_token`/cursor во входе и `next_page_token`/`pageInfo` в ответе;
- связь token с остальными arguments;
- snapshot или live semantics при concurrent changes;
- expiration и error для invalid/expired token;
- точность `total_size`, если поле вообще есть.

По AIP-158 service может вернуть меньше элементов, включая ноль, даже не достигнув конца. Только пустой `next_page_token` означает end-of-collection. Все arguments, кроме разрешённого изменения `page_size`, должны совпадать с request, который создал token; иначе возвращается `INVALID_ARGUMENT`. HTTP API может передавать готовый next URI через `Link` по RFC 8288, но cursor/token semantics от этого не меняется.

Pagination нужно включать до публикации list method. Если старый client считал один response полным множеством, последующее добавление page 2 молча теряет данные и нарушает [[20 Бэкенд/Контракты API и обратная совместимость|обратную совместимость]].

### Offset pagination

SQL shape:

```sql
SELECT id, created_at, status
FROM orders
WHERE tenant_id = $1
ORDER BY created_at DESC, id DESC
LIMIT $2 OFFSET $3;
```

Плюсы: простая модель `page=37`, произвольный jump и естественная связь с exact/estimated total count. Минусы: database всё равно должна вычислить и пропустить предшествующие rows; стоимость растёт с offset. PostgreSQL также предупреждает, что разные LIMIT/OFFSET дают непредсказуемые subsets без уникального `ORDER BY`.

Offset не фиксирует границу между requests. Insert перед текущей страницей сдвигает уже увиденную row на следующую страницу и создаёт duplicate. Delete перед границей сдвигает unseen row назад и создаёт gap.

### Keyset/cursor pagination

Для порядка `(created_at DESC, id DESC)` cursor хранит последнюю tuple предыдущей страницы. Следующий query:

```sql
SELECT id, created_at, status
FROM orders
WHERE tenant_id = $1
  AND (created_at, id) < ($2, $3)
ORDER BY created_at DESC, id DESC
LIMIT $4;
```

Composite predicate использует ту же direction и comparator, что `ORDER BY`. `id` превращает порядок в total: без него две rows с одинаковым `created_at` нельзя однозначно расположить относительно cursor.

С подходящим composite B-tree index planner может начать index scan у boundary и не проходить все предыдущие rows. Для этого equality-prefix, порядок columns, direction и comparator должны соответствовать predicate и `ORDER BY`; сам keyset этого не гарантирует, и planner всё ещё может выбрать sequential scan с sort. Подход не даёт дешёвого jump к «странице 37» и сложнее при произвольном multi-column sort, `NULL`, locale collation и mutable sort fields. Если `created_at` или другой cursor field меняется между pages, row может переместиться через boundary; нужен immutable key, snapshot или явно принятая live semantics.

GraphQL Cursor Connections оформляет эту модель через `edges { cursor node }` и `pageInfo`, с `first/after` для forward и `last/before` для backward traversal. Edge order должен оставаться согласованным между страницами и не переворачиваться только из-за backward arguments.

### Continuation token

Cursor — логическая boundary, continuation token — её opaque представление вместе с server policy. Stateless token может содержать versioned payload:

```text
token_version
tenant/query fingerprint
normalized filter and order fingerprint
last sort tuple
snapshot/revision, если обещан snapshot
issued_at/expiry
integrity protection
```

Stateful token вместо этого содержит random handle на server-side traversal state. Он скрывает детали и позволяет snapshot/session, но требует storage, cleanup и routing/replication этой state.

Opaque не означает «base64». AIP-158 прямо предупреждает, что base64 от прозрачной структуры не препятствует клиенту разобрать её и начать зависеть от implementation details. Если token содержит чувствительные данные, нужна confidentiality; если stateless server доверяет полям token, нужна authenticity/integrity. При любом варианте authorization выполняется заново для request: token не является capability на чтение чужого tenant.

Token format версионируют независимо от public API. Decoder может поддерживать текущий и предыдущий internal token versions до их expiration, что позволяет менять index и encoding без breaking clients.

### Snapshot и live traversal

Live keyset даёт полезное свойство: новые rows перед пройденной boundary не создают duplicate на следующих pages. Он не обещает полный снимок. Row, вставленная после boundary с меньшим key, может появиться; удалённая row исчезнет; изменившая sort key row может быть пропущена или увидена снова.

Snapshot token закрепляет database snapshot, revision или `as_of` watermark. Результат стабильнее, но длительный snapshot удерживает storage/version history и имеет TTL. Для административного UI live semantics часто достаточна. Для export, billing и reconciliation нужен snapshot либо алгоритм повторной сверки.

## Пример или трассировка

Исходный порядок, page size 2:

```text
A = (10:03, id=103)
B = (10:02, id=102)
C = (10:01, id=101)
D = (10:00, id=100)
```

Page 1 возвращает `[A, B]`. До page 2 вставляется `X = (10:04, id=104)`.

Offset request `LIMIT 2 OFFSET 2` видит новый порядок `[X, A, B, C, D]` и возвращает `[B, C]`. Наблюдаемый результат: `B` пришёл второй раз, а после двух страниц клиент видел только три уникальные записи.

Cursor после tuple `B` выполняет условие `(created_at,id) < (10:02,102)` и возвращает `[C, D]`. Head insert `X` не пересёк boundary, duplicate нет.

Отдельные contract checks:

- две rows с `created_at=10:02` подтверждают, что `id` нужен как tie-breaker;
- старый token с новым `status=CLOSED` вместо исходного filter получает `INVALID_ARGUMENT`;
- empty result с non-empty next token не завершает traversal;
- tampered token не проходит integrity check;
- пользователь другого tenant не получает данные даже с украденным token.

## Trade-offs

- Offset удобен для маленьких стабильных выборок и UI с номером страницы. Cursor выигрывает на больших таблицах, infinite scroll и feed traversal, где подходящий index даёт range scan и важно отсутствие head-insert duplicate.
- Stateless token не требует server storage и легко масштабируется. Он разрастается, раскрывает metadata без encryption и требует key rotation. Stateful handle компактен и скрывает модель, но создаёт storage lifecycle и availability dependency.
- Live traversal дешёв и показывает изменения. Snapshot даёт повторяемый export, но удерживает revision state и ограничивает срок жизни token.
- Exact total поддерживает last-page UX, но `COUNT` может быть дороже самой страницы и устареть сразу после ответа. Estimate или отсутствие total честнее для больших изменяемых коллекций.
- Максимально гибкий client sort увеличивает число index combinations и сложность cursor comparator. Небольшой набор named orderings проще оптимизировать и сохранять совместимым.

## Типичные ошибки

- Неверное предположение: LIMIT/OFFSET стабилен без полного порядка. Симптом: rows меняются местами даже без writes. Причина: database не гарантирует порядок без `ORDER BY`, а ties не разрешены. Исправление: задать total order с unique tiebreaker.
- Неверное предположение: offset указывает на ранее увиденную row. Симптом: inserts дают duplicates, deletes — gaps. Причина: offset позиционный относительно нового результата. Исправление: keyset cursor либо snapshot.
- Неверное предположение: base64 делает token opaque и безопасным. Симптом: clients зависят от структуры, attacker меняет tenant или sort key. Причина: encoding не даёт secrecy/integrity. Исправление: opaque versioned format, подпись/MAC и encryption при чувствительном payload.
- Неверное предположение: token заменяет authorization. Симптом: украденный token открывает чужую коллекцию. Причина: continuation перепутан с capability. Исправление: заново проверить principal и bind token к authorization/query scope.
- Неверное предположение: short или empty page означает конец. Симптом: client преждевременно прекращает traversal. Причина: service может вернуть меньше requested size. Исправление: завершать только при отсутствии next token.
- Неверное предположение: cursor можно использовать после смены filter/order. Симптом: gaps, duplicates или доступ к другой выборке. Причина: boundary имеет смысл только внутри исходного ordered set. Исправление: fingerprint query в token и отклонять mismatch.
- Неверное предположение: keyset автоматически даёт snapshot. Симптом: mutable sort key перемещает row между страницами. Причина: cursor фиксирует boundary, а не всё множество. Исправление: документировать live semantics, использовать immutable keys/snapshot или reconciliation.

## Когда применять

Offset подходит для небольшого back-office списка, где нужен jump к странице и стоимость глубины ограничена. Cursor/keyset выбирайте для больших online collections, feeds и последовательного обхода. Continuation token нужен, когда server должен скрыть boundary, привязать query policy или удержать snapshot state.

До реализации зафиксируйте filter и sort semantics из [[20 Бэкенд/Фильтрация, сортировка и частичные ответы|соседней заметки]]. Затем выберите index, total order, mutation model и end signal. Для export отдельно сформулируйте, должен ли результат соответствовать одному snapshot.

## Источники

- [AIP-158: Pagination](https://google.aip.dev/158) — Google, Approved, changelog до 2025-07-08, проверено 2026-07-18.
- [PostgreSQL 18: LIMIT and OFFSET](https://www.postgresql.org/docs/18/queries-limit.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-18.
- [PostgreSQL 18: Sorting Rows](https://www.postgresql.org/docs/18/queries-order.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-18.
- [PostgreSQL 18: Indexes and ORDER BY](https://www.postgresql.org/docs/18/indexes-ordering.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-18.
- [PostgreSQL 18: Multicolumn Indexes](https://www.postgresql.org/docs/18/indexes-multicolumn.html) — PostgreSQL Global Development Group, PostgreSQL 18, проверено 2026-07-18.
- [GraphQL Cursor Connections Specification](https://relay.dev/graphql/connections.htm) — Relay/GraphQL specification, online edition, проверено 2026-07-18.
- [RFC 8288: Web Linking](https://www.rfc-editor.org/rfc/rfc8288.html) — IETF, октябрь 2017, проверено 2026-07-18.
- [Paginating table query results in DynamoDB](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Query.Pagination.html) — Amazon Web Services, DynamoDB API, проверено 2026-07-18.
- [DynamoDB Query API](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html) — Amazon Web Services, DynamoDB API, проверено 2026-07-18.
- [JSON:API Specification 1.1: Pagination](https://jsonapi.org/format/#fetching-pagination) — JSON:API, версия 1.1, проверено 2026-07-18.
