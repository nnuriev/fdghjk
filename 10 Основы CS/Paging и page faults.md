---
aliases:
  - Demand paging и page faults
  - Страничная память
tags:
  - область/основы-cs
  - тема/операционные-системы
  - тема/память
статус: проверено
---

# Paging и page faults

## TL;DR

Paging делит virtual address space на pages и отображает их на physical page frames через page tables. Page fault — synchronous CPU exception, когда translation отсутствует или запрещает requested access. Это нормальная часть demand paging: kernel может выделить anonymous page, загрузить file-backed page или выполнить copy-on-write, после чего повторить faulting instruction.

Fault превращается в ошибку только тогда, когда kernel не может легально обслужить access. Invalid mapping обычно даёт `SIGSEGV`; некоторые ошибки file-backed mapping дают `SIGBUS`. Minor fault обслуживается без I/O, major fault требует I/O. Ни один из терминов не означает автоматически «swap» или «сломанная программа».

## Область применимости

- Linux man-pages 6.18 и upstream kernel 7.1 на MMU-enabled architecture.
- Базовая page size зависит от architecture и kernel configuration; 4 KiB используется лишь как типичный x86-64 пример.
- Вне scope: NUMA migration faults, userfaultfd protocol, DAX, device memory и подробности reclaim algorithms.

## Ментальная модель

VMA отвечает: «разрешён ли такой access к этому диапазону и чем он backed?» Page table отвечает: «к какому frame ведёт конкретная virtual page и с какими permission bits?» TLB кэширует недавние ответы page table.

Когда CPU не находит допустимую translation, он останавливает текущую instruction и передаёт fault address и access type kernel. Kernel ищет VMA:

- VMA нет или permissions не подходят — отправить signal;
- anonymous page ещё не материализована — создать zero-filled mapping;
- нужное file-backed содержимое уже resident и up to date — установить PTE без storage I/O;
- для восстановления нужного содержимого фактически требуется storage I/O — запустить его и, возможно, переключить task;
- write идёт в copy-on-write mapping — выделить private page, скопировать content и сделать PTE writable.

После успешной обработки CPU повторяет ту же instruction. Application обычно не видит fault как return value, но видит его latency и counters.

## Как устроено

### Translation path

Virtual address делится на indices уровней page table и offset внутри page. Linux описывает до пяти уровней, но architecture может «свернуть» неиспользуемые levels. Hardware page-table walk находит PTE; TLB избавляет от walk при повторных accesses.

PTE хранит physical frame number и control bits: present/valid, writable, executable, user-accessible, accessed/dirty и architecture-specific flags. Page size больше базовой уменьшает TLB и page-table overhead, но усиливает internal fragmentation и цену allocation/fault.

### Fault path Linux

Architecture-specific handler нормализует exception и передаёт её memory-management code. Для user address kernel находит VMA, проверяет read/write/execute и вызывает `handle_mm_fault()`. Дальше path расходится для anonymous, file-backed, shared и copy-on-write mappings. Реализация в `mm/memory.c` меняется, поэтому названия внутренних helpers нельзя считать user ABI.

Fault handler способен sleep. Например, major file fault ждёт storage I/O, а allocation под memory pressure запускает reclaim. Пока task ждёт, [[10 Основы CS/Планирование CPU и переключение контекста|scheduler]] исполняет другую runnable работу. Minor fault часто обслуживается без context switch, хотя unrelated preemption возможна.

### Minor, major и invalid faults

Linux `getrusage()` определяет `ru_minflt` как faults, обслуженные без I/O activity, а `ru_majflt` — faults, потребовавшие I/O. File page, уже находящаяся в page cache, способна дать minor fault: storage не читается, нужно лишь построить process mapping. Copy-on-write write обычно minor, если allocation не приводит к отдельному I/O path.

Major fault не обязан означать вращающийся disk; I/O может прийти с SSD, network-backed filesystem или swap. И наоборот, медленный memory reclaim не всегда отражается как major fault конкретного task.

Access вне VMA или write в read-only VMA приводит к `SIGSEGV` с причиной вроде mapping error или access error. Для `mmap` файла access к page за текущим end-of-file может дать `SIGBUS`. Это важно для файла, который конкурентно truncate'нули.

## Пример или трассировка

Parent process отображает одну anonymous page как `MAP_PRIVATE|MAP_ANONYMOUS`, пишет в неё `42`, затем вызывает `fork()`:

1. `mmap` создаёт VMA. Первый write вызывает minor fault: kernel выделяет zeroed physical page и ставит writable PTE.
2. После `fork` parent и child PTEs указывают на тот же frame, но write permission убран, а mapping помечен copy-on-write. Полного копирования address space нет.
3. Child читает значение `42` без copy. Если translation уже создана, page fault не нужен; TLB miss и page fault всё равно остаются разными событиями.
4. Child пишет `43`. CPU вызывает protection fault. Kernel видит legal COW write, выделяет новый frame, копирует page и меняет child PTE. Обычно это minor fault.
5. Parent по-прежнему читает `42`, child — `43`. Physical copy появилась только на первой записи.
6. После `munmap` child обращается к старому address. VMA отсутствует, fault неустраним, kernel доставляет `SIGSEGV`.

Если вместо anonymous page отображён холодный file, первый read может стать major fault из-за I/O. Тот же read при тёплом page cache даст minor fault или вообще не fault, если PTE уже существует.

## Trade-offs

Demand paging уменьшает startup time и RSS: kernel материализует только touched pages. Цена — непредсказуемая latency первого access. Pre-faulting и `MAP_POPULATE` переносят часть работы на setup; memory locking удерживает pages resident, но расходует ограниченный locked-memory budget и давит на остальную систему.

Base pages экономят память на sparse access и дешевле копируются при COW. Huge pages уменьшают TLB misses и page-table footprint для плотных больших regions, зато требуют крупной contiguous allocation, могут тратить RAM на partly used regions и делают отдельный fault/compaction дороже.

Swap увеличивает объём anonymous memory, который система способна сохранить, но major fault из swap увеличивает tail latency. Отключение swap не отменяет memory pressure: reclaim file cache и OOM остаются.

## Типичные ошибки

**Неверное предположение:** page fault — ошибка приложения. **Симптом:** normal demand paging принимают за crash. **Причина:** большинство faults kernel обслуживает прозрачно. **Исправление:** разделять handled minor/major faults и signal-producing invalid access.

**Неверное предположение:** major fault означает disk, minor — RAM access. **Симптом:** неверный диагноз storage bottleneck. **Причина:** классификация говорит, потребовалась ли I/O activity для fault; backing device и остальная reclaim latency не закодированы в названии. **Исправление:** коррелировать faults с block/filesystem I/O и page-cache state.

**Неверное предположение:** TLB miss и page fault — одно событие. **Симптом:** любой page-table walk считают переходом в kernel. **Причина:** hardware обычно заполняет TLB после успешного walk без exception. **Исправление:** различать cache miss translation и отсутствующую/запрещённую PTE.

**Неверное предположение:** успешный `mmap` гарантирует physical memory для будущих writes. **Симптом:** поздний OOM при touch. **Причина:** demand allocation, overcommit и cgroup limits откладывают failure. **Исправление:** учитывать commit policy, touch pattern и OOM behavior.

**Неверное предположение:** `fork()` копирует весь heap сразу. **Симптом:** стоимость fork оценивают по полному RSS, но пропускают последующие COW spikes. **Причина:** сначала копируются page tables и разделяются frames; private copies появляются на writes. **Исправление:** оценивать page-table cost и объём страниц, которые parent/child изменят после fork.

## Когда применять

- Для cold-start и tail-latency измеряйте minor/major faults отдельно от CPU и storage latency.
- Для больших mappings определяйте touch density, page size и нужен ли predictable prefault.
- После `fork` оценивайте write working set, а не только исходный RSS.
- При `SIGSEGV`/`SIGBUS` проверяйте VMA permissions, lifetime mapping и изменение backing file.

## Источники

- [Page Tables](https://github.com/torvalds/linux/blob/v7.1/Documentation/mm/page_tables.rst) — репозиторий Linux kernel, tag v7.1, файл `Documentation/mm/page_tables.rst`, проверено 2026-07-18.
- [Memory Management Concepts](https://github.com/torvalds/linux/blob/v7.1/Documentation/admin-guide/mm/concepts.rst) — репозиторий Linux kernel, tag v7.1, разделы Virtual Memory, Page Cache и Anonymous Memory, проверено 2026-07-18.
- [mm/memory.c](https://github.com/torvalds/linux/blob/v7.1/mm/memory.c) — репозиторий Linux kernel, tag v7.1, символы `handle_mm_fault`, `__handle_mm_fault` и COW fault path, проверено 2026-07-18.
- [getrusage(2)](https://man7.org/linux/man-pages/man2/getrusage.2.html) — Linux man-pages 6.18, определения `ru_minflt` и `ru_majflt`, проверено 2026-07-18.
- [mmap(2)](https://man7.org/linux/man-pages/man2/mmap.2.html) — Linux man-pages 6.18, `MAP_PRIVATE`, `MAP_POPULATE`, `SIGSEGV` и `SIGBUS`, проверено 2026-07-18.
- [madvise(2)](https://man7.org/linux/man-pages/man2/madvise.2.html) — Linux man-pages 6.18, paging advice и populate operations, проверено 2026-07-18.
- [mlock(2)](https://man7.org/linux/man-pages/man2/mlock.2.html) — Linux man-pages 6.18, memory locking и `RLIMIT_MEMLOCK`, проверено 2026-07-18.
- [mmap()](https://pubs.opengroup.org/onlinepubs/9799919799/functions/mmap.html) — The Open Group Base Specifications Issue 8, POSIX.1-2024, проверено 2026-07-18.
