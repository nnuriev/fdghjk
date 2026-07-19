---
aliases:
  - Основы отказоустойчивости и SRE — CourseHunter 7091
tags:
  - тип/разбор-курса
  - источник/coursehunter
  - тема/отказоустойчивость
  - тема/sre
  - тема/распределенные-системы
  - тема/system-design
статус: проверено
---

# Основы отказоустойчивости и SRE

## TL;DR

Отказоустойчивость — не свойство одного паттерна. Система остаётся полезной, когда у неё явно определены допустимые отказы, пользовательский SLO, границы консистентности, механизм обнаружения сбоя, контролируемая деградация и процедура восстановления. На собеседовании сильный ответ связывает архитектуру с наблюдаемым результатом: **какой отказ случился → какой инвариант сохраняем → что увидит клиент → как это измерим → как восстановимся**.

## Вопросы из блока

1. Какие новые классы отказов появляются при переходе от монолита к распределённой системе?
2. Что такое partial failure и почему timeout не доказывает, что операция не выполнилась?
3. Что утверждает CAP theorem? В какой момент возникает выбор consistency/availability?
4. Чем strong consistency, linearizability и eventual consistency полезны в рассуждении о продукте?
5. Зачем нужны replication factor и quorum? Почему три узла обычно полезнее двух?
6. Чем synchronous replication отличается от asynchronous по latency, availability и риску потери подтверждённой записи?
7. Что такое split brain и где должен находиться механизм fencing?
8. Чем startup, readiness и liveness probes различаются семантически?
9. Почему liveness check не должен зависеть от всех downstream services?
10. Чем SLI, SLO и SLA отличаются друг от друга?
11. Как рассчитать error budget и burn rate?
12. Почему стремление к 100% availability может ухудшить продукт?
13. Что такое четыре golden signals и чем RED отличается от USE?
14. Какие алерты должны будить on-call, а какие оставаться на dashboard?
15. Как связаны MTTR, MTBF, recovery automation и организационный процесс?
16. Как безопасно провести chaos experiment?
17. В чём trade-off rolling, blue/green, canary и feature flags?
18. Как менять несовместимую схему БД без остановки старой версии приложения?
19. Что делает Incident Commander и почему он обычно не чинит систему сам?
20. Что должно быть в blameless postmortem?

## 1. Модель отказа

В монолите вызов функции либо вернул результат, либо процесс завершился ошибкой. В распределённой системе между инициатором и эффектом появляется сеть, удалённый процесс, очередь, несколько часов и независимые fault domains. Поэтому клиент может наблюдать timeout, хотя сервер уже зафиксировал запись. Он не умеет отличить «сервер не получил запрос» от «ответ потерялся после commit».

Из этого следуют три практических правила:

- любой remote call имеет deadline;
- mutating operation проектируется с повторной доставкой в уме;
- состояние «не знаю, выполнилось ли» является нормальным исходом протокола, а не редким исключением.

Классифицировать отказ полезно по нескольким осям: transient/permanent, fail-stop/Byzantine, локальный/коррелированный, dependency/resource/network, полный/частичный. Эта классификация определяет реакцию. Retry годится для ограниченного transient failure, но бессмысленен при валидационной ошибке и опасен при overload.

## 2. CAP без лозунгов

![[90 Вложения/CurseHunter/7091/Кадры/01-cap-partition.jpg|720]]

CAP говорит о поведении replicated data system во время network partition. Когда узлы не могут обменяться сообщениями, система не может одновременно гарантировать:

- **Consistency** в смысле linearizable register: каждый read видит последнее успешно завершённое write;
- **Availability**: каждый запрос к неупавшему узлу завершается неошибочным ответом;
- **Partition tolerance** не выбирается как продуктовая опция: если связь между частями системы может пропасть, архитектура обязана определить поведение.

Поэтому вопрос не «CP или AP навсегда», а «какая операция и какой инвариант важнее именно во время partition». Один продукт может быть CP для списания денег и AP для выдачи рекомендаций.

### Минимальный сценарий

Есть два replica, `A` и `B`; связь между ними пропала. Клиент записал `x=2` в `A` и получил success. Read в `B`:

- если `B` обязан ответить, он может вернуть старое `x=1` — availability сохранена, linearizability нарушена;
- если `B` отказывает до восстановления связи, linearizability можно сохранить, availability для этого запроса потеряна.

PACELC дополняет практическую картину: даже без partition приходится выбирать между latency и consistency. Но это не отменяет точную область CAP.

## 3. Replication, quorum и split brain

Для `N` voters majority quorum равен `floor(N/2)+1`. Пересечение любых двух majorities не пусто, поэтому при корректном consensus protocol два conflicting leaders не могут одновременно получить законный commit quorum.

| Voters | Quorum | Допустимо потерять voters | Комментарий |
| ---: | ---: | ---: | --- |
| 2 | 2 | 0 | второй узел добавляет копию, но не повышает write availability |
| 3 | 2 | 1 | типичный минимальный HA quorum |
| 4 | 3 | 1 | та же fault tolerance, что у 3, но дороже |
| 5 | 3 | 2 | выдерживает два независимых отказа |

Нечётное число не «магически надёжнее». Оно не тратит узел на конфигурацию с той же fault tolerance. Witness/etcd/consensus member должен находиться в независимом fault domain; иначе формальное число участников маскирует коррелированный отказ.

### Leader replication

- asynchronous replica уменьшает write latency и может повысить availability, но failover способен потерять уже подтверждённые записи;
- synchronous confirmation от нужного набора replicas повышает durability, но добавляет latency и делает write недоступным при отсутствии quorum;
- read from follower снижает нагрузку на leader, но требует заявить staleness/monotonic-read contract.

Split brain — два компонента считают себя leader и принимают несовместимые writes. Leader election без fencing недостаточен: старый leader может продолжать воздействовать на внешний ресурс. Fencing token должен монотонно возрастать, а сам ресурс обязан отклонять устаревшие токены.

## 4. Kubernetes probes как разные контракты

![[90 Вложения/CurseHunter/7091/Кадры/02-kubernetes-probes.jpg|720]]

| Probe | Вопрос | Неуспех |
| --- | --- | --- |
| startup | завершился ли долгий запуск | после threshold контейнер перезапускается; до успеха startup liveness/readiness не мешают запуску |
| readiness | можно ли направлять трафик в текущем состоянии | Pod исключается из ready endpoints, процесс не обязан перезапускаться |
| liveness | способен ли процесс восстановиться только через restart | kubelet перезапускает контейнер после threshold |

Типичная ошибка: liveness ходит в PostgreSQL, Redis и все downstream services. Падение общей зависимости делает unhealthy сразу весь fleet, Kubernetes перезапускает живые процессы, они одновременно прогреваются и создают restart storm. Downstream health обычно влияет на readiness или degraded response, но не доказывает, что текущий процесс застрял.

Probe должна проверять именно тот контракт, последствие которого запускает. Дешёвый локальный liveness обнаруживает deadlock/event-loop stall; readiness учитывает незавершённую инициализацию, drain и отсутствие обязательного локального ресурса.

## 5. SLI, SLO, SLA и error budget

**SLI (Service Level Indicator)** — измеряемый пользовательский результат: доля успешных запросов, latency хороших событий, freshness, durability. **SLO (Service Level Objective)** — целевое значение SLI за окно. **SLA (Service Level Agreement)** — внешний договор и последствия нарушения; он не обязан совпадать с внутренним SLO.

Хороший availability SLI использует события, а не uptime процесса:

```text
availability = good_events / valid_events
```

`good` должен отражать продукт: например, HTTP 200 за ≤300 ms. Planned maintenance, retries и client errors включаются или исключаются только по заранее описанной политике.

Если SLO = 99.9% на 30 дней, error budget = 0.1% valid events. Для time-based approximation это около 43.2 минуты, но request-based budget обычно полезнее: десятиминутный пик может затронуть намного больше пользователей, чем час ночью.

![[90 Вложения/CurseHunter/7091/Кадры/19-error-budget.jpg|720]]

Burn rate показывает, во сколько раз budget расходуется быстрее равномерного темпа. Rate `1` означает, что весь budget закончится ровно к концу окна; rate `14.4` уничтожит 30-дневный budget примерно за 50 часов. Multi-window, multi-burn-rate alerts ловят и быстрые тяжёлые аварии, и медленную деградацию без постоянного шума.

Почему не 100%: бесконечная надёжность недостижима, а цена последних «девяток» конкурирует с безопасными изменениями. SLO превращает спор «достаточно ли надёжно» в продуктовый trade-off. Если budget исчерпан, команда временно уменьшает риск изменений и инвестирует в reliability; если запас есть — может быстрее экспериментировать.

## 6. Observability и алертинг

Observability — способность выводить внутреннее состояние из telemetry: metrics, structured logs, traces, profiles. Это не синоним «у нас есть Grafana».

![[90 Вложения/CurseHunter/7091/Кадры/20-monitoring-methods.jpg|720]]

| Метод | Сигналы | Где полезен |
| --- | --- | --- |
| Four Golden Signals | latency, traffic, errors, saturation | пользовательский сервис и его capacity |
| RED | rate, errors, duration | request/event processing |
| USE | utilization, saturation, errors | CPU, memory, disk, network, pools |

Latency надо делить хотя бы на success/error и смотреть distribution, а не только average. Saturation — очередь, pool exhaustion, goroutines, in-flight, Kafka lag — часто предсказывает outage раньше error rate.

Alert должен быть actionable и привязан к пользовательскому воздействию или быстрому burn budget. Dashboard отвечает «что происходит?», ticket — «что надо улучшить в рабочее время?», page — «кто-то должен действовать немедленно». Алерт на каждую CPU spike создаёт alert fatigue и ухудшает MTTR.

Для Kafka consumer недостаточно одного lag: нужны rate поступления и обработки, lag по partition, возраст старейшего сообщения, rebalance rate, processing errors/DLQ. Lag `100000` при миллионе событий в секунду может быть нормой, а lag `100` для платёжной команды возрастом час — аварией.

## 7. Проверка надёжности: load, stress и chaos

Load test проверяет ожидаемый профиль; stress test ищет предел и форму деградации; soak test выявляет leaks и накопление; chaos experiment проверяет конкретную гипотезу об отказе.

![[90 Вложения/CurseHunter/7091/Кадры/21-chaos-engineering.jpg|720]]

Корректный chaos experiment:

1. формулирует steady state через SLI;
2. вводит реалистичный fault: process kill, latency, packet loss, resource exhaustion;
3. ограничивает blast radius и длительность;
4. имеет abort conditions и независимую «красную кнопку»;
5. сравнивает наблюдение с гипотезой;
6. заканчивается конкретным action item или подтверждением известной границы.

«Убить production database и посмотреть» без гипотезы, observability и остановки — не chaos engineering.

## 8. Безопасные изменения

![[90 Вложения/CurseHunter/7091/Кадры/22-canary-release.jpg|720]]

- **Rolling update** экономит ресурсы, но некоторое время смешивает версии и требует backward-compatible protocols.
- **Blue/green** даёт быстрое переключение и rollback application layer, но удваивает окружение; state/schema откатить так же просто нельзя.
- **Canary** ограничивает blast radius и сравнивает SLI новой версии с baseline; малая выборка и сезонность могут скрыть редкий failure.
- **Feature flag** отделяет deployment от activation, но создаёт combinatorial states и требует lifecycle/удаления старых flags.

Для schema change используется expand-contract:

1. expand: добавить совместимое поле/таблицу, не ломая старый код;
2. migrate: новый код пишет/читает совместимо, выполняется backfill и проверка;
3. contract: удалить старую схему только после исчезновения старых consumers и rollback window.

Forward-only migration часто безопаснее rollback DDL: приложение откатывается на версию, совместимую с уже расширенной схемой. Любой canary обязан иметь заранее определённые success/abort metrics, а не ручное «похоже, всё хорошо».

## 9. Incident response и postmortem

![[90 Вложения/CurseHunter/7091/Кадры/23-incident-commander.jpg|720]]

Incident Commander (IC) объявляет severity, назначает роли, держит общий timeline, принимает решения при разногласиях и отвечает за stakeholder communication. Если IC одновременно глубоко чинит сервис, он теряет global picture; техническую работу ведут responders.

Приоритеты: остановить пользовательский impact → стабилизировать → восстановить → только потом искать полную root cause. Быстрый rollback, traffic shift, disable feature, degrade mode или load shedding часто лучше красивого hotfix.

![[90 Вложения/CurseHunter/7091/Кадры/24-postmortem-structure.jpg|720]]

Рабочий blameless postmortem содержит:

- summary, impact и точный timeline;
- detection и response: что сработало, где потеряли время;
- contributing factors, а не один удобный «root cause»;
- what went well / what went poorly;
- action items с owner, priority, deadline и проверяемым результатом;
- lessons learned для других систем.

Blameless не означает отсутствие ответственности. Он убирает наказание за добросовестное действие в несовершенной системе, чтобы люди не скрывали сигналы. Negligence и сознательное нарушение политики рассматриваются отдельным процессом.

## Практическое задание

Сервис заказов имеет SLO 99.9%. После потери связи с Redis readiness всех pods падает, Kubernetes удаляет их из endpoints; autoscaler создаёт новые pods, они одновременно идут в PostgreSQL, база насыщается, а retry увеличивает RPS в 9 раз.

Разберите сценарий по цепочке:

1. неверное предположение: cache — обязательная dependency для readiness;
2. симптом: весь fleet недоступен и база перегружена;
3. механизм: коррелированный health failure + cold-start herd + retry amplification;
4. исправление: cache fallback/controlled staleness, раздельные probes, retry budget+jitter, admission control, warm-up limit;
5. доказательство: SLI, saturation, retry ratio, DB queue, cache hit rate, burn-rate alerts;
6. recovery: traffic reduction, disable retries/feature, восстановление cache, постепенный ramp-up.

## Источники

- [Perspectives on the CAP Theorem](https://groups.csail.mit.edu/tds/papers/Gilbert/Brewer2.pdf) — Gilbert, Lynch, IEEE Computer, 2012, проверено 2026-07-19.
- [High Availability, Load Balancing, and Replication](https://www.postgresql.org/docs/current/high-availability.html) — PostgreSQL Global Development Group, PostgreSQL 18 current docs, проверено 2026-07-19.
- [Liveness, Readiness, and Startup Probes](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-probes) — Kubernetes Documentation, current, проверено 2026-07-19.
- [Service Level Objectives](https://sre.google/sre-book/service-level-objectives/) — Google SRE Book, проверено 2026-07-19.
- [Embracing Risk](https://sre.google/sre-book/embracing-risk/) — Google SRE Book, проверено 2026-07-19.
- [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) — Google SRE Book, проверено 2026-07-19.
- [Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/) — Google SRE Workbook, проверено 2026-07-19.
- [Managing Incidents](https://sre.google/workbook/incident-response/) — Google SRE Workbook, проверено 2026-07-19.
- [Postmortem Culture](https://sre.google/sre-book/postmortem-culture/) — Google SRE Book, проверено 2026-07-19.
