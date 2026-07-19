---
aliases:
  - Multi-region architecture
  - Мультирегиональная архитектура
  - Геораспределённая архитектура
tags:
  - область/распределённые-системы
  - тема/мультирегиональность
  - архитектура/размещение
статус: проверено
---

# Multi-region architecture

## TL;DR

**Multi-region architecture** размещает части системы в независимых географических failure domains ради меньшей пользовательской latency, доступности при потере региона, data locality или disaster recovery. Копия compute в двух местах ещё не делает систему мультирегионально корректной: отдельно проектируют traffic steering, write authority, replication, межрегиональные зависимости, failover/failback, control plane и наблюдаемость.

Главный trade-off задаёт состояние. Синхронный межрегиональный commit уменьшает потерю данных и упрощает единый порядок, но платит WAN latency и может остановиться при partition. Асинхронная репликация оставляет регион автономным и быстрым, зато допускает lag, потерю последних подтверждённых writes при failover или конфликт нескольких writers. Архитектура должна привязать эти последствия к RPO/RTO и бизнес-инвариантам, а не к общему ярлыку `active-active`.

## Область применимости

Заметка описывает архитектурный каркас, независимый от облака. Современные примеры сверены с документацией Azure, AWS и Google Cloud на 2026-07-18. Регион не гарантированно является одним failure domain: внутри него существуют availability zones, а некоторые control-plane или identity зависимости глобальны.

## Ментальная модель

Рассматривайте регион как автономную ячейку (**cell**) с явными входами и состоянием:

```text
users -> global routing -> Region A: compute -> local state
                       \-> Region B: compute -> local state
                                  A <-> B replication
```

Для каждой стрелки задайте поведение при обрыве. Если Region A работает, но не видит B, это не менее важно, чем полное выключение A. Если оба региона зависят от одного global secret store или control-plane API, общий компонент остаётся shared failure domain.

Операция regional evacuation не должна зависеть от успешного вызова в самом выводимом регионе. Routing configuration, credentials, deployment artifacts и recovery metadata должны быть доступны снаружи.

## Как устроено

### Traffic steering

Глобальный DNS, anycast или application load balancer направляет клиента по latency, geography или health. Health signal должен отражать способность выполнить критический user journey, а не только ответ `/healthz` процесса. Регион с живым compute, но недоступной write database, может быть непригоден для write traffic и всё ещё обслуживать безопасные reads.

DNS failover зависит от TTL и caches; соединения уже установленных clients сами не мигрируют. Anycast или proxy реагирует быстрее, но control plane и data plane самого routing сервиса становятся частью модели отказа. Client retries обязаны учитывать идемпотентность: повтор в другом регионе может встретить ещё не реплицированную первую запись.

### State placement и write authority

Для каждого класса данных выбирают режим:

- single home region: writes идут владельцу, удалённые регионы читают replicas;
- synchronous quorum across regions: commit ждёт набор failure domains;
- asynchronous primary/replica: быстро локально, failover принимает ненулевой RPO;
- multi-writer: локальные writes, но нужны causal/version metadata и conflict policy;
- region-local ephemeral state: не реплицируется, восстанавливается или теряется по контракту.

Смешивать режимы нормально. Identity и ledger могут требовать единого порядка, preferences — merge, cache — rebuild. [[30 Данные/Репликация данных|Механизм репликации]] важнее количества развёрнутых копий.

Google Spanner показывает другой вариант: данные размещаются по replica configurations, Paxos groups выбирают leaders, а TrueTime позволяет внешне согласованный порядок транзакций при оговорённой uncertainty. Это специализированный протокол, а не следствие самого факта «три региона».

### Межрегиональные зависимости

Синхронный вызов из A в B добавляет WAN latency и превращает потерю B в частичный отказ A. На критическом пути предпочитают local dependencies, асинхронную репликацию событий и bounded fallback. Если global uniqueness требует удалённой координации, эту цену называют явно и не скрывают каскадом service calls.

Очереди тоже имеют locality. Один global broker может стать точкой WAN и отказа; независимые regional brokers требуют replication, duplicate handling и правила порядка. Backlog после partition должен помещаться в локальный storage до восстановления связи.

### Control plane, deployment и configuration

Regions развёртывают независимо, чтобы плохой release не поразил все площадки одновременно. Staged rollout и разные failure times полезнее симметричной одновременной доставки. Однако schema и protocol должны оставаться совместимыми во время skew версий.

Global configuration требует versioning и последнего известного безопасного snapshot. Регион не должен прекращать data-plane работу только потому, что не видит центральный control plane, если бизнес допускает автономность.

### Failover и failback

Failover — state transition с preconditions: target догнал нужную позицию, write authority fenced, routing изменён, capacity target достаточна. Автоматический promotion без fencing старого primary создаёт split brain.

Failback сложнее обратного переключения. В исходном регионе могут остаться stale данные, старая epoch и backlog. Его сначала пересобирают или reconciliate, догоняют, возвращают как replica и лишь затем передают authority.

## Пример или трассировка

Сервис заказов работает в A и B. Каждый регион имеет local compute; база использует primary A и asynchronous replica B. Допустимый RPO — 5 минут, RTO — 30 минут.

1. A подтверждает заказ `o91`, но запись ещё не дошла до B.
2. Межрегиональная связь и A пропадают. Global health перестаёт направлять новый трафик в A.
3. Recovery controller сверяет последнюю durable replication position B. Бизнес-владелец принимает потенциальную потерю последних 70 секунд в пределах RPO и повышает B с новой epoch.
4. Clients повторяют неопределённые запросы в B с прежними idempotency keys. `o91` может отсутствовать, поэтому система не объявляет его точно несуществующим: помещает outcome в reconciliation flow.
5. A возвращается. Его старый primary fenced и не принимает writes. A пересобирают из B, затем подключают как replica.

Если заявленный RPO был `0`, эта архитектура ему не соответствовала: async replica не может обещать отсутствие потери подтверждённых writes при внезапной утрате A. Нужно синхронное размещение durable copies в независимых failure domains либо иной commit protocol.

## Trade-offs

Больше регионов уменьшают distance до users и расширяют набор переживаемых отказов, но увеличивают стоимость, deployment skew, replication traffic и число частичных состояний. Третий voting region может разрешить majority при partition, но если он расположен рядом с одним из двух, географическая корреляция остаётся.

Синхронная replication улучшает RPO и coordination, но latency нижней границей получает network round trip до необходимой удалённой replica. Асинхронная быстрее и доступнее локально, зато требует failover decision о потенциальной потере и reconciliation.

Cell-based isolation ограничивает blast radius, но требует partitioning tenants, независимых quotas и tooling для перемещения. Один глобальный cluster проще использовать, пока его общие bottlenecks и recovery не выходят за требования.

## Типичные ошибки

- **Неверное предположение:** два deployments означают переживание region outage. **Симптом:** оба региона теряют login или configuration одновременно. **Причина:** shared global dependency осталась единственной. **Исправление:** построить dependency graph и проверить regional autonomy каждого critical path.
- **Неверное предположение:** traffic manager решает failover данных. **Симптом:** B принимает writes на stale replica или теряет подтверждённый заказ. **Причина:** routing переключён раньше authority и replication checks. **Исправление:** единый runbook с data preconditions, fencing и reconciliation.
- **Неверное предположение:** failback — тот же failover наоборот. **Симптом:** вернувшийся A распространяет старые данные. **Причина:** stale epoch и divergence. **Исправление:** rebuild/rejoin как replica до возврата write authority.
- **Неверное предположение:** все данные требуют одного режима. **Симптом:** preferences платят latency ledger либо ledger получает слабый merge. **Причина:** consistency не разложена по инвариантам. **Исправление:** классифицировать data domains и выбрать placement отдельно.

## Когда применять

Multi-region оправдана при измеримой потребности: latency далёких users, обязательная locality, regional disaster tolerance или RPO/RTO, недостижимые одной площадкой. Начинайте с failure scenarios и business impact, затем проектируйте data plane; зеркальное копирование инфраструктуры без state protocol только умножает стоимость.

Проверка включает game day с потерей region connectivity, control plane и отдельной state dependency; измеряет фактические RPO/RTO, capacity target, backlog drain и failback. Архитектура не завершена, пока неизвестный outcome пользовательской операции не имеет reconciliation path.

## Источники

- [Spanner: Google’s Globally-Distributed Database](https://research.google.com/archive/spanner-osdi2012.pdf) — Google, OSDI 2012, проверено 2026-07-18.
- [Highly available multi-region web application](https://learn.microsoft.com/en-us/azure/architecture/web-apps/guides/multi-region-app-service/multi-region-app-service?tabs=paired-regions) — Microsoft Azure Architecture Center, актуальная архитектура, проверено 2026-07-18.
- [Use multiple Availability Zones and AWS Regions](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/use-multiple-availability-zones-and-aws-regions.html) — Amazon Web Services, Well-Architected Reliability Pillar, проверено 2026-07-18.
- [Disaster recovery scenarios for applications](https://docs.cloud.google.com/architecture/dr-scenarios-planning-guide) — Google Cloud Architecture Center, проверено 2026-07-18.
