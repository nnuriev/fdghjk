---
aliases:
  - Compaction в LSM-хранилищах
  - LSM compaction
  - Компакция LSM
tags:
  - область/данные
  - тема/внутреннее-устройство-хранилищ
  - механизм/compaction
статус: проверено
---

# Compaction в LSM-хранилищах

## TL;DR

- **Compaction** сливает несколько immutable sorted runs/SST в новые файлы, разрешает версии одного ключа, освобождает старые файлы и поддерживает ограничение на число runs.
- Это не просто «удаление мусора». Без compaction растут число мест для чтения, объём старых версий/tombstones и storage usage; в итоге движок вынужден замедлить или остановить запись.
- **Leveled compaction** держит мало перекрывающихся runs на нижних уровнях: чтение и место дешевле, но данные чаще переписываются. **Tiered/size-tiered compaction** дольше хранит несколько runs: запись дешевле, read/space amplification выше.
- Tombstone можно удалить только когда доказано, что он больше не скрывает старое значение и не нужен snapshot. Иначе удалённая запись «воскреснет».
- Crash-safe compaction сначала строит и синхронизирует новые SST, затем атомарно публикует Version edit в MANIFEST; старые inputs удаляются только после переключения версии и ухода читателей.

## Область и версии

Общий механизм относится к [[30 Данные/LSM-tree|LSM-tree]]. Детали и термины проверены на RocksDB 11.1.1, tag `v11.1.1`, commit `6cdeb9d9d0630763327f512e6255cab33f6834e7`; официальная wiki зафиксирована на commit `98273e83a8c7897bdbcd01ffbaef39571ba949ee`. Проверено 2026-07-18.

RocksDB Universal Compaction — представитель tiered-подхода, но не синоним любого tiered алгоритма. Точные triggers, score и правила выбора файлов зависят от версии и настроек.

## Ментальная модель: погашение долга

Flush быстро превращает memtable в новый отсортированный файл, но не устраняет пересечения с прежними файлами. Каждая такая выгрузка добавляет новый run, который должен участвовать в чтении. Compaction погашает накопленный долг:

```text
новые runs + старые runs
          ↓ merge по (user_key, sequence, type)
новая согласованная версия файлов
```

Долг виден в трёх местах:

- **read debt:** один lookup или range scan объединяет больше runs;
- **space debt:** одновременно хранятся старые версии, tombstones и outputs;
- **future write debt:** всё это придётся прочитать и переписать позже.

Если входящий поток стабильно превышает доступную compaction bandwidth, настройки лишь меняют момент кризиса. Для ограниченного диска число runs не может расти бесконечно, поэтому write stall — необходимая обратная связь.

## Что делает один compaction

1. Version/compaction picker выбирает input files и все перекрывающиеся файлы целевого уровня, необходимые для сохранения его инвариантов.
2. Итераторы читают внутренние ключи в порядке `(user_key, descending sequence, type)`.
3. Merge выбирает видимые версии, но сохраняет те, что ещё нужны snapshots или более глубоким данным.
4. Результат режется на новые SST по размеру и диапазонам.
5. Файлы завершаются и становятся durable согласно контракту движка.
6. MANIFEST получает Version edit: добавить outputs, удалить references на inputs.
7. Новая Version становится текущей. Старые файлы физически удаляются, когда ни один reader/snapshot больше их не держит.

Immutable inputs позволяют читателям продолжать работу со старой Version, пока compaction строит новую. Атомарная единица здесь — не одновременная замена всех файлов файловой системой, а durable metadata transition.

### Версии и tombstones

Для одного user key merge видит цепочку внутренних записей. Самая новая запись скрывает старые только относительно конкретного snapshot. Поэтому старую версию можно отбросить, если она не может быть видна ни одному поддерживаемому snapshot. Tombstone дополнительно можно убрать, только если нет старого значения в непросмотренных нижних уровнях или внешнего потребителя, которому нужен этот deletion marker.

Политика «оставить только самое новое значение» корректна лишь при полном знании перекрывающегося диапазона и отсутствии старых snapshots. На промежуточном уровне она может воскресить значение из более глубокого SST.

## Leveled compaction

В classic leveled layout:

- level 0 содержит недавно flushed SST с перекрывающимися диапазонами;
- каждый ненулевой уровень представляет один логический sorted run, разбитый на SST без перекрытия по user-key range внутри уровня;
- размер следующего уровня обычно больше предыдущего на заданный multiplier;
- compaction из уровня `L` читает выбранные файлы и перекрывающийся диапазон `L+1`, затем создаёт новую неперекрывающуюся раскладку.

Для point lookup это важный инвариант: после L0 подходит не более одного файла каждого ненулевого уровня. Цена — повторное переписывание части большого `L+1`, когда сверху приходят меньшие диапазоны. Чем выше size ratio и хуже overlap, тем заметнее write amplification.

RocksDB Level Compaction — гибрид: L0 ведёт себя как набор tiered runs, а L1+ — как leveled структура. Поэтому фраза «leveled означает один файл на уровень» неверна: речь об одном логическом run, range-partitioned на много файлов.

## Tiered и size-tiered compaction

Tiered policy допускает несколько sorted runs одного диапазона и объединяет их позже, часто когда накопилось несколько runs сопоставимого размера. Каждая запись проходит меньше merge stages, поэтому write amplification обычно ниже. Обратная сторона:

- lookup проверяет больше runs;
- range scan выполняет более широкий k-way merge;
- одновременное существование runs увеличивает space amplification;
- редкий merge большой группы создаёт burst I/O и требует временного места.

RocksDB Universal Compaction выбирает runs по size amplification и сходству размеров. Она подходит write-heavy workloads, если хватает cache/filters и disk headroom, но способна создавать более резкие пики, чем leveled compaction.

## Сквозной пример

Есть три перекрывающихся runs; `@N` — sequence number:

```text
новый R2:  a@7=2, c@8=DEL
старый R1: a@4=1, b@5=9
нижний L1: c@2=3, d@3=4
```

Предположим, compaction охватывает весь нижний диапазон, старых snapshots нет, а ниже нет других версий `a..d`.

Merge видит:

```text
a@7=2  → оставляем; a@4=1 больше никому не видна
b@5=9  → оставляем
c@8=DEL → скрывает c@2=3; обе записи можно убрать на bottommost range
d@3=4  → оставляем
```

Новый run:

```text
a@7=2, b@5=9, d@3=4
```

Наблюдаемый результат: шесть внутренних записей прочитаны, три записаны; чтение `a` вместо проверки трёх runs обращается к одному новому run. Если бы существовал snapshot `seq=4`, `a@4=1` и `c@2=3` могли бы понадобиться, а выбрасывание их было бы ошибкой. Если бы ниже оставался `c@1`, tombstone `c@8` тоже пришлось бы сохранить.

### Crash во время примера

- crash до durable MANIFEST edit: recovery выбирает старую Version; готовый, но не опубликованный output не участвует в базе и позже очищается;
- crash после durable edit: recovery выбирает новую Version, где outputs добавлены, а inputs логически удалены;
- физическое удаление inputs до публикации Version разрушило бы оба варианта, поэтому порядок критичен.

## Trade-offs: как policy меняет amplification

| Policy | Write amplification | Read amplification | Space amplification | Фоновый профиль |
|---|---:|---:|---:|---|
| Leveled | Выше | Ниже | Ниже | Более постоянные небольшие merges |
| Tiered/size-tiered | Ниже | Выше | Выше | Реже, но крупнее и резче |

Это направление trade-off, а не универсальные числа. Compression, key distribution, overwrite rate, tombstones, snapshots, filters, level sizes и compaction picking меняют результат. Сравнивать policies нужно по одинаковому определению метрик из [[30 Данные/Read и write amplification|заметки об amplification]].

## Управление compaction debt

Наблюдать нужно не только текущий throughput, но и накопленную работу:

- число L0 files и overlapping runs;
- pending compaction bytes;
- входные/выходные bytes compaction и write amplification;
- write stall/slowdown time;
- свободное место с учётом одновременных inputs и outputs;
- latency point reads и range scans по уровням;
- возраст tombstones и oldest snapshot.

При перегрузке варианты ограничены: уменьшить ingest, увеличить compaction CPU/I/O, снизить конкуренцию с foreground reads, изменить policy/level sizes или разделить горячие диапазоны. Увеличение stall threshold без устранения debt лишь откладывает остановку и может исчерпать диск.

## Типичные ошибки

### Считать compaction обычной дефрагментацией

- **Неверное предположение:** его можно навсегда выключить, если место пока есть.
- **Симптом:** растут runs и read latency, затем начинаются stalls.
- **Причина:** compaction поддерживает логические инварианты read path и удаляет скрытые версии, а не только уплотняет блоки.
- **Исправление:** бюджетировать его как обязательную часть steady state.

### Немедленно удалять tombstone

- **Неверное предположение:** удалённый key не требует хранения записи.
- **Симптом:** после compaction появляется старое значение.
- **Причина:** нижний SST сохранил value, который tombstone должен был скрывать.
- **Исправление:** доказать bottommost/full-overlap условие и отсутствие snapshots перед drop.

### Путать leveled level с одним SST

- **Неверное предположение:** lookup всегда читает ровно один файл на весь L1.
- **Симптом:** неверные размеры файлов и parallelism compaction.
- **Причина:** уровень — один логический run, разделённый на много неперекрывающихся SST.
- **Исправление:** различать run, level и file.

### Оптимизировать write amplification без места

- **Неверное предположение:** переход на tiered policy только уменьшит I/O.
- **Симптом:** compaction не стартует или диск заполняется во время большого merge.
- **Причина:** одновременно нужны inputs, outputs и несколько retained runs.
- **Исправление:** заранее рассчитать peak temporary space и настроить backpressure.

### Удалять input files до metadata commit

- **Неверное предположение:** раз output создан, старые файлы больше не нужны.
- **Симптом:** crash recovery не может открыть ни старую, ни новую Version.
- **Причина:** durable MANIFEST ещё ссылается на inputs.
- **Исправление:** сначала sync outputs и Version edit, затем переключить Version и только после ухода readers удалить inputs.

## Когда применять какую policy

Leveled compaction обычно выбирают для read-heavy или mixed workloads, где важны point lookup, range scans и ограниченное место. Tiered/Universal уместнее при write-heavy ingest и допустимых read/space amplification. Решение проверяют нагрузочным тестом, который включает steady state после заполнения базы: короткий тест до накопления debt почти всегда выглядит лучше реальности.

## Источники

- [Compaction](https://github.com/facebook/rocksdb/wiki/Compaction/a4880c101f719057efc8fbc8019322b623bf158d) — RocksDB Wiki, revision `a4880c101f719057efc8fbc8019322b623bf158d`, 2023-06-29, проверено 2026-07-18.
- [Leveled Compaction](https://github.com/facebook/rocksdb/wiki/Leveled-Compaction/12101e0e6a8f9706e05ddfea7072970e0ef25bbd) — RocksDB Wiki, revision `12101e0e6a8f9706e05ddfea7072970e0ef25bbd`, 2023-11-14, проверено 2026-07-18.
- [Universal Compaction](https://github.com/facebook/rocksdb/wiki/Universal-Compaction/008089dbd350f3d41d3b62307a697ea55fcaf802) — RocksDB Wiki, revision `008089dbd350f3d41d3b62307a697ea55fcaf802`, 2023-06-29, проверено 2026-07-18.
- [MANIFEST](https://github.com/facebook/rocksdb/wiki/MANIFEST/b41e3d3f806ba63bfacbb4583db32e7b29a01979) — RocksDB Wiki, revision `b41e3d3f806ba63bfacbb4583db32e7b29a01979`, 2022-01-27, проверено 2026-07-18.
- [Write Stalls](https://github.com/facebook/rocksdb/wiki/Write-Stalls/992739396cf73f01144567b4461e424a607989b5) — RocksDB Wiki, revision `992739396cf73f01144567b4461e424a607989b5`, 2021-10-18, проверено 2026-07-18.
- [Установка результатов compaction](https://github.com/facebook/rocksdb/blob/6cdeb9d9d0630763327f512e6255cab33f6834e7/db/compaction/compaction_job.cc#L2267-L2360) — RocksDB, tag `v11.1.1`, commit `6cdeb9d9d0630763327f512e6255cab33f6834e7`, проверено 2026-07-18.
