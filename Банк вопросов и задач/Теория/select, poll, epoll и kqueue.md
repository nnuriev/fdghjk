---
aliases:
  - "Теоретический вопрос: select, poll, epoll и kqueue"
tags:
  - область/основы-cs
  - тема/операционные-системы
  - механизм/мультиплексирование-ввода-вывода
  - тип/вопрос
статус: проверено
---

# select, poll, epoll и kqueue

## Вопрос

Объясните тему «select, poll, epoll и kqueue»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

`select`, `poll`, `epoll` и `kqueue` помогают одному thread ждать изменения состояния многих источников. Они сообщают readiness, то есть что соответствующая операция, вероятно, сделает progress без блокировки. Они не читают данные за приложение, не резервируют buffer и не превращают I/O в completion model.

`select` и `poll` получают полный набор интересов при каждом ожидании. `select` кодирует его bitsets и ограничен `FD_SETSIZE` в libc API; `poll` использует массив `pollfd` без этого фиксированного предела, но ядро и приложение всё равно проходят массив на каждом вызове. Linux `epoll` хранит interest list и ready list в ядре: регистрации меняют через `epoll_ctl()`, а `epoll_wait()` возвращает batch готовых entries. BSD `kqueue` похож постоянной kernel-side регистрацией, но строит более общую модель filters и умеет ждать I/O, timers, signals, process и vnode events через один `kevent()`.

Level-triggered (LT) readiness повторяет notification, пока условие остаётся истинным. Edge-triggered (ET) сообщает переход; обработчик обязан вычерпать non-blocking source до `EAGAIN`. ET уменьшает повторные notifications, но одна пропущенная ветка state machine может навсегда остановить connection.

Полный разбор: [[10 Основы CS/select, poll, epoll и kqueue|select, poll, epoll и kqueue]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «Netpoll и большое число соединений: Netpoller, select, poll, epoll и kqueue, Блокирующий и неблокирующий ввод-вывод.» — [[Авито/roadmap#Concurrency и runtime|Авито/roadmap, раздел «Concurrency и runtime»]].

## Источники

- [select(2)](https://man7.org/linux/man-pages/man2/select.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [poll(2)](https://man7.org/linux/man-pages/man2/poll.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [epoll(7)](https://man7.org/linux/man-pages/man7/epoll.7.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [epoll_ctl(2)](https://man7.org/linux/man-pages/man2/epoll_ctl.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [epoll_wait(2)](https://man7.org/linux/man-pages/man2/epoll_wait.2.html) — Linux man-pages 6.18, проверено 2026-07-18.
- [kqueue(2)](https://man.freebsd.org/cgi/man.cgi?query=kqueue&sektion=2&manpath=FreeBSD+14.3-RELEASE) — FreeBSD Project, 14.3-RELEASE, проверено 2026-07-18.
- [The Open Group Base Specifications Issue 8: select](https://pubs.opengroup.org/onlinepubs/9799919799/functions/select.html) — IEEE и The Open Group, POSIX.1-2024, проверено 2026-07-18.
- [The Open Group Base Specifications Issue 8: poll](https://pubs.opengroup.org/onlinepubs/9799919799/functions/poll.html) — IEEE и The Open Group, POSIX.1-2024, проверено 2026-07-18.
