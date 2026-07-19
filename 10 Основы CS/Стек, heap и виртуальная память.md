---
aliases:
  - Stack, heap и virtual memory
  - Адресное пространство процесса
tags:
  - область/основы-cs
  - тема/операционные-системы
  - тема/память
статус: проверено
---

# Стек, heap и виртуальная память

## TL;DR

Virtual memory даёт process собственное address space и отображает диапазоны virtual addresses на physical pages или backing objects. Stack и heap — способы организовать данные внутри этого пространства, а не разные типы RAM. У каждого OS thread свой stack; heap обычно общий для threads процесса и обслуживается user-space allocator, который крупными порциями получает mappings у kernel.

Virtual size, resident set и allocator heap size отвечают на разные вопросы. Зарезервировать 1 GiB addresses не значит занять 1 GiB RAM. `free()` не обязан сразу уменьшить RSS: allocator может оставить pages для повторного использования.

## Область применимости

- Linux user space: man-pages 6.18, upstream kernel 7.1, MMU-enabled systems.
- Native thread model: POSIX.1-2024 и NPTL/glibc 2.43.
- Go-specific связь: toolchain Go 1.26.5; подробности вынесены в [[60 Go/Стеки и escape analysis|стеки и escape analysis]].
- Вне scope: kernel allocators, NUMA policy, GC algorithms и memory ordering.

## Ментальная модель

Address space состоит из virtual memory areas (VMA). Каждый VMA описывает непрерывный диапазон с одинаковыми permissions и backing: executable file, shared library, anonymous memory, mapped file, thread stack. Page tables содержат finer-grained translations для реально отображённых pages, а TLB кэширует часть translations.

Три величины нельзя смешивать:

- virtual size: сколько address ranges process отобразил или зарезервировал;
- RSS (resident set size): какие pages этого process resident в RAM в момент измерения по правилам конкретного счётчика;
- PSS (proportional set size): shared page делится между processes, чтобы оценка лучше отражала долю физической памяти.

Один VMA может почти не иметь resident pages. Одна physical page может быть отображена несколькими processes. Одинаковый virtual address в двух processes обычно ведёт к разным physical pages.

## Как устроено

### Stack

Function call создаёт stack frame: return address, сохранённые registers и local storage согласно ABI/compiler. Обычная stack allocation часто сводится к изменению stack pointer; syscall на каждый frame не нужен. Возврат функции восстанавливает pointer сразу для всего frame, поэтому individual `free` отсутствует.

Каждому POSIX thread нужен собственный stack. Для thread, созданного через `pthread_create`, NPTL выделяет stack mapping с настраиваемой guard area. Если soft `RLIMIT_STACK`, зафиксированный при старте process, не равен `unlimited`, он задаёт default stack size новых threads; иначе NPTL берёт default для architecture. Guard area ловит ограниченный выход за край, но не превращает бесконечную recursion в восстанавливаемую ситуацию. Main thread stack создаётся иначе, поэтому детали дополнительных thread stacks нельзя автоматически переносить на него.

Go goroutine не получает отдельный pthread stack фиксированного default size. Go runtime выделяет небольшой contiguous stack, при необходимости переносит его в больший region и корректирует tracked pointers. Это implementation property Go 1.26.5, а не гарантия размера из language spec.

### Heap

На уровне языка heap хранит objects, lifetime которых не укладывается в LIFO frames либо которые allocator решил разместить динамически. На уровне старых Unix interfaces «heap» часто означает contiguous data segment до program break. Современный allocator не обязан ограничиваться этим сегментом.

glibc `malloc` 2.43 управляет chunks и arenas в user space, запрашивая большие regions через `brk` и anonymous `mmap`. Поэтому большинство `malloc`/`free` не вызывает kernel. Свободный chunk остаётся внутри arena и может продолжать учитываться в RSS; allocator вернёт region через `munmap` или уменьшение program break только когда layout и policy это позволяют.

В Go адресный оператор `&` не решает placement. Compiler делает escape analysis: object остаётся на stack, если lifetime доказан, либо уходит в garbage-collected heap. Решение и diagnostics зависят от toolchain.

### Virtual memory и защита

`mmap()` создаёт VMA, а `mprotect()` меняет допустимые accesses. Physical page часто появляется позже, при первом обращении. [[10 Основы CS/Paging и page faults|Page-fault handler]] проверяет VMA и access type, выделяет anonymous page, находит page cache entry либо сообщает invalid access.

Threads одного process ссылаются на общий `mm_struct`, поэтому видят одни mappings. Отдельный process получает своё memory context. После `fork()` parent и child первоначально делят physical pages через copy-on-write; write fault создаёт private copy.

## Пример или трассировка

Process вызывает `mmap(NULL, 1 GiB, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0)` на Linux:

1. Kernel находит свободный virtual range и создаёт VMA. Вызов может сразу завершиться `ENOMEM` из-за address-space, accounting или policy limits.
2. При успехе `VmSize` вырастает примерно на 1 GiB. Kernel не обязан выделять 1 GiB physical pages, поэтому RSS почти не меняется.
3. Если mapping обслуживается отдельными 4 KiB base pages без prefault и Transparent Huge Pages, первый write в каждую ещё не материализованную page вызывает minor page fault: kernel выделяет zeroed page и создаёт writable PTE. THP или multi-size THP способны материализовать одним fault более крупный диапазон. RSS растёт по мере touched pages. Base page size не универсален, его нужно читать через `sysconf(_SC_PAGESIZE)`.
4. Повторный write в уже mapped page идёт через обычный TLB/page-table translation без fault, пока mapping resident и permissions не изменились.
5. `munmap()` удаляет mapping. Следующий access к старому pointer недопустим и обычно приводит к `SIGSEGV`.

Трасса отделяет reservation, commit/accounting и residency. Overcommit policy также означает, что успешный `mmap` не всегда гарантирует будущий physical allocation при write.

## Trade-offs

Stack allocation дёшева и даёт хороший locality, когда lifetime совпадает с call frame. Ограничения — глубина recursion, большой frame и невозможность сохранить object после возврата без перемещения или escape. Heap поддерживает произвольный lifetime и sharing, но платит allocator metadata, fragmentation, synchronization и, в managed runtime, GC work.

Большой reserved mapping оставляет пространство для роста без немедленного RSS. На 32-bit process virtual addresses сами становятся дефицитным ресурсом; на 64-bit чаще ограничивают cgroup, commit policy и page tables. Touch всего mapping заранее делает latency предсказуемее, но увеличивает startup time и resident footprint.

Много OS threads расходует virtual address ranges на stacks, даже если реально touched малая часть. Goroutines уменьшают эту reservation granularity, но продолжают потреблять physical memory по мере роста и удержания references.

## Типичные ошибки

**Неверное предположение:** stack физически быстрее heap. **Симптом:** placement меняют без измерения access pattern. **Причина:** после mapping CPU обращается к обычным cache lines; разница прежде всего в allocation/lifetime, locality и management cost. **Исправление:** выбирать ownership и lifetime, затем измерять allocations и cache behavior.

**Неверное предположение:** каждый `malloc` делает syscall. **Симптом:** неверная модель system time и contention. **Причина:** allocator режет заранее полученные arenas на chunks. **Исправление:** различать application allocation и получение mappings у kernel.

**Неверное предположение:** `free()` немедленно уменьшает RSS. **Симптом:** memory graph не падает после освобождения объектов. **Причина:** pages остаются в arena, fragmentation не позволяет вернуть region или счётчик обновляется иначе. **Исправление:** смотреть allocator stats, `smaps`, live objects и reclaim policy раздельно.

**Неверное предположение:** `VmSize` равно потреблению RAM. **Симптом:** ложная диагностика OOM по большому virtual mapping. **Причина:** untouched, shared и nonresident pages входят в virtual size. **Исправление:** сопоставлять VmSize, RSS/PSS, swap, cgroup usage и allocator metrics.

**Неверное предположение:** local variable в Go всегда на goroutine stack. **Симптом:** неожиданные heap allocations и GC pressure. **Причина:** lifetime и compiler proof вызывают escape. **Исправление:** проверять `-gcflags=-m=2` на фиксированной toolchain и benchmark.

## Когда применять

- Для memory incident сначала назовите метрику: address-space reservation, RSS/PSS, allocator heap, live heap или cgroup charge.
- Stack/heap placement оптимизируйте после ownership и lifetime, а не по синтаксису `new`/`&`.
- Размеры thread stacks задавайте только при доказанной глубине и оставляйте guard margin.
- При больших mappings отдельно проверяйте overcommit, touch pattern, page size и failure path.

## Источники

- [Process Addresses](https://github.com/torvalds/linux/blob/v7.1/Documentation/mm/process_addrs.rst) — репозиторий Linux kernel, tag v7.1, файл `Documentation/mm/process_addrs.rst`, проверено 2026-07-18.
- [Memory Management Concepts](https://github.com/torvalds/linux/blob/v7.1/Documentation/admin-guide/mm/concepts.rst) — репозиторий Linux kernel, tag v7.1, файл `Documentation/admin-guide/mm/concepts.rst`, проверено 2026-07-18.
- [mmap(2)](https://man7.org/linux/man-pages/man2/mmap.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [proc_pid_maps(5)](https://man7.org/linux/man-pages/man5/proc_pid_maps.5.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [proc_pid_smaps(5)](https://man7.org/linux/man-pages/man5/proc_pid_smaps.5.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [pthread_create(3)](https://man7.org/linux/man-pages/man3/pthread_create.3.html) — Linux man-pages 6.18, NPTL stack defaults, проверено 2026-07-18.
- [brk(2)](https://man7.org/linux/man-pages/man2/brk.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [The GNU C Library Reference Manual: The GNU Allocator](https://sourceware.org/glibc/manual/2.43/pdf/libc.pdf) — GNU Project, glibc 2.43, раздел 3.2.2, проверено 2026-07-18.
- [runtime/stack.go](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/stack.go) — репозиторий Go, tag go1.26.5, commit `c19862e5f8415b4f24b189d065ed739517c548ba`, проверено 2026-07-18.
