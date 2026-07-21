---
aliases:
  - "Теоретический вопрос: Saga"
tags:
  - область/распределённые-системы
  - тема/распределённые-транзакции
  - механизм/компенсация
  - тип/вопрос
статус: проверено
---

# Saga

## Вопрос

Как работает «Saga»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

**Saga** разбивает долгую распределённую операцию на последовательность локальных транзакций `T1 … Tn`. Каждая успешно коммитится и становится видимой независимо. До точки необратимого обязательства неудачный шаг может перевести workflow на semantic compensations `Ck … C1`; после pivot обычно нужен forward recovery или ручное завершение.

Compensation — новая бизнес-операция, а не ACID rollback: возврат денег не стирает факт списания, отменённое письмо нельзя «разослать назад», а освобождённый inventory могли увидеть другие процессы. Saga стремится к terminal forward или compensated state при eventual recovery и выполнимых шагах; без этих предпосылок она остаётся non-terminal и требует reconciliation или ручного решения. Общей isolation она не даёт. Корректность строится на явной state machine, идемпотентных шагах, durable progress, retry policy и предметных инвариантах промежуточных состояний.

Полный разбор: [[40 Распределённые системы/Saga|Saga]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/05 Архитектура, устойчивость и консенсус#Distributed workflow|Distributed workflow]] — исходный блок о saga и outbox/inbox.
- [[CurseHunter/5785/05 Архитектура, устойчивость и консенсус#Saga|Saga]] — вопрос о compensation, choreography и orchestration.
- «Ответ кандидата слишком быстро свёл выбор к consistency/speed и затем сам признал, что consistency зависит от replication. Более сильная рамка: SQL или key-value, CAP/PACELC, модели consistency и Saga.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#SQL, NoSQL, CAP и Saga — `00:32:20–00:36:08`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «SQL, NoSQL, CAP и Saga — `00:32:20–00:36:08`»]].
- «Transactional outbox, Two-phase commit и Saga.» — [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/Магнит — 2025-08-19 — 460к, раздел «Минимальный маршрут по vault»]].

- [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Распределённые транзакции: 2PC и Saga — `01:21:02–01:24:08`|Распределённые транзакции: 2PC и Saga — `01:21:02–01:24:08`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [Sagas](https://www.cs.princeton.edu/research/techreps/598) — Hector Garcia-Molina и Kenneth Salem, Princeton University technical report CS-TR-226-87, 1987, проверено 2026-07-18.
- [Sagas](https://sigmodrecord.org/1987/12/09/sagas/) — ACM SIGMOD Record 16(3), 1987, проверено 2026-07-18.
- [MicroProfile Long Running Actions 2.0.2](https://download.eclipse.org/microprofile/microprofile-lra-2.0.2/microprofile-lra-spec-2.0.2.html) — Eclipse Foundation, MicroProfile LRA 2.0.2 Final, 2026-02-16, проверено 2026-07-18.
- [RFC 9110, § 9.2.2 Idempotent Methods](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.2.2) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
