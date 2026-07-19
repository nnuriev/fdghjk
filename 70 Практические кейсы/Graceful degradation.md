---
aliases:
  - Graceful degradation
  - Управляемая деградация
  - Degraded mode
tags:
  - область/reliability-performance-operations
  - тема/отказоустойчивость
статус: проверено
---

# Graceful degradation

## TL;DR

Graceful degradation заранее заменяет полный, дорогой результат на более дешёвый, но корректный пользовательский outcome. Цель не скрыть отказ, а сохранить critical journey и ограничить положительную обратную связь: меньше работы на запрос, короче удержание ресурсов, меньше retries и выше шанс восстановления.

Деградировать можно качество, свежесть, полноту или время выполнения. Нельзя молча ослаблять business, security и durability invariants. Если безопасного упрощённого ответа нет, быстрый явный отказ лучше правдоподобного неверного результата.

## Ментальная модель

У сервиса есть лестница стоимости:

```text
full result -> cheaper partial/stale result -> accept for later -> reject early
```

Каждая ступень имеет отдельный контракт: что пользователь получает, какие гарантии сохранены, какой ресурс экономится и как система вернётся наверх. [[40 Распределённые системы/Load shedding|Load shedding]] уменьшает число принятых запросов; graceful degradation уменьшает стоимость принятого запроса. Часто нужны оба механизма.

## Как устроено

### Критичность определяется до инцидента

Request path раскладывают на обязательное ядро и optional work. Для каждой части фиксируют:

- user/business invariant;
- стоимость CPU, memory, I/O, fan-out и deadline;
- допустимую stale age или неполноту;
- способ сообщить degraded outcome;
- dependency и её failure classifier.

Примеры безопасных режимов: search по меньшему candidate set, timeline без персонального ranking, stale cache с age marker, read-only после потери write authority, durable acceptance с delayed processing. Пример опасной «деградации»: пропустить authorization при недоступном policy service. Это уже нарушение границы безопасности.

### Триггер должен опережать коллапс

Переключение по error rate часто запаздывает. Полезнее локальные saturation signals: in-flight work, runnable workers, pool wait, queue age, memory pressure и остаток deadline. Decision принимается до дорогого fan-out. Если сначала вызвать пять зависимостей, а потом решить вернуть partial response, capacity уже потрачена.

Режим может включаться автоматически с hysteresis и minimum dwell time. Вручную управляемый flag нужен как emergency override, но его состояние, owner и срок должны быть видны. Возврат происходит ступенями: холодный cache и накопленный backlog делают мгновенное включение всех features рискованным.

### Ответ остаётся наблюдаемым

Partial/stale result помечают в protocol или domain state: `partial=true`, `as_of`, `pending`, отдельный status. Метрики разделяют full, degraded, rejected и failed. Иначе availability выглядит высокой, хотя продукт потерял значимую функцию.

Degradation budget связывают с SLO: например, не более 2% ответов в stale-mode за окно и freshness не старше 10 минут. Это не обязательно отдельный SLO, но пользовательский ущерб должен попадать в измерение.

### Dependency failure не должен удерживать критический path

Optional dependency получает короткий deadline, отдельный concurrency budget и [[40 Распределённые системы/Circuit breaker|circuit breaker]]. Fallback обязан быть дешевле основного пути и иметь собственную capacity. Перенаправить весь поток во второй регион или cache без проверки supply означает перенести outage.

## Пример или трассировка

Search API выполняет core retrieval за `8 ms CPU` и optional ranking/enrichment ещё за `6 ms CPU` на запрос. Доступный CPU budget равен `12,5 CPU-s/s`.

При 700 RPS полный путь требует:

```text
700 * (8 + 6) ms = 9,8 CPU-s/s
```

Baseline использует `9,8 / 12,5 = 78,4%` CPU budget и остаётся чуть ниже порога деградации. На spike 900 RPS нужно `12,6 CPU-s/s`, или `100,8%` доступного budget: очередь растёт, p99 превышает client deadline, а retries усиливают поток.

При CPU > 80% admission отключает enrichment до fan-out и ищет меньше candidates. Стоимость падает до `8 ms`:

```text
900 * 8 ms = 7,2 CPU-s/s
```

После переключения CPU demand падает до `7,2 / 12,5 = 57,6%`, поэтому очередь получает запас на drain.

Ответ содержит `quality=degraded`, а ranking freshness и доля degraded requests видны на dashboard. Critical search остаётся корректным, хотя качество ниже. Если поток превысит capacity и этого режима, low-priority requests получают быстрый `503` с `Retry-After`; система не создаёт бесконечную очередь.

После спада degraded mode держится ещё две минуты, пока queue age и CPU не вернутся ниже нижнего порога. Наблюдаемый результат: полезный throughput сохраняется, recovery не запускает новый spike, а потеря качества измеряется отдельно от hard errors.

## Trade-offs

Stale cache дешёв и доступен, но может нарушить решение пользователя, если возраст не виден. Partial response сохраняет interaction, однако усложняет API и клиентов. Async acceptance сглаживает пик, но переносит SLO с response latency на completion age и требует durable queue.

Feature flag прост в аварии, но груб: все пользователи теряют функцию. Per-request criticality точнее использует capacity, зато требует trustworthy classification и защиты от завышения приоритета. Static fallback надёжен только если регулярно выполняется; редко используемый код склонен ломаться именно во время outage.

Деградация иногда маскирует хронический capacity deficit. Поэтому time in degraded mode и причина переключения должны создавать action: расширить capacity, исправить cost или пересмотреть product contract.

## Типичные ошибки

- **Неверное предположение:** любой partial result лучше ошибки. **Симптом:** пользователь принимает решение по неполным данным. **Причина:** деградирован бизнес-инвариант без маркировки. **Исправление:** явный contract и fail closed для недопустимых случаев.
- **Неверное предположение:** fallback бесплатен. **Симптом:** после отказа primary падает cache или второй регион. **Причина:** весь поток переведён без отдельной capacity. **Исправление:** bounded fallback и собственный admission budget.
- **Неверное предположение:** режим можно включить после saturation. **Симптом:** feature выключена, но очередь и pools всё ещё заполнены. **Причина:** решение принято после дорогой работы. **Исправление:** ранний overload signal и admission перед fan-out.
- **Неверное предположение:** восстановление dependency разрешает мгновенный full mode. **Симптом:** cold cache и backlog снова перегружают её. **Причина:** нет hysteresis и ramp. **Исправление:** ступенчатое возвращение с gate по saturation.
- **Неверное предположение:** degraded success равен обычному success. **Симптом:** SLO зелёный при систематически урезанном продукте. **Причина:** outcomes склеены одной метрикой. **Исправление:** отдельные labels/SLI и degradation budget.

## Когда применять

Graceful degradation полезна, когда есть дешёвый outcome, сохраняющий critical invariant: read-heavy продукты, ranking/enrichment, search, projections и asynchronous workflows. Для ledger correctness, authorization, privacy и уникальности чаще нужен fail closed или delayed outcome, а не приближённый ответ.

Режим считается готовым после проверки под overload и dependency blackhole. Нужно доказать три вещи: он действительно дешевле, не держит отказавший ресурс до длинного deadline и возвращается без повторной перегрузки.

## Источники

- [Handling Overload](https://sre.google/sre-book/handling-overload/) — Google, Site Reliability Engineering, глава 21, degraded responses и overload handling, проверено 2026-07-18.
- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering, глава 22, load shedding, graceful degradation и recovery, проверено 2026-07-18.
- [Production Services Best Practices](https://sre.google/sre-book/service-best-practices/) — Google, Site Reliability Engineering, production checklist и degraded results, проверено 2026-07-18.
