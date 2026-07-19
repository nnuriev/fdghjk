---
aliases:
  - Circuit breaker
  - Автоматический выключатель вызовов
tags:
  - область/распределённые-системы
  - тема/устойчивость
статус: проверено
---

# Circuit breaker

## TL;DR

Circuit breaker запоминает недавний результат вызовов зависимости и временно запрещает новые, когда вероятность успеха слишком мала. Fail-fast освобождает threads, connections и deadline budget, а ограниченное число probes проверяет восстановление.

Breaker не заменяет timeout, bounded concurrency и retry policy. Он реагирует только на завершившиеся наблюдения; без timeout зависшие вызовы не пополняют статистику, а без bulkhead успевают исчерпать ресурсы до открытия. Вдобавок термин неоднозначен: библиотечный breaker обычно работает как `CLOSED → OPEN → HALF_OPEN`, тогда как Envoy называет circuit breakers лимиты connections, pending requests, active requests и retries.

## Область применимости

- State-based модель сверена с Resilience4j 2.4.0, последним стабильным релизом на 2026-07-18. Ветка 3.x ещё не выпущена и не задаёт версионную область заметки.
- Resource-limit модель соответствует Envoy 1.38.3.
- Основной сценарий: синхронный вызов удалённой зависимости с наблюдаемым success/failure outcome.
- Вне scope: health checking отдельных endpoints, service discovery, consensus и аварийное переключение данных.

## Ментальная модель

Breaker — локальный автомат допуска. В `CLOSED` он пропускает вызовы и собирает окно наблюдений. В `OPEN` новые вызовы не доходят до зависимости и сразу получают controlled failure. После паузы `HALF_OPEN` пропускает небольшое число probes: успех возвращает нормальный трафик, неуспех снова закрывает доступ.

Важна не сама диаграмма состояний, а граница измерения. Breaker для всего `payments.example` смешает разные методы, tenants и endpoints. Ошибка одной тяжёлой операции способна отключить здоровое чтение. Поэтому instance разделяют там, где различаются failure domain, стоимость и политика fallback.

## Как устроено

### Окно и переходы состояний

Count-based sliding window хранит последние `N` outcomes. Time-based окно агрегирует вызовы за последние интервалы времени. Решение об открытии обычно использует:

- minimum number of calls, чтобы не судить по двум случайным ошибкам;
- failure rate threshold;
- slow-call threshold и границу, после которой вызов считается slow;
- open wait duration;
- разрешённое число HALF_OPEN probes.

Параметры образуют одну политику. Малое окно быстро реагирует, но шумит. Большое устойчивее к случайности, зато поздно замечает резкий отказ. Slow-call threshold полезен до полного падения: зависимость может ещё возвращать `200`, удерживая все workers дольше допустимого.

Outcome classifier обязан отражать семантику. Validation error клиента не говорит о здоровье downstream и обычно не должна открывать breaker. Timeout, connection failure и выбранные `5xx` говорят. Даже здесь есть исключения: локальный deadline, исчерпанный в очереди до вызова, нельзя приписывать зависимости.

### HALF_OPEN и защита восстановления

После wait duration нельзя сразу возвращать весь трафик. HALF_OPEN даёт ограниченное число probes, иначе все клиенты одновременно ударят по только что восстановленному серверу. Probes тоже имеют deadline и concurrency bound.

Распределённые callers держат локальные breaker states. Это снижает координацию и позволяет каждому быстро fail-fast, но сотня instances создаст сотню независимых probe cohorts. Централизовать state дорого и опасно: общий store входит в критический путь. На практике уменьшают herd через jitter перехода, ограничение probes и mesh-level admission.

### Resource circuit breakers в Envoy

Envoy ограничивает ресурсы upstream cluster по priority: maximum connections, pending requests, parallel requests, active retries и connection pools. При превышении request быстро отклоняется; для HTTP Envoy может добавить `x-envoy-overloaded`.

Это ближе к bulkhead и bounded admission, чем к `OPEN/HALF_OPEN`. Счётчики разделяются worker threads и обновляются с eventual consistency, поэтому короткая race способна немного превысить настроенный предел. Инвариант здесь другой: не «перестать вызывать нездоровую зависимость», а «не позволить одному cluster исчерпать ресурсы proxy».

Retry breaker особенно важен вместе с [[40 Распределённые системы/Retry, exponential backoff и jitter|retry policy]]: обычный трафик может быть допустим, а добавочная retry load уже опасна. Retry budget лучше фиксированного малого числа, когда нормальная concurrency заметно меняется.

### Fallback и наблюдаемость

Fallback должен быть дешевле и надёжнее основного пути. Переключение всех запросов на одну БД или cache способно просто перенести перегрузку. Stale response допустим только при явно описанной семантике; успешный технический fallback не должен маскировать неверный бизнес-результат.

Метрики включают state transitions, rejected calls, failure/slow rates, HALF_OPEN outcomes, latency вызова и результат fallback. Иначе открытый breaker выглядит как внезапное улучшение latency, хотя полезные ответы исчезли.

## Пример или трассировка

Для `inventory.reserve` задана иллюстративная политика: окно 20 вызовов, minimum 10, failure threshold 50%, OPEN 10 s, HALF_OPEN не более 5 probes. Каждый вызов ограничен timeout и bulkhead.

1. Из первых 10 завершившихся вызовов 6 получают timeout. Failure rate равен 60%, breaker переходит `CLOSED → OPEN`.
2. Следующие 300 запросов за 10 секунд не занимают connection pool зависимости. Они сразу получают контролируемую ошибку; часть заказов переходит в допустимый pending state.
3. После 10 секунд только 5 вызовов проходят в HALF_OPEN. Остальные продолжают fail-fast.
4. Четыре probes успешны, один падает. Политика оценивает их окно; если threshold не превышен, breaker возвращается в CLOSED. При новом превышении он снова откроется.

Параллельно Envoy держит `max_pending_requests=35`. Даже до статистического открытия 36-й запрос не накапливается в proxy queue. Два механизма защищают разные границы.

## Trade-offs

Быстрое открытие сокращает wasted work и tail latency, но повышает false positives при коротком сетевом шуме. Медленное даёт зависимости больше шансов, однако позволяет отказу дольше удерживать ресурсы.

Library-level breaker видит доменный метод и точнее классифицирует ошибки. Mesh/proxy проще развернуть единообразно и умеет ограничивать transport resources, но хуже понимает бизнес-результат. Нередко нужны оба, если границы ответственности не дублируют друг друга.

Локальное state доступно без координации, но instances расходятся во мнении о здоровье. Общий state даёт единое решение ценой latency, нового dependency и большого blast radius ошибочной классификации.

## Типичные ошибки

### Breaker без timeout

- **Неверное предположение:** медленные зависшие вызовы сами откроют breaker.
- **Симптом:** pool и workers заканчиваются, failure rate остаётся низким.
- **Причина:** outcome ещё не завершён и не попал в окно.
- **Исправление:** сначала bounded deadline и concurrency, затем breaker.

### Все ошибки считаются отказом зависимости

- **Неверное предположение:** любой non-success доказывает нездоровье upstream.
- **Симптом:** поток плохих клиентских данных отключает здоровый сервис.
- **Причина:** classifier смешивает validation, local cancellation и upstream failure.
- **Исправление:** явно перечислить record/ignore outcomes и тестировать их.

### HALF_OPEN возвращает полный трафик

- **Неверное предположение:** истёкший timer означает восстановление.
- **Симптом:** только поднявшийся downstream снова мгновенно падает.
- **Причина:** нет ограниченных probes и плавного допуска.
- **Исправление:** cap HALF_OPEN calls, jitter и наблюдение за recovery.

### Fallback перегружает соседнюю систему

- **Неверное предположение:** запасной путь имеет бесконечную capacity.
- **Симптом:** после открытия breaker падает cache или второй region.
- **Причина:** весь поток синхронно перенаправлен без отдельного admission control.
- **Исправление:** capacity plan, bounded fallback и [[40 Распределённые системы/Load shedding|load shedding]].

## Когда применять

State-based breaker полезен для повторяющихся вызовов зависимости, у которой бывают достаточно длительные коррелированные отказы. Для редкого вызова статистика почти бессмысленна; timeout и явная ошибка проще.

Resource breakers нужны на границах с конечными pools и queues независимо от статистики ошибок. Перед включением фиксируют failure classifier, scope instance, переходы, fallback и метрики. Иначе breaker создаёт ещё одно состояние, которое трудно объяснить во время инцидента.

## Источники

- [Circuit Breaking](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/upstream/circuit_breaking) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Circuit breakers](https://www.envoyproxy.io/docs/envoy/v1.38.3/configuration/upstream/cluster_manager/cluster_circuit_breakers) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Circuit Breaker configuration proto](https://www.envoyproxy.io/docs/envoy/v1.38.3/api-v3/config/cluster/v3/circuit_breaker.proto.html) — Envoy Proxy, API v3 в версии 1.38.3, проверено 2026-07-18.
- [Release v2.4.0](https://github.com/resilience4j/resilience4j/releases/tag/v2.4.0) — resilience4j/resilience4j, tag `v2.4.0`, опубликован 2026-03-14, проверено 2026-07-18.
- [CircuitBreakerStateMachine.java](https://github.com/resilience4j/resilience4j/blob/v2.4.0/resilience4j-circuitbreaker/src/main/java/io/github/resilience4j/circuitbreaker/internal/CircuitBreakerStateMachine.java) — resilience4j/resilience4j, tag `v2.4.0`, проверено 2026-07-18.
