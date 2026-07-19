---
aliases:
  - Incident mitigation
  - Mitigation инцидента
  - Стабилизация во время инцидента
tags:
  - область/reliability-performance-operations
  - тема/инциденты
статус: проверено
---

# Incident mitigation

## TL;DR

Во время инцидента первая цель: остановить рост пользовательского ущерба и вернуть систему в контролируемое состояние. Полное объяснение причины можно получить позже. Mitigation выбирают по ожидаемому снижению impact, времени, обратимости и риску; после каждого изменения проверяют outcome и фиксируют evidence.

Сильный response разделяет command, operational work, communication и planning. Один владелец координирует изменения, live document хранит текущее состояние, а параллельные гипотезы не превращаются в несогласованные production-действия.

## Ментальная модель

Инцидент: это незамкнутый control loop:

```text
observe impact -> choose bounded action -> change system -> verify impact
       ^                                                |
       +---------------- update state ------------------+
```

Mitigation не обязана устранять defect. Она разрывает механизм ущерба: прекращает bad rollout, уменьшает вход, изолирует failure domain, возвращает старый path, выключает optional work или восстанавливает capacity. Root-cause analysis начинается после стабилизации, хотя evidence для неё собирают сразу.

## Как устроено

### Объявить состояние и роли

Incident commander держит общую картину, приоритет и право на переходы. Operations lead управляет production-изменениями. Communication сообщает impact и cadence updates. Planning ведёт timeline, ресурсы, handoff и последующее возвращение системы к normal state.

Для небольшой команды роли можно совмещать, но ownership остаётся явным. Свободные инженеры исследуют гипотезы read-only и докладывают evidence. Production changes проходят через operations owner, иначе два полезных действия способны конфликтовать.

Live document сверху содержит: impact, affected scope, текущую severity, commander, последнюю проверенную system state, активную mitigation, recent changes, следующий checkpoint и ссылки на dashboards/queries. Он служит общей памятью и основой [[70 Практические кейсы/Root-cause analysis|последующего RCA]].

### Сначала измерить impact, затем причину

Black-box SLI отвечает, что теряет пользователь: долю failed operations, latency, freshness, data correctness. Разрезы по region, tenant, endpoint, version и dependency ограничивают scope. CPU spike без user outcome не задаёт severity; нормальный average не опровергает отказ одной cohort.

Полезны три вопроса:

1. ущерб растёт, стабилен или уменьшается;
2. какой failure domain ещё здоров;
3. какое последнее изменение или feedback loop продолжает добавлять ущерб.

### Выбрать минимальное действие с большим рычагом

Типовая лестница, не строгий порядок:

- остановить rollout/config propagation и batch;
- отключить faulty feature или вернуть route к проверенной версии;
- включить [[70 Практические кейсы/Graceful degradation|degraded mode]] и shed low-priority load;
- ограничить retries, concurrency или проблемный tenant;
- изолировать dependency/cell/region;
- добавить проверенную warm capacity;
- выполнить failover после проверки authority, replication и оставшегося headroom.

Самое быстрое действие не всегда безопасно. Failover способен перенести весь поток на отстающую replica; массовый restart одновременно убивает warm cache; добавление replicas усиливает connection-pool exhaustion. Перед шагом фиксируют expected observation, stop condition и rollback.

### Изменения сериализуются, исследования параллелятся

Если одновременно поменять routing, limits и binary, улучшение нельзя приписать конкретному шагу, а откат становится неоднозначным. Исключение: быстро распространяющийся severe impact может потребовать набора заранее отрепетированных действий. Тогда набор считается одной mitigation с известными зависимостями и проверяется целиком.

Каждая запись timeline содержит время, исполнителя, команду/изменение, причину, expected result и фактический outcome. Время лучше брать из системных событий и UTC/единой зоны; ручные воспоминания после outage неточны.

### Restore не равен resolved

После возврата SLI проверяют queue age, lag, unknown transactions, dropped work, stale caches, replica divergence и временные overrides. Затем осторожно возвращают отключённый traffic и batch. Incident закрывают после устойчивого observation window, назначения recovery work и явного handoff.

Evidence сохраняют до destructive cleanup: release manifests, logs/traces, config snapshots, profiles и timeline. Но нельзя откладывать mitigation ради идеального forensic snapshot, если пользователи продолжают терять операции.

## Пример или трассировка

После release `v47` API держит 10 000 RPS. Optional recommendation dependency начинает отвечать только через 3 s; 40% requests используют её. Worker/concurrency pool с пределом 4 000 заполняется, user error rate растёт до 32%.

Commander фиксирует impact и останавливает rollout. Operations включает существующий flag `recommendations=off`, который пропускает optional call до захвата его concurrency slot. Через три минуты:

```text
error rate: 32% -> 1,2%
in-flight recommendation calls: 4 000 -> 0
core API throughput: 6 800 -> 9 880 successful RPS
```

Сервис стабилизирован, хотя рекомендации временно отсутствуют. Затем `v47` откатывают canary-ступенями, потому что traces показывают новый трёхсекундный deadline вместо прежнего короткого budget. Backlog отсутствует, но degraded responses учитываются отдельно.

Наблюдаемый результат: выключение optional work уменьшило impact быстрее полного RCA. Если бы команда сначала массово добавила API replicas, каждый открыл бы новые connections и лишь расширил поток в зависимость.

## Trade-offs

Rollback быстрый при recent regression, но опасен после несовместимых writes. Feature disable имеет маленький blast radius, однако оставляет binary и скрытые эффекты. Load shedding сохраняет critical traffic ценой явных rejects. Failover восстанавливает serving при локальном отказе, но рискует данными и capacity второго domain.

Manual action гибко отвечает неизвестному сценарию, зато зависит от опыта и permissions. Automation быстрее и воспроизводимее для известного состояния, но ошибочный trigger размножает действие. Поэтому destructive automation имеет preconditions, ограничение scope и human authorization.

Диагностика и mitigation конкурируют за внимание. Во время активного user impact выигрывает обратимое действие, которое проверяет гипотезу и одновременно уменьшает ущерб. Глубокий профиль без плана стабилизации полезен позже.

## Типичные ошибки

- **Неверное предположение:** сначала надо доказать root cause. **Симптом:** impact растёт, пока команда спорит о графиках. **Причина:** diagnosis поставлен выше stabilization. **Исправление:** timebox гипотез и reversible mitigation по пользовательскому SLI.
- **Неверное предположение:** больше инженеров ускоряют response сами по себе. **Симптом:** конфликтующие changes и потерянный timeline. **Причина:** нет command/operations ownership. **Исправление:** роли, command post и один production writer.
- **Неверное предположение:** restart очищает проблему. **Симптом:** cold-start herd повторяет outage. **Причина:** trigger, backlog или capacity deficit остались. **Исправление:** назвать feedback loop и возвращать instances ступенями.
- **Неверное предположение:** failover безопасен после health failure. **Симптом:** standby перегружается или принимает stale writes. **Причина:** не проверены supply и authority. **Исправление:** preconditions по replication, fencing и headroom.
- **Неверное предположение:** зелёный error graph завершает incident. **Симптом:** позже обнаруживаются потерянные события. **Причина:** проверен serving path, но не state/recovery. **Исправление:** reconciliation checklist и sustained observation.

## Когда применять

Incident protocol включают при user-visible degradation, риске данных/безопасности, быстром распространении отказа или необходимости координировать несколько владельцев. Для малой локальной неисправности достаточно on-call procedure, но escalation threshold должен быть записан заранее.

Mitigation считается успешной, когда impact устойчиво ограничен, system state объясним, новые изменения контролируются и есть безопасный путь recovery. «Сервис снова отвечает» без этих условий: промежуточный checkpoint.

## Источники

- [Managing Incidents](https://sre.google/sre-book/managing-incidents/) — Google, Site Reliability Engineering, глава 14, роли, command post и live incident document, проверено 2026-07-18.
- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering, глава 22, immediate mitigation overload/cascades, проверено 2026-07-18.
