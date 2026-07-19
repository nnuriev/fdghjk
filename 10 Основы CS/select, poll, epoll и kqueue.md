---
aliases:
  - I/O multiplexing
  - Readiness notification
  - select poll epoll kqueue
tags:
  - область/основы-cs
  - тема/операционные-системы
  - механизм/мультиплексирование-ввода-вывода
статус: проверено
---

# select, poll, epoll и kqueue

## TL;DR

`select`, `poll`, `epoll` и `kqueue` помогают одному thread ждать изменения состояния многих источников. Они сообщают readiness, то есть что соответствующая операция, вероятно, сделает progress без блокировки. Они не читают данные за приложение, не резервируют buffer и не превращают I/O в completion model.

`select` и `poll` получают полный набор интересов при каждом ожидании. `select` кодирует его bitsets и ограничен `FD_SETSIZE` в libc API; `poll` использует массив `pollfd` без этого фиксированного предела, но ядро и приложение всё равно проходят массив на каждом вызове. Linux `epoll` хранит interest list и ready list в ядре: регистрации меняют через `epoll_ctl()`, а `epoll_wait()` возвращает batch готовых entries. BSD `kqueue` похож постоянной kernel-side регистрацией, но строит более общую модель filters и умеет ждать I/O, timers, signals, process и vnode events через один `kevent()`.

Level-triggered (LT) readiness повторяет notification, пока условие остаётся истинным. Edge-triggered (ET) сообщает переход; обработчик обязан вычерпать non-blocking source до `EAGAIN`. ET уменьшает повторные notifications, но одна пропущенная ветка state machine может навсегда остановить connection.

## Область применимости

Linux-часть сверена по tag `v7.1` и Linux man-pages 6.18, portable contracts — по POSIX.1-2024. `kqueue` дан только как концептуальное сопоставление по FreeBSD 14.3-RELEASE man page; переносить flags один к одному между `epoll` и `kqueue` нельзя.

Основной объект наблюдения — [[10 Основы CS/Файловые дескрипторы|FD]], чаще [[10 Основы CS/Сокеты|socket]], pipe, `eventfd`, `timerfd` или `signalfd`. Для regular files readiness обычно немедленная и не означает, что storage I/O завершён; `epoll_ctl()` не принимает обычный файл как поддерживаемый pollable target.

## Ментальная модель

Readiness — предикат над состоянием объекта:

```text
readable:  read/recv/accept не должны ждать в момент проверки
writable: небольшая write/send либо завершение connect не должны ждать в момент проверки
hangup:    peer закрыл направление; buffered data ещё могут оставаться
error:     у объекта есть pending error, который нужно прочитать и обработать
```

Notification не выдаёт lease. Между return из wait и I/O другой thread может изменить состояние. Поэтому [[10 Основы CS/Блокирующий и неблокирующий ввод-вывод|non-blocking mode]] и обработка `EAGAIN` остаются частью correctness даже после readiness event.

У `epoll` удобно представлять две коллекции:

```text
interest list: что приложение хочет наблюдать
ready list:    ссылки на entries, где произошло/сохраняется нужное состояние
```

`epoll_ctl()` меняет первую, activity объекта наполняет вторую, `epoll_wait()` забирает готовый batch. Такая persistent registration убирает передачу полного interest set при каждом ожидании, но не отменяет стоимость регистрации, wakeups, обработки returned events и contention между workers.

## Как устроено

### `select()`

`select()` принимает три `fd_set`: read, write и exceptional conditions. Аргумент `nfds` равен максимальному FD плюс один, а ядро проверяет номера ниже этой границы. После return sets изменены: остаются только ready descriptors, поэтому перед следующим вызовом приложение строит их заново.

В glibc `fd_set` имеет фиксированный `FD_SETSIZE = 1024`. Передача FD, который не помещается, приводит к undefined behavior макросов `FD_SET`/`FD_CLR`. Увеличить process `RLIMIT_NOFILE` недостаточно. Для современного Linux service это делает `select()` плохим выбором, хотя для маленького portable набора API всё ещё прост.

Readable в `select()` включает EOF. Writable означает, что достаточно малая запись не блокируется; большая способна заблокироваться. `exceptfds` не служит общим каналом ошибок и обычно относится к exceptional protocol conditions вроде out-of-band data.

`pselect()` добавляет атомарную временную замену signal mask на время ожидания. Это закрывает lost-wakeup race вида «проверили флаг signal, signal пришёл, затем уснули». Аналог для `poll()` — `ppoll()`.

### `poll()`

`poll()` принимает массив `struct pollfd { fd, events, revents }`. `events` задаёт interest, `revents` заполняет ядро. Отрицательный FD можно временно игнорировать. `POLLERR`, `POLLHUP` и `POLLNVAL` возвращаются независимо от того, запросил ли их caller.

Фиксированного `FD_SETSIZE` нет, а события выражены одной структурой, поэтому код проще расширять. Но массив целиком передаётся ядру, entries проверяются при каждом wait, а после return приложение ищет ненулевые `revents`. При большом наборе, где ready лишь несколько FD, эта повторная работа становится заметной. Если ready почти все или set часто полностью меняется, преимущество persistent registration у `epoll` уменьшается.

`POLLHUP` не означает, что buffer пуст. Для stream нужно сначала дочитать `POLLIN` data, и только следующий `read()` с ненулевым запрошенным размером после исчерпания вернёт `0`. Обработчик, который закрывает FD сразу по `HUP`, теряет хвост сообщения.

### `epoll`

`epoll_create1(EPOLL_CLOEXEC)` создаёт отдельный FD экземпляра. `epoll_ctl(ADD/MOD/DEL)` управляет interests, `epoll_wait()`/`epoll_pwait2()` возвращает массив событий размером не больше `maxevents`.

Default mode — level-triggered. Пока socket readable, следующие waits продолжат его возвращать. `EPOLLET` включает edge-triggered delivery: после изменения обработчик повторяет `read`, `write` или `accept4`, пока не получит `EAGAIN`. Все targets держат non-blocking, иначе одна операция внутри drain loop способна усыпить весь event-loop thread.

`EPOLLONESHOT` отключает entry после одного delivered event. Worker обрабатывает состояние и rearm через `EPOLL_CTL_MOD`. Это помогает закрепить один connection за одним worker, но забытый rearm даёт тихо зависший FD. `EPOLLEXCLUSIVE` решает отдельную задачу: уменьшает thundering herd, когда несколько epoll instances ждут один listener; это не общий replacement для ownership protocol.

Event bits нужно трактовать вместе. `EPOLLERR` и `EPOLLHUP` могут прийти без явной регистрации. `EPOLLRDHUP` сообщает half-close stream peer, но buffered input всё равно дочитывают. Writable after non-blocking `connect()` требует `SO_ERROR`.

Ключ interest entry включает номер FD и open file description. Дубликат через `dup()` способен быть отдельной регистрацией, но закрытие одного номера не обязательно удалит underlying open file description из всех epoll sets, пока остаются другие references. Безопаснее явно делать `EPOLL_CTL_DEL`, затем закрывать и помечать application object закрытым. Уже возвращённый batch может содержать событие для FD, закрытого при обработке более раннего элемента.

### `kqueue` как BSD-сопоставление

`kqueue()` возвращает descriptor очереди. `kevent()` одним вызовом применяет `changelist` и получает `eventlist`. Event определяется парой `(ident, filter)`, а filter проверяет конкретный класс состояния: `EVFILT_READ`, `EVFILT_WRITE`, `EVFILT_TIMER`, `EVFILT_SIGNAL`, `EVFILT_PROC`, `EVFILT_VNODE` и другие.

Это шире Linux `epoll`, который сосредоточен на pollable FDs; Linux обычно приводит timer, signal и user notification к FD через `timerfd`, `signalfd` и `eventfd`. Обе архитектуры позволяют построить единый event loop, но на разных примитивах.

`EV_CLEAR` сбрасывает состояние после выдачи; его используют для filters, которые сообщают transitions. По интуиции он близок к edge-triggered обработке, но не равен `EPOLLET` для всех filters. `EV_ONESHOT` удаляет event после выдачи, `EV_DISPATCH` отключает до re-enable; у `epoll` ближайший механизм — `EPOLLONESHOT` с rearm. Portable abstraction должна нормализовать семантику каждого event, а не только переименовать flags.

### Scalability и fairness

Утверждение «epoll всегда O(1) и быстрее» слишком грубое. Persistent interest и ready list особенно выигрывают при большом стабильном set и малой доле ready FD. При частых `ADD/MOD/DEL`, маленьком наборе или когда почти все FD готовы, costs выглядят иначе. Lock contention, cache locality, число wakeups и размер batches способны доминировать над формой API.

ET drain loop создаёт риск starvation: один hot socket всегда содержит data и удерживает thread. Event loop задаёт per-FD budget по bytes/events/time, помещает незавершённый объект в собственную ready queue и даёт ход остальным. Readiness API сообщает возможность progress, но политику справедливости выбирает приложение.

## Пример или трассировка

Pipe read end зарегистрирован в `epoll`; writer записал 2048 bytes. Reader получил event и прочитал только 1024:

```text
                    после read(1024)      следующий epoll_wait()
LT, default         1024 bytes осталось   снова вернёт readable
ET, EPOLLET         1024 bytes осталось   может уснуть: нового edge не было
```

Корректная ET-трассировка выглядит так:

```text
epoll_wait() -> EPOLLIN
read(4096)   -> 2048
read(4096)   -> -1 EAGAIN
              теперь source вычерпан, можно снова ждать
```

Если одновременно пришёл `EPOLLIN | EPOLLRDHUP`, цикл сначала читает все bytes до `EAGAIN` или `0`, затем переводит protocol state в peer-half-closed. Закрытие сразу по `RDHUP` потеряло бы buffered payload.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| FreeBSD до 4.1 / начиная с 4.1 | Не было `kqueue`/`kevent` | Появилась persistent filter-based event queue | BSD event loop получил единый механизм I/O и non-I/O filters | [kqueue(2)](https://man.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2&manpath=FreeBSD+14.3-RELEASE) |
| Linux до 2.5.44 / начиная с 2.5.44 | Основными readiness API были `select`/`poll` | Появился `epoll` с kernel-side interest и ready lists | Большие стабильные наборы sparse-ready FD не нужно передавать целиком на каждый wait | [epoll(7)](https://man7.org/linux/man-pages/man7/epoll.7.html) |
| Linux до 2.6.27 / начиная с 2.6.27 | `epoll_create()` требовал отдельного `fcntl(FD_CLOEXEC)` | `epoll_create1(EPOLL_CLOEXEC)` ставит flag атомарно | Убрано окно утечки FD через concurrent `exec` | [epoll_create(2)](https://man7.org/linux/man-pages/man2/epoll_create.2.html) |

## Trade-offs

`select()` остаётся компактным portable API для малого числа FD, но предел 1024 и destructive bitsets делают его слабой основой server runtime. `poll()` portable, не имеет этого предела и понятнее выражает events; linear per-call traversal остаётся.

`epoll` выигрывает на Linux при большом стабильном interest set и sparse activity. За это платят отдельным lifecycle регистрации, Linux-specific code, rearm/close races и более сложным ET режимом. Начинать с LT обычно безопаснее; ET нужен после измерения wakeup overhead и с тестами на drain до `EAGAIN`.

`kqueue` естественно объединяет разные filters и служит основной BSD моделью. Cross-platform runtime часто прячет `epoll` и `kqueue` за общим scheduler API, но lowest-common-denominator abstraction теряет filter-specific данные и lifecycle. Если нужны детали, backend semantics приходится учитывать явно.

## Типичные ошибки

### Закрывать по `HUP` до чтения

- **Неверное предположение:** hangup означает пустой input buffer.
- **Симптом:** последний fragment response исчезает.
- **Причина:** EOF наблюдается после уже принятых bytes.
- **Исправление:** обработать readable data до `read()` с ненулевым запрошенным размером, вернувшего `0`; затем закрывать по protocol state.

### Читать один раз в ET режиме

- **Неверное предположение:** каждый unread chunk даст новое event.
- **Симптом:** connection зависает с bytes в kernel buffer.
- **Причина:** edge уже выдан, состояние осталось readable.
- **Исправление:** non-blocking drain до `EAGAIN`, с bounded fairness budget и собственной ready queue при yield.

### Держать `EPOLLOUT` постоянно

- **Неверное предположение:** writable event нужен всегда.
- **Симптом:** loop непрерывно просыпается на idle connections.
- **Причина:** socket обычно writable, пока send queue не заполнена.
- **Исправление:** включать write interest только при pending output или connect in progress.

### Узнавать connection только по номеру FD

- **Неверное предположение:** событие с `fd = 17` всегда относится к текущему объекту 17.
- **Симптом:** stale batch обрабатывает уже переиспользованный FD.
- **Причина:** close/reopen быстрее application event processing.
- **Исправление:** хранить stable object token/generation, централизовать `DEL + close` и помечать object closed.

## Когда применять

`select` годится для небольших portable tools, `poll` — для умеренного динамического набора и простой portability. `epoll` выбирают для Linux service с большим числом sockets; `kqueue` — для BSD/macOS backend с учётом его filters. API выбирают после ответа на три вопроса: сколько FD стабильно зарегистрировано, какая доля ready на wakeup, как event loop ограничивает работу одного hot source.

## Источники

- [select(2)](https://man7.org/linux/man-pages/man2/select.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [poll(2)](https://man7.org/linux/man-pages/man2/poll.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [epoll(7)](https://man7.org/linux/man-pages/man7/epoll.7.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [epoll_ctl(2)](https://man7.org/linux/man-pages/man2/epoll_ctl.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [epoll_wait(2)](https://man7.org/linux/man-pages/man2/epoll_wait.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [kqueue(2)](https://man.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2&manpath=FreeBSD+14.3-RELEASE) — FreeBSD Project, 14.3-RELEASE, проверено 2026-07-18.
- [The Open Group Base Specifications Issue 8: select](https://pubs.opengroup.org/onlinepubs/9799919799/functions/select.html) — IEEE и The Open Group, POSIX.1-2024, проверено 2026-07-18.
- [The Open Group Base Specifications Issue 8: poll](https://pubs.opengroup.org/onlinepubs/9799919799/functions/poll.html) — IEEE и The Open Group, POSIX.1-2024, проверено 2026-07-18.
