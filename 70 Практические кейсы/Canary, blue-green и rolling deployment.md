---
aliases:
  - Canary deployment
  - Blue-green deployment
  - Blue/green deployment
  - Rolling deployment
  - Canary, blue/green и rolling deployment
tags:
  - область/reliability-performance-operations
  - тема/деплой
статус: проверено
---

# Canary, blue-green и rolling deployment

## TL;DR

Rolling, blue-green и canary решают разные части риска релиза. Rolling ограничивает скорость замены экземпляров. Blue-green заранее поднимает второе окружение и делает traffic switch. Canary выделяет малую, ограниченную по времени production-cohort и принимает решение по её сигналам относительно control и абсолютного SLO.

Эти подходы можно совмещать: развернуть candidate в blue, направить туда 1% трафика как canary, затем переключить поток и удалить green после rollback window. Ни один вариант сам по себе не решает совместимость shared schema, очередей, данных и внешних side effects.

## Ментальная модель

У deployment есть три независимые ручки:

```text
inventory: сколько old/new экземпляров живёт одновременно
exposure: какой traffic/data/tenant видит candidate
decision: по каким gate продолжить, остановить или вернуть control
```

Rolling прежде всего управляет inventory, blue-green создаёт две полные inventory, canary управляет exposure и evidence. Ошибка начинается, когда название стратегии принимают за доказательство безопасности, не задав compatibility и decision gates.

## Как устроено

### Rolling deployment

Старые экземпляры постепенно заменяются новыми. Параметры вроде `maxUnavailable` ограничивают потерю ready capacity, `maxSurge` разрешает временный избыток. Readiness должна означать способность обслуживать полезный трафик после startup и warm-up; process alive для этого недостаточно.

Плюс rolling в невысокой дополнительной стоимости. Цена: old и new живут одновременно. API, event schema, database и peer protocol обязаны работать при любом разрешённом сочетании версий. Если новый экземпляр открыл больше DB connections или холодный cache делает его дорогим, surge способен перегрузить dependency.

### Blue-green deployment

Green обслуживает пользователей, blue получает candidate. После smoke/warm-up router, load balancer или DNS переводит трафик. Старая среда остаётся готовой для быстрого обратного switch.

Compute временно почти удваивается, а state обычно общий или синхронизируемый. Traffic rollback ничего не откатывает в shared database. DNS cutover дополнительно имеет неоднородный cache; мгновенный switch в control plane не гарантирует мгновенный switch клиентов.

### Canary deployment

Candidate получает небольшую репрезентативную часть machines, requests, tenants, keys или data partitions. Control работает одновременно. Gate сравнивает:

- user outcomes: errors, latency, correctness, freshness;
- candidate с control в одном временном окне;
- обе cohort с абсолютным SLO;
- saturation и downstream load;
- объём выборки и длительность, достаточные для delayed effects.

Случайный 1% не обнаружит дефект одного крупного tenant или редкого event type. Cohort выбирают по failure hypothesis. Один canary за раз упрощает attribution; пересекающиеся изменения загрязняют сигнал.

### Общие инварианты безопасного rollout

Артефакт immutable и воспроизводим. Версия видна в metrics/logs/traces. У каждого шага есть maximum exposure, observation window, continue/abort gate и owner. Pipeline умеет pause до следующей ступени и автоматически останавливает расширение при нарушении gate.

Для stateful change действует [[50 Проектирование систем/Миграция и rollout без остановки|expand-observe-migrate-switch-contract]]. Старый reader должен понимать состояния, которые уже пишет новый writer, до конца rollback window. Feature flag отделяет включение поведения от доставки binary, но сам требует versioned config, audit и kill switch.

## Пример или трассировка

Сервис работает на 20 replicas и принимает 2 000 RPS. Candidate имеет дефект: 15% запросов нового path возвращают `500`.

**Немедленный blue-green switch** на 100% даст около `300 errors/s`. Router можно быстро вернуть на green, но все пользователи попадут под дефект до detection.

**Rolling** с `maxSurge=2`, `maxUnavailable=1` сначала поднимет два новых экземпляра. При равномерном routing candidate получит примерно 10% потока, а общая error rate станет около `1,5%`. Если pipeline следит лишь за `Ready`, он продолжит замену и увеличит ущерб.

**Canary 5% на пять минут** получает:

```text
2 000 RPS * 0,05 * 300 s = 30 000 запросов
30 000 * 0,15 = 4 500 ожидаемых ошибок candidate
```

Control остаётся около baseline, candidate явно нарушает error gate, rollout останавливается на 5% exposure. Наблюдаемый результат: canary снизил blast radius, но только потому, что cohort одновременно сравнивалась с control и абсолютным SLO. Если ошибка зависела бы от tenant, случайная request-cohort могла её пропустить.

После исправления candidate можно снова проверить в blue как canary, а затем расширять 5% -> 25% -> 50% -> 100%. Green удаляют лишь после проверки shared state и окончания rollback window.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| Kubernetes v1.36, проверено 2026-07-18 | Deployment хранит revisions через управляемые ReplicaSets и выполняет controlled rolling update | Актуальная документация сохраняет rolling update, pause/resume и rollback; default `progressDeadlineSeconds` равен 600 s, default history хранит 10 старых ReplicaSets | Это механика inventory, а не готовый canary evaluator или решение data compatibility | [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/), [Update a Deployment Without Downtime](https://kubernetes.io/docs/tasks/run-application/update-deployment-rolling/) |

## Trade-offs

| Стратегия | Сильная сторона | Основная цена | Главный скрытый риск |
| --- | --- | --- | --- |
| Rolling | Небольшой extra compute, плавная замена | Смешение версий, медленный полный rollback | Overlap incompatibility и потеря capacity во время warm-up |
| Blue-green | Быстрый traffic switch и чистая среда candidate | Двойная capacity и синхронизация environment | Shared state уже изменён; DNS/clients переключаются неатомарно |
| Canary | Малый blast radius и production evidence | Routing, cohort design, статистика и automation | Нерепрезентативная выборка или contaminated control |

Canary не обязан быть медленным. Критические crash/error signals требуют короткого окна и малой cohort; resource leak или daily batch требуют более длинного. Blue-green не обязан переключаться целиком: weighted routing превращает blue в canary. Rolling без evaluation gate остаётся постепенным распространением, а не экспериментом.

## Типичные ошибки

- **Неверное предположение:** `Ready` означает «версия безопасна». **Симптом:** rollout завершён при росте пользовательских ошибок. **Причина:** readiness проверяла startup, но не SLI. **Исправление:** отдельные rollout gates по outcome и saturation.
- **Неверное предположение:** 1% трафика всегда репрезентативен. **Симптом:** ошибка появляется только после полного rollout. **Причина:** canary не содержала нужный tenant/key/event. **Исправление:** cohort по failure hypothesis и critical journeys.
- **Неверное предположение:** blue-green гарантирует rollback. **Симптом:** old binary не читает новые rows. **Причина:** traffic plane обратим, data plane уже нет. **Исправление:** compatibility window, reverse sync либо roll-forward.
- **Неверное предположение:** `maxUnavailable=0` сохраняет capacity. **Симптом:** dependency достигает насыщения во время surge. **Причина:** новые replicas холодные или открывают дополнительные pools. **Исправление:** budget на surge, warm-up и downstream resources.
- **Неверное предположение:** relative comparison достаточен. **Симптом:** candidate и control одинаково плохи, gate проходит. **Причина:** общий incident снизил обе cohort. **Исправление:** относительное сравнение плюс абсолютный SLO.

## Когда применять

Rolling подходит для частых backward-compatible stateless releases с ограниченным extra capacity. Blue-green полезен, когда окружение можно воспроизвести целиком и важен быстрый traffic reversal. Canary нужен для изменений, риск которых проявляется только на настоящем workload, и когда есть надёжные attribution/gates.

Для critical change чаще выигрывает композиция: immutable artifact, shadow или internal cohort, canary с автоматической остановкой, ступенчатый rollout и сохранённый old path. Стратегию выбирают по failure domain, а не по названию платформенной функции.

## Источники

- [Canarying Releases](https://sre.google/workbook/canarying-releases/) — Google, The Site Reliability Workbook, глава 16, проверено 2026-07-18.
- [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) — Kubernetes, документация v1.36, controlled rolling updates и revisions, проверено 2026-07-18.
- [Update a Deployment Without Downtime](https://kubernetes.io/docs/tasks/run-application/update-deployment-rolling/) — Kubernetes, документация v1.36, progress deadline и rollback mechanics, проверено 2026-07-18.
