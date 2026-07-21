---
aliases:
  - "Теоретический вопрос: Сигналы и graceful termination"
tags:
  - область/основы-cs
  - тема/операционные-системы
  - механизм/сигналы
  - тип/вопрос
статус: проверено
---

# Сигналы и graceful termination

## Вопрос

Объясните тему «Сигналы и graceful termination»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

Signal — асинхронное уведомление процесса или thread с маленьким фиксированным payload. Kernel отмечает signal pending, выбирает eligible thread и применяет disposition: default action, ignore или user handler. Disposition общая для процесса, signal mask принадлежит отдельному thread. Обычные signals не образуют очередь: несколько одинаковых pending occurrences могут схлопнуться в одну.

Handler прерывает код в произвольной точке. В нём безопасны лишь async-signal-safe operations; `printf`, allocation, lock и почти вся прикладная логика недопустимы. Portable схема пишет byte в self-pipe, Linux event loop может заранее заблокировать signals и читать их через `signalfd`. После этого обычный код запускает termination state machine.

Graceful termination не даётся самим `SIGTERM`. Приложение должно прекратить admission, ограниченно дождаться in-flight work, сохранить только обещанное durable state, закрыть protocol directions и выйти до внешнего deadline. `SIGKILL` и `SIGSTOP` нельзя поймать, заблокировать или проигнорировать, поэтому бесконечного cleanup быть не может.

Полный разбор: [[10 Основы CS/Сигналы и graceful termination|Сигналы и graceful termination]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «Это полезная race-подобная ошибка, но терминологически не всегда та же data race, что между двумя language threads. Ответ должен назвать используемую memory model. На native POSIX/C boundary handler ограничивают async-signal-safe operations, либо заранее блокируют signal и синхронно принимают его через `sigwait*`/`signalfd`. Механизм подробно связан с сигналами и graceful termination.» — [[CurseHunter/6817/Бланк вопросов и заданий#4. Может ли race возникнуть в «однопоточном» приложении|CurseHunter/6817, раздел «4. Может ли race возникнуть в «однопоточном» приложении»]].
- «Вопросы про process state, signals, DNS и TLS пересекаются с процессами, signals, DNS resolution и TLS handshake. Здесь интервью не предлагает принципиально новых задач, но делает акцент на диагностике через наблюдаемые признаки.» — [[Telegram Собесы/FLANT — 2026-06-30 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/FLANT — 2026-06-30 — 400к, раздел «Сопоставление с материалами vault»]].
- «Process/thread, memory allocation, OOM и signals: Процесс, поток и goroutine, Стек, heap и виртуальная память, Исчерпание ресурсов процесса, Сигналы и graceful termination.» — [[Авито/roadmap#Сети, ОС и инфраструктура|Авито/roadmap, раздел «Сети, ОС и инфраструктура»]].

- [[CurseHunter/6817/Бланк вопросов и заданий#5. Как зарегистрировать обработку сигналов в Go?|5. Как зарегистрировать обработку сигналов в Go?]] — точная формулировка вопроса курса 6817 из «Урок 5. Прерывания и системные вызовы».

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
