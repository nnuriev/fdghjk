---
aliases:
  - Deployment rollback
  - Откат релиза
  - Roll-forward и rollback
tags:
  - область/reliability-performance-operations
  - тема/деплой
статус: проверено
---

# Rollback

## TL;DR

Rollback возвращает выбранный слой к известной версии, но не перематывает систему во времени. Binary и routing часто обратимы; уже записанные данные, отправленные события, списанные деньги и полученные клиентами ответы остаются. Поэтому план отката строят вокруг compatibility и authority, а не вокруг команды «развернуть предыдущий образ».

Безопасный релиз заранее называет rollback window, irreversible boundary, триггер, артефакт, исполнителя и проверку результата. После необратимой границы выбирают roll-forward, compensation или repair. Попытка механически вернуть старый код может увеличить ущерб.

## Ментальная модель

Изменение затрагивает несколько слоёв состояния, которые меняются с разной скоростью:

```text
traffic/config -> binary -> schema/protocol -> persisted data -> external effects
      легко вернуть          совместимость           часто только compensate
```

Rollback безопасен, если старая версия всё ещё понимает все состояния, которые могли появиться, и имеет право ими управлять. Это доказательство, а не свойство deployment tool.

## Как устроено

### Определить единицу отката

Откатывать можно artifact, feature flag, config, traffic route, schema step, data migration или business action. У них разные механизмы и permissions. Иногда самый быстрый путь к восстановлению: выключить одну feature, не меняя binary. Иногда config и binary должны вернуться атомарной парой, потому что старый код не знает новых параметров.

Релизный manifest должен связывать commit, immutable image digest, config/schema versions, feature flags и deployment time. Тег `latest` или пересобранный «тот же» artifact лишает rollback воспроизводимости.

### Найти границу обратимости

До выпуска проверяют compatibility matrix:

- читает ли old binary данные и enum values, записанные candidate;
- принимает ли old consumer события новой schema;
- не удалены ли field, index, topic или secret;
- продолжается ли reverse sync после смены write authority;
- можно ли компенсировать внешний side effect;
- не зависит ли клиент уже от нового ответа или API.

[[50 Проектирование систем/Миграция и rollout без остановки|Expand/contract migration]] сохраняет overlap: сначала добавляется новая форма, затем обе версии её переносят, и лишь после rollback window удаляется старая. Если candidate стал единственным writer и создал state, который old не умеет читать, point of no return уже пройден.

### Rollback тоже проходит rollout

Последовательность безопасного отката:

1. остановить дальнейшее exposure и заморозить несвязанные изменения;
2. подтвердить, что trigger коррелирует с релизом и откат не нарушит более сильный инвариант;
3. отключить создание несовместимого state или fence candidate writers;
4. вернуть artifact/config/route ограниченной cohort;
5. проверить startup, readiness, user SLI, saturation и data invariants;
6. расширить возврат ступенями и наблюдать recovery debt;
7. выполнить reconciliation для unknown/partial effects и зафиксировать новую baseline.

Экстренность не отменяет gates. Старый release мог давно не видеть текущий traffic, certificate или dependency API. Rollback candidate разумно сначала проверить на небольшом failure domain, если пользовательский ущерб не требует немедленного глобального switch.

### Trigger должен быть машинно наблюдаемым

Условия формулируют до релиза: `candidate error rate > 2% for 5 min`, `p99 delta > 100 ms при control в SLO`, нарушение domain checksum, рост queue age или resource saturation. «Если что-то пойдёт не так» не даёт оператору решения.

Rollback завершён не после смены revision, а после возвращения user SLI, прекращения новых плохих эффектов и обработки накопленного хвоста. Queue, retries, broken sessions и репликационный lag способны сохранять симптом после удаления причины.

## Пример или трассировка

Версия `v2` добавляет order status `RESERVED_V2`. Canary получает 10 writes/s четыре минуты и успевает записать:

```text
10 * 4 * 60 = 2 400 строк RESERVED_V2
```

Затем p99 растёт, pipeline возвращает traffic на `v1`. Однако parser `v1` считает неизвестный status фатальной ошибкой. Routing rollback прошёл, а user error rate растёт на чтении 2 400 уже записанных orders.

Безопасный expand-план выглядел бы иначе: до `v2` выпускается `v1.1`, который читает неизвестный status как `RESERVED` и сохраняет raw value; `v2` пишет новую форму только под flag; при trigger flag сначала прекращает новые `RESERVED_V2`, затем route возвращается на `v1.1`. Repair переводит 2 400 строк или подтверждает их эквивалентность.

Наблюдаемый результат: быстрый traffic reversal сработал только после того, как старая версия стала forward-compatible. Без этого правильнее было исправить reader и roll-forward, а не возвращать `v1`.

## Trade-offs

Rollback быстро убирает regression и уменьшает время диагностики под пользовательским ущербом. Roll-forward сохраняет новое state и часто безопаснее после schema/data cutover, но требует времени на исправление и новый release. Feature kill switch быстрее обоих, если проблема локализована и выключенное поведение не нарушает data contract.

Длинный rollback window повышает recoverability, но требует дольше поддерживать old path, reverse replication и двойную schema. Короткое окно удешевляет систему, зато irreversible cleanup должен происходить только после достаточного evidence.

Автоматический rollback уменьшает exposure для ясных SLI regressions. На noisy metric он создаёт oscillation или откатывает здоровую версию во время общего incident. Нужны control cohort, абсолютный SLO, hysteresis и ограничение числа автоматических переходов.

## Типичные ошибки

- **Неверное предположение:** revision rollback возвращает всё состояние. **Симптом:** old binary падает на новых rows. **Причина:** откатился compute, но не data. **Исправление:** compatibility matrix и явная irreversible boundary.
- **Неверное предположение:** предыдущий artifact известен. **Симптом:** rollback разворачивает другой build или config. **Причина:** mutable tag и несвязанные manifests. **Исправление:** immutable digest и release manifest.
- **Неверное предположение:** откат можно начать одновременно на всех слоях. **Симптом:** два writer продолжают commit с разной семантикой. **Причина:** не определены authority и fencing order. **Исправление:** state machine отката с одним владельцем записи.
- **Неверное предположение:** восстановившиеся errors означают конец. **Симптом:** backlog позже повторно перегружает сервис. **Причина:** не проверены recovery и reconciliation. **Исправление:** gates по queue age, lag, unknown outcomes и domain invariants.
- **Неверное предположение:** rollback всегда лучше hotfix. **Симптом:** старая версия возвращает закрытую vulnerability или не поддерживает новый dependency contract. **Причина:** цена возврата не сравнена с roll-forward. **Исправление:** decision table до релиза.

## Когда применять

Rollback выбирают, когда regression связан с изменением, previous artifact остаётся совместимым, а reversal дешевле исправления под нагрузкой. Roll-forward нужен после несовместимого write cutover, удаления данных, истечения external contract или когда старая версия сама небезопасна.

В Kubernetes v1.36 история Deployment хранится в ReplicaSets; по умолчанию сохраняются 10 старых revisions, а `revisionHistoryLimit: 0` отключает возможность такого rollback. Это лишь inventory capability. Data, config и external-effect plan всё равно проектируются отдельно.

## Источники

- [Update a Deployment Without Downtime](https://kubernetes.io/docs/tasks/run-application/update-deployment-rolling/) — Kubernetes, документация v1.36, revision history и `kubectl rollout undo`, проверено 2026-07-18.
- [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) — Kubernetes, документация v1.36, revisions, pause и controlled rollout, проверено 2026-07-18.
- [Canarying Releases](https://sre.google/workbook/canarying-releases/) — Google, The Site Reliability Workbook, глава 16, rollback и release gates, проверено 2026-07-18.
- [Data Processing Pipelines](https://sre.google/workbook/data-processing/) — Google, The Site Reliability Workbook, rollout и correctness stateful pipelines, проверено 2026-07-18.
