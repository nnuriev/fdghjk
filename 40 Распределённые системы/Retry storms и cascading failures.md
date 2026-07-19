---
aliases:
  - Retry storms
  - Cascading failures
  - Шторм повторных запросов
  - Каскадные отказы
tags:
  - область/распределённые-системы
  - тема/устойчивость
  - механизм/повторы
статус: проверено
---

# Retry storms и cascading failures

## TL;DR

Retry полезен, когда отдельная попытка потерялась из-за краткого сбоя. Но под перегрузкой повтор создаёт новую работу именно тогда, когда системе меньше всего хватает capacity. Возникает положительная обратная связь: latency растёт → deadlines истекают → клиенты повторяют → offered load растёт → очереди и latency растут ещё сильнее. Так локальная деградация превращается в **retry storm** и затем в **cascading failure** зависимых сервисов.

Защита строится не одним exponential backoff. Нужны end-to-end deadline, одна ответственная точка retry, ограниченный retry budget, jitter, bounded concurrency, admission control, load shedding, circuit breaker и проверенная идемпотентность. Цель — сохранить полезную пропускную способность (**goodput**) и дать системе восстановиться, а не максимизировать число попыток.

## Ментальная модель

Пусть нормальный входной поток — `λ`, доступная скорость обработки — `μ`. Пока `λ < μ`, очередь стабилизируется. После потери части capacity получаем `λ > μ`, backlog растёт. Если каждый timeout порождает ещё `r` попыток, фактический поток становится больше исходного:

```text
capacity loss -> queue -> latency -> timeout -> retry -> more queue
      ^                                               |
      +-----------------------------------------------+
```

Retry не создаёт capacity и не отменяет уже выполняющийся запрос. При коротком client timeout оригинал может продолжать занимать CPU, connection и lock, пока его дубль уже пришёл. Метрика request rate растёт, но completed useful operations — goodput — падает.

Каскад начинается, когда переполненный B удерживает ресурсы A; A перестаёт отвечать C; C повторяет и расширяет перегрузку. Общий thread pool, connection pool или синхронная fan-out связь передают failure boundary дальше.

## Как устроено

### Мультипликативное усиление

Если пять слоёв независимо делают до трёх попыток, один пользовательский запрос способен породить `3^5 = 243` вызова к нижнему слою. Этот пример приводит AWS Builders’ Library как довод в пользу retry только на одном уровне стека. Даже если часть вызовов завершится раньше, верхние слои не знают об этом после timeout и продолжают нагрузку.

Fan-out усиливает эффект дополнительно: запрос к десяти shards с retry каждого shard создаёт другую форму взрыва. Hedged requests тоже являются дополнительной работой; они полезны только при контролируемом tail и свободном capacity, а не как безусловный retry.

### Синхронизация клиентов

Одинаковый timeout и deterministic backoff создают волны. Тысячи клиентов замечают сбой одновременно, ждут `1 s`, затем одновременно атакуют recovering instance; следующая волна приходит через `2 s`. Полный или decorrelated jitter размазывает попытки по времени. Но jitter снижает синхронизацию, а не объём: retry budget всё равно нужен.

Детали алгоритмов backoff разобраны в [[40 Распределённые системы/Retry, exponential backoff и jitter|отдельной заметке о retry и jitter]].

### Deadlines и cancellation

Каждый hop получает оставшийся end-to-end budget, а не полный локальный timeout. Если upstream уже не сможет использовать ответ, downstream должен прекратить отменяемую работу. Иначе система тратит scarce capacity на «зомби»-запросы. Эта связь раскрыта в [[20 Бэкенд/Дедлайны запросов и распространение отмены|заметке о дедлайнах и отмене]].

Cancellation не гарантирует отмену необратимого effect: запрос мог уже commit. Поэтому retries безопасны только для идемпотентной операции или со стабильным operation ID.

### Retry budget и admission control

Retry budget ограничивает долю дополнительных попыток относительно успешного трафика или общего ресурса. Когда budget исчерпан, клиент возвращает ошибку вместо усиления аварии. Ограничение должно жить рядом с общей точкой retry, иначе каждый process считает свой малый budget независимо.

На стороне сервера bounded queue и concurrency limiter не позволяют latency расти без границы. Когда работа уже не уложится в deadline, [[40 Распределённые системы/Load shedding|load shedding]] быстро отклоняет её. Это болезненно, но сохраняет capacity для запросов, которые ещё могут завершиться.

### Circuit breaker и изоляция

[[40 Распределённые системы/Circuit breaker|Circuit breaker]] временно останавливает вызовы к явно деградировавшей зависимости и допускает ограниченные probes. Он уменьшает бесполезную нагрузку, но не заменяет лимит concurrency: до открытия breaker всплеск уже может исчерпать pool.

Отдельные pools и bulkheads не дают медленной optional dependency занять все workers критического пути. Fallback должен быть дешевле исходной операции; fallback, который сам обращается к той же перегруженной базе, лишь меняет форму каскада.

## Пример или трассировка

API A имеет 200 workers и вызывает B. Обычно B отвечает за 40 ms; timeout A — 100 ms, две дополнительные попытки без jitter.

1. У B теряется половина capacity. Очередь поднимает latency до 120 ms, хотя requests всё ещё завершаются.
2. На 100 ms A объявляет timeout и запускает второй вызов. Первый продолжает работу в B.
3. Оба вызова занимают connections; B видит почти двойной поток, latency растёт до 300 ms. A запускает третьи попытки.
4. Все 200 workers A ждут B. Health endpoint ещё отвечает, но пользовательские запросы к A не принимаются; upstream C начинает собственные retries.
5. После добавления одной точки retry с budget 10%, remaining-deadline propagation, concurrency limit 80 и early shedding B получает bounded load. Часть запросов быстро получает `503/Retry-After`, зато очередь сокращается и goodput восстанавливается.

Наблюдаемый признак исправления — не нулевое число ошибок, а ограниченные in-flight/backlog, рост доли быстрых отказов во время перегрузки и восстановление успешных completions без повторных волн.

## Trade-offs

Больше retries повышает шанс пережить независимую transient failure, но ухудшает overload и увеличивает tail latency. Короткий timeout быстрее освобождает caller, однако рождает ложные повторы, если не основан на реальном latency budget. Длинный timeout уменьшает повторы, но дольше удерживает ресурсы.

Backoff уменьшает частоту попыток одного клиента; admission control защищает сервер от суммы всех клиентов. Breaker экономит работу при устойчивом отказе; load shedding защищает capacity при перегрузке. Эти механизмы работают слоями и решают разные feedback loops.

Жёсткий concurrency limit может недоиспользовать внезапно выросшую capacity. Adaptive limiter лучше следует latency, но его controller сам требует устойчивых сигналов и ограничений, чтобы не осциллировать.

## Типичные ошибки

- **Неверное предположение:** retry всегда повышает надёжность. **Симптом:** после небольшой деградации request rate кратно растёт, а success rate падает. **Причина:** failure вызвана overload, а повторы добавили работу. **Исправление:** retry только для классифицированных transient failures и в рамках общего budget.
- **Неверное предположение:** exponential backoff достаточно. **Симптом:** recovering service получает синхронные волны. **Причина:** нет jitter и admission control. **Исправление:** randomized delay плюс bounded in-flight и server-side shedding.
- **Неверное предположение:** каждый слой вправе retry. **Симптом:** нижняя база видит сотни запросов на одну операцию. **Причина:** мультипликативное усиление. **Исправление:** выбрать один слой, который владеет retry и видит end-to-end deadline.
- **Неверное предположение:** timeout отменил effect. **Симптом:** повтор создаёт две записи или два платежа. **Причина:** оригинал commit после ответа caller. **Исправление:** idempotency key, status lookup и reconciliation неопределённых исходов.

## Когда применять

Retry нужен для редких transient network errors, leader transitions и rate limits с явным `Retry-After`, если operation безопасна для повтора и остаётся время в deadline. Не retry permanent validation errors, overload без backoff/budget и операции с неопределённым необратимым эффектом.

В production наблюдают original requests и attempts раздельно, retry amplification, in-flight, queue age, deadline exceeded, shed rate и goodput. Runbook должен уметь временно уменьшить retries быстрее, чем масштабируется перегруженная зависимость.

## Источники

- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering book, 2016, проверено 2026-07-18.
- [Handling Overload](https://sre.google/sre-book/handling-overload/) — Google, Site Reliability Engineering book, 2016, проверено 2026-07-18.
- [Timeouts, retries, and backoff with jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/) — Amazon Web Services, Amazon Builders’ Library, проверено 2026-07-18.
- [RFC 9110, § 10.2.3 Retry-After](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
