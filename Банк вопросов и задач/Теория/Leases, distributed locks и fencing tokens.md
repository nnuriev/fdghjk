---
aliases:
  - "Теоретический вопрос: Leases, distributed locks и fencing tokens"
tags:
  - область/распределённые-системы
  - тема/координация
  - механизм/ограждение
  - тип/вопрос
статус: проверено
---

# Leases, distributed locks и fencing tokens

## Вопрос

Как работает «Leases, distributed locks и fencing tokens»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

Distributed lock хранит решение о том, кому выдано право работать с ресурсом. Lease ограничивает это право сроком: после истечения authority может передать его другому владельцу, не дожидаясь пропавшего клиента. Но истёкший lease не останавливает процесс, не отменяет отправленный пакет и не стирает команду из очереди. Старый holder способен проснуться и выполнить работу одновременно с новым.

Fencing token закрывает этот разрыв. Каждая новая выдача exclusive-права получает монотонно растущее поколение. Holder передаёт token в защищаемую операцию, а сам ресурс атомарно отвергает поколение меньше уже увиденного. Lock service без такой проверки даёт координационное намерение, а не гарантированную mutual exclusion для внешнего side effect.

Lease, lock и fencing решают разные части задачи: lock сериализует выдачу права, lease освобождает его после недоступности holder, fencing лишает старую копию возможности действовать. Если ресурс не умеет проверять token, нужен иной барьер, вплоть до физического fencing узла.

Полный разбор: [[40 Распределённые системы/Leases, distributed locks и fencing tokens|Leases, distributed locks и fencing tokens]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/05 Архитектура, устойчивость и консенсус#Lease против lock|Lease против lock]] — вопрос о pause, expiry и fencing на authoritative resource.
- [[CurseHunter/5785/05 Архитектура, устойчивость и консенсус#Что спросит интервьюер?|Что спросит интервьюер?]] — follow-up о commit, failover, quorum intersection и membership.
- [[CurseHunter/7091/05 Кеширование и высокая доступность#3. Distributed lock: lease, token, fencing|3. Distributed lock: lease, token, fencing]] — вопрос о delayed old owner и проверке fencing token ресурсом.
- «Per-conversation sequence можно назначать транзакционно на shard leader. Чаты короткие и P2P, поэтому это не создаёт общего global sequencer. При failover новый owner получает fencing epoch; старый leader не может подтверждать новые writes после потери lease, что следует из fencing tokens.» — [[Авито/Решения/System Design/Messenger BE#Отправка|Авито/Решения/System Design/Messenger BE, раздел «Отправка»]].
- «`take-over` атомарно увеличивает epoch и назначает новый device. Старое устройство после network pause продолжает играть локально, но его writes отклоняются fencing check. Это применение lease с fencing, а не доверие expiry само по себе.» — [[Авито/Решения/System Design/Spotify#Checkpoint и смена device|Авито/Решения/System Design/Spotify, раздел «Checkpoint и смена device»]].

## Источники

- [Leases: An Efficient Fault-Tolerant Mechanism for Distributed File Cache Consistency](https://www.cs.cmu.edu/afs/cs.cmu.edu/academic/class/15712-s12/www/papers/gray89.pdf) — Cary G. Gray, David R. Cheriton, SOSP 1989, проверено 2026-07-18.
- [The Chubby Lock Service for Loosely-Coupled Distributed Systems](https://research.google.com/archive/chubby-osdi06.pdf) — Google, OSDI 2006, проверено 2026-07-18.
- [In Search of an Understandable Consensus Algorithm](https://raft.github.io/raft.pdf) — Diego Ongaro, John Ousterhout, расширенная версия USENIX ATC 2014, проверено 2026-07-18.
- [Pacemaker Explained](https://clusterlabs.org/projects/pacemaker/doc/3.0/Pacemaker_Explained/pdf/Pacemaker_Explained.pdf) — ClusterLabs, Pacemaker 3.0.1, раздел Fencing, проверено 2026-07-18.
