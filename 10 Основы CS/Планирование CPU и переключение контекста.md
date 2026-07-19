---
aliases:
  - CPU scheduling и context switching
  - Планирование потоков
tags:
  - область/основы-cs
  - тема/операционные-системы
  - тема/производительность
статус: проверено
---

# Планирование CPU и переключение контекста

## TL;DR

CPU scheduler выбирает следующий runnable thread для конкретного CPU. Blocked thread в выборе не участвует, сколько бы времени он ни ждал. Context switch сохраняет исполняемый контекст одного thread и восстанавливает другой; при смене address space добавляются page-table/TLB costs, а cache working set не «сохраняется» и позже восстанавливается промахами.

System call, interrupt, переход в kernel mode и context switch — разные события. Быстрый syscall может вернуться в тот же thread без switch. Blocking `read()` обычно приводит к switch, потому что текущий thread перестаёт быть runnable.

## Область применимости

- POSIX.1-2024 scheduling model и Linux man-pages 6.18.
- Реализация scheduler: upstream Linux 7.1; архитектурные детали context switch зависят от CPU.
- Основной workload: обычные threads `SCHED_OTHER`; `SCHED_FIFO`, `SCHED_RR` и `SCHED_DEADLINE` разобраны только как ближайшие альтернативы.
- Вне scope: NUMA placement, IRQ affinity, глубокая настройка real-time Linux и `sched_ext`.

## Ментальная модель

У thread есть два разных набора состояний:

- жизненное состояние: running, runnable, sleeping/blocked, stopped;
- scheduling policy и параметры: class, priority, nice, affinity, cgroup weight/quota.

Scheduler не «ускоряет» blocked work. Он распределяет доступные CPU между runnable threads с учётом policy и ограничений. Wakeup лишь возвращает thread в runnable set; немедленный запуск не гарантирован.

Для обычной нагрузки Linux 7.1 использует fair scheduling class. EEVDF (Earliest Eligible Virtual Deadline First) учитывает virtual runtime и lag: task с неотрицательным lag имеет право на CPU, а среди eligible tasks выбирается ранний virtual deadline. Nice меняет относительный вес, но на результат влияют также group scheduling, cgroups, affinity и фактически доступная CPU capacity.

Real-time policies решают другую задачу. `SCHED_FIFO` исполняет highest-priority runnable thread до блокировки, yield или preemption более высоким priority; timeslice у него нет. `SCHED_RR` добавляет quantum между threads одного priority. `SCHED_DEADLINE` задаёт runtime, deadline и period и сочетает EDF с Constant Bandwidth Server. Ошибка конфигурации здесь способна вытеснить обычные tasks, поэтому real-time policy нельзя использовать как общий способ «сделать быстрее».

## Как устроено

### Когда scheduler получает управление

Текущий thread вызывает scheduler, когда блокируется на I/O, lock или timer, явно делает `sched_yield()` либо завершает работу. Это voluntary switch. Involuntary switch возникает, когда thread вытесняет более приоритетная работа, исчерпан допустимый интервал исполнения или kernel балансирует runnable load. Wakeup на другом CPU может выставить необходимость reschedule.

Timer tick — один из источников scheduling events, но не единственный. Tickless kernel всё равно вытесняет task на wakeup, interrupt return и других safe points, если policy требует выбрать другого runnable thread.

### Что переключается

Kernel сохраняет архитектурно необходимое состояние `prev`: stack pointer, callee-saved registers и служебное scheduling state. Затем восстанавливает kernel context `next`; user registers вернутся при последующем выходе этого task в user mode. FPU/vector state, debug registers и детали address-space switch зависят от архитектуры и оптимизаций kernel.

Если оба threads разделяют один `mm_struct`, page tables менять не требуется. Между разными processes kernel переключает memory context; CPU может сохранить часть TLB entries благодаря ASID/PCID, но полагаться на полный TLB reuse нельзя. L1/L2/L3 cache не копируется в task structure. Данные прежнего working set остаются, пока их не вытеснит конкурирующая работа, поэтому реальная цена switch часто проявляется позже как cache и TLB misses.

Сама операция switch обычно дешевле потери locality, migration между CPUs и роста runnable queue. Отсюда production-правило: считать context switches полезно, но tail latency объясняют вместе с run-queue delay, migrations, cache misses и причиной блокировки.

## Пример или трассировка

Есть два threads на одном CPU: `A` читает blocking socket, `B` считает hash.

1. Kernel исполняет `A`. Вызов `read()` переводит CPU в kernel mode, но это ещё не context switch.
2. Данных нет. Kernel ставит `A` в wait queue и меняет состояние так, что task больше не runnable.
3. `schedule()` выбирает `B`, сохраняет context `A` и восстанавливает `B`. Это voluntary context switch для `A`.
4. Network interrupt и protocol stack кладут данные в socket buffer, затем wakeup возвращает `A` в runnable queue.
5. `A` не обязан запуститься сразу. Если его policy допускает preemption и scheduler выбирает `A`, kernel сохраняет `B`, восстанавливает `A`, завершает `read()` и возвращает bytes в user mode.

Если `A` и `B` принадлежат одному process, они разделяют page tables. Если это разные processes, второй switch может потребовать сменить active memory context. В обоих случаях packet interrupt, mode switch и task switch остаются отдельными событиями.

Linux отдаёт агрегаты voluntary и involuntary switches через `getrusage()` (`ru_nvcsw`, `ru_nivcsw`) и `/proc`. Эти counters показывают частоту, но не причину и не latency каждого события.

## Trade-offs

Fair scheduler распределяет CPU time по weights и стремится совместить fairness с responsiveness обычной нагрузки, но не обещает жёсткий deadline или максимальный throughput. Real-time class уменьшает scheduling uncertainty для правильно спроектированной periodic task, ценой риска starvation и необходимости admission/resource control.

CPU affinity сохраняет locality и полезна для latency-sensitive workload. Жёсткая привязка мешает load balancing: один CPU перегружен, пока соседний простаивает. Сначала измеряют migrations и run-queue delay, затем ограничивают placement.

Больше runnable threads помогает скрыть blocking latency и загрузить CPUs. Oversubscription CPU-bound работы создаёт очереди и чаще вытесняет working sets. Для Go это означает, что [[60 Go/Планировщик GMP|GMP scheduler]] не отменяет kernel scheduling: Go выбирает G для M/P, затем Linux выбирает сам OS thread M.

## Типичные ошибки

**Неверное предположение:** каждый syscall вызывает context switch. **Симптом:** стоимость API оценивают как полную смену process. **Причина:** syscall меняет privilege mode; scheduler может вернуть управление тому же thread. **Исправление:** разделять syscall entry, blocking и task switch.

**Неверное предположение:** runnable task уже исполняется. **Симптом:** после wakeup наблюдается unexplained latency. **Причина:** task ждёт CPU в run queue. **Исправление:** измерять wakeup-to-run delay и runnable pressure.

**Неверное предположение:** context switch сохраняет CPU cache как регистры. **Симптом:** недооценена цена oversubscription. **Причина:** cache state остаётся общим аппаратным ресурсом и вытесняется другими working sets. **Исправление:** проверять cache/TLB misses и migrations.

**Неверное предположение:** отрицательный nice или `SCHED_FIFO` гарантирует быстрый ответ. **Симптом:** starvation либо всё ещё большие pauses на page faults и locks. **Причина:** CPU priority не устраняет blocking, memory pressure и unbounded critical sections. **Исправление:** выбирать policy после разбора полного latency path; для real-time также lock memory и ограничивать runtime.

## Когда применять

- При CPU saturation отделяйте время исполнения от времени ожидания в run queue.
- При I/O latency ищите точку, где task перестаёт быть runnable, и событие wakeup.
- Сравнивайте context-switch counters только для одинакового workload и дополняйте trace/perf events.
- Не меняйте scheduling class, nice и affinity без гипотезы, метрики и rollback.

## Источники

- [sched(7)](https://man7.org/linux/man-pages/man7/sched.7.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [getrusage(2)](https://man7.org/linux/man-pages/man2/getrusage.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [General Information: Process Scheduling](https://pubs.opengroup.org/onlinepubs/9799919799/functions/V2_chap02.html#tag_16_08_04) — The Open Group Base Specifications Issue 8, POSIX.1-2024, проверено 2026-07-18.
- [EEVDF Scheduler](https://github.com/torvalds/linux/blob/v7.1/Documentation/scheduler/sched-eevdf.rst) — репозиторий Linux kernel, tag v7.1, файл `Documentation/scheduler/sched-eevdf.rst`, проверено 2026-07-18.
- [Deadline Task Scheduling](https://github.com/torvalds/linux/blob/v7.1/Documentation/scheduler/sched-deadline.rst) — репозиторий Linux kernel, tag v7.1, файл `Documentation/scheduler/sched-deadline.rst`, проверено 2026-07-18.
- [kernel/sched/core.c](https://github.com/torvalds/linux/blob/v7.1/kernel/sched/core.c) — репозиторий Linux kernel, tag v7.1, символы `schedule`, `context_switch` и `finish_task_switch`, проверено 2026-07-18.
