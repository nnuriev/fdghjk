---
aliases:
  - "Теоретический вопрос: CAP и PACELC"
tags:
  - область/распределённые-системы
  - тема/согласованность
  - тип/вопрос
статус: проверено
---

# CAP и PACELC

## Вопрос

Как работает «CAP и PACELC»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

CAP — условный impossibility result, а не меню «выбери любые два свойства». В модели Gilbert–Lynch сервис с atomic/linearizable read-write register не может во время network partition одновременно гарантировать корректный ответ и availability каждого non-failing node. Если связь обязательна для решения, одна сторона должна ждать или отказать; если обе стороны отвечают независимо, linearizability в общем случае теряется.

Буква `C` в CAP означает atomic consistency, то есть [[40 Распределённые системы/Linearizability|linearizability]] в формальной модели, а не `C` из ACID и не расплывчатое «данные согласованы». `A` — liveness guarantee на каждый запрос, а не годовой SLA. `P` описывает отказ связи, который система обязана учитывать.

PACELC добавляет второй вопрос: `if Partition, Availability or Consistency; Else, Latency or Consistency`. Это полезная taxonomy для реплицированных хранилищ в штатном режиме, но не теорема той же силы, что proof Gilbert–Lynch, и не полная классификация продукта.

Полный разбор: [[40 Распределённые системы/CAP и PACELC|CAP и PACELC]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/04 Распределённое хранение данных#CAP без лозунга|CAP без лозунга]] — вопрос о поведении операций во время partition, а не постоянной маркировке системы.
- [[CurseHunter/7091/01 Основы отказоустойчивости и SRE#2. CAP без лозунгов|2. CAP без лозунгов]] — проверенная формулировка выбора поведения конкретной операции во время partition.
- «Ответ кандидата слишком быстро свёл выбор к consistency/speed и затем сам признал, что consistency зависит от replication. Более сильная рамка: SQL или key-value, CAP/PACELC, модели consistency и Saga.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#SQL, NoSQL, CAP и Saga — `00:32:20–00:36:08`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «SQL, NoSQL, CAP и Saga — `00:32:20–00:36:08`»]].
- «CAP и PACELC, Delivery semantics и Idempotency и deduplication.» — [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/Магнит — 2025-08-19 — 460к, раздел «Минимальный маршрут по vault»]].
- «Если бизнес добавляет самостоятельный контракт «подтверждённый checkpoint переживает region loss с RPO ≤10 секунд», запись синхронно фиксируется в paired region до acknowledgment. Тогда WAN latency входит в 200 мс budget, а при partition API не сможет подтвердить новый durable checkpoint. Выбор между двумя policy — явный trade-off по CAP/PACELC, а не следствие исходного требования о смене устройства.» — [[Авито/Решения/System Design/Spotify#Checkpoint и смена device|Авито/Решения/System Design/Spotify, раздел «Checkpoint и смена device»]].

- [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Компоненты приложения и CAP — `00:59:41–01:04:09`|Компоненты приложения и CAP — `00:59:41–01:04:09`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [Brewer's Conjecture and the Feasibility of Consistent, Available, Partition-Tolerant Web Services](https://groups.csail.mit.edu/tds/papers/Gilbert/Brewer6.pdf) — Seth Gilbert и Nancy Lynch, ACM SIGACT News 33(2), 2002, исходная статья и formal proof для asynchronous network model, проверено 2026-07-18.
- [Linearizability: A Correctness Condition for Concurrent Objects](https://www.cs.cmu.edu/~wing/publications/HerlihyWing90.pdf) — Maurice Herlihy и Jeannette Wing, ACM TOPLAS 12(3), 1990, atomic/linearizable history, проверено 2026-07-18.
- [Consistency Tradeoffs in Modern Distributed Database System Design](https://www.cs.umd.edu/~abadi/papers/abadi-pacelc.pdf) — Daniel J. Abadi, IEEE Computer 45(2), 2012, формулировка PACELC, проверено 2026-07-18.
- [Dynamo: Amazon's Highly Available Key-value Store](https://www.allthingsdistributed.com/files/amazon-dynamo-sosp2007.pdf) — Giuseppe DeCandia et al., SOSP 2007, optimistic replication и reconciliation, проверено 2026-07-18.
