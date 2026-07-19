---
aliases:
  - Fault injection/chaos basics [L5]
  - Fault injection
  - Chaos engineering basics
tags:
  - тип/кейс
  - область/reliability-performance-operations
  - тема/надёжность
  - тема/тестирование
статус: черновик
---

# Fault injection и chaos basics

## TL;DR

Fault injection — механизм контролируемого введения отказа: latency, packet loss, process kill, dependency error, resource pressure или failover. Chaos engineering — более широкая дисциплина эксперимента: она задаёт steady state, фальсифицируемую hypothesis, fault, blast radius, abort conditions, observations и recovery.

Запуск «убьём случайный pod и посмотрим» без ожидаемого user-visible outcome не даёт проверяемого знания. Без scope, stop signal и recovery plan он превращается в неуправляемое production-изменение.

## Контекст

Ниже — иллюстративный, а не фактически проведённый experiment. Order API работает под представительной нагрузкой 250 RPS и записывает orders в основную БД. Дизайн обещает, что краткая latency одного database target будет изолирована пулом, timeout budget и retries.

Первый эксперимент не берёт production целиком. Scope — один canary service instance, один выделенный tenant и 5% synthetic traffic. Fault — добавить 250 ms к database calls на три минуты. Цифры — пример experiment design, а не универсальные SLO.

## Симптомы и влияние

До injection steady state описан по выходу системы, а не по отсутствию внутренних errors:

```text
accepted load       = 250 RPS
success rate        >= 99.9%
p99 end-to-end      <= 300 ms
duplicate orders    = 0
oldest queue age    <= 5 s
```

Иллюстративный run опровергает hypothesis: после injection service-level retries и client retries умножают database attempts, pool заполняется, p99 растёт выше порога, а queue age продолжает расти. Abort condition останавливает injection до охвата большего traffic cohort.

Важен не только peak impact. После отмены fault backlog ещё некоторое время удерживает latency выше baseline. Это recovery debt, который не виден, если experiment заканчивается в момент выключения fault.

## Ментальная модель и гипотезы

### Fault injection — actuator, chaos experiment — доказательство

Один и тот же fault injector может быть частью unit/integration test, game day или continuous chaos. Chaos engineering начинается не с injector, а с прогноза о user-visible behavior:

```text
given representative load and healthy baseline,
when fault F affects target cohort C for duration D,
then steady-state metrics remain within bounds B,
mitigation M activates within T,
and the system recovers within R after fault removal.
```

Гипотеза должна быть фальсифицируемой. «Система должна выжить» не задаёт ни outcome, ни duration. Для кейса выше:

```text
Если DB latency вырастет на 250 ms для canary cohort,
то timeout/retry policy сохранит success >= 99.5%, p99 <= 700 ms,
duplicates = 0 и queue age <= 10 s,
а после removal все метрики вернутся к baseline за 2 min.
```

### Steady state — допустимый output, а не неподвижная система

Steady state может допускать небольшой error rate или кратковременную degradation. Он описывает observable output: availability, latency, correctness, freshness и recovery time. CPU и число pods полезны для diagnosis, но не заменяют customer SLI.

Перед injection нужно доказать, что baseline здоров. Если SLO уже нарушен без fault, experiment не разделит причины.

### Blast radius и abort condition — разные controls

Blast radius ограничивает, к чему injector вообще имеет доступ:

- environment, region/zone и resource selectors;
- traffic percentage, tenant/cohort и operation class;
- fault magnitude, duration и число simultaneous targets;
- IAM/RBAC permissions injector;
- downstream side effects, например запрет реальных payments в synthetic cohort.

Abort condition останавливает ongoing experiment по observable signal. Она должна иметь threshold, window и владельца. Для иллюстративного run:

```text
abort if any:
  5xx > 1% for two consecutive 30 s windows
  p99 > 1 s for two consecutive 30 s windows
  duplicate orders > 0
  oldest queue age > 20 s
  telemetry/stop controller unavailable
```

Остановка injector не равна rollback. Задержка, оставшийся process kill, failover или corrupted test data могут потребовать отдельного restore action. Поэтому experiment plan содержит и автоматический stop, и проверенный recovery playbook.

### Fault injection не равен load/stress testing

[[70 Практические кейсы/Load и stress testing|Load test]] обычно изменяет offered workload при исправной инфраструктуре и ищет SLO capacity/breakpoint. Fault injection изменяет поведение компонента и спрашивает, сработают ли resilience mechanisms под representative load.

Механизмы могут пересекаться: CPU pressure или traffic spike может быть chaos variable. Отличие в гипотезе и oracle. «Какова capacity curve?» — performance experiment; «сохранится ли user outcome при отказе части capacity?» — resilience experiment.

## Диагностика

Эксперимент наблюдает три временные области:

1. **Baseline:** steady state удерживается без fault.
2. **Injection:** user SLI и mitigation signals изменяются в ожидаемых bounds; видны retries, pool wait и queue growth.
3. **Recovery:** fault убран, но experiment ждёт возврата к baseline и проверяет data consistency.

Важны и black-box, и white-box signals. Success rate, p99, duplicate count и completion age проверяют hypothesis. Pool saturation, retry attempts, queue depth, circuit state и replica health объясняют mechanism. [[70 Практические кейсы/Dashboards и actionable alerts|Dashboard]] должен быть готов до начала, а не собираться после срабатывания abort.

Сначала лучше менять один fault dimension. Комбинации «latency + instance loss + traffic spike» нужны для correlated failures, но до понимания одиночных effects они ухудшают root-cause attribution.

## Root cause

В иллюстративном сценарии причина не в самих 250 ms. Система превратила один медленный database call в несколько attempts на разных layers. Каждый retry держал pool slot дольше, новые requests вставали в неограниченную очередь, а timeout наверху порождал ещё один client retry.

Цепочка:

```text
dependency latency
-> longer slot holding
-> retries multiply admitted work
-> pool and queue saturation
-> deadline failures
-> more retries
-> slow recovery after fault removal
```

Так injection обнаружил скрытую [[40 Распределённые системы/Retry storms и cascading failures|retry amplification]], а не просто доказал, что «БД медленная».

## Исправление

### Немедленное

- Сработавшая abort condition останавливает injection; operator проверяет, что target вернулся в исходное state.
- Canary cohort выводится из experiment routing, если impact продолжается.
- Admission ограничивается, а очередь контролируемо drain-ится; не добавляются новые безусловные retries.

### Долгосрочное

- Один layer владеет retry policy; attempts вписаны в end-to-end deadline и имеют backoff/jitter.
- Bounded queue и admission control включают [[40 Распределённые системы/Backpressure и queue buildup|backpressure]] до захвата дорогого pool slot.
- [[70 Практические кейсы/Bulkheads и dependency isolation|Bulkhead]] не даёт slow database path занять весь serving capacity.
- Эксперимент, обнаруживший weakness, остаётся versioned regression scenario с теми же hypothesis, bounds и fault magnitude.

## Проверка результата

После fix запускают тот же fault с тем же traffic model. Experiment проходит только если:

- user-facing bounds удержались во всех observation windows;
- retry attempts ограничены, pool не завис в saturation, queue age bounded;
- alerts и runbook trigger сработали в ожидаемый срок;
- после removal система вернулась к baseline до recovery deadline;
- data reconciliation не нашла duplicates, lost writes или orphan state.

Первый narrow run не доказывает resilience всей системы. Он подтверждает одну hypothesis в зафиксированном scope. Расширять blast radius можно только после устойчивых повторов и проверки stop/recovery controls.

## Профилактика

Храните experiment как code/config вместе с versioned fault definition, selectors, duration, steady-state query, abort policy и owner. Результат должен сохранять timestamps, deployed versions, traffic model, observations и action items.

Новые experiments приоритизируют по past incidents, FMEA, critical dependencies и риску `frequency × impact`. Если команда уже знает, что один instance failure нарушает SLO, сначала исправляют известный defect. Chaos полезен для known-unknowns и unknown-unknowns, а не для дорогого подтверждения уже известной поломки.

## Trade-offs

- Pre-production снижает customer risk и позволяет проверить abort. Production даёт реальные traffic, topology и shared limits, но может потратить [[70 Практические кейсы/Error budgets|error budget]] и требует narrow cohort. Маршрут: дешёвый test → production-like environment → ограниченный production experiment.
- Регулярная автоматизация может ловить regressions после изменений. Редкий game day лучше проверяет human coordination и [[70 Практические кейсы/Runbooks|runbook]], но хуже как регулярная regression guard. Нужны оба формата.
- Малый blast radius уменьшает risk, но может не достичь shared bottleneck. Расширение scope оправдано, когда narrow hypothesis уже подтверждена, а safeguards и restore проверены.

## Типичные ошибки

- **Неверное предположение:** injection сам по себе является тестом. **Симптом:** после run есть graphs, но нет pass/fail. **Причина:** не заданы steady state и hypothesis. **Исправление:** сначала observable bounds и recovery deadline.
- **Неверное предположение:** stop button откатывает fault. **Симптом:** injection закончен, а targets не в baseline. **Причина:** stop orchestration не восстанавливает все effects. **Исправление:** post-action/restore playbook и recovery gate.
- **Неверное предположение:** внутренний health доказывает steady state. **Симптом:** CPU нормален, но orders теряются или дублируются. **Причина:** proxy metric подменил user outcome. **Исправление:** black-box success, latency, correctness и freshness.
- **Неверное предположение:** сразу нужно ломать всю region. **Симптом:** реальный incident без диагностического знания. **Причина:** blast radius опередил зрелость safeguards. **Исправление:** минимальный cohort и staged expansion.

## Когда применять выводы

Начинайте с механизмов, которые design уже обещает: instance replacement, database failover, timeout/retry, [[70 Практические кейсы/Graceful degradation|graceful degradation]], cache fallback и queue recovery. Каждому promise нужна одна narrow hypothesis с user SLI.

Не запускайте experiment, если baseline нездоров, impact заведомо превысит budget, telemetry/abort unavailable, нет owner или recovery не отрепетирован. Цель — уменьшить неопределённость, а не создать её ещё одним неконтролируемым изменением.

## Источники

- [Principles of Chaos Engineering](https://principlesofchaos.org/) — Principles of Chaos Engineering, steady state, hypothesis, real-world events и minimize blast radius, проверено 2026-07-18.
- [REL12-BP04 Test resiliency using chaos engineering](https://docs.aws.amazon.com/wellarchitected/latest/framework/rel_testing_resiliency_failure_injection_resiliency.html) — AWS Well-Architected Framework, latest online edition, experiment lifecycle, guardrails, recovery и regression, проверено 2026-07-18.
- [Planning your AWS FIS experiments](https://docs.aws.amazon.com/fis/latest/userguide/getting-started-planning.html) — Amazon Web Services, AWS Fault Injection Service, steady state, hypothesis и stop thresholds, проверено 2026-07-18.
- [AWS FIS experiment template components](https://docs.aws.amazon.com/fis/latest/userguide/experiment-templates.html) — Amazon Web Services, AWS Fault Injection Service, targets, actions, stop conditions и role, проверено 2026-07-18.
- [Chaos experiments in Azure Chaos Studio](https://learn.microsoft.com/en-us/azure/chaos-studio/chaos-studio-chaos-experiments) — Microsoft, Azure Chaos Studio, редакция 2026-07-01, hypothesis, scope, duration и observations, проверено 2026-07-18.
- [Testing for Reliability](https://sre.google/sre-book/testing-reliability/) — Google, Site Reliability Engineering, chapter 17, online edition 2017, testing failure/recovery и resilience, проверено 2026-07-18.
