---
aliases:
  - Durability и fsync
  - Устойчивость данных и fsync
  - Durable writes
tags:
  - область/данные
  - тема/внутреннее-устройство-хранилищ
  - механизм/durability
статус: проверено
---

# Durability и fsync

## TL;DR

- **Durability** — точное обещание о том, какие подтверждённые изменения переживут заданный класс отказа. «Данные записаны» без указания отказа и durable boundary ничего не гарантирует.
- Возврат из `write()` обычно означает, что данные принял page cache ядра. `fsync`/`fdatasync` или эквивалент просит протолкнуть их через filesystem и устройство; итоговая гарантия зависит и от контроллера, volatile caches, power-loss protection и корректности hardware.
- [[30 Данные/Write-ahead log (WAL)|WAL]] позволяет синхронизировать небольшой последовательный журнал на commit, а большие data pages записывать позже. После crash redo восстанавливает подтверждённое состояние.
- Главный trade-off — latency durable flush против окна потери данных. Group commit делит один flush между транзакциями; asynchronous commit возвращает ответ раньше, но должен явно описывать допустимое окно потери.
- `fsync` не делает многостраничное изменение атомарным и не исправляет неверный recovery protocol. Нужны правильный порядок WAL, metadata publication, обработка ошибок и crash testing.

## Область и версии

Общий I/O path зависит от OS, filesystem и устройства. Конкретные гарантии и настройки проверены для PostgreSQL 18.4, исходного кода `REL_18_4`, commit `f5cc81719e6da4cbdb1f797c48b693e91018153a`, и RocksDB 11.1.1, tag `v11.1.1`, commit `6cdeb9d9d0630763327f512e6255cab33f6834e7`. Проверено 2026-07-18.

Здесь рассматривается локальная durability. Подтверждение replica, quorum или object storage задаёт другую границу и не выводится автоматически из локального `fsync`.

## Ментальная модель: сначала назвать отказ и границу

Одна и та же запись может пережить падение процесса и исчезнуть при power loss:

```text
buffer процесса
    ↓ write/pwrite
page cache ОС
    ↓ filesystem writeback + fsync/fdatasync
контроллер / volatile device cache
    ↓ flush/barrier или защищённый cache
устойчивый носитель
```

Полезно задавать гарантию парой:

```text
success boundary → failure model
```

Например: «после успешного synchronous commit транзакция переживает crash процесса, kernel panic и потерю питания одного корректно работающего узла». Это сильнее и проверяемее, чем «мы вызвали `fsync`».

### Что означают этапы

- **Process buffer:** данные исчезнут при crash процесса, если не переданы ядру.
- **OS page cache:** `write()` уже вернулся, но dirty pages могут исчезнуть при kernel/power failure.
- **Filesystem:** определяет порядок data и metadata writes, journaling и семантику flush.
- **Device/controller cache:** может быть volatile; безопасен при наличии честного flush protocol или power-loss protection.
- **Durable media:** последний слой модели, но и он не защищает от bit rot, firmware bugs или потери всего устройства. Для них нужны checksums, scrubbing, replication и backups.

## `write`, `fsync` и `fdatasync`

`write()` сообщает, что ядро приняло bytes или ошибку. Оно не обязано ждать носитель. Фоновый writeback позже отправит dirty pages вниз, но момент этой записи не является commit guarantee.

`fsync(fd)` запрашивает синхронизацию данных файла и metadata, необходимых для его состояния. `fdatasync(fd)` может не ждать metadata, не влияющие на содержимое, и поэтому иногда дешевле. Но создание нового файла, rename и публикация MANIFEST/root pointer включают namespace metadata: движок должен синхронизировать все объекты, требуемые его crash protocol, а не только data fd.

Системный вызов — не магическое доказательство. Гарантия ослабевает, если:

- filesystem или mount mode не обеспечивают ожидаемый порядок;
- устройство подтверждает flush до устойчивой записи;
- write cache volatile и не имеет power-loss protection;
- приложение игнорирует I/O error;
- после ошибки продолжает подтверждать commits, хотя durable prefix неизвестен.

Поэтому PostgreSQL предоставляет разные `wal_sync_method`, а документация отдельно предупреждает о ненадёжных consumer-grade drives. Выбор метода — часть портирования и тестирования, не универсальная оптимизация.

## Почему WAL уменьшает commit cost

Без журнала commit многостраничной транзакции потребовал бы сделать durable все изменённые heap/index pages в согласованном порядке. Это много случайных writes и сложная атомарность.

С WAL порядок другой:

1. изменения страниц представлены WAL records;
2. WAL prefix до commit record записывается последовательно и синхронизируется;
3. клиент получает успех;
4. data pages остаются dirty и записываются позже;
5. после crash redo повторяет записи, которых нет на durable pages.

Durability commit сводится к durable prefix журнала, но только при соблюдении WAL-before-data. `fsync` журнала не исправит страницу, записанную раньше её WAL record.

## Сквозной пример

Транзакция меняет страницу `P`; update WAL заканчивается LSN `800`, commit record — LSN `920`.

```text
1. pwrite(WAL through 920) → bytes находятся в OS page cache
2. fdatasync(WAL fd)       → durable prefix достигает 920
3. return SUCCESS          → synchronous durability выполнена
4. dirty P остаётся в buffer pool
5. power loss
6. recovery replays record 800 into P
```

Наблюдаемый результат: подтверждённое значение восстанавливается, хотя сама data page не была flushed до шага 5.

Если ответ вернуть после шага 1, получаем asynchronous commit: power loss может удалить уже подтверждённую транзакцию. Если dirty `P` разрешить стать durable до WAL `800`, нарушается структурная безопасность: recovery может не иметь записи, объясняющей новое состояние страницы.

В RocksDB обычный write добавляет batch в WAL и memtable; `WriteOptions.sync=true` требует синхронизировать WAL перед возвратом, а default `false` этого не требует. `disableWAL=true` ещё сильнее ослабляет recovery: memtable changes могут исчезнуть полностью, если не дошли до SST.

## Latency, throughput и batching

### Sync на каждый commit

Каждая транзакция ждёт durable flush. Latency предсказуема относительно устройства, но максимальный throughput ограничивается числом flush в секунду, даже если bytes мало.

### Group commit

Несколько транзакций публикуют WAL до разных LSN и ждут один flush до максимального LSN группы. Все с LSN внутри durable prefix получают успех. Throughput растёт, а гарантия не меняется; цена — небольшое ожидание формирования группы и возможная очередь при saturation.

### Asynchronous commit

Ответ возвращается до flush. Уменьшается foreground latency, но появляется окно потери уже подтверждённых транзакций. В PostgreSQL 18.4 с `synchronous_commit=off` документация указывает верхнюю границу риска до трёх `wal_writer_delay`; database state остаётся consistent, потому что WAL-before-data всё равно соблюдается.

### `fsync=off`

Это не просто большее окно потери. PostgreSQL предупреждает о риске unrecoverable corruption: OS может записать data files и WAL в порядке, несовместимом с recovery. Настройка допустима только там, где весь кластер можно без сожаления пересоздать из другого источника.

## Full-page writes и torn pages

Носитель может гарантировать атомарность меньшего блока, чем database page. Power loss во время записи оставляет torn page: часть старая, часть новая. Обычный delta WAL не всегда может безопасно примениться к такому неизвестному основанию.

PostgreSQL при `full_page_writes=on` журналирует полный образ страницы при первом изменении после checkpoint. Recovery сначала восстанавливает известный целый образ, затем применяет последующие records. Это увеличивает WAL volume, особенно при частых checkpoints, но закрывает отдельный failure mode. Сам `fsync` не превращает запись нескольких database pages в атомарную операцию.

## Trade-offs

| Стратегия | Успешный ответ означает | Цена | Failure mode |
|---|---|---|---|
| Sync commit + корректный WAL flush | Commit record входит в durable prefix | Flush latency; помогает group commit | Hardware/filesystem могут нарушить контракт |
| Async commit | Изменение принято процессом, durable позже | Меньше foreground latency | Потеря окна подтверждённых транзакций |
| WAL без sync по default RocksDB write | WAL/memtable обновлены, но WAL может быть только в cache | Высокий throughput | Потеря недавнего WAL при power loss |
| WAL disabled | Запись только в memtable до flush | Минимум WAL I/O | Потеря всей неflushed memtable |
| PostgreSQL `fsync=off` | Нет crash-safe ordering | Максимальная скорость для одноразовых данных | Возможен corruption, требуется пересоздание |

Быстрый NVMe с power-loss protection уменьшает flush latency, но не отменяет protocol. Репликация может дать другую точку durability — например, ack после записи на два узла, — однако нужно отдельно уточнить, дошёл ли log до памяти, OS cache или durable media каждой replica.

## Типичные ошибки

### Говорить «записали на диск» после `write()`

- **Неверное предположение:** page cache уже устойчив к power loss.
- **Симптом:** успешные операции пропадают после отключения питания.
- **Причина:** dirty data не прошли durable flush.
- **Исправление:** определить failure model и ждать нужный sync boundary.

### Оптимизировать только среднюю latency

- **Неверное предположение:** быстрый средний `fsync` гарантирует быстрые commits.
- **Симптом:** редкие stalls дают большую p99/p999 latency.
- **Причина:** очередь flush, filesystem writeback, device garbage collection или compaction конкурируют за I/O.
- **Исправление:** измерять latency distribution под steady-state нагрузкой и отдельно видеть queue depth.

### Считать `synchronous_commit=off` равным `fsync=off`

- **Неверное предположение:** обе настройки лишь теряют последние транзакции.
- **Симптом:** недооценён риск полного повреждения кластера.
- **Причина:** async commit откладывает клиентский ack boundary, а `fsync=off` ломает порядок WAL/data writes.
- **Исправление:** выбирать async commit для допустимого окна потери; не отключать crash-safety protocol у незаменимых данных.

### Игнорировать sync ошибок и metadata

- **Неверное предположение:** повторный вызов или следующий успешный commit автоматически исправит прошлую ошибку; sync одного data file публикует rename.
- **Симптом:** после crash отсутствует новый SST/MANIFEST либо durable prefix неизвестен.
- **Причина:** ошибка разорвала обещание, а namespace transition имеет собственные metadata writes.
- **Исправление:** считать sync error потерей доказанной durability, останавливать/переводить систему в безопасный режим и следовать полному protocol конкретной filesystem.

### Тестировать только graceful restart

- **Неверное предположение:** корректное закрытие проверяет crash recovery.
- **Симптом:** баг обнаруживается только при реальном power loss.
- **Причина:** shutdown успевает flush buffers и не попадает в опасные промежутки.
- **Исправление:** fault injection между WAL write, WAL sync, data write и metadata publication; затем проверка целостности и обещанного ack set.

## Когда какую гарантию выбирать

Синхронная durability нужна для денег, прав доступа, заказов и любых данных, которые нельзя заново получить после подтверждения. Async commit подходит для событий, которые можно переотправить или потерять в явно оговорённом окне. WAL-disabled ingest оправдан, если источник воспроизводим и система умеет обнаружить неполную загрузку.

В operational contract стоит записать:

1. какие failures входят в обещание;
2. после какого API result данные считаются durable;
3. локальная это гарантия или replica/quorum;
4. максимальное допустимое окно потери;
5. как обнаруживаются sync errors и повреждение;
6. каким crash test это регулярно подтверждается.

## Источники

- [General Concepts — File Synchronization](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap04.html) — IEEE и The Open Group, POSIX.1-2024, Issue 8, проверено 2026-07-18.
- [Reliability](https://www.postgresql.org/docs/18/wal-reliability.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Asynchronous Commit](https://www.postgresql.org/docs/18/wal-async-commit.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [WAL Configuration](https://www.postgresql.org/docs/18/wal-configuration.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [WAL Settings](https://www.postgresql.org/docs/18/runtime-config-wal.html) — PostgreSQL Global Development Group, PostgreSQL 18.4, проверено 2026-07-18.
- [Реализация WAL flush](https://github.com/postgres/postgres/blob/f5cc81719e6da4cbdb1f797c48b693e91018153a/src/backend/access/transam/xlog.c) — PostgreSQL, tag `REL_18_4`, commit `f5cc81719e6da4cbdb1f797c48b693e91018153a`, символы `XLogFlush` и `issue_xlog_fsync`, проверено 2026-07-18.
- [WriteOptions::sync и disableWAL](https://github.com/facebook/rocksdb/blob/6cdeb9d9d0630763327f512e6255cab33f6834e7/include/rocksdb/options.h#L2319-L2344) — RocksDB, tag `v11.1.1`, commit `6cdeb9d9d0630763327f512e6255cab33f6834e7`, проверено 2026-07-18.
