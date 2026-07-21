---
aliases:
  - "Теоретический вопрос: Стек, heap и виртуальная память"
tags:
  - область/основы-cs
  - тема/операционные-системы
  - тема/память
  - тип/вопрос
статус: проверено
---

# Стек, heap и виртуальная память

## Вопрос

Объясните тему «Стек, heap и виртуальная память»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

Virtual memory даёт process собственное address space и отображает диапазоны virtual addresses на physical pages или backing objects. Stack и heap — способы организовать данные внутри этого пространства, а не разные типы RAM. У каждого OS thread свой stack; heap обычно общий для threads процесса и обслуживается user-space allocator, который крупными порциями получает mappings у kernel.

Virtual size, resident set и allocator heap size отвечают на разные вопросы. Зарезервировать 1 GiB addresses не значит занять 1 GiB RAM. `free()` не обязан сразу уменьшить RSS: allocator может оставить pages для повторного использования.

Полный разбор: [[10 Основы CS/Стек, heap и виртуальная память|Стек, heap и виртуальная память]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Нельзя сразу объявлять memory leak. Нужно сопоставить virtual ranges, RSS и PSS, Go heap metrics, anonymous/file-backed mappings, touched pages, page sizes, swap и cgroup charge. Большой reserved range может быть почти пустым; высокий RSS может принадлежать page cache/shared mappings; allocator может удерживать уже свободные spans.» — [[CurseHunter/6817/Бланк вопросов и заданий#Задание 5. Диагностировать `VIRT=100 GiB`, `RSS=3 GiB` у Go-сервиса|CurseHunter/6817, раздел «Задание 5. Диагностировать `VIRT=100 GiB`, `RSS=3 GiB` у Go-сервиса»]].
- «Allocator, escape analysis, goroutine stacks и GC pressure: Стеки и escape analysis, Аллокации, GC и GC pressure, Стек, heap и виртуальная память.» — [[Авито/roadmap#Concurrency и runtime|Авито/roadmap, раздел «Concurrency и runtime»]].
- «Process/thread, memory allocation, OOM и signals: Процесс, поток и goroutine, Стек, heap и виртуальная память, Исчерпание ресурсов процесса, Сигналы и graceful termination.» — [[Авито/roadmap#Сети, ОС и инфраструктура|Авито/roadmap, раздел «Сети, ОС и инфраструктура»]].

- [[CurseHunter/6817/Бланк вопросов и заданий#2. Доступ к heap сам по себе медленнее доступа к stack?|2. Доступ к heap сам по себе медленнее доступа к stack?]] — точная формулировка вопроса курса 6817 из «Урок 13. Q&A после курса».

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
