---
aliases:
  - Thundering herd problem
  - Стадный эффект
  - Синхронный всплеск запросов
tags:
  - область/reliability-performance-operations
  - тема/устойчивость
  - механизм/синхронизация-нагрузки
статус: проверено
---

# Thundering herd

## TL;DR

**Thundering herd** возникает, когда одно событие одновременно будит множество клиентов или workers, а полезную работу способен выполнить лишь один или небольшой bounded-набор участников. Остальные конкурируют за тот же cache key, lock, connection, leader или backend capacity. Средний трафик при этом может выглядеть нормальным: систему ломает короткий коррелированный пик.

Лечение разрывает синхронность и подавляет дубликаты. Для одинаковой работы применяют request coalescing, для cache refresh — stale serving и разнесённые TTL, для периодических действий и reconnect — jitter, для дорогой зависимости — bounded concurrency и load shedding. Масштабирование помогает только тогда, когда общий ресурс действительно масштабируется и успевает подняться до всплеска.

## Область применимости

Заметка описывает общий production-механизм. Cache stampede — его частный случай на miss/expiry path. [[40 Распределённые системы/Retry storms и cascading failures|Retry storm]] отличается положительной обратной связью: ошибки порождают новые попытки и увеличивают число работ. [[30 Данные/Hot partitions и hot keys|Hot key]] описывает skew по ключу и может оставаться горячим постоянно, без синхронного события.

Примеры сверены с `golang.org/x/sync/singleflight` v0.22.0, RFC 5861 и Linux man-pages 6.18; проверено 2026-07-18. Конкретные TTL, concurrency limits и допустимость stale-ответа зависят от бизнес-контракта.

## Ментальная модель

Пусть событие `E` одновременно активирует `N` участников, а защищаемая зависимость выдерживает `C` конкурентных операций. Если каждый участник самостоятельно выполняет одну и ту же работу, мгновенный fan-out равен `N`, даже когда полезный результат один:

```text
one expiry/recovery/event -> N contenders -> one scarce resource
                                      \-> N-1 duplicate operations
```

Инвариант защиты звучит так: на одну логическую причину одновременно выполняется не больше доказанного числа дорогих операций. Остальные получают stale result, ждут общий bounded fill, отклоняются или начинают работу в разное время.

Jitter уменьшает корреляцию во времени, но не сокращает суммарное число действий. Coalescing сокращает дубликаты, но без deadline способен собрать множество callers за одним зависшим лидером. Поэтому эти приёмы дополняют друг друга.

## Как устроено

### Откуда берётся синхронность

Типичные общие триггеры:

- одинаковый TTL популярного cache entry на всех replicas;
- восстановление DNS, базы или сети, после которого тысячи clients одновременно reconnect/retry;
- cron, lease renewal, credential refresh или polling на круглой границе времени;
- restart большого числа replicas с пустыми caches и ленивой инициализацией;
- освобождение lock или готовность file descriptor, на которые ждут многие workers;
- feature flag или configuration update, одновременно переключающий весь fleet на дорогой path.

Усреднение по минуте скрывает механизм. Нужны peak rate на коротком окне, concurrent in-flight, число contenders/waiters, source calls на один logical key и распределение времени срабатывания по replicas.

### Подавление одинаковой работы

Request coalescing, или single-flight, назначает одного исполнителя для `(operation, key, scope)`. Остальные callers ждут тот же результат. В `singleflight.Group` v0.22.0 scope ограничен процессом: двадцать replicas по-прежнему способны одновременно сделать двадцать fills одного ключа. Межпроцессный coalescing требует общего cache/origin shield, lease или другого coordination protocol.

Ключ coalescing должен включать всё, что меняет результат и права доступа: tenant, auth scope, locale, version. Слишком широкий ключ смешивает разные запросы; слишком узкий не схлопывает дубликаты. Ошибка лидера тоже обычно разделяется между waiters, поэтому общий fill получает deadline, а stale или retry path не должен снова создать herd.

### Stale serving и два срока жизни

Для данных, где допустима ограниченная устарелость, soft TTL отмечает время refresh, а hard TTL — последний момент безопасной выдачи. Первый caller после soft TTL начинает refresh; остальные продолжают получать старую копию. RFC 5861 задаёт HTTP-директиву `stale-while-revalidate` с той же идеей.

Такой путь нельзя переносить на authorization decision, отозванный credential или другой объект, где старая версия нарушает безопасность. Контракт stale-окна задаётся по классу данных. Подробные cache trade-offs разобраны в [[50 Проектирование систем/Cache и CDN|заметке о cache и CDN]].

### Разнесение событий

Jitter добавляют к TTL, retry delay, polling interval, lease renewal и scheduled job. Случайность выбирают один раз на период либо детерминированно seed-ят identity экземпляра, чтобы fleet разошёлся по времени, а поведение можно было воспроизвести. Независимый jitter на каждом коротком цикле способен создавать лишний drift; отсутствие jitter сохраняет синхронные волны.

Rollout и recovery тоже разносит progressive admission: сначала малый трафик прогревает caches и pools, затем доля растёт по наблюдаемой capacity. Одновременный restart всех replicas часто уменьшает полезную capacity именно в момент холодного старта.

### Ограничение ущерба

Coalescing не защищает от множества разных ключей. Перед origin остаётся общий и per-key concurrency limit, bounded queue и [[40 Распределённые системы/Load shedding|load shedding]]. Caller, чей deadline истечёт до получения слота, не должен попадать в очередь.

На уровне ядра тот же принцип виден в `epoll`: для нескольких threads, ожидающих один edge-triggered file descriptor в одном epoll instance, пробуждается один waiter. Это локальная оптимизация пробуждений, а не универсальная защита application-level dependencies.

## Пример или трассировка

Двадцать API replicas держат локальную копию каталога. У записи одинаковый TTL. На каждой replica в момент expiry одновременно приходит 50 запросов, загрузка origin занимает 200 ms, а origin устойчиво выдерживает 40 таких reads/s.

1. Без защиты 1 000 cache misses почти одновременно идут в origin. Его очередь растёт, fill выходит за client deadline, а повторные запросы превращают herd в retry storm.
2. Process-local single-flight оставляет по одному fill на replica: origin получает 20 concurrent reads вместо 1 000. Это уже лучше, но все 20 по-прежнему начинаются в одном 200-ms окне.
3. Shared cache/origin shield допускает один refresh для ключа. Остальные replicas получают stale copy в разрешённом окне; TTL следующего refresh получает jitter.
4. Общий origin concurrency limit не даёт множеству разных expired keys занять больше выделенной capacity.

Наблюдаемый результат: отношение `origin reads / logical catalog requests` на событии expiry падает с `1 000/1 000` до `1/1 000`; число waiters остаётся bounded их deadlines, origin queue не растёт, а stale-serve rate кратко поднимается и затем возвращается к baseline.

## Trade-offs

| Приём | Что убирает | Цена и граница |
| --- | --- | --- |
| Jitter | синхронный пик | не уменьшает общий объём; усложняет воспроизводимость |
| Process-local single-flight | дубликаты внутри replica | не координирует fleet; общий лидер задерживает waiters |
| Distributed lease/shield | дубликаты между replicas | coordination dependency, fencing и recovery владельца |
| Stale-while-revalidate | ожидание fill и origin load | устаревший ответ допустим не для всех данных |
| Pre-warm/progressive traffic | cold-start herd | дополнительная capacity и более медленный rollout |
| Concurrency limit/shedding | защищает конечный origin | часть запросов ждёт или быстро отказывает |

Простое увеличение TTL реже запускает refresh, но увеличивает staleness и не устраняет корреляцию следующего expiry. Дополнительные origin replicas помогут при распределяемых reads; один non-commutative hot write или global lock они не распараллелят.

## Типичные ошибки

- **Неверное предположение:** средний QPS ниже capacity, значит overload невозможен. **Симптом:** короткие пики latency и origin QPS повторяются на границах TTL или минут. **Причина:** коррелированная нагрузка скрыта большим окном агрегации. **Исправление:** смотреть peak/concurrency на коротком окне и jitter-ить общий триггер.
- **Неверное предположение:** local single-flight решил проблему fleet. **Симптом:** число origin fills равно числу replicas. **Причина:** coordinator живёт внутри процесса. **Исправление:** shared cache/shield либо доказанный origin limit на сумму replicas.
- **Неверное предположение:** distributed lock сам по себе безопасно coalesce-ит refresh. **Симптом:** после pause или network partition два владельца записывают результат в неверном порядке. **Причина:** lease без [[40 Распределённые системы/Leases, distributed locks и fencing tokens|fencing token]] не запрещает старому владельцу завершить работу. **Исправление:** fencing/versioned publish и idempotent commit либо stale-serving без единоличной записи.
- **Неверное предположение:** restart очистит перегрузку. **Симптом:** после массового restart origin становится ещё хуже. **Причина:** исчезли тёплые caches и connections, а все replicas стартовали вместе. **Исправление:** сначала ограничить вход, затем restart малыми batches и прогреть critical path.
- **Неверное предположение:** stale допустим для любого cache entry. **Симптом:** пользователь получает уже отозванное право или удалённый объект. **Причина:** availability-приём нарушил security/correctness invariant. **Исправление:** классифицировать данные и оставлять fail-closed path там, где старая версия опасна.

## Когда применять

Ищите herd, когда пики совпадают с expiry, recovery, deploy, restart или периодической границей, а множество одинаковых операций конкурирует за один ресурс. Во время инцидента сначала уменьшите fan-out: временно выдавайте безопасную stale-копию, ограничьте concurrency к origin, остановите синхронные jobs/retries и прогревайте capacity постепенно. Перед массовым restart сохраните короткий trace и метрики источника, иначе главный триггер исчезнет вместе с процессами.

Профилактический тест должен одновременно инвалидировать популярный ключ, вернуть dependency после паузы и поднять группу холодных replicas. Проверяйте peak origin QPS, число fills на logical key, waiters, stale rate, rejected work и время стабилизации.

## Источники

- [Minimizing correlated failures in distributed systems](https://aws.amazon.com/builders-library/minimizing-correlated-failures-in-distributed-systems/) — Amazon Web Services, Amazon Builders’ Library, проверено 2026-07-18.
- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering book, 2016, проверено 2026-07-18.
- [Package singleflight](https://pkg.go.dev/golang.org/x/sync@v0.22.0/singleflight) — Go project, `golang.org/x/sync` v0.22.0, проверено 2026-07-18.
- [singleflight.go](https://github.com/golang/sync/blob/v0.22.0/singleflight/singleflight.go) — репозиторий `golang/sync`, tag `v0.22.0`, проверено 2026-07-18.
- [RFC 5861: HTTP Cache-Control Extensions for Stale Content](https://www.rfc-editor.org/rfc/rfc5861.html) — IETF, RFC 5861, май 2010, проверено 2026-07-18.
- [epoll(7)](https://man7.org/linux/man-pages/man7/epoll.7.html) — Linux man-pages project, man-pages 6.18, проверено 2026-07-18.
