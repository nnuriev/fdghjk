---
aliases:
  - online backfill
  - фоновое заполнение данных
  - backfill данных без простоя
tags:
  - область/данные
  - тема/распределённые-данные
  - практика/миграции
статус: проверено
---

# Online backfill

## TL;DR

Online backfill заполняет новое представление историческими данными, пока production writes продолжаются. Это не один большой `UPDATE`, а возобновляемый data-plane job: стабильный cursor, маленькие идемпотентные batches, checkpoint после commit, защита от concurrent update, throttling по SLO и независимая верификация результата.

Главный инвариант: старый snapshot не имеет права затереть более новое пользовательское состояние. Поэтому до backfill live write path должен поддерживать target либо изменения должны догоняться из журнала; worker записывает результат условно по source version. Завершённый scan означает только «все ranges посещены», а не «source и target эквивалентны».

## Область применимости и версии

Заметка относится к преобразованию rows/documents/index entries внутри или между online stores. Модель конкурентного backfill и промежуточных schema states проверена по F1, PVLDB 2013; практический многофазный migration flow — по Stripe 2017. Детали DDL дополнительно сверены для PostgreSQL 18.4 (`REL_18_4`). Проверено 2026-07-18.

## Ментальная модель

Backfill восстанавливает прошлое, пока live path создаёт настоящее. Представим source как snapshot на границе `T0`, а изменения после неё — как delta stream:

```text
target_complete = apply(snapshot <= T0) + apply(changes > T0)
```

Порядок частей может отличаться: live writes часто начинают зеркалировать до snapshot scan. Тогда одна запись придёт сначала свежей из delta, а позже старой из snapshot. Корректность держится не на порядке доставки, а на version-aware idempotent apply.

У job есть два прогресса:

- **coverage:** какие key ranges уже посещены и checkpointed;
- **freshness/correctness:** насколько target соответствует актуальному source и прошёл ли validation.

Смешивать их нельзя. `cursor=end` при пропущенных concurrent updates — формально законченный, но неверный backfill.

## Как устроено

### Предусловия

До первого batch должны быть определены:

1. source of truth и точная transform function;
2. target schema, способ upsert и idempotency key;
3. механизм live changes: dual write, trigger, CDC/log tail или периодическая reconciliation;
4. стабильный порядок обхода и snapshot/high-water mark;
5. version/CAS rule, которое не даст старому результату победить новый;
6. ресурсы и SLO, при которых job должен замедлиться или остановиться;
7. независимый validation и rollback/cleanup plan.

Если target начнут поддерживать только после завершения scan, все writes во время scan образуют бесконечный moving gap. Обычно сначала обеспечивают новые writes, затем заполняют history.

### Batches и cursor

Работу делят по стабильному primary key или явным ranges. Keyset pagination вида `id > last_id ORDER BY id LIMIT batch` сохраняет прогресс лучше `OFFSET`: concurrent inserts/deletes не сдвигают уже пройденные страницы, а стоимость не растёт с offset. Для mutable/non-unique cursor нужен составной tie-breaker и snapshot semantics.

Checkpoint записывают **после** commit target batch. Если процесс упал после commit, но до checkpoint, batch выполнится повторно; поэтому apply обязан быть идемпотентным. Если checkpoint записать раньше commit, crash навсегда пропустит range.

F1 разбивает reorganization на небольшие tasks по key ranges. Tasks работают на snapshot состояния в начале schema change, допускают retry и используют правило, при котором row, изменённая после snapshot, не перезаписывается старой backfill-версией. Конкретный механизм F1 — продуктовый, а переносимый принцип — version guard.

### Защита от гонки

Подходящие варианты:

- `INSERT ... ON CONFLICT DO NOTHING`, если live path уже создал окончательный target и history заполняет только отсутствующее;
- compare-and-set `WHERE target.source_version < snapshot.source_version`;
- записывать immutable versioned event, а materializer выбирать максимальную logical version;
- повторно читать source перед commit и пропускать row, если `updated_at/version` изменился;
- применять snapshot и CDC в одном упорядоченном offset space.

Одна проверка `target IS NULL` безопасна только для write-once/монотонного поля. При преобразовании существующего значения она может пропустить необходимое обновление или записать старую производную после свежего source write.

### Throttling и resumability

Backfill создаёт read amplification на source, writes/WAL на target, cache churn, replication lag, locks и последующую compaction. Фиксированные «1000 rows per batch» не задают безопасную нагрузку: строки имеют разный размер, а headroom меняется.

Лучше использовать feedback loop:

- верхние границы batch rows и bytes;
- ограничение concurrent workers по shard и узлу;
- пауза или снижение скорости при росте p95/p99, lock wait, replica lag, WAL/commit-log pressure или compaction backlog;
- jitter между workers, чтобы они не синхронизировали пики;
- lease/fencing на range, heartbeat и retry budget;
- durable checkpoint с transform/schema version.

Resumability означает больше, чем «есть last_id». После deploy новой transform старый checkpoint нельзя молча продолжать, если уже записанные rows рассчитаны иначе. Job version входит в identity, а повторный запуск либо совместим, либо начинает явную reconciliation.

### Верификация

Проверка идёт слоями:

1. counts по ranges и категориям, а не только global count;
2. `NULL`/missing rate и constraint validation;
3. deterministic checksums над каноническим представлением;
4. stratified sample, включая редкие edge cases и последние updates;
5. shadow reads на production path;
6. lag/offset live change stream;
7. повторный scan расхождений до нуля или объяснённого порога.

Counts не находят пару «одна лишняя + одна пропущенная», а checksum без canonicalization даёт ложные расхождения из-за порядка полей или формата времени. Validation должен совпадать с пользовательской семантикой target.

## Пример или трассировка

Source row `id=42` имеет `(email='old@example', version=2)` на snapshot `T0`. Backfill строит нормализованный target `email_search`.

1. Worker читает snapshot-версию `2`, вычисляет `old@example` и готовит upsert с `source_version=2`.
2. Пользователь меняет email. Live path записывает source `(new@example, version=3)` и target `(new@example, source_version=3)`.
3. Задержавшийся worker выполняет условие «обновить target, только если существующая `source_version < 2`».
4. Target уже имеет version `3`, поэтому операция backfill становится no-op.

Наблюдаемый результат: в target остаётся `new@example`; snapshot не откатывает пользователя. Без version guard последний по времени SQL от backfill записал бы старое значение, хотя его source логически старше.

Batch покрывает ids `1..100`. После его commit worker падает до записи checkpoint `100`. При рестарте он повторяет тот же range; idempotent upserts не создают дубли, затем checkpoint фиксируется. Наблюдаемый результат: повтор безопасен, а ни один id не пропущен.

## Trade-offs

| Выбор | Преимущество | Цена |
|---|---|---|
| Большие batches | Меньше overhead, быстрее nominal progress | Долгие locks/transactions, тяжёлый retry и spikes |
| Маленькие batches | Контролируемый blast radius | Больше round trips и metadata |
| DB snapshot | Чёткая граница history | Долгоживущий snapshot может удерживать garbage/versions |
| Live scan без snapshot | Меньше snapshot pressure | Нужны сильные version guards и повторная reconciliation |
| Dual write | Низкий change lag | Partial failures между stores |
| CDC/log tail | Один authoritative write | Lag и эксплуатация capture/apply pipeline |

Offline bulk load проще: источник заморожен, поэтому нет гонки snapshot с live writes. Он выигрывает для небольшого окна обслуживания или восстанавливаемого derived index. Online backfill оправдан, когда downtime дороже дополнительного протокола.

## Типичные ошибки

- **Неверное предположение:** один SQL `UPDATE` — самый простой путь. **Симптом:** lock/WAL/replica lag выбивает production SLO, а restart начинает всё заново. **Причина:** работа не разделена и не throttled. **Исправление:** key ranges, bounded batches и durable checkpoints.
- **Неверное предположение:** конец cursor означает корректность. **Симптом:** после cutover находятся missing/stale rows. **Причина:** coverage приняли за equivalence. **Исправление:** отдельный validation и reconciliation pass.
- **Неверное предположение:** retry безопасен автоматически. **Симптом:** дубли или двойное применение transform. **Причина:** batch commit и checkpoint не атомарны, operation не idempotent. **Исправление:** stable idempotency key/versioned upsert и checkpoint after commit.
- **Неверное предположение:** backfill может безусловно перезаписывать target. **Симптом:** свежие изменения откатываются. **Причина:** старый snapshot завершился позже live write. **Исправление:** source version/CAS или упорядоченный log offset.
- **Неверное предположение:** постоянный rate безопасен. **Симптом:** job работал ночью, но перегрузил дневной пик. **Причина:** headroom динамичен. **Исправление:** feedback throttling по пользовательскому SLO и storage backlog.

## Когда применять

Online backfill нужен при добавлении derived column/index, смене key/layout, переносе в новое хранилище и исправлении исторических данных без остановки writes. Он особенно полезен как часть [[30 Данные/Миграции схемы данных|expand/contract]] и [[30 Данные/Dual read и dual write migrations|dual read/write migration]].

До запуска оценивают объём bytes, write amplification, срок при безопасном throttle и запас диска. Во время работы progress публикуют по ranges, lag и validation errors. Cutover разрешается только по данным верификации; процент обработанных rows — операционная метрика, но не критерий истины.

## Источники

- [Online, Asynchronous Schema Change in F1](https://research.google.com/pubs/archive/41376.pdf) — Google, PVLDB 2013, проверено 2026-07-18.
- [Online migrations at scale](https://stripe.com/blog/online-migrations) — Stripe Engineering, опубликовано 2017, проверено 2026-07-18.
- [ALTER TABLE source](https://github.com/postgres/postgres/blob/REL_18_4/doc/src/sgml/ref/alter_table.sgml) — PostgreSQL, исходник документации, tag `REL_18_4` (PostgreSQL 18.4), проверено 2026-07-18.
