---
aliases:
  - "Теоретический вопрос: Paging и page faults"
tags:
  - область/основы-cs
  - тема/операционные-системы
  - тема/память
  - тип/вопрос
статус: проверено
---

# Paging и page faults

## Вопрос

Объясните тему «Paging и page faults»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

Paging делит virtual address space на pages и отображает их на physical page frames через page tables. Page fault — synchronous CPU exception, когда translation отсутствует или запрещает requested access. Это нормальная часть demand paging: kernel может выделить anonymous page, загрузить file-backed page или выполнить copy-on-write, после чего повторить faulting instruction.

Fault превращается в ошибку только тогда, когда kernel не может легально обслужить access. Invalid mapping обычно даёт `SIGSEGV`; некоторые ошибки file-backed mapping дают `SIGBUS`. Minor fault обслуживается без I/O, major fault требует I/O. Ни один из терминов не означает автоматически «swap» или «сломанная программа».

Полный разбор: [[10 Основы CS/Paging и page faults|Paging и page faults]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Базовые различия TLB miss, page fault и huge pages уже разобраны в уроке 2 и в заметке о paging и page faults. Урок 19 добавляет механику x86-64, page permissions, invalidation и разбор ошибок на историческом слайде.» — [[CurseHunter/6817/Бланк вопросов и заданий#Что в записи относится к курсу, а что восстановлено для интервью|CurseHunter/6817, раздел «Что в записи относится к курсу, а что восстановлено для интервью»]].

- [[CurseHunter/6817/Бланк вопросов и заданий#1. Как виртуальный адрес превращается в физический?|1. Как виртуальный адрес превращается в физический?]] — точная формулировка вопроса курса 6817 из «Урок 2. Внутреннее устройство оперативной памяти».
- [[CurseHunter/6817/Бланк вопросов и заданий#2. Зачем нужны многоуровневые таблицы страниц, если одноуровневая проще?|2. Зачем нужны многоуровневые таблицы страниц, если одноуровневая проще?]] — точная формулировка вопроса курса 6817 из «Урок 2. Внутреннее устройство оперативной памяти».
- [[CurseHunter/6817/Бланк вопросов и заданий#3. Чем TLB miss отличается от page fault?|3. Чем TLB miss отличается от page fault?]] — точная формулировка вопроса курса 6817 из «Урок 2. Внутреннее устройство оперативной памяти».
- [[CurseHunter/6817/Бланк вопросов и заданий#4. Когда huge pages ускоряют программу и какой ценой?|4. Когда huge pages ускоряют программу и какой ценой?]] — точная формулировка вопроса курса 6817 из «Урок 2. Внутреннее устройство оперативной памяти».
- [[CurseHunter/6817/Бланк вопросов и заданий#2. Почему программа с почти двухтибибайтным слайсом может завершиться успешно?|2. Почему программа с почти двухтибибайтным слайсом может завершиться успешно?]] — точная формулировка вопроса курса 6817 из «Урок 6. Механизмы управления памятью в операционной системе».
- [[CurseHunter/6817/Бланк вопросов и заданий#1. Как virtual memory обеспечивает изоляцию процессов|1. Как virtual memory обеспечивает изоляцию процессов]] — точная формулировка вопроса курса 6817 из «Урок 19. Виртуальная память».
- [[CurseHunter/6817/Бланк вопросов и заданий#2. Что такое segment и зачем x86 начинал с segmentation|2. Что такое segment и зачем x86 начинал с segmentation]] — точная формулировка вопроса курса 6817 из «Урок 19. Виртуальная память».
- [[CurseHunter/6817/Бланк вопросов и заданий#3. Flat memory model и остатки segmentation в x86-64|3. Flat memory model и остатки segmentation в x86-64]] — точная формулировка вопроса курса 6817 из «Урок 19. Виртуальная память».
- [[CurseHunter/6817/Бланк вопросов и заданий#4. Paging: virtual page, physical frame и неизменный offset|4. Paging: virtual page, physical frame и неизменный offset]] — точная формулировка вопроса курса 6817 из «Урок 19. Виртуальная память».
- [[CurseHunter/6817/Бланк вопросов и заданий#6. Как huge page сокращает page walk|6. Как huge page сокращает page walk]] — точная формулировка вопроса курса 6817 из «Урок 19. Виртуальная память».
- [[CurseHunter/6817/Бланк вопросов и заданий#7. Какие PTE flags реально проверяет hardware|7. Какие PTE flags реально проверяет hardware]] — точная формулировка вопроса курса 6817 из «Урок 19. Виртуальная память».
- [[CurseHunter/6817/Бланк вопросов и заданий#8. TLB, page-walk caches и invalidation|8. TLB, page-walk caches и invalidation]] — точная формулировка вопроса курса 6817 из «Урок 19. Виртуальная память».
- [[CurseHunter/6817/Бланк вопросов и заданий#9. У kernel тоже virtual addresses|9. У kernel тоже virtual addresses]] — точная формулировка вопроса курса 6817 из «Урок 19. Виртуальная память».

## Источники

- [Page Tables](https://github.com/torvalds/linux/blob/v7.1/Documentation/mm/page_tables.rst) — репозиторий Linux kernel, tag v7.1, файл `Documentation/mm/page_tables.rst`, проверено 2026-07-18.
- [Memory Management Concepts](https://github.com/torvalds/linux/blob/v7.1/Documentation/admin-guide/mm/concepts.rst) — репозиторий Linux kernel, tag v7.1, разделы Virtual Memory, Page Cache и Anonymous Memory, проверено 2026-07-18.
- [mm/memory.c](https://github.com/torvalds/linux/blob/v7.1/mm/memory.c) — репозиторий Linux kernel, tag v7.1, символы `handle_mm_fault`, `__handle_mm_fault` и COW fault path, проверено 2026-07-18.
- [getrusage(2)](https://man7.org/linux/man-pages/man2/getrusage.2.html) — Linux man-pages 6.18, определения `ru_minflt` и `ru_majflt`, проверено 2026-07-18.
- [mmap(2)](https://man7.org/linux/man-pages/man2/mmap.2.html) — Linux man-pages 6.18, `MAP_PRIVATE`, `MAP_POPULATE`, `SIGSEGV` и `SIGBUS`, проверено 2026-07-18.
- [madvise(2)](https://man7.org/linux/man-pages/man2/madvise.2.html) — Linux man-pages 6.18, paging advice и populate operations, проверено 2026-07-18.
- [mlock(2)](https://man7.org/linux/man-pages/man2/mlock.2.html) — Linux man-pages 6.18, memory locking и `RLIMIT_MEMLOCK`, проверено 2026-07-18.
- [mmap()](https://pubs.opengroup.org/onlinepubs/9799919799/functions/mmap.html) — The Open Group Base Specifications Issue 8, POSIX.1-2024, проверено 2026-07-18.
