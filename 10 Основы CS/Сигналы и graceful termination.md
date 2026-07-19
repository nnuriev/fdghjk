---
aliases:
  - Signals
  - Graceful termination
  - Signal handling
tags:
  - область/основы-cs
  - тема/операционные-системы
  - механизм/сигналы
статус: проверено
---

# Сигналы и graceful termination

## TL;DR

Signal — асинхронное уведомление процесса или thread с маленьким фиксированным payload. Kernel отмечает signal pending, выбирает eligible thread и применяет disposition: default action, ignore или user handler. Disposition общая для процесса, signal mask принадлежит отдельному thread. Обычные signals не образуют очередь: несколько одинаковых pending occurrences могут схлопнуться в одну.

Handler прерывает код в произвольной точке. В нём безопасны лишь async-signal-safe operations; `printf`, allocation, lock и почти вся прикладная логика недопустимы. Portable схема пишет byte в self-pipe, Linux event loop может заранее заблокировать signals и читать их через `signalfd`. После этого обычный код запускает termination state machine.

Graceful termination не даётся самим `SIGTERM`. Приложение должно прекратить admission, ограниченно дождаться in-flight work, сохранить только обещанное durable state, закрыть protocol directions и выйти до внешнего deadline. `SIGKILL` и `SIGSTOP` нельзя поймать, заблокировать или проигнорировать, поэтому бесконечного cleanup быть не может.

## Область применимости

Semantics сверены по Linux tag `v7.1`, Linux man-pages 6.18 и POSIX.1-2024. Заметка описывает process signals и shutdown lifecycle. Языковые runtimes могут ставить свои handlers и превращать signals в channels/callbacks; их контракт нужно наложить на эту модель, а не заменять ею OS semantics.

Прикладной порядок остановки backend и взаимодействие с readiness/load balancer подробнее разобраны в [[20 Бэкенд/Graceful shutdown backend-сервиса|graceful shutdown backend-сервиса]]. Здесь главный вопрос: как безопасно перенести asynchronous signal в обычный control flow.

## Ментальная модель

Signal проходит четыре фазы:

```text
generation
  -> pending set / realtime queue
  -> выбор eligible thread при delivery
  -> disposition
       default | ignore | handler
```

Generation вызывают kernel exception, terminal, timer, другой process через `kill()`/`sigqueue()` или сам process. Process-directed signal может принять любой thread, который его не блокирует; thread-directed signal предназначен конкретному thread. Synchronous fault вроде `SIGSEGV` привязан к thread, выполнившему faulting instruction.

Graceful termination — отдельный автомат:

```text
RUNNING
  -- SIGTERM/SIGINT --> QUIESCING
                         stop admission
                         drain in-flight до deadline
                         flush contractual state
                         close resources
                         exit
  -- deadline / force --> FORCED EXIT
```

Signal лишь вызывает переход. Cleanup выполняет normal execution context, где доступны locks, allocation, logging и protocol operations.

## Как устроено

### Disposition, mask и pending state

Каждый signal имеет disposition уровня процесса. `sigaction()` устанавливает `SIG_DFL`, `SIG_IGN` или handler. После `fork()` child наследует dispositions; при `execve()` caught dispositions сбрасываются в default, ignored dispositions сохраняются. Signal mask наследуется новым thread по правилам `pthread_create`, поэтому порядок initial blocking важен.

У каждого thread своя mask. Blocked signal остаётся pending, пока не появится eligible delivery context или synchronous consumer. Process-directed pending state и thread-directed pending state различаются, но application обычно интересует практический эффект: если хотя бы один worker не заблокировал `SIGTERM`, kernel способен вызвать handler именно там.

Обычный signal хранится как pending bit. Если `SIGTERM` сгенерировали пять раз до delivery, handler не обязан выполниться пять раз. POSIX realtime signals, напротив, queue и доставляются в определённом порядке с `siginfo`. Signal нельзя использовать как надёжный счётчик событий без queueing contract.

`SIGKILL` и `SIGSTOP` нельзя catch/ignore/block. Default action `SIGTERM` — terminate; graceful behavior появляется только после установленной обработки. `SIGINT` обычно приходит от terminal interrupt, `SIGHUP` исторически связан с terminal hangup и часто переиспользуется для reload, но смысл reload задаёт само приложение.

### Handler и async-signal safety

Handler способен вклиниться, когда thread держит libc internal lock, обновляет allocator metadata или меняет application invariant. Повторный вызов unsafe function может deadlock или повредить state. `stdio` — классический пример: `printf()` из handler способен увидеть наполовину обновлённый buffer.

Handler оставляют минимальным:

- сохраняют и восстанавливают `errno`;
- присваивают простой flag типа `volatile sig_atomic_t`, если этого достаточно для однопоточного control flow;
- либо вызывают async-signal-safe `write()` в заранее созданный non-blocking self-pipe;
- при невозможности продолжать безопасно вызывают `_exit()`, а не `exit()` с unsafe cleanup.

Pipe может заполниться, поэтому handler не блокируется: byte служит wakeup, а полное число occurrences восстанавливают из отдельно допустимого state либо сознательно не обещают. Self-pipe закрывает race между signal и I/O wait; `pselect()`/`ppoll()` решают её атомарной mask swap.

### Synchronous consumption: `sigwait` и `signalfd`

В multithread process удобнее заблокировать набор operational signals **до** создания workers. Затем dedicated thread вызывает `sigwaitinfo()`/`sigtimedwait()` и выполняет обычную synchronization, либо Linux process создаёт `signalfd` и включает его в [[10 Основы CS/select, poll, epoll и kqueue|event loop]].

`signalfd` возвращает records `signalfd_siginfo`; `read()` потребляет pending signals. Набор нужно держать blocked обычной mask, иначе default disposition или handler перехватит delivery. FD поддерживает `SFD_NONBLOCK` и `SFD_CLOEXEC`.

Synchronous hardware faults через `signalfd` не обрабатывают: faulting thread должен получить их обычным signal path, а продолжать после `SIGSEGV` безопасно лишь в очень специальных low-level механизмах. `SIGKILL`/`SIGSTOP` также недоступны через `signalfd`.

### Signals и системные вызовы

Если handler сработал во время blocking syscall, call может вернуться с `EINTR` либо быть автоматически restarted. `SA_RESTART` меняет поведение части interfaces, но список зависит от syscall и options; `poll`/`epoll_wait`, sleeps и socket operations с timeout имеют свои правила.

Blind retry опасен. Если syscall уже передал часть bytes, return может быть short success, а не `EINTR`. Если повторить relative timeout с начала, общий operation deadline растянется при каждом signal. Цикл хранит absolute monotonic deadline, учитывает partial progress и пересчитывает remaining time.

### `SIGPIPE` и child lifecycle

Запись в pipe/socket без reader возвращает `EPIPE` и обычно генерирует `SIGPIPE`, default action которого завершает process. Network servers часто игнорируют или block `SIGPIPE`, либо используют `MSG_NOSIGNAL`, чтобы обрабатывать `EPIPE` в обычной I/O state machine.

Завершившийся child остаётся zombie до `wait()`/`waitpid()` или иной выбранной policy. `SIGCHLD` сообщает об изменении child state, но обычные signals схлопываются, поэтому один handler invocation должен вызывать non-blocking `waitpid(-1, ..., WNOHANG)` в цикле либо wake main loop, который reap всех готовых children.

### Graceful termination по шагам

Первый termination signal делает переход idempotent: повторная обработка не запускает второй параллельный cleanup.

1. Снять readiness и прекратить принимать новую работу. Если accept path может блокироваться, разбудить его отдельным штатным механизмом; listener закрывает его владелец после прекращения admission.
2. Распространить cancellation и общий absolute deadline в workers и outbound calls.
3. Дождаться уже принятой работы в пределах budget. Новые retries и background jobs не должны продлевать shutdown бесконечно.
4. Flush только те buffers, для которых contract обещает доставку или durability. `fflush` и `fsync` имеют разные границы из [[10 Основы CS/Файловая система и буферизация|модели буферизации]].
5. Выполнить protocol-aware half-close/close, завершить telemetry настолько, насколько позволяет deadline, reap children.
6. Вернуть exit status. Второй termination signal или истечение grace period переводит процесс в force policy; внешний supervisor всё равно способен отправить `SIGKILL`.

Порядок критичен. Если сначала ждать in-flight, но оставить admission открытым, счётчик не дойдёт до нуля. Если сначала закрыть shared dependencies, текущие requests начнут падать. Если handler сам захватит application mutex для cleanup, он может прервать thread, который уже держит этот mutex.

### `kill`, `killall` и `pkill`

В Linux эти команды отличаются прежде всего способом выбора адресата; signal semantics после выбора остаётся той же:

- `kill -TERM 4242` адресует известный PID. Отрицательный PID в системном вызове означает process group; конкретный синтаксис shell-команды лучше проверять через `--`, например `kill -TERM -- -1234`.
- `killall -TERM worker` выбирает процессы по имени. Это удобно для однородного локального сервиса, но опасно при совпадающих именах; реализация и поведение `killall` различаются между Unix-системами.
- `pkill -TERM -x worker` выбирает по шаблону атрибутов процесса; `-x` требует полного совпадения имени. `pkill -f` сопоставляет полную command line и потому легко задевает больше процессов, чем ожидалось.

Безопасная последовательность для ручной операции: сначала тем же selector посмотреть кандидатов через `pgrep`, проверить PID, владельца и command line, затем отправить `SIGTERM`; `SIGKILL` оставлять для процесса, который не завершился за заранее определённый grace period. Ни одна из трёх команд не превращает termination в graceful: она лишь доставляет signal, а bounded drain реализует приложение.

## Пример или трассировка

Linux event loop обрабатывает `SIGTERM` через `signalfd`:

```text
startup:
  pthread_sigmask(SIG_BLOCK, {SIGTERM, SIGINT, SIGCHLD})
  создать workers: они наследуют blocked mask
  sfd = signalfd(-1, mask, SFD_NONBLOCK | SFD_CLOEXEC)
  добавить sfd, listener и timerfd в epoll

normal:
  state = RUNNING
  listener readable -> accept4() до EAGAIN

SIGTERM:
  epoll_wait() -> sfd readable
  read(sfd)    -> SIGTERM record
  state        -> QUIESCING
  снять external readiness
  удалить/закрыть listener, запретить admission
  arm timerfd на absolute shutdown deadline

drain:
  completion events уменьшают in_flight
  in_flight == 0 -> flush contractual state -> close -> exit(0)
  timerfd ready  -> cancel/abort remaining work -> close -> exit(nonzero)
```

Signal не выполняет shutdown внутри handler и не прерывает произвольный mutex-protected section. Он становится обычным event, а deadline находится в том же loop. Если приходит второй `SIGTERM`, state machine выбирает заранее заданную force policy вместо повторного запуска шагов.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| Linux до 2.6.22 / начиная с 2.6.22 | Signals принимали handlers или `sigwait*` | Появился `signalfd()` | Linux event loop может получать blocked signals через FD | [signalfd(2)](https://man7.org/linux/man-pages/man2/signalfd.2.html) |
| Linux до 2.6.27 / начиная с 2.6.27 | Новый signalfd настраивали отдельным `fcntl()` | `SFD_NONBLOCK` и `SFD_CLOEXEC` задаются при создании | Убраны extra syscalls и close-on-exec race | [signalfd(2)](https://man7.org/linux/man-pages/man2/signalfd.2.html) |

## Trade-offs

Traditional handler portable и нужен для synchronous faults, но работает в самом ограниченном execution context. Self-pipe переводит event в normal loop и остаётся portable; нужно аккуратно обработать full pipe и coalescing.

Dedicated `sigwait` thread понятен в multithread service и разрешает обычную synchronization после return. Он занимает thread и требует early mask discipline. `signalfd` естественно объединяет signals с Linux epoll/timerfd/eventfd, но привязывает design к Linux и имеет ограничения после `fork()`.

Long graceful period повышает шанс завершить in-flight и сохранить telemetry, но дольше удерживает deploy capacity, sockets и stale work. Короткий period быстрее освобождает instance, зато чаще обрывает операции. Выбор выводят из максимального request deadline и protocol semantics, оставляя отдельный budget на финальный cleanup.

## Типичные ошибки

### Делать cleanup в handler

- **Неверное предположение:** handler — обычный callback.
- **Симптом:** редкий deadlock в allocator, logger или mutex; повреждённый state.
- **Причина:** signal прервал unsafe function или владельца того же lock.
- **Исправление:** handler только уведомляет self-pipe/flag; cleanup выполняет main loop или dedicated thread.

### Блокировать signal после создания workers

- **Неверное предположение:** mask main thread автоматически исправит уже созданные threads.
- **Симптом:** `SIGTERM` иногда получает случайный worker вместо `sigwait`/`signalfd`.
- **Причина:** mask per-thread, а process-directed signal выбирает любой eligible thread.
- **Исправление:** блокировать набор до `pthread_create`, workers наследуют mask.

### Перезапускать любой `EINTR`

- **Неверное предположение:** operation не сделала progress, timeout можно начать заново.
- **Симптом:** duplicate bytes или deadline, который никогда не истекает под signal storm.
- **Причина:** partial success и syscall-specific restart rules проигнорированы.
- **Исправление:** сначала проверить return count, затем retry по contract с absolute deadline.

### Ждать drain, не закрыв admission

- **Неверное предположение:** in-flight сам уменьшится до нуля.
- **Симптом:** process доходит до внешнего `SIGKILL`, хотя requests короткие.
- **Причина:** listener и readiness продолжают принимать новую работу.
- **Исправление:** сначала quiesce и propagation, затем bounded drain.

## Когда применять

Signals подходят для process lifecycle, terminal control, child notification и редких OS events. Они плохо подходят для богатого application messaging: standard signals схлопываются, payload ограничен, delivery асинхронна. Для graceful termination заранее определите intake signal, idempotent state transition, admission barrier, абсолютный deadline, force policy и владельца каждого cleanup шага.

## Источники

- [signal(7)](https://man7.org/linux/man-pages/man7/signal.7.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [sigaction(2)](https://man7.org/linux/man-pages/man2/sigaction.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [signal-safety(7)](https://man7.org/linux/man-pages/man7/signal-safety.7.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [pthread_sigmask(3)](https://man7.org/linux/man-pages/man3/pthread_sigmask.3.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [signalfd(2)](https://man7.org/linux/man-pages/man2/signalfd.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [waitpid(2)](https://man7.org/linux/man-pages/man2/waitpid.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [kill(1)](https://man7.org/linux/man-pages/man1/kill.1.html) — util-linux manual, web-версия, проверено 2026-07-18.
- [killall(1)](https://man7.org/linux/man-pages/man1/killall.1.html) — psmisc manual, web-версия, проверено 2026-07-18.
- [pgrep(1) и pkill(1)](https://man7.org/linux/man-pages/man1/pgrep.1.html) — procps-ng manual, web-версия, проверено 2026-07-18.
- [The Open Group Base Specifications Issue 8: sigaction](https://pubs.opengroup.org/onlinepubs/9799919799/functions/sigaction.html) — IEEE и The Open Group, POSIX.1-2024, проверено 2026-07-18.
- [The Open Group Base Specifications Issue 8: Signal Concepts](https://pubs.opengroup.org/onlinepubs/9799919799/functions/V2_chap02.html#tag_16_04) — IEEE и The Open Group, POSIX.1-2024, проверено 2026-07-18.
