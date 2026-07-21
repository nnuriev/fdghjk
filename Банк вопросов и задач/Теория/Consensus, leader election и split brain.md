---
aliases:
  - "Теоретический вопрос: Consensus, leader election и split brain"
tags:
  - область/распределённые-системы
  - тема/координация
  - тип/вопрос
статус: черновик
---

# Consensus, leader election и split brain

## Вопрос

Как consensus поддерживает единую историю решений, что гарантирует leader election и как предотвращают split brain?

## Короткий ориентир

Consensus согласует одну последовательность решений между replicas при допустимой failure model. Leader election выбирает координатора на term/epoch, но выбор лидера без quorum и fencing не запрещает старому leader продолжать side effects. Split brain возникает, когда независимые части считают себя active; защита требует quorum ownership и monotonically growing token/term на границе ресурса.

Полные разборы:

- [[40 Распределённые системы/Consensus на концептуальном уровне — Raft и Paxos|Consensus: Raft и Paxos]]
- [[40 Распределённые системы/Leader election|Leader election]]
- [[40 Распределённые системы/Split brain|Split brain]]

## Варианты follow-up

- Что именно согласует consensus protocol?
- Почему election без fencing не останавливает старого leader?
- Как quorum ownership ограничивает split brain?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/05 Архитектура, устойчивость и консенсус#Consensus, leader election и lock|CourseHunter 5785, consensus]].
- [[CurseHunter/7091/01 Основы отказоустойчивости и SRE#3. Replication, quorum и split brain|CourseHunter 7091, split brain]].

## Источники

- [Paxos Made Simple](https://lamport.azurewebsites.net/pubs/paxos-simple.pdf) — Leslie Lamport, 2001, проверено 2026-07-18.
- [In Search of an Understandable Consensus Algorithm](https://raft.github.io/raft.pdf) — Diego Ongaro, John Ousterhout, расширенная версия USENIX ATC 2014, проверено 2026-07-18.
- [Impossibility of Distributed Consensus with One Faulty Process](https://www.cs.cornell.edu/courses/cs614/2004sp/papers/FLP85.pdf) — Michael J. Fischer, Nancy A. Lynch, Michael S. Paterson, Journal of the ACM 32(2), 1985, проверено 2026-07-18.
- [Unreliable Failure Detectors for Reliable Distributed Systems](https://research.ibm.com/publications/unreliable-failure-detectors-for-reliable-distributed-systems) — Tushar D. Chandra, Sam Toueg, Journal of the ACM 43(2), 1996, проверено 2026-07-18.
- [The Chubby Lock Service for Loosely-Coupled Distributed Systems](https://research.google.com/archive/chubby-osdi06.pdf) — Google, OSDI 2006, проверено 2026-07-18.
- [Brewer’s Conjecture and the Feasibility of Consistent, Available, Partition-Tolerant Web Services](https://groups.csail.mit.edu/tds/papers/Gilbert/Brewer6.pdf) — Seth Gilbert, Nancy Lynch, ACM SIGACT News 33(2), 2002, проверено 2026-07-18.
- [Pacemaker Explained](https://clusterlabs.org/projects/pacemaker/doc/3.0/Pacemaker_Explained/pdf/Pacemaker_Explained.pdf) — ClusterLabs, Pacemaker 3.0.1, разделы Cluster-Wide Configuration, Nodes и Fencing, проверено 2026-07-18.
