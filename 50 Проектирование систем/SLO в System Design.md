---
aliases:
  - SLO
  - Availability latency durability consistency SLO
  - SLI SLO SLA
tags:
  - область/проектирование-систем
  - тема/slo
статус: проверено
---

# SLO в System Design

## TL;DR

Service level indicator (SLI) измеряет пользовательски значимое поведение, service level objective (SLO) задаёт target на окне, а service level agreement (SLA) добавляет последствия нарушения. В System Design полезно отдельно договориться об availability, latency, durability и consistency: эти свойства связаны, но не заменяют друг друга.

Availability считают по доле полезных операций, latency — как распределение для заданного класса запросов, durability — как риск необратимой утраты подтверждённых данных, consistency — как семантический контракт наблюдаемых версий. Последнюю нельзя честно свести к «99,9% consistency» без определения, какое чтение считается корректным и насколько допустимо отставание.

## Ментальная модель

SLO — это тестируемая граница продукта, а не описание средней работы инфраструктуры.

```text
user journey -> good event definition -> SLI -> target + window -> error budget
```

Если пользователь не может прочитать сообщение из-за stale authorization cache, внутренние метрики всех серверов могут быть зелёными, но user-visible availability нарушена. Поэтому measurement point и population входят в контракт.

## Как устроено

### Полная формула SLI

Для request-based availability:

```text
SLI = good valid events / all valid events
```

Нужно определить:

- событие и точку измерения: client, edge или service;
- population: endpoint, tenant, регион, payload class;
- что считается good;
- какие запросы исключаются из знаменателя;
- окно и правила агрегации.

Time-based uptime хуже описывает частичные отказы. Если один shard обслуживает половину запросов, «процесс работал весь час» не означает доступность сервиса.

### Availability

Availability отвечает на вопрос, получена ли полезная операция в контрактный срок. Для API это обычно доля корректных запросов с разрешённым исходом. Не каждый `4xx` является отказом сервиса, а `200` с пустым либо stale критичным результатом способен быть плохим событием.

Error budget равен `1 - SLO`. Для 99,95% на 30-дневном окне:

```text
30 * 24 * 60 = 43 200 минут
43 200 * 0,0005 = 21,6 минуты эквивалентной полной недоступности
```

При request-based SLI тот же budget расходуется плохими операциями, а не только wall-clock outage.

Последовательные обязательные зависимости связывают availability. При независимых отказах два компонента по 99,9% дают приблизительно `0,999 * 0,999 = 99,8001%` для пути. Это только модель: общая сеть, deploy или control plane создают коррелированные отказы, и простое умножение становится оптимистичным.

### Latency

Среднее скрывает хвост. Указывайте percentile, границу измерения и payload. Например: «99% successful `GET /feed` с limit ≤ 50 завершаются на edge не дольше 250 мс за rolling 28 days».

Percentile нельзя складывать как обычные числа. `p99(A) + p99(B)` не гарантирует p99 всей цепочки, а fan-out к 20 shards повышает шанс встретить медленный ответ. Для критического пути нужен end-to-end SLI и отдельные latency budgets зависимостей.

Timeout должен быть немного шире budget конкретной зависимости и уже родительского deadline. Иначе caller ждёт результат, который уже бесполезен, а повторы умножают overload.

### Durability

Durability отвечает, сохранится ли acknowledged state после ожидаемых отказов и на длинном горизонте. Репликация защищает от части hardware failures, но не от ошибочного delete, повреждения, багов приложения и компрометации credentials. Поэтому контракт включает:

- точку acknowledgment и число durable failure domains до ответа;
- RPO для отказа узла, зоны и региона;
- backup isolation, retention и restore test;
- обнаружение скрытого повреждения данных, checksums и repair;
- RTO и владельца процесса восстановления.

[[30 Данные/Durability и fsync|`fsync` и WAL]] объясняют локальный commit, а [[40 Распределённые системы/RPO и RTO|RPO/RTO]] — границу disaster recovery. Высокая read availability не доказывает durability: система может быстро отдавать уже повреждённые данные.

### Consistency

Consistency задаёт, какие версии и порядок операций разрешено наблюдать. На интервью полезнее назвать session guarantee или invariant, чем ограничиться словами strong/eventual:

- read-your-writes для автора;
- monotonic reads внутри session;
- единый порядок сообщений внутри conversation;
- linearizable conditional update для остатка;
- bounded staleness не больше 5 секунд для каталога.

Модели подробно сопоставлены в [[40 Распределённые системы/Strong, eventual, causal и session consistency|заметке о consistency]]. Если stale read приводит только к повторному refresh, можно купить availability и latency eventual replica. Если он допускает второй capture платежа, нужен другой атомарный invariant.

### Composite SLO и классы workload

Не смешивайте online serving, batch и data freshness в один процент. У них разные good events: request success, завершённая work unit и возраст materialized view. Небольшой набор SLO проще связывает пользовательский ущерб с архитектурой и алертами.

## Сквозной пример: лента

Пусть лента имеет три контракта:

1. 99,95% валидных reads возвращают ответ за 28 дней;
2. p99 latency для первых 50 элементов ≤ 300 мс;
3. 99,9% обычных публикаций появляются у подписчика за 5 секунд, собственная публикация видна автору сразу.

Write API сохраняет пост и outbox event в одном региональном commit. Автор читает source of truth или overlay своего recent write, поэтому получает read-your-writes. Fan-out consumers обновляют materialized timelines асинхронно; freshness SLI измеряет разницу между commit time и появлением ID в timeline. При lag read path может перейти к fan-out-on-read для затронутого автора, сохранив availability ценой latency.

Если interviewer меняет freshness на 100 мс globally, текущая async модель больше не проходит: понадобится иной placement, больше precomputed fan-out capacity либо ослабление scope для celebrities. SLO сделал конфликт видимым.

## Trade-offs

Более высокий availability target требует redundancy и уменьшает окно безопасных изменений. Разница между 99,9% и 99,99% — десятикратное сокращение error budget, а не «ещё одна девятка для презентации».

Жёсткий tail-latency target ограничивает fan-out, synchronous replication и cold paths. Cache улучшает latency, но способен ослабить freshness; hedged requests уменьшают tail ценой дополнительной нагрузки.

RPO = 0 между регионами требует синхронной координации либо продуктового статуса до глобальной durability. Это увеличивает latency и при partition поднимает явный выбор availability/consistency.

## Типичные ошибки

- **Неверное предположение:** availability равна process uptime. **Симптом:** dashboard зелёный, пользователи получают ошибки одного shard. **Причина:** SLI измеряется внутри сервера. **Исправление:** считать good events на пользовательской границе и разрезать по tenant/region.
- **Неверное предположение:** средняя latency достаточна. **Симптом:** p50 улучшается, а timeout rate растёт. **Причина:** хвост скрыт агрегацией. **Исправление:** end-to-end percentiles и histogram с корректными buckets.
- **Неверное предположение:** три replicas означают нулевой риск потери. **Симптом:** ошибочный delete реплицируется на все копии. **Причина:** replication перепутана с backup. **Исправление:** независимые backups, retention и restore drills.
- **Неверное предположение:** eventual consistency — одна гарантия. **Симптом:** клиент видит старую версию после уже показанной новой. **Причина:** не определены session guarantees и convergence bound. **Исправление:** назвать разрешённые наблюдения и staleness SLI.
- **Неверное предположение:** 100% — безопасный target. **Симптом:** любой deploy формально нарушает цель или требует чрезмерной redundancy. **Причина:** отсутствует error budget. **Исправление:** выбрать target по пользовательскому ущербу и стоимости.

## Когда применять

SLO фиксируют до выбора topology, а затем проверяют на схеме для normal load, overload и каждого существенного failure mode. После запуска допущения заменяют измерениями, но target не копируют автоматически из текущей производительности: он остаётся продуктовым обещанием и приоритетом работы.

## Источники

- [Service Level Objectives](https://sre.google/sre-book/service-level-objectives/) — Google, Site Reliability Engineering, глава 4, проверено 2026-07-18.
- [Availability Table](https://sre.google/sre-book/availability-table/) — Google, Site Reliability Engineering, таблица допустимой недоступности, проверено 2026-07-18.
- [Data Integrity: What You Read Is What You Wrote](https://sre.google/sre-book/data-integrity/) — Google, Site Reliability Engineering, глава 26, проверено 2026-07-18.
- [Implementing SLOs](https://sre.google/workbook/implementing-slos/) — Google, The Site Reliability Workbook, глава 2, проверено 2026-07-18.
