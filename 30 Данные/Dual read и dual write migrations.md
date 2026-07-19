---
aliases:
  - dual read migrations
  - dual write migrations
  - миграции с двойным чтением и записью
tags:
  - область/данные
  - тема/распределённые-данные
  - практика/миграции
статус: проверено
---

# Dual read и dual write migrations

## TL;DR

Dual read/write — не конечная архитектура и не флаг «писать в два места», а временный migration protocol. В каждом его состоянии должны быть определены source of truth, возвращаемый read path, способ догонять вторую сторону, критерий cutover и rollback boundary.

Два независимых хранилища не становятся атомарными от последовательных вызовов приложения. Если старое commit прошло, а новое вернуло timeout, исход второго неизвестен. Поэтому безопасный протокол использует стабильную operation/version identity, идемпотентный apply, durable backlog/reconciliation и по возможности одну authoritative write с CDC или transactional outbox. После того как новое хранилище принимает уникальные writes, rollback требует reverse sync; простого переключения reads назад уже недостаточно.

## Область применимости и версии

Рассматривается перенос таблицы/read model между схемами или независимыми stores без остановки трафика. Фазовый пример сверён с Stripe Engineering 2017; change propagation — с PostgreSQL logical replication 18.4, tag `REL_18_4`; общий online schema protocol — с F1 PVLDB 2013. Проверено 2026-07-18. Это не инструкция для конкретного managed migration service: его гарантии snapshot, ordering и DDL coverage нужно проверять отдельно.

## Ментальная модель

У migration есть три независимых направления:

- **Write authority:** где операция считается принятой и какая версия побеждает при расхождении.
- **Propagation:** как изменение попадает во второе представление — local transaction, app dual write, CDC/log, outbox или repair.
- **Read serving:** откуда клиенту возвращают ответ; второе чтение может быть shadow и не влиять на результат.

«Оба stores записываем» не означает «оба источники истины». Два равноправных authorities требуют полноценного conflict-resolution протокола. Для migration обычно проще сохранять единственный authority и считать второй материализованной копией до явного cutover.

Полезно описывать каждое состояние кортежем:

```text
(authoritative write, served read, mirror direction, rollback data path)
```

Переход разрешён только после измеримого gate: backlog догнан, [[30 Данные/Online backfill|backfill]] проверен, shadow mismatches объяснены, а rollback не теряет writes.

## Как устроено

### Последовательность состояний

Один из безопасных вариантов:

| Состояние | Write authority | Served read | Что происходит |
|---|---|---|---|
| `S0` | old | old | Baseline |
| `S1` | old | old | Новые writes зеркалируются old → new; failures durable и повторяемы |
| `S2` | old | old | Backfill history, затем shadow reads сравнивают old/new |
| `S3` | old | постепенно new | New догнан; reads переключаются canary/ramp, old остаётся write authority |
| `S4` | new | new | Write authority переключён; reverse mirror new → old сохраняет rollback |
| `S5` | new | new | Rollback window закрыт, old mirror остановлен и legacy удаляется |

Stripe описывает близкую четырёхфазную миграцию: dual write, переключение reads на новую систему, прекращение writes в старую, удаление старого пути. Эта последовательность — пример их системы, а не универсальное доказательство. В каждом проекте нужно решить, можно ли в `S3` обслуживать read из target при lag и что делать при его отказе.

Состояния лучше переключать постепенно по tenant/key hash, а не двумя глобальными booleans. Тогда один и тот же key имеет детерминированную фазу, canary ограничивает blast radius, а метрики можно сравнить с control cohort. Флаги должны быть версионированы и совместимы с живыми application instances.

### Dual write и частичный успех

Если обе записи находятся в одной transactional database, их часто можно выполнить одним local transaction. Для независимых stores обычна матрица:

| Old | New | Значение |
|---|---|---|
| success | success | Оба согласованы |
| success | definite failure | Old authoritative, нужен retry new |
| success | timeout | New мог commit; retry должен быть идемпотентным |
| failure | success | Нельзя выдавать успех, если old ещё authority; new нужно компенсировать/перезаписать |
| failure | failure | Операция не принята |

Наивное «при ошибке второго удалить из первого» тоже не атомарно: компенсация может упасть, а между шагами данные уже прочитал другой процесс. Двухфазный distributed transaction применим лишь при поддержке обоих stores и цене координации, которую система готова нести.

Часто надёжнее одна authoritative write и асинхронная доставка. [[40 Распределённые системы/Transactional outbox и Change Data Capture|Transactional outbox или Change Data Capture]] связывает изменение с durable log в том же commit domain, после чего идемпотентный consumer обновляет target. Это даёт lag, но убирает промежуток «source commit есть, а намерение обновить target потеряно».

### Идентичность и порядок

Каждая mutation должна нести stable key, operation ID и logical source version/offset. Тогда:

- timeout-retry не создаёт второй эффект;
- target отвергает старую доставку после новой;
- reconciler понимает, какая сторона должна победить;
- cutover gate выражается через обработанный high-water mark;
- audit связывает mismatch с конкретной операцией.

Timestamp физического client clock — слабая замена версии: skew может переставить writes. Лучше использовать source sequence/LSN, per-key revision или fencing epoch. PostgreSQL logical replication сначала копирует snapshot, затем непрерывно применяет изменения; внутри одной subscription транзакции применяются в порядке publisher. Но отдельно изменяемый subscriber способен создать conflicts, поэтому его не следует молча превращать во второй authority.

### Dual read: shadow, fallback и serving

Dual read имеет три разных режима:

1. **Shadow read:** клиенту возвращается old, new вызывается асинхронно/в пределах budget только для сравнения. Ошибка new не меняет пользовательский ответ.
2. **Fallback:** сначала new, при missing/error — old. Это повышает availability миграции, но может скрывать неполный target и удвоить tail latency.
3. **Served new + compare old:** пользователь уже зависит от new; old нужен для обнаружения расхождения или rollback.

Сравнение требует canonicalization: порядок списков, timezone, defaults, floating representation и eventual lag иначе дают ложные mismatches. Метрики делят на missing, stale version, semantic difference, timeout и expected lag, а не сводят к одному проценту.

### Rollback boundary

До `S4` old остаётся authority: выключить зеркало и вернуть reads в old обычно безопасно. После первого unique write, принятого только new, old уже отстаёт. Без reverse mirror возврат reads в old теряет это изменение. Значит, после `S4` есть только три честных варианта:

- продолжать new → old sync до конца rollback window;
- перед rollback остановить writes, догнать reverse backfill и проверить old;
- признать cutover необратимым и выполнять forward fix.

Cleanup old раньше этой границы — не оптимизация диска, а отказ от rollback.

## Пример или трассировка

`old` — authoritative profile store, `new` — новая document model. Операция `op=731`, key `user:42`, source revision `18` меняет locale.

1. Приложение commit-ит revision `18` в old.
2. Запись в new зависает и client получает timeout. Неизвестно, произошёл ли commit.
3. Запрос не повторяет предметную операцию с новым ID. Durable migration ledger сохраняет `(op=731, user:42, rev=18, pending-new)`.
4. Worker повторяет idempotent upsert. Если первый вызов уже commit-ил, target видит тот же operation/revision и отвечает без второго эффекта; если нет — применяет его.
5. Shadow read получает revision `18` с обеих сторон и закрывает pending state.

Наблюдаемый результат: old остаётся source of truth, пользовательская запись не откатывается, а неопределённый исход target со временем разрешается без дубля. Без operation ID retry мог бы дважды добавить элемент массива; без durable ledger процесс потерял бы обязанность догнать new после рестарта.

После read cutover new принимает revision `19` как единственный authority. Если reverse mirror выключен, old остаётся на `18`. Наблюдаемый результат простого rollback reads — пользователь снова видит старое значение. Поэтому переключение write authority и остановка reverse sync — разные фазы.

## Trade-offs

| Подход | Сильная сторона | Цена |
|---|---|---|
| App dual write | Малый lag, полный контроль transform | Partial failures, latency двух stores |
| Single write + CDC/outbox | Один commit authority и durable intent | Eventual lag, pipeline и replay |
| Shadow reads | Проверка на production workload без влияния на ответ | Дополнительная нагрузка и canonicalization |
| Fallback old | Маскирует incomplete target | Скрывает ошибки и увеличивает p99 |
| Reverse mirror | Настоящий rollback после cutover | Дольше живёт двойной путь и write amplification |
| Stop-the-world copy | Простая точка истины | Downtime и большой cutover risk |

Если target полностью derived и легко перестраивается, можно избежать application dual write: snapshot + CDC и атомарная смена alias/read route проще. Если оба stores должны постоянно принимать writes, это уже не migration, а multi-writer architecture с постоянной reconciliation cost.

## Типичные ошибки

- **Неверное предположение:** две успешные функции подряд дают атомарность. **Симптом:** стороны расходятся после timeout/crash. **Причина:** между независимыми commits нет общей transaction boundary. **Исправление:** single authority + durable propagation либо настоящий distributed transaction.
- **Неверное предположение:** retry новой записи всегда безопасен. **Симптом:** дублируется increment/append. **Причина:** timeout скрывал успешный первый commit. **Исправление:** stable operation ID и idempotent/version-guarded apply.
- **Неверное предположение:** dual read — один режим. **Симптом:** shadow error неожиданно ломает request или fallback навсегда скрывает missing rows. **Причина:** не задано, какой ответ authoritative. **Исправление:** отдельно назвать shadow, fallback и served path, задать latency budget.
- **Неверное предположение:** 100% backfill разрешает cutover. **Симптом:** target теряет последние mutations. **Причина:** cursor coverage не доказывает, что live change backlog догнан. **Исправление:** high-water mark, lag=0 в устойчивом окне и semantic validation.
- **Неверное предположение:** rollback — только feature flag. **Симптом:** old возвращает состояние до cutover. **Причина:** new уже принимал unique writes. **Исправление:** reverse sync или явная irreversible boundary.

## Когда применять

Dual read/write protocol нужен при смене key model, schema, database engine или read model, когда old и new должны некоторое время сосуществовать. Он оправдан, если миграцию можно разбить на наблюдаемые фазы и есть место для временной write/read amplification.

Перед стартом фиксируют state diagram, authority в каждом состоянии, формат operation/version, backlog storage, validation queries и rollback data path. На дежурном dashboard нужны lag, pending/failed mirrors, mismatch classes, served-read cohort и доля keys каждой фазы. Миграция завершена не после переключения флага, а когда legacy path удалён и больше не требуется reconciliation между форматами.

## Источники

- [Online migrations at scale](https://stripe.com/blog/online-migrations) — Stripe Engineering, опубликовано 2017, проверено 2026-07-18.
- [Online, Asynchronous Schema Change in F1](https://research.google.com/pubs/archive/41376.pdf) — Google, PVLDB 2013, проверено 2026-07-18.
- [Logical replication](https://www.postgresql.org/docs/18/logical-replication.html) — PostgreSQL Global Development Group, документация PostgreSQL 18.4, проверено 2026-07-18.
- [Logical replication source](https://github.com/postgres/postgres/blob/REL_18_4/doc/src/sgml/logical-replication.sgml) — PostgreSQL, исходник документации, tag `REL_18_4` (PostgreSQL 18.4), проверено 2026-07-18.
