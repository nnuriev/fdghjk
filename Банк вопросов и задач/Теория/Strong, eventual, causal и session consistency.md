---
aliases:
  - "Теоретический вопрос: Strong, eventual, causal и session consistency"
tags:
  - область/распределённые-системы
  - тема/согласованность
  - тип/вопрос
статус: проверено
---

# Strong, eventual, causal и session consistency

## Вопрос

Как работает «Strong, eventual, causal и session consistency»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

Модель согласованности (consistency model) задаёт, какие результаты чтений допустимы для истории конкурентных операций. Она не обещает, что все реплики физически одинаковы в каждый момент, и сама по себе ничего не говорит о durability, доступности или границе транзакции.

`Strong consistency` без уточнения — неоднозначный ярлык. В одних текстах так называют [[40 Распределённые системы/Linearizability|linearizability]], в других — sequential consistency, strict serializability или конкретный режим продукта. В проектировании нужно называть формальное свойство и его scope: один ключ, объект, shard или транзакция.

Eventual consistency обещает сходимость после прекращения новых записей и доставки обновлений, но почти не ограничивает промежуточные чтения. Causal consistency сохраняет причинные зависимости, оставляя конкурентные операции неупорядоченными. Session guarantees дают одному клиенту устойчивый взгляд на слабосогласованные реплики; глобальную историю других клиентов они не исправляют.

Полный разбор: [[40 Распределённые системы/Strong, eventual, causal и session consistency|Strong, eventual, causal и session consistency]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/04 Распределённое хранение данных#Client-centric consistency|Client-centric consistency]] — вопрос о read-your-writes, monotonic reads и session guarantees.
- [[CurseHunter/7091/05 Кеширование и высокая доступность#1. Stale data — часть контракта|1. Stale data — часть контракта]] — вопрос о staleness budget и read-your-writes поверх DB и cache.
- «Ответ кандидата слишком быстро свёл выбор к consistency/speed и затем сам признал, что consistency зависит от replication. Более сильная рамка: SQL или key-value, CAP/PACELC, модели consistency и Saga.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#SQL, NoSQL, CAP и Saga — `00:32:20–00:36:08`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «SQL, NoSQL, CAP и Saga — `00:32:20–00:36:08`»]].
- «Spotify — playlists, stable shuffle queue и продолжение воспроизведения между устройствами. База: модель данных, state transitions, ordering, session consistency, active-active.» — [[Авито/roadmap#4. System design|Авито/roadmap, раздел «4. System design»]].

## Источники

- [How to Make a Multiprocessor Computer That Correctly Executes Multiprocess Programs](https://www.microsoft.com/en-us/research/publication/make-multiprocessor-computer-correctly-executes-multiprocess-programs/) — Leslie Lamport, IEEE Transactions on Computers, 1979, определение sequential consistency, проверено 2026-07-18.
- [Linearizability: A Correctness Condition for Concurrent Objects](https://www.cs.cmu.edu/~wing/publications/HerlihyWing90.pdf) — Maurice Herlihy и Jeannette Wing, ACM TOPLAS 12(3), 1990, проверено 2026-07-18.
- [Session Guarantees for Weakly Consistent Replicated Data](https://doi.org/10.1109/PDIS.1994.331722) — Douglas B. Terry et al., IEEE PDIS 1994, DOI оригинальной публикации, проверено 2026-07-18.
- [Eventually Consistent](https://dl.acm.org/doi/10.1145/1466443.1466448) — Werner Vogels, ACM Queue 6(6), 2008, проверено 2026-07-18.
- [Don't Settle for Eventual: Scalable Causal Consistency for Wide-Area Storage with COPS](https://www.cs.cmu.edu/~dga/papers/cops-sosp2011.pdf) — Wyatt Lloyd et al., SOSP 2011, causal+ и dependency tracking, проверено 2026-07-18.
