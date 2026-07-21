---
aliases:
  - "Теоретический вопрос: Linearizability"
tags:
  - область/распределённые-системы
  - тема/согласованность
  - тип/вопрос
статус: проверено
---

# Linearizability

## Вопрос

Как работает «Linearizability»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

Linearizability, или линеаризуемость, требует, чтобы каждая операция выглядела выполненной атомарно в некоторой точке между invocation и response. Завершённые операции и те pending invocations, которым completion добавляет response, складываются в legal sequential history; остальные pending invocations можно отбросить. Порядок непересекающихся операций совпадает с реальным временем: если `A` завершилась до начала `B`, переставить `B` перед `A` нельзя.

Гарантия относится к поведению объекта, а не к физической синхронности реплик. Для неё не нужны глобально синхронизированные часы, но протокол обязан не выдавать результат из состояния, которое нельзя встроить в такой порядок. Linearizability не обещает availability, durability, multi-key transaction или атомарность клиентского `read → compute → write`.

Полный разбор: [[40 Распределённые системы/Linearizability|Linearizability]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Uber — proximity search, single-winner acceptance, tracking и reconciliation. База: геопоиск, ingestion, state machine, линеаризуемое принятие заказа, multi-region.» — [[Авито/roadmap#4. System design|Авито/roadmap, раздел «4. System design»]].

## Источники

- [Linearizability: A Correctness Condition for Concurrent Objects](https://www.cs.cmu.edu/~wing/publications/HerlihyWing90.pdf) — Maurice Herlihy и Jeannette Wing, ACM TOPLAS 12(3), 1990, formal definition, locality и сравнение с sequential/strict serializability, проверено 2026-07-18.
- [How to Make a Multiprocessor Computer That Correctly Executes Multiprocess Programs](https://www.microsoft.com/en-us/research/publication/make-multiprocessor-computer-correctly-executes-multiprocess-programs/) — Leslie Lamport, IEEE Transactions on Computers, 1979, sequential consistency, проверено 2026-07-18.
- [Sharing Memory Robustly in Message-Passing Systems](https://groups.csail.mit.edu/tds/papers/Attiya/TM-423.pdf) — Hagit Attiya, Amotz Bar-Noy и Danny Dolev, technical report 1990; журнальная версия JACM 42(1), 1995, atomic register ABD, проверено 2026-07-18.
- [In Search of an Understandable Consensus Algorithm](https://raft.github.io/raft.pdf) — Diego Ongaro и John Ousterhout, расширенная версия USENIX ATC 2014, replicated log и commit rules, проверено 2026-07-18.
- [Brewer's Conjecture and the Feasibility of Consistent, Available, Partition-Tolerant Web Services](https://groups.csail.mit.edu/tds/papers/Gilbert/Brewer6.pdf) — Seth Gilbert и Nancy Lynch, ACM SIGACT News 33(2), 2002, исходная статья и formal proof для asynchronous network model, проверено 2026-07-18.
