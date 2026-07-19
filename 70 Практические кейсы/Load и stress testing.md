---
aliases:
  - Load testing
  - Stress testing
  - Нагрузочное и стресс-тестирование
tags:
  - область/reliability-performance-operations
  - тема/производительность
статус: проверено
---

# Load и stress testing

## TL;DR

Load test проверяет, выполняет ли система SLO на ожидаемом профиле нагрузки. Stress test намеренно ведёт её за рабочий диапазон, чтобы найти предел, характер отказа и путь восстановления. Первый отвечает «достаточна ли capacity», второй: «что именно сломается и останется ли отказ ограниченным».

Результат имеет смысл только вместе с workload model, критериями приёмки и телеметрией всех насыщаемых ресурсов. Число RPS без распределения запросов, cache state, payload, concurrency, retries и внешних задержек измеряет генератор синтетики, а не production-систему.

## Ментальная модель

Тест управляет входом и наблюдает три границы:

```text
workload profile -> useful throughput -> saturation -> controlled rejection
                                      \-> collapse / recovery debt
```

До saturation полезный throughput растёт вместе с offered load. В хорошем overload-режиме после предела throughput выходит на плато, лишние запросы быстро отклоняются, а принятая работа сохраняет bounded latency. Плохой результат выглядит иначе: очередь и latency растут, retries добавляют нагрузку, процессы падают, а полезный throughput уменьшается.

## Как устроено

### Сначала гипотеза и контракт

До запуска фиксируют:

- пользовательский поток и mix операций, включая дорогие и редкие пути;
- arrival pattern: средний поток, peak, burst, синхронный запуск cohort и длительность;
- payload distribution, cardinality keys, cache hit ratio и долю новых соединений;
- целевые SLI: success rate, p95/p99 latency, freshness или completion age;
- saturation signals: CPU, memory/GC, runnable work, connection и worker pools, queue age, IOPS и dependency quotas;
- pass/fail gate и безопасный предел теста.

Связь с [[50 Проектирование систем/Оценка нагрузки и ёмкости|capacity planning]] прямая: тест измеряет supply одной единицы при целевом SLO, а модель сравнивает этот supply с peak demand и запасом на отказ.

### Open и closed workload отвечают на разные вопросы

В **closed model** фиксировано число virtual users: следующий запрос пользователя начинается после завершения предыдущего. Когда система замедляется, сам генератор снижает arrival rate. Так легко скрыть перегрузку.

В **open model** arrivals задаются независимо от response time, например 600 requests/s. Это ближе к webhook, публичному API или большой популяции клиентов. Но генератор обязан иметь достаточно CPU, sockets и network, иначе его предел будет ошибочно принят за предел сервиса.

Нужны обе проекции: concurrency описывает пользовательские сессии, arrival rate проверяет способность системы принять внешний поток. Измеренный latency должен включать время ожидания в очереди. Иначе возникает coordinated omission: медленный период порождает меньше измерений, и histogram выглядит лучше реальности.

### Фазы теста разделяют разные failure modes

1. **Smoke:** небольшой поток подтверждает корректность сценария и метрик.
2. **Baseline:** стабильная нагрузка даёт контрольную latency и стоимость операции.
3. **Load:** ступени до ожидаемого peak проверяют SLO и headroom.
4. **Stress/breakpoint:** поток растёт до контролируемого отказа и немного дальше.
5. **Spike:** резкий фронт проверяет очереди, autoscaling delay, cold cache и herd effects.
6. **Soak:** длительный steady load выявляет утечки, compaction, thermal throttling и накопление backlog.
7. **Recovery:** вход возвращается к норме; измеряются drain time, error tail и возвращение saturation к baseline.

Длительность observation window должна покрывать фоновые циклы, которые влияют на результат: GC, checkpoint, compaction, autoscaler, token refresh и batch. Один короткий прогон не подтверждает устойчивый режим.

### Production-like означает причинно похожий, а не обязательно одинаковый

Критичны размер данных, распределение keys, индексы, cache state, лимиты и topology. Уменьшенная среда допустима, если известен закон масштабирования и узкие места совпадают. Нельзя линейно переносить результат с пустой базы на production dataset или с одной dependency-mock на реальный connection pool.

Тест в production даёт наиболее реалистичный трафик, но сам становится изменением с blast radius. Ему нужны отдельный tenant/cohort, ограничения offered load, kill switch, наблюдение SLO и заранее зарезервированная recovery capacity. Shadow traffic не должен повторять внешние side effects.

## Пример или трассировка

API имеет цель `p99 <= 250 ms`, error rate `< 0,5%` и ожидаемый peak `600 RPS`. Четыре одинаковых экземпляра прогревают cache; генератор работает по open model с production mix. Useful throughput в таблице считает успешные ответы, уложившиеся в latency SLO, поэтому он может быть ниже числа ответов без transport/application error.

| Offered load | Useful throughput | p99 | Ошибки | CPU | DB pool на экземпляр |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 300 RPS | 300 RPS | 110 ms | 0,1% | 38% | 34/100 |
| 600 RPS | 599 RPS | 190 ms | 0,2% | 68% | 61/100 |
| 750 RPS | 718 RPS | 420 ms | 3,8% | 91% | 100/100 |
| 900 RPS | 623 RPS | 1,8 s | 24% | 96% | 100/100 |

На `600 RPS` load test проходит. Между 600 и 750 DB pool достигает насыщения, throughput перестаёт расти, а latency уходит за SLO. На 900 RPS полезная производительность падает: запросы ждут pool, истекают client deadlines и возвращаются как retries.

После снижения входа до 300 RPS p99 остаётся выше секунды ещё 45 секунд, пока старая очередь не опустеет. Наблюдаемый результат stress test: рабочий предел меньше 750 RPS; overload не изолирован, а создаёт recovery debt. Исправление проверяют новым прогоном: bounded admission до захвата дорогих ресурсов, короткая очередь и запрет retry для overload-ответа должны сохранить throughput около измеренного плато и быстро вернуть p99 к baseline.

## Trade-offs

Синтетический тест воспроизводим и безопаснее, но редко повторяет production cardinality, клиенты и коррелированные зависимости. Replay реального трафика реалистичнее, зато требует очистки данных, подавления side effects и контроля privacy.

Большая pre-production среда снижает ошибку экстраполяции, но дорога. Маленькая полезна для regression curve, если bottleneck тот же. Production experiment обнаруживает настоящие shared limits, однако тратит error budget и требует такой же дисциплины rollout, как релиз.

Load test даёт рабочую точку. Stress test показывает запас и форму отказа. Один не заменяет другой: тест только до SLO ничего не говорит о поведении на 101% capacity, а breakpoint без expected-load plateau не доказывает готовность к обычному peak.

## Типичные ошибки

- **Неверное предположение:** одинаковый RPS означает одинаковую нагрузку. **Симптом:** тест проходит, production упирается в насыщенный ресурс. **Причина:** потеряны payload, hot keys, misses, fan-out и write mix. **Исправление:** версионировать workload model и сверять её с telemetry.
- **Неверное предположение:** response time генератора всегда равен end-to-end latency. **Симптом:** histogram не видит длинные паузы. **Причина:** closed loop или coordinated omission уменьшили число измерений в медленный период. **Исправление:** open arrivals и учёт planned start time запроса.
- **Неверное предположение:** максимальный throughput и есть безопасная capacity. **Симптом:** обычный burst нарушает p99 и запускает retries. **Причина:** предел измерен после SLO boundary без headroom. **Исправление:** capacity фиксировать на последней устойчивой точке при целевом SLO.
- **Неверное предположение:** окончание генерации означает восстановление. **Симптом:** следующая волна приходит в заполненную очередь. **Причина:** не измерены drain и cleanup. **Исправление:** отдельная recovery-фаза с gate по queue age, errors и saturation.
- **Неверное предположение:** средняя latency показывает деградацию. **Симптом:** небольшой медленный класс исчерпывает workers при нормальном average. **Причина:** bimodal distribution скрыта средним. **Исправление:** histogram/percentiles и разрез по endpoint, outcome и cohort.

## Когда применять

Load test запускают перед изменением capacity-sensitive кода, topology, limits или major launch и регулярно используют как regression test. Stress, spike и recovery tests обязательны для critical serving path, где перегрузка способна перейти в [[40 Распределённые системы/Retry storms и cascading failures|каскадный отказ]].

Критерий готовности: известны expected-load plateau, SLO boundary, первый saturated resource, overload outcome и время восстановления. Если тест остановился на красивом RPS без этих пяти ответов, он ещё не выполнил задачу.

## Источники

- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering, глава 22, load testing до отказа и recovery, проверено 2026-07-18.
- [Testing for Reliability](https://sre.google/sre-book/testing-reliability/) — Google, Site Reliability Engineering, глава 17, проверено 2026-07-18.
- [Architecture strategies for performance testing](https://learn.microsoft.com/en-us/azure/well-architected/performance-efficiency/performance-test) — Microsoft, Azure Well-Architected Framework, определения load и stress test, проверено 2026-07-18.
- [API load testing](https://grafana.com/docs/k6/latest/testing-guides/api-load-testing/) — Grafana Labs, документация k6 v2.1.x, профили smoke/load/stress/spike/breakpoint/soak, проверено 2026-07-18.
