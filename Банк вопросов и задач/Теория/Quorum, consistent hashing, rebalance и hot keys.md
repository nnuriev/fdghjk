---
aliases:
  - "Теоретический вопрос: Quorum, consistent hashing, rebalance и hot keys"
tags:
  - область/данные
  - тема/распределение-данных
  - тип/вопрос
статус: черновик
---

# Quorum, consistent hashing, rebalance и hot keys

## Вопрос

Как quorum, consistent hashing и rebalance взаимодействуют с replication и почему hot key ломает равномерность?

## Короткий ориентир

Quorum задаёт, сколько replicas участвуют в read/write acknowledgement, но пересечение множеств само по себе не решает version ordering и repair. Consistent hashing ограничивает перемещение keys при изменении membership; rebalance остаётся управляемой миграцией state. Равномерное число keys не гарантирует равномерную нагрузку: один hot key способен перегрузить shard.

Полные разборы:

- [[30 Данные/Read и write quorums|Read и write quorums]]
- [[30 Данные/Consistent hashing|Consistent hashing]]
- [[30 Данные/Rebalancing данных|Rebalancing данных]]
- [[30 Данные/Hot partitions и hot keys|Hot partitions и hot keys]]

## Варианты follow-up

- Почему условие `R + W > N` не заменяет version reconciliation?
- Какие данные перемещаются при изменении membership consistent-hash ring?
- Почему равномерное распределение keys не устраняет hot key?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/04 Распределённое хранение данных#Quorum|CourseHunter 5785, quorum]].
- [[CurseHunter/5785/04 Распределённое хранение данных#Rebalance как state machine|CourseHunter 5785, rebalance]].
- [[CurseHunter/5785/04 Распределённое хранение данных#Hot key|CourseHunter 5785, hot key]].

## Источники

- [Dynamo: Amazon’s Highly Available Key-value Store](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf) — Amazon, SOSP 2007, проверено 2026-07-18.
- [Dynamo architecture](https://cassandra.apache.org/doc/5.0.8/cassandra/architecture/dynamo.html) — Apache Cassandra, документация 5.0.8, проверено 2026-07-18.
- [Read repair](https://cassandra.apache.org/doc/5.0.8/cassandra/managing/operating/read_repair.html) — Apache Cassandra, документация 5.0.8, проверено 2026-07-18.
- [Consistent Hashing and Random Trees: Distributed Caching Protocols for Relieving Hot Spots on the World Wide Web](https://doi.org/10.1145/258533.258660) — ACM, Proceedings of STOC 1997, проверено 2026-07-18.
- [Adding, replacing, moving and removing nodes](https://cassandra.apache.org/doc/5.0.8/cassandra/managing/operating/topo_changes.html) — Apache Cassandra, документация 5.0.8, проверено 2026-07-18.
- [Bigtable: A Distributed Storage System for Structured Data](https://research.google.com/archive/bigtable-osdi06.pdf) — Google, OSDI 2006, проверено 2026-07-18.
- [Spanner: Google’s Globally-Distributed Database](https://research.google.com/archive/spanner-osdi2012.pdf) — Google, OSDI 2012, проверено 2026-07-18.
- [Data Definition](https://cassandra.apache.org/doc/5.0.8/cassandra/developing/cql/ddl.html) — Apache Cassandra, документация 5.0.8, проверено 2026-07-18.
