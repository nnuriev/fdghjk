---
aliases:
  - Read и write amplification
  - Read amplification
  - Write amplification
  - Усиление чтения и записи
tags:
  - область/данные
  - тема/внутреннее-устройство-хранилищ
  - механизм/amplification
статус: проверено
---

# Read и write amplification

## TL;DR

- **Amplification** показывает, сколько физической работы система выполняет ради единицы логической работы. Без единиц, границы слоя и окна измерения число `5×` почти бессмысленно.
- **Database write amplification** обычно считают как bytes, записанные storage engine, делённые на logical user bytes. Нужно явно сказать, включены ли WAL, flush, compaction, replication и metadata.
- **Device write amplification** — NAND bytes / host bytes из-за Flash Translation Layer и garbage collection. При согласованных границах end-to-end amplification приблизительно равна произведению database и device amplification.
- **Read amplification** может означать I/O operations, прочитанные blocks/runs или physical bytes на один logical lookup/byte. Эти определения отвечают на разные вопросы.
- **Space amplification** — retained physical bytes относительно live logical data. Старые версии, tombstones, snapshots, compaction inputs/outputs и свободное место страниц увеличивают её.

## Область и версии

Определения сопоставлены с RocksDB Tuning Guide и counters RocksDB 11.1.1, tag `v11.1.1`, commit `6cdeb9d9d0630763327f512e6255cab33f6834e7`; механизм LSM — с оригинальной статьёй O’Neil et al. Проверено 2026-07-18.

Единого межпродуктового стандарта метрик нет. Поэтому ниже сначала задаётся измерительный контракт, а потом сравниваются [[30 Данные/B-tree и B+tree|B+tree]] и [[30 Данные/LSM-tree|LSM-tree]].

## Ментальная модель: логическая операция порождает цепочку работы

Приложение видит один `put(k, v)`, а система может:

```text
logical put
  → WAL write
  → memtable flush
  → compaction L0→L1
  → compaction L1→L2
  → device internal relocation
```

Чтение одного key тоже может проверить memtable, несколько SST indexes/filters, data blocks и базовую таблицу. Сама по себе amplification не означает ошибку: часть дополнительной работы — цена за durability, sorted order, snapshots, compression или дешёвую foreground write latency. Вопрос — укладывается ли такой обмен в I/O, latency и space budget.

## Сначала зафиксировать контракт измерения

Для каждой цифры нужны четыре поля:

1. **Логический знаменатель:** user bytes, число operations, returned bytes или live dataset.
2. **Физический числитель:** host bytes, device bytes, I/O operations, blocks, runs либо files.
3. **Граница:** storage engine, filesystem, block device, replica set или SSD NAND.
4. **Окно:** initial load, steady state, час, полный compaction cycle или lifetime базы.

Например, «write amplification = 4×» может исключать WAL в RocksDB counter, но включать WAL в метрике на уровне block device. Обе цифры корректны внутри своего контракта и несопоставимы без нормализации.

## Write amplification

### Database/host write amplification

Одна распространённая формула:

```text
DB WA = bytes written by the storage engine to host storage
        ---------------------------------------------------
                 logical user bytes accepted
```

В числитель могут входить WAL, SST flush, compaction outputs, index/filter blocks, manifest и страничные перезаписи. Некоторые движки публикуют отдельную compaction WA, где WAL исключён. Deletes и overwrites усложняют знаменатель: размер API payload и изменение live dataset — разные величины.

У LSM foreground write сначала дешёвая, но один byte может многократно переписываться по уровням. Leveled compaction обычно повышает WA ради меньших read/space amplification; tiered policy делает обратный trade-off.

У mutable B+tree нет LSM-compaction, но остаются WAL, запись целой страницы ради малого изменения, split, index maintenance и page cleaning. Маленькое обновление 20 bytes на 8 KiB page уже создаёт большое отношение physical/logical bytes, даже если страница записана один раз.

### Device write amplification

Для SSD:

```text
Device WA = NAND bytes programmed
            ---------------------
              host bytes written
```

FTL записывает данные out-of-place, переносит ещё живые flash pages и стирает erase blocks. Overprovisioning, TRIM, free-space fragmentation и workload locality влияют на это отношение. Storage engine обычно видит host bytes, а firmware — NAND bytes.

Если границы и окно совпадают:

```text
end-to-end WA ≈ DB WA × Device WA
```

Это не тождество при разных accounting rules, compression, filesystem COW или replication между слоями.

## Read amplification

У термина несколько полезных определений:

```text
I/O RA    = physical read operations / logical query
Block RA  = data/index blocks examined / logical query
Byte RA   = physical bytes read / useful bytes returned
Run RA    = sorted runs consulted / lookup
```

Для point lookup latency часто лучше объясняет I/O RA; для bandwidth-heavy range scan — Byte RA. Cache hit может уменьшить physical I/O до нуля, хотя CPU всё ещё проверяет filters и runs. Поэтому в отчёте нужно отдельно указывать cache state.

В B+tree холодный lookup читает незакэшированные уровни и, для непокрывающего индекса, table/heap page. Диапазон после первого спуска проходит листья последовательно.

В LSM point lookup может проверить memtables, несколько overlapping L0 files и по одному файлу ненулевых leveled levels. Bloom filters резко уменьшают I/O для отсутствующих keys, но false positives и hits всё равно читают data blocks. Range scan сливает итераторы всех пересекающихся runs, поэтому его RA зависит от числа runs и overlap.

## Space amplification

Распространённая формула:

```text
Space A = physical retained bytes / live logical bytes
```

Иногда продукт публикует **overhead percentage**:

```text
(physical - live) / live × 100%
```

Тогда `Space A = 1.5×` соответствует `50%` overhead, а не `150%`. Нужно проверять формулу.

В LSM space растёт из-за старых версий, tombstones, snapshots, нескольких runs и одновременных compaction inputs/outputs. Tiered compaction обычно требует большего headroom. В B+tree — из-за fill factor, page fragmentation, dead tuples/MVCC versions и временных rebuild files. Compression уменьшает physical bytes, но может увеличить CPU и объём данных, который нужно распаковать для маленького чтения.

## Сквозной числовой пример

Две логические записи по `1 KiB` дают `2 KiB` user data. За выбранное полное окно движок записал:

```text
WAL:                2 KiB
memtable flush:     2 KiB
compaction outputs: 6 KiB
-------------------------
host writes:       10 KiB
```

Тогда:

```text
DB WA = 10 / 2 = 5×
```

SSD для этих `10 KiB` host writes запрограммировал `15 KiB` NAND:

```text
Device WA = 15 / 10 = 1.5×
End-to-end WA = 15 / 2 = 7.5× = 5× · 1.5×
```

Point read возвращает `1 KiB`, но из-за одного Bloom false positive и настоящего hit читает два блока по `4 KiB`:

```text
I/O RA = 2 reads/query
Byte RA = 8 KiB / 1 KiB = 8×
```

На диске находятся `12 KiB`, а live logical data всё ещё `2 KiB`:

```text
Space A = 12 / 2 = 6×
Space overhead = (12 - 2) / 2 × 100% = 500%
```

Наблюдаемый результат: одна и та же система одновременно имеет DB WA `5×`, device WA `1.5×`, end-to-end WA `7.5×`, I/O RA `2`, Byte RA `8×` и Space A `6×`. Это иллюстративная арифметика, не benchmark конкретного движка.

## Trade-offs: как механизмы меняют метрики

| Механизм | Что улучшает | Чем платит |
|---|---|---|
| Большой B+tree page/fanout | Меньше уровней и I/O lookup | Больше byte WA для малых updates, возможна лишняя read bandwidth |
| LSM memtable + sequential flush | Низкая foreground write latency | Будущие compactions и дополнительные runs |
| Leveled compaction | Read и space amplification | Write amplification |
| Tiered compaction | Write amplification | Read/space amplification и burst I/O |
| Bloom filter | Point-miss read amplification | RAM, filter reads, CPU; не решает диапазоны |
| Compression | Space и host/device bytes | CPU и read granularity |
| Большой cache | Physical read amplification | RAM; не уменьшает работу после cold start |
| Долгие snapshots | Изоляция/историческое чтение | Старые версии и tombstones нельзя убрать |

Оптимизация одной метрики без SLA часто просто передвигает цену. Например, уменьшение compaction rate снижает текущий write I/O, но накапливает runs, повышает read/space amplification и будущий stall risk.

## Как измерять в steady state

1. Прогреть базу до целевого размера, превышающего cache, если моделируется disk-bound workload.
2. Дождаться устойчивого уровня compaction debt; initial load без нижних уровней занижает WA.
3. Зафиксировать logical bytes/operations на API boundary.
4. Снять WAL, flush, compaction и total filesystem/device bytes отдельно.
5. Разделить point hits, point misses и range scans; указать cache hit ratio.
6. Захватить как минимум полный compaction cycle и пики временного места.
7. Сопоставить throughput с p50/p99/p999 latency и write stalls.

В RocksDB counters `COMPACT_READ_BYTES`, `COMPACT_WRITE_BYTES` и `FLUSH_WRITE_BYTES` позволяют разложить внутренний I/O, но сами по себе не включают все layers. Для end-to-end оценки нужны host/device counters с тем же окном.

## Типичные ошибки

### Публиковать `WA=5×` без формулы

- **Неверное предположение:** у термина одно универсальное определение.
- **Симптом:** dashboard storage engine не совпадает с block-device telemetry.
- **Причина:** одна метрика исключила WAL/metadata, другая их включила.
- **Исправление:** подписать numerator, denominator, boundary и window.

### Смешивать host и NAND bytes

- **Неверное предположение:** SSD записывает ровно столько, сколько отправила база.
- **Симптом:** износ выше прогноза по DB counters.
- **Причина:** FTL garbage collection создаёт device WA поверх database WA.
- **Исправление:** измерять оба слоя и оценивать end-to-end amplification.

### Считать число levels равным read I/O

- **Неверное предположение:** lookup обязательно читает по файлу с каждого уровня.
- **Симптом:** модель завышает cached misses или занижает overlapping L0 reads.
- **Причина:** filters/cache могут исключить I/O, а L0/tiered levels содержат несколько runs.
- **Исправление:** измерять реальные block reads отдельно для hits, misses и ranges.

### Делать вывод по initial load

- **Неверное предположение:** write cost до заполнения уровней отражает steady state.
- **Симптом:** после нескольких часов throughput падает и начинаются stalls.
- **Причина:** compaction debt и нижние levels ещё не сформировались во время теста.
- **Исправление:** предварительно заполнить базу и тестировать полный compaction cycle.

### Минимизировать WA любой ценой

- **Неверное предположение:** меньше физических writes всегда означает лучший storage engine.
- **Симптом:** растут read latency, disk footprint или recovery time.
- **Причина:** система перестала своевременно compact/organize data.
- **Исправление:** оптимизировать совокупный SLA и resource budget, а не одну величину.

## Когда применять метрики

Amplification нужна при выборе структуры хранения, SSD endurance, compaction policy и capacity planning. Для решения достаточно не «самого маленького числа», а границ:

- выдержит ли устройство end-to-end writes за срок службы;
- помещается ли compaction и temporary space в диск;
- укладываются ли point/range reads в IOPS и bandwidth;
- остаётся ли foreground latency стабильной в steady state;
- какую цену durability и snapshots вносят осознанно.

## Источники

- [RocksDB Tuning Guide](https://github.com/facebook/rocksdb/wiki/RocksDB-Tuning-Guide/768bd97d06691a899d3adcb0333ccaa578ad5415) — RocksDB Wiki, revision `768bd97d06691a899d3adcb0333ccaa578ad5415`, 2023-03-28, проверено 2026-07-18.
- [Compaction](https://github.com/facebook/rocksdb/wiki/Compaction/a4880c101f719057efc8fbc8019322b623bf158d) — RocksDB Wiki, revision `a4880c101f719057efc8fbc8019322b623bf158d`, 2023-06-29, проверено 2026-07-18.
- [Leveled Compaction](https://github.com/facebook/rocksdb/wiki/Leveled-Compaction/12101e0e6a8f9706e05ddfea7072970e0ef25bbd) — RocksDB Wiki, revision `12101e0e6a8f9706e05ddfea7072970e0ef25bbd`, 2023-11-14, проверено 2026-07-18.
- [Universal Compaction](https://github.com/facebook/rocksdb/wiki/Universal-Compaction/008089dbd350f3d41d3b62307a697ea55fcaf802) — RocksDB Wiki, revision `008089dbd350f3d41d3b62307a697ea55fcaf802`, 2023-06-29, проверено 2026-07-18.
- [RocksDB statistics counters](https://github.com/facebook/rocksdb/blob/6cdeb9d9d0630763327f512e6255cab33f6834e7/include/rocksdb/statistics.h#L231-L234) — RocksDB, tag `v11.1.1`, commit `6cdeb9d9d0630763327f512e6255cab33f6834e7`, проверено 2026-07-18.
- [The Log-Structured Merge-Tree (LSM-Tree)](https://doi.org/10.1007/s002360050048) — Patrick O’Neil, Edward Cheng, Dieter Gawlick, Elizabeth O’Neil, Acta Informatica 33(4), 1996, проверено 2026-07-18.
