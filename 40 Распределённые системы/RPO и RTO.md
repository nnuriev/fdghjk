---
aliases:
  - RPO и RTO
  - Recovery Point Objective и Recovery Time Objective
  - Цели восстановления данных и сервиса
tags:
  - область/распределённые-системы
  - тема/аварийное-восстановление
  - метрика/цели-восстановления
статус: проверено
---

# RPO и RTO

## TL;DR

Recovery Point Objective (RPO) задаёт допустимую точку в прошлом, до которой данные должны быть восстановлены после disruption. Если последняя пригодная точка была за пять минут до сбоя, фактическое окно потери — пять минут. RPO не равен replication lag: replica может отставать на секунду и уже содержать logical corruption, а snapshot с малым возрастом может оказаться непригодным или несогласованным с очередью.

Recovery Time Objective (RTO) задаёт максимально допустимое время от interruption до восстановления сервиса. Конец измерения — готовность оговорённого business journey с данными, зависимостями, доступами, capacity и проверенной корректностью. Старт VM, promotion базы или ответ `/healthz` отмечает промежуточный этап.

Оба показателя — business objectives, а не свойства продукта и не обещания диаграммы. Архитектура даёт recovery capability, которую измеряют на restore/game day. Если capability не укладывается в цель, меняют [[40 Распределённые системы/Disaster recovery|DR-стратегию]] либо явно пересматривают цель с владельцем процесса.

## Область применимости

Версионная область: NIST SP 800-34 Rev. 1 Final (2010), AWS Well-Architected 2022-03-31 и Google Cloud DR Planning Guide, last reviewed 2024-07-05; проверено 2026-07-18. Цели относятся к workload и его business process, а не только к базе. RPO описывает длительность потенциальной потери, но не количество и качество данных.

Для каждой цели нужно назвать failure scenario. Потеря одной zone, всего региона, ransomware и bad deploy дают разные recovery paths.

## Ментальная модель

Обе цели удобно разместить на одной временной оси:

```text
последняя чистая точка        disruption                 сервис восстановлен
09:55                        10:00                      10:40
|<---- окно потери 5 мин ---->|<---- recovery 40 мин ---->|
             RPO                           RTO
```

RPO смотрит назад от disruption: насколько далеко пришлось откатить данные. RTO смотрит вперёд: сколько занял возврат полезной функции. Это разные бюджеты, хотя один механизм влияет на оба.

Цель и результат тоже не смешивают. `RPO_target=5m` — допустимая граница. Clean point за 3 минуты до события даёт `RPO_actual=3m`. AWS называет проверенную способность Recovery Point Capability (RPC), а время — Recovery Time Capability (RTC); evidence включает timestamps, recovery point и пройденный пользовательский сценарий.

## Как устроено

### Цели выводятся из business impact

NIST начинает с BIA: связывает system resources, business processes, interdependencies и maximum tolerable downtime (MTD). Component RTO должен позволять процессу вернуться раньше MTD. AWS рекомендует учитывать деньги, доверие клиентов, операционные последствия и regulatory risk; рост ущерба может быть нелинейным, например после закрытия расчётного окна.

Владелец бизнеса задаёт допустимый ущерб, техническая команда показывает цену и достижимость. Произвольный `zero` создаёт дорогую архитектуру и всё равно не покрывает corruption; слишком мягкая цель молча принимает ущерб.

### Что измеряет RPO

NIST определяет RPO как point in time до disruption, к которой должны быть восстановлены business data. AWS выражает тот же смысл через максимальный допустимый интервал между последней recovery point и interruption.

Чтобы посчитать фактический RPO, нужны три факта:

1. когда началось событие, относительно которого считается потеря;
2. какая последняя recovery point признана чистой и восстановимой;
3. все ли связанные stores приведены к логически согласованной точке.

Database на 09:55, object storage на 09:58 и consumer offsets на 10:01 могут по отдельности укладываться в пять минут, а вместе создать ссылки на отсутствующие objects и повторную обработку. Нужны consistency group, общий transaction/log position либо явная reconciliation procedure.

[[30 Данные/Репликация данных|Репликация]] влияет на RPO для отказа инфраструктуры: synchronous commit в независимые failure domains способен приблизить потерю подтверждённых writes к нулю, async replication оставляет окно. Но lag — только один input. Backlog мог быть доставлен, но ещё не применён; replica может не пройти promotion; corruption или delete могли успеть распространиться. Для такого сценария recovery point определяется backup/PITR до плохой операции.

`RPO=0` следует формулировать строго: для перечисленных fault scenarios ни одна подтверждённая бизнес-операция не теряется. Это требует соответствующей commit boundary для всех данных операции, включая event log или blob, и не следует из слова `multi-region`.

### Что входит в RTO

AWS определяет RTO как максимальную допустимую задержку между interruption и restoration. Для end-to-end workload фактическое время раскладывается так:

```text
detection + declaration + containment/fencing
+ provisioning + data restore/replay
+ dependency and security readiness
+ traffic switch + validation + capacity ramp
```

Параллельные этапы не складываются механически, но dependency critical path задаёт нижнюю границу. Database за 8 минут бесполезна, если encryption key восстанавливается 30, а DNS и client caches ведут в старую площадку ещё 20.

Начало и конец фиксируют в objective. Для полного outage старт обычно совпадает с interruption. При corruption система может технически отвечать, но business process повреждён с первой плохой записи; если отсчёт начать лишь с alert, detection delay исчезнет из отчёта, хотя ущерб уже шёл. Конец задают наблюдаемым критерием: успешный synthetic order, доступ реального operator role, сохранённая запись, обработанное событие и допустимая latency при нужной capacity.

### Цели зависят от сценария и зависимостей

Для region outage warm standby может дать короткий RTO и малый RPO. Для bad deploy оба региона способны испортиться одновременно; recovery пойдёт через старую версию приложения и clean backup. Поэтому таблица целей содержит строки `workload × failure scenario`, а не одну пару чисел на компанию.

RTO каждой зависимости должен укладываться в оставшийся budget пути. Если identity возвращается через 60 минут, checkout не получит RTO 15 минут, даже когда его собственные pods стартуют за две. В [[40 Распределённые системы/Multi-region architecture|multi-region architecture]] отдельно проверяют глобальные DNS, control plane, secrets и third parties.

### Измерение capability

Game day фиксирует incident timestamp, clean point, границы этапов, итоговую потерю, integrity checks и готовность critical journey. Тест проводят с production-like объёмом: restore и replay меняются с размером данных и backlog.

Проверка включает failback и reconciliation. Если быстрое переключение оставляет долгий ручной ремонт, дополнительно измеряют время до полной capacity и backlog drain.

## Пример или трассировка

Для checkout установлены `RPO_target=10m` и `RTO_target=45m` при logical corruption.

1. В 14:00 ошибочная migration начинает портить записи. Async replica получает изменения с lag 30 секунд, поэтому быстро портится тоже.
2. Alert срабатывает в 14:07, writes замораживаются в 14:09. Последняя подтверждённая clean PITR point — 13:54.
3. В recovery environment разворачивается прежняя schema и application version. Database возвращается к 13:54, связанные object metadata и queue offsets сверяются с этой позицией.
4. В 14:35 проходят integrity checks; в 14:39 тестовый checkout создаёт заказ, списывает inventory и публикует событие. Тогда сервис признаётся восстановленным.

Фактическое окно потери равно 6 минутам (`13:54 → 14:00`), recovery заняло 39 минут (`14:00 → 14:39`): обе цели выполнены. Время старта compute в 14:14 не даёт `RTO_actual=14m`, потому что данные и user journey ещё не были готовы. Replication lag 30 секунд не дал RPO 30 секунд: replica содержала ту же corruption.

## Trade-offs

Меньшие RPO/RTO требуют больше cost, redundancy, reserved capacity, automation и тренировок. Но цели связаны не монотонно. Длинный log улучшает granularity recovery point, а его replay увеличивает RTO. Частые snapshots сокращают replay, но создают I/O и storage cost.

Synchronous replication снижает потерю при infrastructure failure ценой write latency и availability во время partition. Async replica ускоряет штатные writes, принимая ненулевое окно. Ни одна не отменяет backup для logical corruption.

Слишком строгая единая tier заставляет некритичные workloads оплачивать active-active. Слишком много индивидуальных целей усложняет управление. Небольшое число tiers плюс документированные исключения обычно сохраняет и экономический смысл, и проверяемость.

## Типичные ошибки

- **Неверное предположение:** RPO равен replication lag. **Симптом:** lag мал, восстановиться можно только на старый backup. **Причина:** replica повреждена или непригодна к promotion. **Исправление:** измерять последнюю clean, restorable и согласованную точку.
- **Неверное предположение:** RTO закончился при старте VM. **Симптом:** отчёт обещает recovery, пользователи не проходят checkout. **Причина:** измерен компонент. **Исправление:** end-to-end start/end criteria.
- **Неверное предположение:** target автоматически стал гарантией. **Симптом:** первая авария превышает цель в разы. **Причина:** capability не тестировалась на реальном объёме. **Исправление:** game days и measured RTC/RPC.
- **Неверное предположение:** одна пара подходит всем сценариям и dependencies. **Симптом:** region failover работает, corruption recovery отсутствует. **Причина:** fault model скрыт. **Исправление:** objectives по workload, journey и scenario.
- **Неверное предположение:** RPO описывает весь ущерб данным. **Симптом:** временной бюджет выполнен, потеряны редкие дорогостоящие операции. **Причина:** RPO не учитывает количество, качество и value данных. **Исправление:** дополнить его business constraints и reconciliation policy.

## Когда применять

RPO/RTO задают для каждого workload с ненулевым impact. В design doc записывают business owner, critical journey, failure scenario, target, точку начала/окончания отсчёта, зависимые objectives, recovery mechanism и последнее evidence capability.

Пересмотр нужен после изменения data volume, topology, dependencies, retention, deployment process или business impact. Число без даты game day быстро становится пожеланием. Цель должна подсказать оператору, какую точку выбрать, к какому моменту вернуть сценарий и чем это доказать.

## Источники

- [NIST SP 800-34 Rev. 1: Contingency Planning Guide for Federal Information Systems](https://nvlpubs.nist.gov/nistpubs/legacy/sp/nistspecialpublication800-34r1.pdf) — NIST, Rev. 1 Final, 2010, проверено 2026-07-18.
- [REL13-BP01 Define recovery objectives for downtime and data loss](https://docs.aws.amazon.com/wellarchitected/2022-03-31/framework/rel_planning_for_recovery_objective_defined_recovery.html) — Amazon Web Services, Well-Architected Framework, редакция 2022-03-31, проверено 2026-07-18.
- [REL13-BP02 Use defined recovery strategies to meet the recovery objectives](https://docs.aws.amazon.com/wellarchitected/2022-03-31/framework/rel_planning_for_recovery_disaster_recovery.html) — Amazon Web Services, Well-Architected Framework, редакция 2022-03-31, проверено 2026-07-18.
- [Disaster recovery planning guide](https://docs.cloud.google.com/architecture/dr-scenarios-planning-guide) — Google Cloud Architecture Center, last reviewed 2024-07-05, проверено 2026-07-18.
