---
aliases:
  - Dashboards and actionable alerts
  - Операционные дашборды и алерты
  - SLO burn-rate alerts
tags:
  - область/reliability-performance-operations
  - тема/наблюдаемость
  - тема/slo
статус: проверено
---

# Dashboards и actionable alerts

## TL;DR

Dashboard ускоряет формирование и проверку гипотезы; alert требует своевременного действия. Не каждую полезную диаграмму нужно превращать в page. Срочный alert начинается с пользовательского симптома или угрозы error budget, содержит owner, scope, severity, runbook и контекст последнего изменения. Причинные метрики помогают расследовать, но будят on-call только тогда, когда есть конкретное действие до пользовательского ущерба.

Хорошая стартовая схема для request SLO: multiwindow, multi-burn-rate alerts. Для 30-дневного окна page срабатывает при 14,4x burn rate одновременно за 1 час и 5 минут, либо при 6x за 6 часов и 30 минут. Длинное окно доказывает значимость, короткое подтверждает, что расход продолжается.

## Ментальная модель

У dashboard и alert разные вопросы:

```text
dashboard: что происходит и какая гипотеза следующая?
alert: кто должен сделать что именно и насколько срочно?
```

Operational path строится сверху вниз:

```text
user impact -> SLO/error budget -> affected slice
            -> recent change -> dependency/resource evidence
            -> mitigation -> recovery confirmation
```

График CPU без этой цепочки заставляет расследовать компонент до доказательства ущерба. Page на CPU делает ещё хуже: человек просыпается из-за состояния машины, которое система нередко переживает сама.

## Как устроено

### Dashboard как интерфейс расследования

Первый экран отвечает на пять вопросов без переключения вкладок:

1. Какой user journey и SLO нарушен, сколько бюджета потрачено?
2. Когда началось и продолжается ли ухудшение?
3. Кто пострадал: operation, region, tenant class, version, shard?
4. Какое изменение совпало по времени: binary, config, schema, traffic shift?
5. Какой ресурс или dependency ограничивает восстановление?

Практичная иерархия:

- service overview: availability/latency/freshness SLIs, budget remaining, traffic и deploy annotations;
- failure-domain slices: region, zone, version, operation class, shard owner;
- dependency view: call rate, errors, latency, retry и circuit state;
- saturation view: CPU/run queue, memory/GC, pools, queue age, disk/network;
- recovery view: drain rate, oldest work, replica health и прогноз возврата в SLO.

[[50 Проектирование систем/Observability в System Design|Metrics, logs и traces]] связывают эти уровни: metrics показывают масштаб, exemplars или trace ID ведут к конкретному causal path, structured log даёт редкие детали. Dashboard не должен копировать все доступные метрики. Каждая panel либо отвечает на operational question, либо помогает выбрать следующее действие.

### Контракт панели

У графика фиксируют:

- единицу, aggregation и measurement boundary;
- time window и timezone;
- denominator для ratio;
- SLO/capacity threshold и источник threshold;
- expected missing-data semantics;
- контролируемые filters и опасные высококардинальные разрезы;
- ссылки на query, runbook и owner.

Среднее по instances часто скрывает худший failure domain. Для saturation полезны максимум и распределение; для user impact нужен взвешенный aggregate плюс разрез по region/version. Графики canary и control показывают на одной шкале и одновременно сверяют с абсолютным SLO: оба могут одинаково деградировать из-за внешнего incident.

Release/config/schema annotations обязательны. Корреляция ещё не доказывает root cause, но сокращает поиск и позволяет быстро проверить rollback как mitigation.

### Что делает alert actionable

Page оправдан, если выполняются все условия:

- есть текущий или неизбежный пользовательский ущерб;
- требуется немедленное действие человека, одной автоматизации недостаточно;
- alert приходит достаточно рано, чтобы действие изменило исход;
- указан один ответственный team/service owner;
- notification содержит scope, severity, started-at, текущие значения и первый безопасный шаг;
- после действия есть критерий recovery.

Если реакция может ждать рабочего времени, создают ticket. Если действие не определено, сигнал остаётся dashboard/report до появления playbook. Email, который никто не обязан читать, не становится третьим видом реакции.

Symptom alert обычно лучше cause alert. `Checkout error budget burns 15x` говорит об impact при любой причине. `DB CPU > 80%` полезен как page лишь если оператор обязан вмешаться до SLO и threshold доказан capacity test. Иначе DB CPU прикладывают к notification как diagnostic context.

### Burn rate и окна

Для SLO `S`:

```text
budget_fraction = 1 - S
burn_rate = observed_bad_fraction / budget_fraction
budget_spend = burn_rate * alert_window / SLO_window
```

Для SLO 99,9% budget fraction равна 0,001. Burn rate 14,4 означает bad fraction 0,0144, то есть 1,44%. За час он тратит:

```text
14,4 * 1h / 720h = 0,02 = 2% 30-дневного бюджета
```

PromQL-форма page из Google SRE Workbook:

```promql
(
  bad_ratio_1h > 14.4 * 0.001
  and bad_ratio_5m > 14.4 * 0.001
)
or
(
  bad_ratio_6h > 6 * 0.001
  and bad_ratio_30m > 6 * 0.001
)
```

Первое условие ловит быстрый расход 2% бюджета, второе ловит более медленный расход 5%. Ticket можно строить на 1x за окна 3 дня и 6 часов, что соответствует примерно 10% бюджета. Эти числа служат starting point, а не универсальным законом: low-traffic и extremely high/low SLO требуют другой модели.

Перевод duration окна в долю request-based бюджета предполагает сопоставимый event rate внутри SLO-окна. При сильной суточной сезонности burn rate всё ещё нормализует долю плохих событий, но прогноз абсолютного расхода дополняют bad/total counts и ожидаемым профилем трафика.

Длинное окно без короткого долго остаётся firing после recovery. Короткое без длинного шумит на всплесках, которые почти не тратят budget. Условие `long AND short` сочетает значимость с быстрым reset.

[[70 Практические кейсы/Error budgets|Error budget policy]] определяет последствия исчерпания, а alert предупреждает о скорости расхода. Alert не должен менять SLO scope на лету: исключения и valid events фиксируют в SLI.

### Low traffic, missing data и слепые зоны

Десять запросов в час и один failure дают 10% error rate. Для 99,9% SLO это 100x burn rate, но статистического контекста почти нет. Решение зависит от цены запроса:

- high-value операция может требовать расследовать каждую потерю;
- synthetic black-box traffic добавляет ранний сигнал;
- несколько семантически связанных low-volume paths можно объединить;
- окно и target пересматривают вместе со stakeholders;
- alert требует minimum event count, если единичный failure незначим.

Отсутствие samples нельзя автоматически считать нулём. Нулевой traffic, сломанный exporter и недоступный monitoring backend выглядят одинаково наивному запросу. Для critical SLI отдельно следят за telemetry freshness, scrape/export errors, rule evaluation и notification delivery. Monitoring path имеет собственные health signals и synthetic heartbeat до receiver.

### Routing, grouping и suppression

Один incident способен вызвать тысячи instance alerts. Notification layer группирует их по service/failure domain, объединяет дубликаты и подавляет дочерние симптомы при активном alert верхнего уровня. Silence допустим на ограниченный срок с owner и причиной; бессрочный mute превращает blind spot в конфигурацию.

Во время rollout сравнение canary/control может породить отдельный release gate, но on-call должен получить одну incident notification. Alert labels, от которых зависит grouping и routing, держат стабильными и bounded; request ID и exception text остаются annotations/logs.

### Жизненный цикл alert

Alert готов только после проверки:

1. Query корректно считает denominator, gaps и reset.
2. Controlled fault или replay вызывает alert за ожидаемое время.
3. Notification доходит до реального owner и открывает рабочий runbook.
4. Grouping/inhibition не скрывают независимый incident и не создают storm.
5. Recovery закрывает alert и подтверждается SLI, а не исчезновением cause metric.
6. Каждое ложное или бесполезное срабатывание заканчивается правкой либо удалением alert.

Runbook начинается с безопасной mitigation и критериев escalation. Длинный каталог возможных root causes полезен позже; первая минута требует scope, recent changes, rollback/traffic shift/load shed и способ проверить эффект.

## Пример или трассировка

У checkout 99,9% availability SLO на 30 дней. В 14:02 начинается rollout `v42`. Overview показывает:

```text
global burn rate 1h: 15x
global burn rate 5m: 18x
control v41 bad ratio: 0,08%
canary v42 bad ratio: 7,2%
affected slice: region eu-west, operation create_order
DB CPU: 55%, pool wait p99: 0 ms
```

Оба окна пересекают 14,4x, поэтому приходит page. Notification сообщает user impact, version/region, долю canary, owner checkout, ссылку на rollback runbook и recovery condition: 5m burn ниже 1x при восстановленном canary traffic.

On-call останавливает rollout и возвращает canary на `v41`. Через пять минут короткое окно падает ниже threshold, page resolves; часовой график ещё хранит incident, как и budget spend. Trace exemplar показывает, что `v42` ошибочно классифицировал валидный order как invalid до обращения к DB. CPU panel помогла быстро отвергнуть гипотезу saturation, но page на CPU здесь не сработал бы вовсе.

После incident команда добавляет domain result counter в canary gate и тестирует alert replay. Dashboard сохраняет annotation rollout/rollback и расход бюджета, чтобы следующий review видел причинную последовательность.

## Trade-offs

Symptom-based page даёт высокую точность по impact, но может прийти после первых пострадавших пользователей. Predictive cause alert способен предупредить раньше, цена состоит в ложных срабатываниях и постоянной перекалибровке threshold. Cause становится page только при доказанном lead time и конкретной профилактической реакции.

Большое число panels облегчает редкий ad hoc анализ, но повышает cognitive load во время incident. Маленький overview ускоряет первые минуты, а drill-down сохраняет глубину. Один экран не обязан отвечать на все вопросы последующего расследования.

Aggressive grouping снижает storm, но может скрыть независимые failures. Слабая группировка сохраняет детали и перегружает on-call. Labels выбирают по mitigation domain: один owner и одно действие получают одну notification.

Короткие окна быстрее, шумнее и зависят от sampling. Длинные точнее показывают budget impact, но медленно reset. Multiwindow condition покупает оба свойства ценой более сложных правил и необходимости тестировать их как production code.

## Типичные ошибки

- **Неверное предположение:** каждая красная panel должна page. **Симптом:** on-call получает alerts без пользовательского impact и перестаёт им доверять. **Причина:** dashboard и interrupt имеют разные цели. **Исправление:** page только на срочное действие, остальное оставить context/ticket/report.
- **Неверное предположение:** статический CPU threshold универсален. **Симптом:** alert шумит на здоровом batch или пропускает pool exhaustion при низком CPU. **Причина:** utilization перепутана с saturation и SLO. **Исправление:** измеренный capacity threshold, symptom alert и причинная panel.
- **Неверное предположение:** `for: 1h` заменяет часовое rate window. **Симптом:** краткие повторяющиеся spikes тратят бюджет, но timer каждый раз reset. **Причина:** длительность истинности не равна агрегированному расходу. **Исправление:** считать bad ratio на полном окне и использовать multiwindow burn rate.
- **Неверное предположение:** `no data` означает zero errors. **Симптом:** monitoring outage рисует зелёный SLO. **Причина:** gaps заполнены нулями. **Исправление:** явная missing-data semantics и alert на freshness telemetry path.
- **Неверное предположение:** runbook со списком причин делает alert actionable. **Симптом:** инженер читает документ, но не понимает первый безопасный шаг. **Причина:** evidence и mitigation не привязаны к notification. **Исправление:** scope, current values, recent changes, owner, действие и recovery criterion в первых строках.
- **Неверное предположение:** silencing решает noisy alert. **Симптом:** постоянный silence скрывает настоящий incident. **Причина:** дефект сигнала замаскирован маршрутизацией. **Исправление:** ограниченный silence с expiry, затем исправить query/threshold или удалить alert.

## Когда применять

Service overview создают вместе с первым production SLO, а alerting подключают после проверки SLI и ownership. Для нового сервиса сначала достаточно user-impact page, telemetry-health alert и нескольких доказанных capacity signals. Новые alerts добавляют по реальным failure modes, если они меняют время или качество реакции.

Каждый квартал либо после incident просматривают page volume, false positives, missed incidents, time-to-detect, time-to-mitigate и alerts без действия. Dashboard panels и rules, которыми никто не пользуется, удаляют: observability тоже имеет стоимость и нуждается в ownership.

## Источники

- [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) — Google, Site Reliability Engineering, глава 6, проверено 2026-07-18.
- [Monitoring](https://sre.google/workbook/monitoring/) — Google, The Site Reliability Workbook, глава 4, проверено 2026-07-18.
- [Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/) — Google, The Site Reliability Workbook, глава 5, проверено 2026-07-18.
- [Implementing SLOs](https://sre.google/workbook/implementing-slos/) — Google, The Site Reliability Workbook, глава 2, проверено 2026-07-18.
- [Alertmanager configuration](https://github.com/prometheus/alertmanager/blob/v0.32.1/docs/configuration.md) — репозиторий `prometheus/alertmanager`, tag `v0.32.1`, routing, grouping и inhibition, проверено 2026-07-18.
- [Alertmanager v0.32.1](https://github.com/prometheus/alertmanager/releases/tag/v0.32.1) — репозиторий `prometheus/alertmanager`, release `v0.32.1` от 2026-04-29, проверено 2026-07-18.
