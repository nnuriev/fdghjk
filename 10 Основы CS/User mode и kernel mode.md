---
aliases:
  - User space и kernel space
  - Режим пользователя и режим ядра
tags:
  - область/основы-cs
  - тема/операционные-системы
  - тема/безопасность
статус: проверено
---

# User mode и kernel mode

## TL;DR

User mode и kernel mode — аппаратные уровни привилегий CPU. Обычный код process исполняется с ограниченными правами: он не может менять page tables, управлять устройствами или читать kernel memory. При system call, exception или interrupt CPU входит в kernel mode по заранее настроенной точке входа. Kernel проверяет запрос, выполняет привилегированную работу и возвращает прежний user context либо запускает другой task.

Переход режима (mode switch) не равен context switch. CPU может войти в kernel и вернуться в тот же thread. И наоборот, kernel способен переключить threads, пока оба user contexts ещё не исполняются.

## Область применимости

- Модель upstream Linux 7.1; общая граница применима к MMU-based Unix systems.
- Архитектурный пример использует Linux x86-64 и инструкцию `syscall`; ARM64 и RISC-V имеют другие entry instructions и ABI.
- Вне scope: virtualization rings, KVM guest mode, firmware и детали mitigations конкретных CPU vulnerabilities.

## Ментальная модель

User process получает виртуальную машину в малом: набор virtual addresses и непривилегированные instructions. Kernel владеет настоящей машиной и выдаёт контролируемые операции через [[10 Основы CS/Системные вызовы|системные вызовы]]. Page-table permissions и current privilege level заставляют CPU отклонить запрещённый access независимо от намерений программы.

Граница относится к исполняемому коду, а не к Unix identity. Process с UID 0 и всеми capabilities всё равно выполняет свои инструкции в user mode. Его полномочия проверяются уже внутри kernel после входа. Обычный user process не «становится root-кодом ядра» из-за успешной авторизации.

Kernel mode также не означает отдельный kernel process. Когда thread вызывает `read()`, kernel обычно исполняет handler в контексте этого же task: доступны его credentials, descriptor table и memory map, а время учитывается как system CPU time. Kernel threads существуют, но это другая сущность.

## Как устроено

### Что защищает hardware

CPU различает privilege levels. На x86-64 Linux user code работает в ring 3, kernel — в ring 0. Page-table entries задают, разрешены ли user access, write и execute. Privileged instructions для управления interrupts, page tables и устройств недоступны ring 3.

Если user code нарушает правило, CPU не «пропускает один access». Он создаёт synchronous exception. Например, обращение к unmapped page вызывает page-fault exception; kernel либо устраняет причину по правилам [[10 Основы CS/Paging и page faults|paging]], либо направляет signal faulting thread. Его disposition, например default action для `SIGSEGV`, уже может завершить весь process.

### Три пути входа

System call — синхронный и намеренный запрос текущего thread. Exception тоже синхронна относительно инструкции, но сообщает об условии вроде page fault или divide error. Hardware interrupt асинхронен относительно текущего instruction stream и приходит от timer или device.

Во всех трёх случаях CPU переходит на доверенную entry point. Architecture-specific assembly сохраняет исходное состояние, формирует kernel stack frame и передаёт управление низкоуровневому C-коду. Linux entry layer в строгом порядке обновляет context tracking, RCU, tracing, lockdep и preemption state. Перед возвратом kernel обрабатывает pending signals, task work и необходимость reschedule.

Kernel не доверяет user pointers. Проверка диапазона сама по себе недостаточна: обращение к mapping может вызвать fault, а другой thread может менять данные. Поэтому Linux использует `copy_from_user()`/`copy_to_user()` и API семейства `get_user`/`put_user`, которые учитывают faults и возвращают ошибку или число нескопированных bytes. Проверку business invariant после копирования всё равно выполняет конкретный subsystem.

### Где появляется switch

Entry instruction меняет privilege level и stack context, но current task остаётся тем же. Scheduler включается лишь при отдельной причине: task блокируется, его вытесняют или на выходе обнаружен `need_resched`. Подробная последовательность разобрана в [[10 Основы CS/Планирование CPU и переключение контекста|планировании CPU и context switching]].

## Пример или трассировка

Рассмотрим raw `syscall(SYS_getpid)` на Linux x86-64:

1. User wrapper кладёт syscall number и arguments в регистры согласно x86-64 syscall ABI.
2. Инструкция `syscall` переключает CPU из ring 3 в ring 0 и передаёт управление kernel entry code. Это mode switch.
3. Entry code сохраняет user state, выполняет tracing/seccomp/audit hooks при их наличии и вызывает handler.
4. Handler читает идентификатор current task. Ожидать I/O ему не нужно.
5. Exit path проверяет signals и reschedule work, затем восстанавливает user state и возвращается в ring 3.

Обычно такой handler не создаёт причину для context switch. Независимая preemption всё же возможна, поэтому утверждать «между двумя инструкциями точно исполнялся только этот thread» нельзя.

Теперь заменим `getpid` на blocking `read` пустого pipe. Первые шаги те же, но handler ставит task в wait queue. Только после этого scheduler выбирает другой thread. Один syscall содержит mode switch и context switch, однако это два причинно разных события.

## Trade-offs

Аппаратная граница не даёт user process повредить kernel обычной записью по адресу. Цена — переходы через контролируемый ABI, проверки, копирование или pinning user memory и дополнительные security hooks. Batch operations и shared mappings уменьшают частоту crossings, но усложняют lifecycle, validation и recovery после partial progress.

Код в kernel получает минимальную latency до hardware и общую власть над системой. Ошибка там способна вызвать kernel panic, memory corruption или privilege escalation. User-space driver/service легче изолировать и обновлять, но он платит за IPC и crossings. Выбор делают по требованиям к privilege, latency и fault containment, а не ради абстрактной «скорости kernel mode».

Containers сохраняют этот trade-off: processes в разных containers обычно делят один kernel. Namespace ограничивает видимость ресурсов, capabilities — разрешённые операции, но CPU privilege boundary остаётся общей.

## Типичные ошибки

**Неверное предположение:** root process постоянно работает в kernel mode. **Симптом:** security model строят вокруг UID как аппаратного privilege ring. **Причина:** UID и capabilities проверяет kernel, а user instructions всё равно непривилегированны. **Исправление:** разделять CPU mode и authorization policy.

**Неверное предположение:** mode switch всегда переключает process. **Симптом:** syscall overhead приравнивают к смене page tables и cache working set. **Причина:** быстрый handler возвращает тот же current task. **Исправление:** считать отдельно entry/exit, blocking и scheduler switch.

**Неверное предположение:** kernel может безопасно разыменовать любой user pointer после проверки на `NULL`. **Симптом:** kernel bug, partial copy или fault в неожиданном месте. **Причина:** адрес может быть unmapped, protected или изменён конкурентно. **Исправление:** применять uaccess API и валидировать уже скопированное значение.

**Неверное предположение:** вся работа kernel выполняется «фоновым kernel thread». **Симптом:** неверная атрибуция latency и CPU time. **Причина:** syscall handler обычно работает в контексте вызвавшего task. **Исправление:** различать process context, interrupt context и настоящий kernel thread.

## Когда применять

- Используйте эту границу, чтобы объяснять, почему application не читает disk или network device обычным load.
- В performance trace отделяйте user time, system time, scheduler wait и I/O wait.
- В security review проверяйте и entry authorization, и безопасную передачу данных через boundary.
- При сравнении платформ фиксируйте архитектуру: entry instruction и register ABI различаются.

## Источники

- [Entry/exit handling for exceptions, interrupts and syscalls](https://github.com/torvalds/linux/blob/v7.1/Documentation/core-api/entry.rst) — репозиторий Linux kernel, tag v7.1, файл `Documentation/core-api/entry.rst`, проверено 2026-07-18.
- [x86-64 syscall entry](https://github.com/torvalds/linux/blob/v7.1/arch/x86/entry/entry_64.S) — репозиторий Linux kernel, tag v7.1, файл `arch/x86/entry/entry_64.S`, проверено 2026-07-18.
- [Unprivileged memory access](https://github.com/torvalds/linux/blob/v7.1/Documentation/core-api/mm-api.rst) — репозиторий Linux kernel, tag v7.1, раздел User Space Memory Access, проверено 2026-07-18.
- [syscall(2)](https://man7.org/linux/man-pages/man2/syscall.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [capabilities(7)](https://man7.org/linux/man-pages/man7/capabilities.7.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [getrusage(2)](https://man7.org/linux/man-pages/man2/getrusage.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
