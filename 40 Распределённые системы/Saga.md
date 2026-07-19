---
aliases:
  - Saga pattern
  - Сага
  - Distributed saga
tags:
  - область/распределённые-системы
  - тема/распределённые-транзакции
  - механизм/компенсация
статус: проверено
---

# Saga

## TL;DR

**Saga** разбивает долгую распределённую операцию на последовательность локальных транзакций `T1 … Tn`. Каждая успешно коммитится и становится видимой независимо. До точки необратимого обязательства неудачный шаг может перевести workflow на semantic compensations `Ck … C1`; после pivot обычно нужен forward recovery или ручное завершение.

Compensation — новая бизнес-операция, а не ACID rollback: возврат денег не стирает факт списания, отменённое письмо нельзя «разослать назад», а освобождённый inventory могли увидеть другие процессы. Saga стремится к terminal forward или compensated state при eventual recovery и выполнимых шагах; без этих предпосылок она остаётся non-terminal и требует reconciliation или ручного решения. Общей isolation она не даёт. Корректность строится на явной state machine, идемпотентных шагах, durable progress, retry policy и предметных инвариантах промежуточных состояний.

## Область применимости

Оригинальная модель Saga опубликована Garcia-Molina и Salem в 1987 году для long-lived database transactions. Здесь она применяется к service workflows и сопоставляется с MicroProfile LRA 2.0.2 Final от 2026-02-16, проверено 2026-07-18. Конкретные workflow engines могут давать дополнительные гарантии, но название `saga` само по себе не определяет transport, ordering или exactly-once.

## Ментальная модель

Вместо одной невидимой транзакции система ведёт durable журнал переходов:

```text
STARTED -> PAYMENT_RESERVED -> STOCK_RESERVED -> SHIPMENT_CREATED -> DONE
                              \
                               -> COMPENSATING -> PAYMENT_RELEASED -> CANCELLED
```

Каждая стрелка — локальный commit. Между стрелками система может упасть, сообщение может прийти повторно, а пользователь — отменить заказ. Saga должна после restart определить следующий допустимый transition, а не начинать всё заново.

Полезные категории шагов:

- **compensable** — эффект можно предметно компенсировать, например release reservation;
- **pivot** — точка, после которой бизнес обязуется завершить workflow и не рассчитывает на полный откат;
- **retriable** — последующие шаги должны быть безопасно повторяемыми до успеха.

Это не обязательные термины оригинальной статьи, а практический способ проверить, что у процесса есть достижимая terminal state.

## Как устроено

### Durable state machine

У каждой saga есть стабильный `saga_id`, текущий state, версия и журнал решений. Переход выполняется условно: handler читает expected state, применяет локальный effect и записывает новый state в одной транзакции. Duplicate command с уже пройденным transition возвращает сохранённый результат.

Если команда следующему сервису публикуется отдельно от локального commit, появляется dual-write окно. Его закрывает [[40 Распределённые системы/Transactional outbox и Change Data Capture|transactional outbox]]; ответный event consumer дедуплицирует через inbox. Это даёт at-least-once обмен с effectively-once локальными переходами, а не глобальную exactly-once saga.

### Orchestration и choreography

При **orchestration** отдельный coordinator хранит workflow и отправляет команды. Плюсы — явный порядок, timeout, обзор состояния и единая recovery logic. Минусы — зависимость от coordinator implementation и риск превратить его в сервис, знающий внутренности всех доменов.

При **choreography** сервисы реагируют на события друг друга. Локальная автономность выше, но глобальный процесс размазан по subscriptions: сложнее увидеть cycle, определить owner timeout и изменить порядок шагов. Event choreography не устраняет необходимость хранить состояние saga; она лишь распределяет переходы.

### Compensation как бизнес-контракт

Для каждого `Ti` заранее задают `Ci`, её предусловия и остаточные эффекты. `reserve stock` компенсируется `release reservation`; `capture payment` — refund, который сам может не пройти и требует retry/reconciliation. Если компенсация тоже падает, saga остаётся `COMPENSATING`, а не объявляется успешно отменённой.

Compensations должны быть идемпотентны и коррелироваться с исходным effect ID. Их выполняют обычно в обратном порядке зависимостей, но параллельные независимые ветви могут иметь DAG, а не линейный stack.

### Isolation и semantic locks

Другие транзакции видят промежуточные commits. Поэтому возможны lost business opportunity, dirty semantic read и write skew на уровне процесса. Например, последняя единица товара временно зарезервирована saga, которая позже отменится; другой заказ уже получил отказ.

Защита зависит от домена: статус `PENDING`, временная reservation с expiry, version check, escrow rights или ограничение операций над объектом до terminal state. Долгий database lock обычно не решение: он возвращает блокировку, от которой saga пыталась уйти.

### Timeouts и гонка с поздним ответом

Timeout — событие workflow, а не доказательство провала удалённого шага. Coordinator может начать compensation, пока поздний `SUCCESS` уже в пути. Transition должен проверять текущий state: после `COMPENSATING` поздний успех либо игнорируется с reconciliation, либо порождает соответствующую компенсацию. Иначе процесс одновременно продолжит forward и backward paths.

## Пример или трассировка

Saga бронирования поездки должна зарезервировать отель и рейс.

1. Coordinator создаёт `saga=s17, state=STARTED` и через outbox отправляет `ReserveHotel(s17)`.
2. Hotel service создаёт reservation `h5` по уникальному `(s17, step=hotel)` и отвечает `HotelReserved`. Coordinator коммитит `HOTEL_RESERVED`.
3. Flight service отвечает `FlightUnavailable`. Coordinator условно меняет state на `COMPENSATING` и отправляет `ReleaseHotel(s17, h5)`.
4. Hotel освобождает reservation, но ответ теряется. После timeout команда повторяется; тот же compensation ID не освобождает другой booking и возвращает прежний result.
5. Coordinator получает подтверждение и ставит `CANCELLED`.

Если позднее придёт duplicate `HotelReserved`, version/state check не вернёт saga на forward path. Если `ReleaseHotel` временно недоступен, пользователь видит «отмена выполняется», а alert отслеживает возраст `COMPENSATING`. Объявить `CANCELLED` до фактической компенсации означало бы скрыть незавершённое обязательство.

## Trade-offs

[[40 Распределённые системы/Two-phase commit|2PC]] связывает участников единым финальным commit/abort decision, но без дополнительного протокола не даёт global isolation или одновременную visibility. Он требует prepare-capable resources и может блокировать их. Saga сохраняет автономность сервисов и допускает часы или дни работы, зато переносит consistency в предметную state machine и compensations.

Orchestration облегчает reasoning и operations сложного процесса. Choreography подходит короткой стабильной цепочке с ясными событиями, но при росте числа ветвей скрытая связность обычно дороже центральной схемы workflow.

Полная автоматическая compensation не всегда желательна. Для дорогого или необратимого действия лучше остановить saga в `NEEDS_REVIEW`, сохранить доказательства и дать оператору явную команду, чем выполнять догадку под видом rollback.

## Типичные ошибки

- **Неверное предположение:** compensation возвращает мир в исходное состояние. **Симптом:** refund выполнен, но пользователь уже увидел charge или получил письмо. **Причина:** committed effects наблюдаемы и могут быть необратимы. **Исправление:** описать semantic compensation и остаточные последствия.
- **Неверное предположение:** timeout означает, что шаг не выполнен. **Симптом:** compensation конфликтует с поздним success. **Причина:** потерялся ответ после commit. **Исправление:** стабильный step ID, state/version check и обработка late results.
- **Неверное предположение:** event choreography не нуждается в владельце процесса. **Симптом:** никто не замечает, что saga застряла между сервисами. **Причина:** нет durable global progress и timeout owner. **Исправление:** materialized workflow state и наблюдаемые terminal/in-progress states.
- **Неверное предположение:** один retry policy подходит всем шагам. **Симптом:** permanent business rejection ретраится часами, а transient compensation бросается рано. **Причина:** technical failure смешан с domain outcome. **Исправление:** классифицировать результаты и отдельно задать retry, compensate и manual review.

## Когда применять

Saga подходит для долгих процессов между автономными сервисами, когда промежуточные состояния приемлемы, каждый effect можно повторить, компенсировать или передать на ручное завершение. Примеры: заказ, доставка, travel booking, onboarding.

Не используйте saga как оправдание распила одной локальной транзакции между сервисами. Если данные принадлежат одному consistency boundary, локальная ACID transaction проще. До запуска saga зафиксируйте state diagram, IDs шагов, pivot, compensations, deadlines, поздние ответы, manual recovery и метрику возраста каждого non-terminal state.

## Источники

- [Sagas](https://www.cs.princeton.edu/research/techreps/598) — Hector Garcia-Molina и Kenneth Salem, Princeton University technical report CS-TR-226-87, 1987, проверено 2026-07-18.
- [Sagas](https://sigmodrecord.org/1987/12/09/sagas/) — ACM SIGMOD Record 16(3), 1987, проверено 2026-07-18.
- [MicroProfile Long Running Actions 2.0.2](https://download.eclipse.org/microprofile/microprofile-lra-2.0.2/microprofile-lra-spec-2.0.2.html) — Eclipse Foundation, MicroProfile LRA 2.0.2 Final, 2026-02-16, проверено 2026-07-18.
- [RFC 9110, § 9.2.2 Idempotent Methods](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.2.2) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
