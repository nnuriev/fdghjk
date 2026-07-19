---
aliases:
  - Atomics and memory ordering
  - Атомарные операции и порядок памяти
tags:
  - область/основы-cs
  - тема/операционные-системы
  - тема/конкурентность
статус: проверено
---

# Атомики и memory ordering

## TL;DR

Atomicity отвечает: «может ли операция наблюдаться частично?». Memory ordering отвечает: «какие другие чтения и записи разрешено наблюдать до и после неё?». Это независимые свойства. Relaxed atomic остаётся неделимым и участвует в modification order своей переменной, но не публикует соседний payload. Release store и acquire load, который прочитал значение из соответствующей release sequence, создают synchronizes-with edge; вместе с program order он даёт happens-before. Sequential consistency (`seq_cst`) добавляет единый total order для всех `seq_cst` operations.

Сильный порядок упрощает доказательство, но не превращает несколько полей в transaction и не делает non-atomic data race допустимой. В Go выбор уже сделан языком: `sync/atomic` предоставляет только sequentially consistent atomics. Поэтому C/POSIX `memory_order_acquire` нельзя механически приравнивать к `atomic.Load` в Go; Go operation имеет более сильный контракт.

## Область применимости

- Формальная основа: POSIX.1-2024 Issue 8, раздел 4.15, согласованный с memory model ISO C 2018.
- Рассматривается shared memory между user-space threads. Linux futex упомянут как consumer atomic protocol; его blocking semantics разобраны в [[10 Основы CS/Примитивы синхронизации|заметке о примитивах синхронизации]].
- Go-граница: memory model от 2022-06-06 и стандартная библиотека Go 1.26.5. Подробные API и idioms уже есть в [[60 Go/Пакет sync-atomic|заметке о `sync/atomic`]].
- Вне scope: Linux Kernel Memory Model (LKMM), MMIO, DMA, persistence ordering, transactional memory и безопасное освобождение памяти в произвольных lock-free структурах.

## Ментальная модель

Shared-memory protocol удобно проверять на четырёх уровнях:

1. **Sequenced-before** задаёт обязательный порядок evaluations внутри одного thread по правилам языка.
2. **Modification order** полностью упорядочивает изменения одной atomic object. У каждой object свой order; общего порядка между разными relaxed atomics из этого не следует.
3. **Synchronizes-with** соединяет threads. Типичный edge появляется, когда acquire load читает значение release store или его release sequence.
4. **Happens-before** — транзитивное замыкание sequenced-before и межпоточных synchronization edges. Только через него доказывают видимость обычного payload.

Cache coherence близка ко второму уровню: участники согласуют историю одной location. Memory consistency шире и ограничивает наблюдения между разными locations. Фраза «cache coherent, значит всё видно по порядку» смешивает эти уровни.

| Memory order | Что гарантирует atomic object | Как упорядочивает другие accesses | Типичное применение |
| --- | --- | --- | --- |
| `relaxed` | Неделимость и per-object modification order | Не создаёт synchronization edge для соседних данных | Независимый counter, где ordering приходит из другого primitive |
| `release` | Store или RMW публикует предшествующие accesses | Запрещает им уйти после release в абстрактном execution | Публикация готового state |
| `acquire` | Load или RMW принимает publication, если читает release sequence | Последующие accesses не могут оказаться до acquire | Чтение опубликованного state |
| `acq_rel` | Обе стороны для read-modify-write | Принимает прошлое и публикует собственное предшествующее состояние | CAS/RMW transition в цепочке owners |
| `seq_cst` | Acquire/release semantics по виду operation плюс единый order `S` всех SC operations | Даёт наиболее простую глобальную картину среди atomics | Default, когда выигрыш weaker order не доказан |

Atomic operation не означает, что implementation обязательно lock-free. POSIX `<stdatomic.h>` предоставляет `atomic_is_lock_free()`, а macros `ATOMIC_*_LOCK_FREE` различают never, sometimes и always lock-free types. «Atomic» — семантика наблюдения; «lock-free» — progress property реализации.

## Как устроено

### Язык ограничивает и compiler, и CPU

Исходный порядок строк не равен порядку, который обязаны наблюдать другие threads. Compiler переставляет, объединяет или удаляет memory operations, пока сохраняет разрешённое языком поведение. CPU использует store buffers, speculative loads, out-of-order execution и coherent caches. Memory model стоит над обоими слоями: задаёт допустимые observations, а compiler отображает atomic и fence operations на инструкции конкретной architecture.

Отсюда два следствия. Во-первых, тест на x86 не доказывает переносимость protocol на ARM или RISC-V. Во-вторых, `volatile` не заменяет atomic: оно ограничивает часть compiler optimizations для accesses к volatile object, но не даёт atomic modification order и межпоточный synchronizes-with contract.

Barrier тоже лучше понимать как ограничение порядка, а не как команду «сбросить все caches в RAM». На coherent SMP публикация обычно передаёт ownership cache line между cores; требуемый machine instruction зависит от architecture и вида operation.

### Release/acquire message passing

Начальное состояние: `ready == false`, `payload` не опубликован.

```c
// Thread P
payload = 42;                                              // ordinary write
atomic_store_explicit(&ready, true, memory_order_release);

// Thread C
if (atomic_load_explicit(&ready, memory_order_acquire)) {
    assert(payload == 42);                                 // ordinary read
}
```

Если acquire load прочитал `true` из release store, строится цепочка:

```text
write(payload=42)
  sequenced-before
release-store(ready=true)
  synchronizes-with
acquire-load(ready)==true
  sequenced-before
read(payload)
```

Транзитивно write happens-before read, поэтому consumer обязан увидеть `42`. Если load вернул `false`, synchronization edge с этой publication нет и consumer не должен читать payload.

Замена обеих operations на `relaxed` сохраняет атомарность `ready`, но убирает publication edge. Даже если consumer фактически увидел `true`, ordinary write и read `payload` не упорядочены happens-before. В C/POSIX это data race и undefined behavior. Само значение flag не переносит видимость соседней memory без нужного ordering.

Release sequence расширяет прямую пару store/load. В модели POSIX.1-2024 она начинается release operation над atomic object и продолжается смежными в modification order operations того же thread либо atomic read-modify-write operations. Acquire, прочитавший значение из этой sequence, принимает publication её head. Это важно для ownership chains, но делает доказательство чувствительным к тому, какая именно modification была прочитана.

### Relaxed: атомарный счётчик без публикации

Relaxed `fetch_add` корректен, если counter сам и есть весь shared state, а его значение не служит сигналом готовности другого объекта. Например, shards могут считать число обработанных событий relaxed operations, а итоговый reader получить completion ordering через `pthread_join`, mutex или иной primitive.

Опасная подмена выглядит так: writer заполняет обычную структуру и relaxed store публикует pointer или `ready`; reader видит новый atomic value и сразу разыменовывает payload. Per-object coherence flag не создаёт happens-before для полей объекта. Нужны release/acquire, mutex либо иной документированный publication primitive.

### Sequential consistency: общий порядок только для SC operations

`memory_order_seq_cst` требует единого total order `S` всех SC operations, согласованного с happens-before и modification orders затронутых objects. Это не «глобальные часы» для каждой инструкции: ordinary operations входят в рассуждение через sequenced-before и happens-before, а weaker atomics не обязаны образовывать ту же простую картину.

Минимальный litmus test, `x == y == 0`:

```text
Thread 1                         Thread 2
x.store(1, seq_cst)              y.store(1, seq_cst)
r1 = y.load(seq_cst)             r2 = x.load(seq_cst)
```

Outcome `r1 == 0 && r2 == 0` запрещён. Чтобы оба load прочитали initial zero, в `S` каждый load должен стоять до store другого thread. Но program order требует `store(x) < load(y)` и `store(y) < load(x)`. Получается cycle, несовместимый с одним total order.

Если stores сделать release, а loads acquire, оба нулевых результата допустимы: ни один load не прочитал release store, значит synchronizes-with edges не возникли. Acquire не заставляет увидеть «самое свежее» значение; оно задаёт порядок только для publication, которую operation действительно наблюдает.

### Read-modify-write, CAS и составные инварианты

Atomic read-modify-write (`fetch_add`, exchange, успешный compare-and-swap) читает и изменяет одну object как неделимую operation. По POSIX/C RMW читает последнюю предшествующую ему modification в modification order. Это предотвращает lost update одного counter, но не склеивает несколько atomic objects в transaction.

CAS проверяет значение, а не историю. Если state прошло `A → B → A`, compare-and-swap с expected `A` может успешно завершиться, хотя логический объект уже другой. Это ABA problem. Version/tag уменьшает неоднозначность; mutex или immutable snapshot часто упрощает proof. Для pointer algorithms одного CAS всё равно мало: нужно отдельно доказать lifetime и memory reclamation, иначе address можно переиспользовать после free.

Под contention CAS loop способен многократно проигрывать и повторять работу. Отсутствие blocking syscall не означает wait-free progress и не гарантирует меньшую latency. Один hot atomic также заставляет cores передавать cache line; расположенные рядом независимые atomics могут создать false sharing.

### Связь с locks и futex

Mutex unlock ведёт себя как release, последующий успешный lock — как acquire для защищённого state. Высокоуровневый lock одновременно задаёт ownership, wait policy и memory ordering, поэтому обычно проще atomics для многополевого инварианта.

Futex решает другую половину задачи: атомарно сравнивает futex word с expected и при совпадении блокирует thread. Он не превращает surrounding ordinary accesses в корректный C protocol. Типичный mutex fast path использует acquire CAS при захвате, release store при освобождении и futex wait/wake только для парковки contenders. Политика значений и ordering принадлежит user-space library.

### Граница Go

Go memory model тоже строит happens-before как transitive closure sequenced-before и synchronized-before и обещает DRF-SC для race-free programs. Но последствия race отличаются от C: Go ограничивает реализации даже для некоторых racing word-sized reads, тогда как C/POSIX data race даёт undefined behavior. Это не повод оставлять race; [[60 Go/Race detector|race detector]] и явная synchronization остаются рабочим правилом.

Все operations `sync/atomic` в Go ведут себя так, будто расположены в некотором sequentially consistent order. Если B наблюдает effect A, A synchronized-before B. Public API не принимает `memory_order_relaxed`, `acquire` или `release`. Поэтому C-style weaker-order optimization в Go нельзя выразить через стандартный `sync/atomic`, а доказательство должно ссылаться на [[60 Go/Модель памяти Go и happens-before|Go memory model]], документацию конкретного primitive и существующую [[60 Go/Пакет sync-atomic|заметку об atomics]].

## Пример или трассировка

Возьмём release/acquire publication выше и рассмотрим три executions.

### Consumer прочитал `false`

1. Consumer выполняет acquire load до release store или выбирает initial modification `false`.
2. Synchronizes-with edge с producer отсутствует.
3. Consumer пропускает branch и не читает payload.

Execution корректен: acquire не обещает дождаться producer.

### Consumer прочитал `true`

1. Producer пишет `payload = 42`, затем release-store `ready = true`.
2. Consumer acquire-load читает эту publication.
3. Release synchronizes-with acquire; через program order `payload = 42` happens-before `read(payload)`.
4. Assertion обязана пройти.

### Flag relaxed, payload обычный

1. Producer пишет payload и relaxed-store `true`.
2. Consumer relaxed-load может вернуть `true`, потому что atomic object имеет coherent modification order.
3. Между ordinary payload accesses нет happens-before.
4. В C/POSIX возникла data race; рассуждать о наблюдаемом `payload` дальше нельзя.

Контраст показывает границу: atomicity flag отвечает за целостность самого flag. Publication payload появляется только из ordering edge.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| POSIX.1-2017, Issue 7 → POSIX.1-2024, Issue 8 | POSIX перечислял functions, которые synchronizes memory, без полной встроенной C memory model | Раздел 4.15 получил formal data-race, happens-before, modification-order и `memory_order` semantics, адаптированные из ISO C 2018 | Контракт pthread/sem и C atomics можно доказывать в одной нормативной модели | [POSIX.1-2024 Rationale, A.4.15](https://pubs.opengroup.org/onlinepubs/9799919799.2024edition/xrat/V4_xbd_chap01.html#tag_21_04_15) |
| До Go 1.19 → Go 1.19 и новее | Memory model и atomic API не имели typed atomic types текущего вида | Memory model пересмотрена; добавлены typed atomics; Go явно оставил только sequentially consistent atomics | C/C++ acquire/release snippets нельзя переносить как API Go; стандартный Go protocol рассуждает через SC atomics | [Go 1.19 Release Notes](https://go.dev/doc/go1.19#memory-model) |

## Trade-offs

- **Mutex или atomics.** Mutex сериализует весь invariant и умеет park waiters. Atomics уменьшают API surface для одного scalar state, но переносят сложность в proof, retry и memory reclamation. Когда нужно согласованно изменить два поля, mutex обычно ближе к задаче.
- **Relaxed или acquire/release.** Relaxed оставляет максимум свободы implementation и подходит для независимой статистики. Acquire/release публикует payload без глобального SC order, но каждое чтение надо связать с конкретной release sequence. Ошибка proof превращается в race, а выигрыш зависит от architecture и workload.
- **Acquire/release или seq_cst.** SC проще проверять через один total order и безопаснее как исходный выбор. Weaker order применяют после benchmark и litmus-level proof, когда реальная платформа выигрывает от ослабления.
- **CAS loop или blocking lock.** CAS избегает sleep при короткой конкуренции, но под contention тратит CPU и cache bandwidth на retries. Mutex может park waiter и даёт стабильнее понятный invariant; цена — queueing и возможный context switch.
- **Несколько atomic fields или один immutable snapshot.** Отдельные loads могут относиться к разным моментам. Atomic pointer на immutable snapshot даёт согласованное состояние одной publication, но writer платит allocation/copy и обязан безопасно управлять lifetime.

## Типичные ошибки

### Atomicity принимают за ordering

- **Неверное предположение:** раз flag atomic, предыдущие ordinary writes автоматически видимы.
- **Симптом:** consumer видит ready state, но читает старый или racing payload.
- **Причина:** relaxed operation упорядочивает только сам atomic object.
- **Исправление:** release/acquire publication, mutex или другой documented synchronization edge.

### Acquire считают свежим чтением

- **Неверное предположение:** acquire load обязан вернуть последнюю wall-clock запись.
- **Симптом:** algorithm ждёт progress, но load продолжает видеть старое допустимое значение.
- **Причина:** acquire ограничивает порядок после наблюдённой modification, а не выбирает её за вас.
- **Исправление:** строить wait loop и progress protocol отдельно; доказывать, какую release operation прочитал load.

### Несколько atomics считают transaction

- **Неверное предположение:** SC loads `balance` и `version` образуют единый snapshot.
- **Симптом:** reader получает пару значений, которая не была одним логическим state.
- **Причина:** каждая operation атомарна, но между двумя loads writer может выполнить transition.
- **Исправление:** mutex, versioned retry protocol или atomic publication одного immutable snapshot.

### Смешивают atomic и ordinary access

- **Неверное предположение:** достаточно сделать atomic только writer либо «важные» reads.
- **Симптом:** race report, undefined behavior в C или непредсказуемый protocol.
- **Причина:** ordinary conflicting access не участвует в едином atomic protocol и не упорядочен happens-before.
- **Исправление:** все accesses к synchronization object выполнять atomic operations либо защищать одним lock.

### `volatile` используют для межпоточной связи

- **Неверное предположение:** `volatile` запрещает compiler и CPU менять порядок так же, как atomic.
- **Симптом:** busy-wait или publication работает на одной сборке и ломается после optimization либо на другой architecture.
- **Причина:** volatile access не получает modification order и synchronizes-with semantics atomics.
- **Исправление:** использовать `<stdatomic.h>`, pthread primitive или synchronization API языка.

### CAS не замечает ABA и lifetime

- **Неверное предположение:** успешный CAS доказывает, что object не менялся с момента load.
- **Симптом:** update применяется к другой logical generation либо разыменовывается освобождённая память.
- **Причина:** CAS сравнивает текущее bit pattern; история и lifetime в него не входят.
- **Исправление:** version/tag, hazard pointers/epoch scheme с отдельным доказательством либо mutex.

### Weaker order выбирают по названию architecture

- **Неверное предположение:** на x86 ordinary accesses и так «почти SC», поэтому release/acquire не нужны.
- **Симптом:** protocol зависит от compiler transformation или ломается на другом GOARCH/CPU.
- **Причина:** source-level correctness задаёт memory model языка, а не наблюдение одной machine build.
- **Исправление:** сначала доказать protocol в модели языка, затем измерять generated code на поддерживаемых targets.

## Когда применять

Atomic подходит, когда shared state сводится к одной независимо интерпретируемой location: counter, flag с явно заданной publication semantics, sequence number или pointer на immutable snapshot. Перед выбором weaker order письменно ответьте на четыре вопроса:

1. Какая release operation публикует данные?
2. Какая acquire operation обязана прочитать её или её release sequence?
3. Какие ordinary accesses соединяет получившийся happens-before path?
4. Какие outcomes остаются допустимы, если acquire прочитал другое значение?

Если один ответ расплывчат, берите mutex или `seq_cst` и упрощайте protocol. Для Go этот выбор ещё короче: стандартные atomics уже SC; если invariant не умещается в одну synchronization point, используйте [[60 Go/Mutex, RWMutex и примитивы координации sync|mutex]], channel ownership или immutable publication, а не пытайтесь имитировать C memory orders.

## Источники

- [Memory Ordering and Synchronization](https://pubs.opengroup.org/onlinepubs/9799919799.2024edition/basedefs/V1_chap04.html#tag_04_15) — The Open Group, POSIX.1-2024, Issue 8, раздел 4.15, проверено 2026-07-18.
- [Rationale for Memory Ordering and Synchronization](https://pubs.opengroup.org/onlinepubs/9799919799.2024edition/xrat/V4_xbd_chap01.html#tag_21_04_15) — The Open Group, POSIX.1-2024, Issue 8 rationale, проверено 2026-07-18.
- [<stdatomic.h>](https://pubs.opengroup.org/onlinepubs/9799919799.2024edition/basedefs/stdatomic.h.html) — The Open Group, POSIX.1-2024, Issue 8, проверено 2026-07-18.
- [ISO/IEC 9899:201x Committee Draft N1570](https://www.open-std.org/jtc1/sc22/wg14/www/docs/n1570.pdf) — ISO/IEC JTC 1/SC 22/WG14, C11 committee draft N1570, 2011-04-12, разделы 5.1.2.4 и 7.17, проверено 2026-07-18.
- [Linux kernel memory barriers](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/Documentation/core-api/wrappers/memory-barriers.rst?h=v7.1) — репозиторий Linux kernel, tag v7.1; guide, а не hardware specification, проверено 2026-07-18.
- [futex(2)](https://www.man7.org/linux/man-pages/man2/futex.2.html) — Linux man-pages project, man-pages 6.18, 2026-02-14, проверено 2026-07-18.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26.5, проверено 2026-07-18.
- [Go 1.19 Release Notes: Memory Model](https://go.dev/doc/go1.19#memory-model) — The Go Project, Go 1.19, проверено 2026-07-18.
- [Package sync/atomic](https://pkg.go.dev/sync/atomic@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
