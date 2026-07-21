---
aliases:
  - "Теоретический вопрос: Lock-free, RCU, ABA и actor model"
tags:
  - область/go
  - тема/конкурентность
  - тип/вопрос
статус: черновик
---

# Lock-free, RCU, ABA и actor model

## Вопрос

Чем различаются lock-free, RCU/immutable snapshots и actor ownership и где возникает ABA problem?

## Короткий ориентир

Lock-free описывает progress guarantee системы, а не отсутствие retries или starvation отдельной goroutine. RCU-подобная модель публикует immutable snapshot и откладывает reclamation, actor model сериализует доступ через ownership очереди сообщений. CAS по одному значению не замечает, что состояние успело пройти A→B→A; это и есть ABA boundary.

Полные разборы:

- [[CurseHunter/6593/05 Lock-free, акторы и транзакции|Lock-free, акторы и транзакции]]

## Варианты follow-up

- Чем lock-free progress отличается от wait-free?
- Почему CAS может пропустить переход A→B→A?
- Кто владеет mutable state в actor model?

## Варианты формулировки и происхождение

- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#Четыре уровня синхронизации linked set|Четыре уровня синхронизации linked set]] — сравнение coarse, fine-grained, optimistic и lock-free protocol.
- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#Coarse-grained|Coarse-grained]] — вариант с одним linearization lock.
- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#Fine-grained|Fine-grained]] — вариант lock-coupling с единым порядком locks.
- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#Optimistic|Optimistic]] — вариант traversal с validation и retry.
- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#Lock-free|Lock-free]] — вариант CAS-loop с logical deletion и reclamation.
- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#Progress guarantees|Progress guarantees]] — вопрос об obstruction-free, lock-free и wait-free progress.
- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#Очередь Michael–Scott|Очередь Michael–Scott]] — вопрос о dummy node, helping, linearization и reclamation.
- [[CurseHunter/6593/02 Примитивы синхронизации#Самодельные locks|Самодельные locks]] — блок интервью-упражнений со spin, ticket и hybrid locks.
- [[CurseHunter/6593/02 Примитивы синхронизации#Что нужно доказать|Что нужно доказать для самодельного lock]] — вопрос о exclusion, progress, ordering и overflow.
- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#RCU и immutable snapshot|CourseHunter 6593, RCU]].
- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#Стек Трайбера и ABA|CourseHunter 6593, ABA]].
- [[CurseHunter/6593/05 Lock-free, акторы и транзакции#Actor model|CourseHunter 6593, actor model]].

## Источники

- [Код уроков 8 и 9](https://github.com/Balun-courses/concurrency_go/tree/47dfb8919653eb9528bd6fa5b4fadc2d38a56598/lessons) — Balun-courses/concurrency_go, commit `47dfb89`, каталоги `8_lesson_sync_algorithms_and_lock_free` и `9_lesson_concurrency_patterns`, проверено 2026-07-19.
- [Package sync/atomic](https://pkg.go.dev/sync/atomic) — Go standard library, Go `1.26.5`, проверено 2026-07-19.
- [Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms](https://www.cs.rochester.edu/research/synchronization/pseudocode/queues.html) — Maged M. Michael и Michael L. Scott, 1996, проверено 2026-07-19.
