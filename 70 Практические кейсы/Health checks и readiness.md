---
aliases:
  - Health checks
  - Readiness and liveness probes
  - Проверки здоровья
tags:
  - область/reliability-performance-operations
  - тема/надёжность
  - тема/kubernetes
статус: проверено
---

# Health checks и readiness

## TL;DR

Одна проверка `GET /health` не отвечает на все вопросы о состоянии instance. Нужно различать три семантики: завершилась ли инициализация (`startup`), способен ли локальный процесс продолжать работу без перезапуска (`liveness`) и следует ли направлять ему новый трафик (`readiness`). Это не означает, что workload обязан включать все три probes: startup нужна при долгом или непредсказуемом старте, liveness — только при failure, который restart доказанно лечит, readiness — когда instance включают в serving pool. Проверка пользовательского пути снаружи (`black-box` или synthetic check) решает ещё одну задачу: подтверждает доступность сервиса через реальные DNS, routing, TLS и dependencies.

Readiness failure должна исключать instance из выбора для новых запросов, но не перезапускать его. Liveness failure оправдана только тогда, когда restart с высокой вероятностью исправит локальное зависание. Если liveness синхронно зависит от общей базы данных, outage базы способен превратиться в массовые рестарты, потерю прогрева и более долгий incident.

## Ментальная модель

Каждая проверка задаёт свой операционный вопрос и действие:

| Проверка | Вопрос | Действие при неуспехе |
| --- | --- | --- |
| `startup` | Instance закончил инициализацию? | Не включать остальные probes; после серии failures остановить container, затем применить `restartPolicy` |
| `liveness` | Этот процесс застрял так, что restart поможет? | Остановить container, затем применить `restartPolicy` |
| `readiness` | Можно ли направлять этому instance новый traffic? | Исключить endpoint из обычного load balancing |
| black-box / synthetic | Работает ли пользовательский путь снаружи? | Записать SLI, поднять alert или переключить traffic по отдельной политике |

Инвариант простой: причина неуспеха должна соответствовать действию. Недоступная shared dependency не становится доступнее от restart всех clients. Instance с незагруженной конфигурацией не должен получать traffic, даже если его процесс жив.

## Как устроено

### Почему `process is running` недостаточно

Процесс способен принимать TCP connection, но не завершать запросы: event loop застрял, worker pool исчерпан, routing table ещё не загружена или приложение перестало продвигать очередь. Поэтому TCP probe подтверждает только возможность установить соединение. HTTP, gRPC или `exec` probe может проверять более содержательный контракт, но глубокая проверка тоже не гарантирует end-to-end success.

Полезно разделить четыре слоя:

1. **Process:** runtime жив, main loop или critical worker продолжает progress.
2. **Serving state:** инициализация завершена, instance не draining, локальные обязательные ресурсы доступны.
3. **Dependency path:** hard dependencies способны выполнить нужную операцию.
4. **User path:** запрос проходит через внешний entry point и возвращает корректный результат.

Первые два слоя подходят для probes внутри orchestrator. Третий проверяют осторожно: probe каждого Pod не должна сама создавать заметную нагрузку на общую dependency. Четвёртый относится к [[50 Проектирование систем/Observability в System Design|observability]] и SLI, а не к restart policy одного container.

### Startup probe

Медленно стартующий процесс без startup probe рискует быть убит liveness probe до окончания migrations, cache warm-up или загрузки модели. В Kubernetes при настроенной `startupProbe` liveness и readiness не выполняются, пока startup не станет успешной. После успеха управление переходит обычным probes; startup больше не исполняется.

Бюджет старта задают `failureThreshold * periodSeconds` с поправкой на timeout и расписание проверок. Он должен покрывать подтверждённый верхний хвост нормальной инициализации, но оставаться конечным: действительно застрявший start обязан когда-нибудь перезапуститься и поднять наблюдаемый failure.

Startup probe не заменяет исправление медленного старта. Она лишь отделяет допустимую инициализацию от зависшего процесса и не позволяет liveness преждевременно вмешаться.

### Liveness probe

Liveness проверяет локальное состояние, которое restart способен восстановить. Подходящие примеры:

- main loop не обновлял progress timestamp дольше безопасной границы;
- critical internal worker окончательно остановился;
- runtime обнаружил unrecoverable invariant violation и не может корректно обслуживать запросы.

Проверка «база отвечает» для liveness почти всегда опасна. При общем database outage все replicas одновременно становятся `not live`, kubelet перезапускает containers, а reconnect и cache warm-up добавляют нагрузку во время восстановления. Та же ошибка возникает, если liveness endpoint ждёт saturated request pool: перегрузка вызывает restart, restart уменьшает готовую capacity и усиливает перегрузку.

Liveness endpoint должен быть дешёвым, bounded по времени и учитывать progress основной serving path. Полностью отдельный admin server не должен безусловно отвечать `200`, если рабочий event loop умер; иначе probe видит здоровый служебный listener рядом с неработающим приложением.

### Readiness probe

Readiness сообщает, следует ли выбирать endpoint для **новых** запросов. Она становится отрицательной, когда instance:

- ещё не закончил инициализацию;
- начал graceful drain;
- не загрузил обязательную конфигурацию или routing state;
- потерял локальный ресурс, без которого не способен выполнить serving contract;
- временно перегружен и удаление из балансировки действительно помогает перераспределить traffic.

В Kubernetes failed readiness probe не перезапускает container. Pod продолжает работать, а его адрес получает `ready: false` в EndpointSlice и перестаёт быть обычным backend соответствующих Services. Исключение — Service с `spec.publishNotReadyAddresses: true`, для которого condition `ready` принудительно считается истинной. Обновление discovery и load balancer не мгновенно, а уже установленные keep-alive connections и in-flight requests могут сохраниться. Поэтому readiness — механизм admission для будущего traffic, а не гарантия, что после смены состояния не придёт ни одного запроса.

Проверять remote dependency внутри readiness стоит по её роли:

- **Hard dependency:** если без неё instance не может выполнить ни один запрос, отрицательная readiness честно отражает serving contract. Однако одинаковый failure у всех replicas способен оставить Service без ready endpoints и не создаёт новую capacity.
- **Soft dependency:** если доступен cache, stale read или упрощённый ответ, readiness должна сохранить instance в ротации, а деградация отражается отдельными метриками и SLI.
- **Shared dependency:** вместо активного запроса от каждой probe лучше использовать дешёвое локальное состояние клиента, bounded cache результата или состояние [[40 Распределённые системы/Circuit breaker|circuit breaker]], не превращая health checks в дополнительную retry storm.

Выбор между fail-open и fail-closed зависит от контракта. Для correctness-critical операции безопаснее перестать принимать трафик. Для read path с допустимым stale result полезнее остаться ready и применить graceful degradation.

### Механизмы Kubernetes probes

Kubernetes поддерживает четыре handler:

- `httpGet`: успехом считается HTTP status от `200` до `399`;
- `tcpSocket`: успех означает, что kubelet смог открыть TCP connection;
- `grpc`: встроенная проверка вызывает gRPC Health Checking Protocol и ожидает статус `SERVING`;
- `exec`: команда внутри container должна завершиться с exit code `0`.

TCP probe слабее application-level проверки: открытый socket ничего не говорит о корректности ответа. `exec` probe позволяет проверить локальное состояние, но частый запуск тяжёлой команды расходует CPU, processes и filesystem I/O. HTTP и gRPC endpoints обычно дешевле, если их контракт узкий и handler не делит без ограничения очередь с пользовательскими запросами.

Поля `periodSeconds`, `timeoutSeconds`, `failureThreshold` и `successThreshold` образуют фильтр между быстрым обнаружением и flapping. Малый period и threshold быстрее выводят broken endpoint, но краткий GC pause или transient network delay создаёт false positive. Большие значения медленнее реагируют. Для liveness и startup `successThreshold` обязан быть `1`; readiness может требовать несколько последовательных успехов, чтобы не возвращать нестабильный instance после одного удачного ответа.

### Readiness при остановке

Правильная остановка связывает readiness с [[20 Бэкенд/Graceful shutdown backend-сервиса|graceful shutdown backend-сервиса]]:

```text
получен сигнал остановки
  -> serving state = draining, readiness = false
  -> discovery и load balancers получают обновление
  -> прекращается admission новых запросов
  -> завершаются in-flight requests в пределах grace period
  -> закрываются listeners и процесс завершается
```

Нельзя полагаться только на фиксированный `sleep`: время распространения зависит от discovery, proxies и connection reuse. Server обязан сам прекратить принимать новую работу и корректно обработать late arrivals. Для долгих RPC или queue consumers нужны отдельные правила drain и checkpoint.

### Health checks не заменяют SLI

Зелёная readiness у всех Pods не доказывает доступность пользователя: DNS может указывать не туда, certificate истёк, ingress отклоняет запросы, а downstream возвращает логически неверный ответ. Поэтому [[50 Проектирование систем/SLO в System Design|SLI]] считают на реальном request path, а black-box probe запускают снаружи failure domain.

Обратное тоже верно: единичный synthetic check не представляет распределение всего traffic. Он полезен как canary конкретного пути, но dashboard должен сопоставлять его с request-based availability, latency, saturation и deployment events. Правила для таких сигналов описаны в [[70 Практические кейсы/Dashboards и actionable alerts|dashboards и actionable alerts]].

## Пример или трассировка

Сервис обычно стартует за 80 секунд, иногда после cold cache — за 210 секунд. Его Pod настроен так:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: orders
spec:
  containers:
    - name: orders
      image: example/orders:1.8.4
      ports:
        - name: http
          containerPort: 8080
      startupProbe:
        httpGet:
          path: /startupz
          port: http
        periodSeconds: 10
        timeoutSeconds: 1
        failureThreshold: 30
      readinessProbe:
        httpGet:
          path: /readyz
          port: http
        periodSeconds: 5
        timeoutSeconds: 1
        failureThreshold: 2
        successThreshold: 2
      livenessProbe:
        httpGet:
          path: /livez
          port: http
        periodSeconds: 10
        timeoutSeconds: 1
        failureThreshold: 3
```

`/startupz` возвращает успех после загрузки обязательной конфигурации и восстановления локального состояния. Тридцать проверок с периодом 10 секунд дают примерно пятиминутный startup budget; до первого успеха readiness и liveness не запускаются.

После старта `/livez` проверяет progress main loop, но не обращается к базе. `/readyz` возвращает неуспех при `draining`, незагруженной routing table или невозможности принять новую работу в bounded local pool. Два последовательных failures быстро выводят endpoint из ротации, а два successes дают простую hysteresis перед возвратом.

Во время outage базы приложение продолжает отвечать на cacheable reads и возвращает контролируемую ошибку для writes. Liveness остаётся успешной: restart не починит базу. Readiness остаётся успешной для общего read-capable endpoint. Если read и write pools разнесены по разным Pods и Services, write pool может отдельно стать not ready; для одного Pod condition `Ready` общая, поэтому классы запросов разделяет application-level routing или admission. Метрики отдельно показывают degraded mode и долю failed writes.

Если main loop перестаёт обновлять progress marker, `/livez` три раза подряд не отвечает успешно. Kubernetes перезапускает container; startup probe снова защищает его на этапе инициализации. Если restart не помогает, это видно по restart count и alerts, а не скрывается бесконечным циклом зелёной readiness.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| Kubernetes 1.20, 2020-12-08 | Startup probe была beta | `startupProbe` получила stable status | Медленный start можно отделить от liveness без experimental API | [Kubernetes 1.20 release announcement](https://kubernetes.io/blog/2020/12/08/kubernetes-1-20-release-announcement/) |
| Kubernetes 1.26 | EndpointSlice conditions `serving` и `terminating` ещё не имели stable contract в старых версиях | Обе conditions имеют stable status начиная с 1.26 | Proxies могут различать terminating endpoint, который ещё обслуживает существующие соединения, и ready endpoint для нового traffic | [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/) |
| Kubernetes 1.27, 2023-04-11 | Встроенные gRPC probes были beta | gRPC probes стали generally available | Для gRPC workload не нужен внешний binary только ради стандартной health probe | [Kubernetes v1.27 release](https://kubernetes.io/blog/2023/04/11/kubernetes-v1-27-release/) |
| Kubernetes 1.36.2, 2026-06-09 | Предыдущие minor releases имели свои support windows | 1.36.2 — актуальный patch release на дату проверки | Конкретные probe fields и lifecycle в этой заметке проверены по документации ветки 1.36 | [Kubernetes releases](https://kubernetes.io/releases/) |

## Trade-offs

**Shallow readiness** дёшева и устойчива к shared outage, но способна оставить endpoint в ротации, когда обязательная dependency недоступна. **Deep readiness** ближе к serving contract, зато добавляет latency, нагрузку и correlated failures. Практичный компромисс — локально вычисляемое состояние обязательных clients с bounded freshness, а полный user path проверять отдельно.

**Быстрое обнаружение** уменьшает число запросов к broken instance. Цена — false positives при коротких pauses и риск одновременно вывести много replicas. Thresholds выбирают по допустимому ущербу и наблюдаемому распределению probe latency, а rollout проверяет, что remaining ready capacity выдержит traffic.

**Отдельный probe server** защищает health endpoint от обычной очереди и помогает диагностировать overload. Он же способен скрыть смерть serving path. **Общий server** лучше представляет request path, но может flapping-овать именно во время saturation. В обоих вариантах probe должна читать явный serving state и progress, а не считать сам факт ответа доказательством здоровья.

Readiness-based load shedding удобно использует существующий balancer, но это грубый сигнал на весь endpoint и его распространение не мгновенно. Для overload часто точнее bounded concurrency, priority admission и быстрый `429/503`, сохраняя instance ready для допустимого класса запросов.

## Типичные ошибки

- **Неверное предположение:** одна `/health` подходит startup, liveness, readiness и monitoring. **Симптом:** instance то получает traffic до инициализации, то перезапускается из-за dependency outage. **Причина:** разные вопросы связаны с одним действием. **Исправление:** разделить contracts и явно описать consequence каждого failure.
- **Неверное предположение:** liveness должна проверять все dependencies. **Симптом:** outage базы вызывает restart loop всего fleet. **Причина:** restart clients не восстанавливает shared dependency и добавляет reconnect load. **Исправление:** оставить в liveness только локальные recoverable-by-restart failures, dependency health вынести в readiness, metrics и degradation policy.
- **Неверное предположение:** открытый TCP port означает работоспособное приложение. **Симптом:** probe зелёная, а RPC зависают. **Причина:** listener принимает connection, но worker path не делает progress. **Исправление:** application-level probe с bounded проверкой serving state.
- **Неверное предположение:** `ready: false` мгновенно прекращает весь traffic. **Симптом:** после начала drain приходят late requests. **Причина:** EndpointSlice и proxies обновляются асинхронно, keep-alive и in-flight connections сохраняются. **Исправление:** server-side admission stop, bounded drain и достаточный termination grace period.
- **Неверное предположение:** более частая probe всегда безопаснее. **Симптом:** краткий GC pause выводит несколько replicas и создаёт cascading overload. **Причина:** period и thresholds не учитывают нормальный tail и remaining capacity. **Исправление:** измерить probe latency, добавить consecutive failures и проверить отказ replica под нагрузкой.
- **Неверное предположение:** readiness обязана стать отрицательной при любой ошибке downstream. **Симптом:** отказ soft dependency убирает все endpoints, хотя сервис мог вернуть cache или упрощённый ответ. **Причина:** техническая ошибка перепутана с невозможностью выполнить serving contract. **Исправление:** разделить hard/soft dependencies и сохранить ready в явно наблюдаемом degraded mode.
- **Неверное предположение:** зелёные probes доказывают SLO. **Симптом:** control plane считает Pods здоровыми, пользователи получают TLS или ingress errors. **Причина:** probes не проходят внешний user journey. **Исправление:** request-based SLI и black-box checks из внешнего failure domain.

## Когда применять

Три семантики startup, liveness и readiness нужно рассмотреть для каждого долгоживущего workload, но включать только применимые probes. Readiness обычно нужна serving workload, который orchestrator включает в load balancing. Startup нужна при долгой или непредсказуемой инициализации. Liveness оправдана только при доказанном recoverable-by-restart failure. Сначала определяют serving contract и допустимое действие, затем пишут endpoint. Если команда не способна назвать failure, который restart исправляет, безопаснее не добавлять liveness, чем использовать случайную глубокую проверку.

Для batch job readiness обычно не нужна: job не получает Service traffic. Liveness может быть полезна только при доказанном recoverable hang; timeout и retry policy самого job часто точнее. Для queue consumer readiness трактуют как разрешение получать новые сообщения, а in-flight work останавливают отдельным drain protocol.

Probes проверяют в realistic failure tests: медленный start, зависший main loop, отказ shared dependency, saturation, удаление Pod под load и задержка распространения EndpointSlice. Успешный happy-path `curl /health` не проверяет главное — соответствие сигнала реальному действию control plane.

## Источники

- [Liveness, Readiness, and Startup Probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/) — Kubernetes, документация ветки 1.36, проверено 2026-07-18.
- [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/) — Kubernetes, документация ветки 1.36, проверено 2026-07-18.
- [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/) — Kubernetes, API `discovery.k8s.io/v1`, проверено 2026-07-18.
- [EndpointSlice v1 API](https://kubernetes.io/docs/reference/kubernetes-api/discovery/endpoint-slice-v1/) — Kubernetes, API reference 1.36, проверено 2026-07-18.
- [Kubernetes 1.20 release announcement](https://kubernetes.io/blog/2020/12/08/kubernetes-1-20-release-announcement/) — Kubernetes, 1.20, проверено 2026-07-18.
- [Kubernetes v1.27 release](https://kubernetes.io/blog/2023/04/11/kubernetes-v1-27-release/) — Kubernetes, 1.27, проверено 2026-07-18.
- [Health Checking](https://grpc.io/docs/guides/health-checking/) — gRPC, Health Checking Protocol `grpc.health.v1`, проверено 2026-07-18.
- [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) — Google, Site Reliability Engineering, глава 6, проверено 2026-07-18.
