---
aliases:
  - Process vs thread vs goroutine
  - Процесс, поток и горутина
tags:
  - область/основы-cs
  - тема/операционные-системы
  - тема/конкурентность
статус: проверено
---

# Процесс, поток и goroutine

## TL;DR

Процесс (process) задаёт границу владения ресурсами и изоляции: адресное пространство, таблицу файловых дескрипторов, полномочия и другие атрибуты. Поток (thread) — исполняемый и планируемый контекст внутри процесса; у него свои регистры, stack, thread ID и состояние scheduler, но общие с соседними потоками память и большинство ресурсов процесса. Goroutine — задача Go runtime. Она живёт внутри одного процесса, имеет растущий stack и исполняется на меняющихся OS threads через scheduler Go.

Практическое правило: процесс выбирают ради изоляции, поток — когда нужен нативный исполняемый контекст ОС, goroutine — для дешёвой конкурентности внутри Go-программы. Ни одна из этих сущностей сама по себе не даёт безопасного доступа к общей памяти или правильного lifecycle.

## Область применимости

- POSIX.1-2024 и Linux user-space API из Linux man-pages 6.18.
- Реализация Linux: upstream tag v7.1; implementation-зависимые утверждения ниже привязаны к этому tag.
- Go: языковой контракт Go 1.26 и runtime toolchain Go 1.26.5.
- Вне scope: namespaces и containers, межпроцессный IPC, точные эвристики scheduler Go.

## Ментальная модель

Удобно разделить три вопроса: кто владеет ресурсами, кого планирует kernel и кого планирует language runtime.

| Сущность | Главная граница | Что обычно своё | Что разделяется |
| --- | --- | --- | --- |
| Process | Изоляция и владение ресурсами | Virtual address space, PID, credentials, набор открытых ресурсов | Явно разделённые mappings, open file descriptions, IPC |
| Thread | Исполнение внутри process | Регистры, stack, TID, signal mask, scheduling state | Address space, heap, code, file descriptor table, signal dispositions |
| Goroutine | Конкурентная задача Go runtime | Go stack, состояние G, цепочка вызовов | Весь Go heap и ресурсы process; OS thread не закреплён |

Таблица намеренно говорит «обычно». Linux строит задачи через `clone()`/`clone3()`: flags выбирают, какие kernel objects будут общими. POSIX thread на Linux создаётся с набором sharing flags, включая общие virtual memory и file descriptor table. Новый process после `fork()` получает отдельное address space с copy-on-write и копию descriptor table, но записи в ней продолжают ссылаться на те же open file descriptions.

В Linux слово process двусмысленно. Kernel планирует `task_struct`, то есть отдельные threads. Threads одного POSIX process образуют thread group: `getpid()` возвращает thread-group ID, а `gettid()` — уникальный TID конкретного thread. Поэтому фраза «scheduler запустил process» обычно означает, что он выбрал один runnable thread этого process.

## Как устроено

### Process и thread в Linux

При создании task kernel либо копирует, либо разделяет ссылки на структуры ресурсов. `CLONE_VM` даёт общее address space, `CLONE_FILES` — общую descriptor table, `CLONE_SIGHAND` — общие signal dispositions, а `CLONE_THREAD` помещает task в тот же thread group. Для `CLONE_THREAD` Linux требует совместное использование signal handlers и virtual memory. Так Linux получает threads из того же базового механизма, которым создаёт отдельные processes.

Общая память делает коммуникацию дешёвой, но убирает защитную границу. Любой thread может испортить heap всего process. Необработанный segmentation fault обычно завершает process, а не изолирует повреждение в одном worker. Отдельный process платит за IPC, отдельные page tables и управление lifecycle, зато kernel не разрешает ему обращаться к чужому address space без специального механизма.

### Goroutine в Go

Спецификация Go определяет goroutine как независимый concurrent thread of control в том же address space. Слово thread здесь описывает поток управления, а не POSIX thread.

В runtime Go 1.26.5 scheduler связывает три объекта:

- `G` хранит состояние goroutine;
- `M` представляет OS thread;
- `P` хранит ресурсы, необходимые `M` для выполнения Go-кода. Число `P` задаёт `GOMAXPROCS`.

Одна G в разные моменты исполняется на разных M. Один M последовательно исполняет много G. Когда goroutine ждёт channel, mutex или network event, runtime обычно паркует G и оставляет M/P для другой работы. При потенциально долгом syscall P может быть передан другому M. Вернувшейся G ещё нужно снова получить P.

Эта экономия не бесплатна. Каждая goroutine удерживает stack, descriptor задачи и всё достижимое из её stack. Миллион parked goroutines не требует миллиона OS threads, но вполне способен исчерпать память, file descriptors или downstream capacity. Поэтому дешёвый запуск не заменяет [[60 Go/Worker pool, fan-in, fan-out и bounded concurrency|bounded concurrency]].

`runtime.LockOSThread` создаёт исключение: goroutine остаётся на текущем OS thread, пока не вызовет `UnlockOSThread` или не завершится. Такая привязка нужна thread-local foreign API и некоторым UI loops, но мешает scheduler свободно сопоставлять G и M.

## Пример или трассировка

Пусть Go process имеет один `P`, OS thread `M0` и goroutine `G0`:

1. `G0` выполняет `go worker()`. Runtime создаёт `G1`, выделяет ей небольшой stack и кладёт в runnable queue. Kernel ничего нового пока не создаёт: появился runtime task, а не OS thread.
2. `G0` ждёт channel. Runtime переводит её в waiting и запускает `G1` на той же паре `M0/P0`. Произошёл goroutine switch, но kernel context switch не обязателен.
3. `G1` вызывает pollable network read. [[60 Go/Netpoller|Netpoller]] получает `EAGAIN`, регистрирует readiness и паркует только G. `M0/P0` снова свободны.
4. Другая G вызывает syscall, который действительно блокирует OS thread. Kernel переводит M в sleep; runtime позволяет другому M получить P0 и продолжить Go-код.
5. После wakeup заблокированный M возвращается из kernel, но G продолжит Go-код лишь после получения P.

Трасса показывает три независимых решения: runtime выбирает G, kernel выбирает M, а process остаётся общей resource boundary для обеих goroutines.

## Trade-offs

Отдельный process лучше сдерживает memory corruption, crash и несовместимые dependencies. Цена — serialization, IPC, отдельное управление deployment/lifecycle и более дорогой обмен большими mutable structures.

Threads обмениваются данными обычными loads/stores и подходят для native libraries или thread-affine API. Цена — data races, общий fault domain и stack reservation на каждый thread. Scheduler ОС видит каждый thread и может исполнять их параллельно на разных CPUs.

Goroutines дают blocking-style код при высокой concurrency и хорошо сочетаются с [[60 Go/Планировщик GMP|GMP scheduler]]. Они не дают process isolation, не ограничивают admission и не обещают привязку к OS thread. CPU-bound goroutines также конкурируют за конечное число P.

## Типичные ошибки

**Неверное предположение:** process — то же самое, что один running thread. **Симптом:** CPU usage process превышает одно ядро, а диагностика по PID не объясняет нагрузку. **Причина:** process содержит несколько отдельно планируемых threads. **Исправление:** смотреть TID и per-thread scheduling/CPU statistics.

**Неверное предположение:** goroutine — лёгкий OS thread в отношении всех ресурсов. **Симптом:** число threads небольшое, но память и descriptors заканчиваются. **Причина:** runtime экономит kernel threads, но каждая G удерживает stack и application state. **Исправление:** ограничить входную concurrency и обеспечить завершение по правилам [[60 Go/Goroutines и lifecycle|lifecycle goroutines]].

**Неверное предположение:** общая память thread или goroutine делает запись видимой автоматически. **Симптом:** race detector или редкие неконсистентные значения. **Причина:** shared address space не создаёт happens-before. **Исправление:** использовать synchronization из [[60 Go/Модель памяти Go и happens-before|модели памяти Go]].

**Неверное предположение:** PID однозначно идентифицирует планируемую сущность Linux. **Симптом:** сигналы, affinity или profiler относятся не к тому thread. **Причина:** `getpid()` возвращает TGID, а отдельный thread имеет TID. **Исправление:** уточнять, какой API принимает process ID, thread ID или thread-group ID.

## Когда применять

- Выбирайте process boundary, если важнее fault containment и security isolation.
- Используйте threads при интеграции с native scheduler, thread-local state или API с thread affinity.
- Используйте goroutines для конкурентных Go-операций, но отдельно задавайте ownership, cancellation и admission limit.
- В performance-разборе всегда уточняйте, какой switch измеряется: goroutine, OS thread или process address space.

## Источники

- [General Information, Process Scheduling](https://pubs.opengroup.org/onlinepubs/9799919799/functions/V2_chap02.html) — The Open Group Base Specifications Issue 8, POSIX.1-2024, проверено 2026-07-18.
- [pthreads(7)](https://man7.org/linux/man-pages/man7/pthreads.7.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [clone(2)](https://man7.org/linux/man-pages/man2/clone.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [gettid(2)](https://man7.org/linux/man-pages/man2/gettid.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [The Go Programming Language Specification: Go statements](https://go.dev/ref/spec#Go_statements) — The Go Project, Go 1.26, проверено 2026-07-18.
- [runtime/HACKING.md: G, M и P](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/runtime/HACKING.md) — репозиторий Go, tag go1.26.5, commit `c19862e5f8415b4f24b189d065ed739517c548ba`, проверено 2026-07-18.
- [Package runtime: LockOSThread](https://pkg.go.dev/runtime@go1.26.5#LockOSThread) — стандартная библиотека Go, tag go1.26.5, проверено 2026-07-18.
