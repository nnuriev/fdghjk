---
aliases:
  - "Теоретический вопрос: Ordering и causality"
tags:
  - область/распределённые-системы
  - тема/время-и-порядок
  - тип/вопрос
статус: проверено
---

# Ordering и causality

## Вопрос

Как работает «Ordering и causality»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

В распределённом выполнении естественен не один глобальный порядок, а частичный порядок причинности (causality). Событие `a` happened-before `b`, если они упорядочены внутри одного процесса, `a` отправляет сообщение, полученное в `b`, либо между ними есть цепочка таких связей. Если нет пути ни `a -> b`, ни `b -> a`, события concurrent: это означает отсутствие известной причинной связи, а не физическую одновременность.

Lamport clock гарантирует `a -> b => L(a) < L(b)`, но обратное неверно: числа могут искусственно упорядочить независимые события. Vector clock сохраняет больше информации и позволяет отличить descendant от concurrent version, однако его metadata растёт с числом участников. Total order нужен там, где операции конфликтуют и должны иметь один результат; требовать его для независимых действий — платить coordination latency и availability без пользы.

Полный разбор: [[40 Распределённые системы/Ordering и causality|Ordering и causality]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/7091/04 Очереди и асинхронная коммуникация#1. Partition — единица порядка и параллелизма|1. Partition — единица порядка и параллелизма]] — вопрос о порядке по key, числе consumers и hot partition.
- «Spotify — playlists, stable shuffle queue и продолжение воспроизведения между устройствами. База: модель данных, state transitions, ordering, session consistency, active-active.» — [[Авито/roadmap#4. System design|Авито/roadmap, раздел «4. System design»]].

## Источники

- [Time, Clocks, and the Ordering of Events in a Distributed System](https://lamport.azurewebsites.net/pubs/time-clocks.pdf) — Leslie Lamport, Communications of the ACM 21(7), 1978, проверено 2026-07-18.
- [Virtual Time and Global States of Distributed Systems](https://vs.inf.ethz.ch/publ/papers/VirtTimeGlobStates.pdf) — Friedemann Mattern, International Workshop on Parallel and Distributed Algorithms, 1988 / proceedings 1989, проверено 2026-07-18.
- [Timestamps in Message-Passing Systems That Preserve the Partial Ordering](https://fileadmin.cs.lth.se/cs/Personal/Amr_Ergawy/dist-algos-papers/4.pdf) — Colin Fidge, Australian Computer Science Communications 10(1), 1988, проверено 2026-07-18.
- [Dynamo: Amazon’s Highly Available Key-value Store](https://www.amazon.science/publications/dynamo-amazons-highly-available-key-value-store) — Amazon, SOSP 2007, проверено 2026-07-18.
