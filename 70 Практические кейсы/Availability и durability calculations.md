---
aliases:
  - Availability и durability calculations
  - Расчёт доступности и сохранности данных
  - Вероятностная модель надёжности
tags:
  - область/reliability-performance-operations
  - тема/доступность
  - тема/durability
статус: проверено
---

# Availability и durability calculations

## TL;DR

Availability измеряет вероятность получить полезный результат в момент обращения, durability оценивает риск необратимо потерять уже подтверждённое состояние на заданном горизонте. Один показатель нельзя вывести из другого: недоступная реплика может позже вернуться без потери данных, а доступная система способна быстро отдавать уже повреждённое состояние.

Последовательные обязательные зависимости при допущении независимости перемножают availability. Избыточные независимые копии дают `1 - произведение вероятностей одновременного отказа`. То же перемножение для durability особенно опасно: operator error, общий control plane, баг, credentials и асинхронная репликация создают коррелированные failure modes. Поэтому расчёт всегда заканчивается перечнем допущений, acknowledgment boundary, RPO/RTO и проверкой восстановления.

## Ментальная модель

У каждого показателя своя случайная величина:

```text
availability: запрос в момент t получил допустимый ответ?
durability: acknowledged object пережил горизонт H без необратимой потери?
```

Формула описывает модель отказов, а не производит надёжность. Если две зоны питаются через общий узел или все replicas принимают ошибочный `DELETE`, слово «независимые» исчезает, вместе с ним исчезают дополнительные девятки.

## Как устроено

### Наблюдаемая availability

Time-based вариант:

```text
A_time = (T_total - T_unavailable) / T_total
```

Request-based вариант:

```text
A_requests = good_valid_operations / all_valid_operations
```

Второй лучше отражает частичный отказ, неравномерный трафик и разные failure domains. Однако сначала нужно определить good event: `HTTP 200` с неверным телом, stale критичными данными или ответом позже deadline способен быть плохой операцией. Эти границы задаёт [[50 Проектирование систем/SLO в System Design|SLI/SLO]].

Допустимая недоступность на окне:

```text
bad_time = window * (1 - A_target)
```

30 дней содержат 43 200 минут. Target 99,95% оставляет `43 200 * 0,0005 = 21,6` минуты эквивалентной полной недоступности. При request-based SLI тот же бюджет выражается плохими операциями, а не wall-clock временем.

### Последовательные зависимости

Если user journey требует успеха всех `n` компонентов и их отказы независимы:

```text
A_path = A1 * A2 * ... * An
```

Это теоретическая верхняя оценка архитектурного пути. Она не включает bugs приложения, rollout, конфигурацию, DNS, capacity и работу оператора, если эти факторы не представлены отдельными членами. При общей причине отказа простое произведение становится оптимистичным.

Soft dependency в произведение не входит, если система сохраняет определённый good outcome без неё. Например, недоступный recommendation service может убрать персонализацию, но основной checkout остаётся хорошим событием. Это архитектурная причина проектировать [[40 Распределённые системы/Частичные отказы|частичные отказы]] и graceful degradation явно.

### Параллельная избыточность

Если достаточно хотя бы одной из `n` независимых реплик:

```text
A_redundant = 1 - (1 - A1) * (1 - A2) * ... * (1 - An)
```

Две реплики по 99,9% теоретически дают:

```text
1 - 0,001 * 0,001 = 0,999999 = 99,9999%
```

Но путь ещё содержит load balancer, discovery и механизм переключения. Реплика, о которой никто не узнал или на которую нельзя безопасно переключиться, математически существует, операционно нет. [[40 Распределённые системы/Active-active и active-passive|Active-active и active-passive]] различаются в том числе временем обнаружения и failover risk.

Для ремонтируемого компонента долгосрочную steady-state availability часто оценивают как:

```text
A ≈ MTBF / (MTBF + MTTR)
```

Эта оценка предполагает устойчивый процесс чередования работы и восстановления. Среднее скрывает распределение: редкий outage на сутки и много минутных outages могут дать похожий процент, но требуют разных mitigation. Для user-facing SLO измеренный good-event ratio важнее расчёта через MTBF.

### Durability на горизонте

Durability задают вместе с горизонтом и объектом обещания:

```text
D(H) = 1 - P(acknowledged data irreversibly lost during H)
```

Annual durability 99,999999999% соответствует model loss probability `q = 10^-11` на год. Это не availability и не обещание, что каждый конкретный год пройдёт без потерь. Если для модели считать `q` одинаковым для каждого из `N` объектов, то ожидаемое число потерь равно:

```text
E[lost_objects] = N * q
```

При `N = 1 000 000 000` получаем `0,01` объекта в год, то есть одну потерю на 100 лет в среднем. Вероятность хотя бы одной потери можно оценить как `1 - (1 - q)^N ≈ 1 - e^(-Nq)`, но только при независимости объектных потерь. Коррелированная потеря bucket, encryption key или региона ломает это приближение.

### Реплики, correlation и acknowledgment

Toy model для трёх копий с независимой вероятностью потери `q` на одном горизонте даёт `q³`. В реальной системе полезнее выделить common-cause risk:

```text
P_loss = p_common + (1 - p_common) * q_independent^3
```

Если `q_independent = 10^-3`, а вероятность общего destructive event `p_common = 10^-4`, независимая часть равна `10^-9`, но общий риск оставляет итог около `10^-4`. Четвёртая синхронная replica почти не помогает против ошибочного delete. Immutable versioned backup с другим control plane и проверенным restore уменьшает другой член модели.

Точка acknowledgment определяет, какие копии уже обязаны быть durable, когда клиент видит success. Локальный [[30 Данные/Durability и fsync|`fsync` и WAL]] защищают commit от части process/host failures. Синхронная запись в разные failure domains уменьшает RPO ценой latency и availability при partition. Асинхронная репликация отвечает быстрее, но создаёт exposure window: подтверждённые данные ещё не переживут потерю primary region.

Durability-модель обязана включать:

- hardware loss и latent corruption, checksums, scrubbing и repair;
- ошибочное или злонамеренное удаление, versioning, retention и access isolation;
- software/schema bug, который корректно реплицирует повреждение;
- потерю ключей и metadata, без которых bytes бесполезны;
- backup completeness, restore throughput и время обнаружения;
- RPO/RTO для node, zone, region и control-plane compromise.

[[40 Распределённые системы/RPO и RTO|RPO и RTO]] часто дают более проверяемый операционный контракт, чем одна оценка в одиннадцать девяток. Backup становится доказательством recoverability только после restore drill и сверки invariants.

## Пример или трассировка

Checkout синхронно проходит через edge, application и database. Их расчётные availability равны 99,99%, 99,95% и 99,99%. При независимости и обязательности всех трёх:

```text
A_path = 0,9999 * 0,9995 * 0,9999
       = 0,999300109995
       ≈ 99,930011%
```

Это около `43 200 * (1 - 0,999300109995) ≈ 30,24` минуты полной недоступности за 30 дней. Обещать пользователю 99,95% на основании этих targets уже нельзя: расчётный путь хуже до учёта собственных bugs и операций.

Команда делает recommendation soft dependency и не меняет checkout calculation: при её отказе ответ без рекомендаций всё ещё good. Для database добавляет вторую независимо доступную zone replica. Если каждая database replica имеет 99,9%, теоретическая availability пары равна 99,9999%. Затем команда проверяет допущения: quorum действительно доступен при потере зоны, failover укладывается в deadline, общий network/control plane не входит в обе вероятности.

Order commit подтверждается после durable quorum в двух зонах, а offsite backup делается асинхронно. Это даёт разные claims: потеря одного узла или зоны не должна терять acknowledged order; destructive logical change восстанавливается до последней независимой backup/checkpoint и имеет ненулевой RPO. Restore drill измеряет не процент availability, а полноту orders, согласованность ledger и время возврата к serving.

## Trade-offs

Синхронная redundancy уменьшает окно потери, но добавляет network latency и превращает медленную или разделённую replica в ограничение write availability. Асинхронная схема сохраняет write availability и latency, принимая ненулевой RPO.

Больше копий снижает independent hardware risk. Цена растёт почти линейно, а common-cause risk остаётся. Разнообразие failure domains, credentials, software versions и backup media часто полезнее четвёртой одинаковой replica, но усложняет операции и restore.

Time-based availability легко перевести в минуты и SLA. Request-based availability ближе к пользовательскому ущербу, зато зависит от профиля трафика и требует чёткой классификации valid/good events. Для сервиса с переменным трафиком используют оба представления, но контракт основывают на одном явно выбранном SLI.

## Типичные ошибки

- **Неверное предположение:** availability компонентов можно всегда перемножить. **Симптом:** расчёт обещает шесть девяток, общий deploy роняет все replicas. **Причина:** независимость принята без анализа common causes. **Исправление:** fault tree по zone, network, control plane, release и operator domains; correlated risk моделировать отдельно.
- **Неверное предположение:** три replicas означают высокую durability. **Симптом:** ошибочный delete исчезает со всех копий. **Причина:** replication сохраняет текущий state, включая ошибку. **Исправление:** versioned immutable backup, изолированные права, retention и restore drill.
- **Неверное предположение:** vendor SLA равен availability приложения. **Симптом:** каждый dependency формально выполняет SLA, end-to-end SLO нарушен. **Причина:** SLA имеет свой scope, exclusions и measurement point. **Исправление:** считать user journey и измерять собственный SLI.
- **Неверное предположение:** `200 OK` доказывает availability. **Симптом:** процент зелёный, checkout возвращает пустой order. **Причина:** protocol success перепутан с полезным outcome. **Исправление:** доменный good-event predicate и black-box проверка.
- **Неверное предположение:** annual durability гарантирует ноль потерь. **Симптом:** на большом числе объектов появляются реальные потери при очень высокой доле сохранности. **Причина:** вероятность одного объекта перепутана с fleet-wide событием. **Исправление:** переводить target в expected loss, моделировать correlation и иметь reconciliation/repair.
- **Неверное предположение:** backup автоматически задаёт RPO/RTO. **Симптом:** файл есть, но restore дольше допустимого или не восстанавливает metadata. **Причина:** проверялась запись backup, не восстановление системы. **Исправление:** регулярный restore с checksum, business invariants и замером времени.

## Когда применять

Расчёт делают на user journey до выбора topology, затем повторяют после определения failure domains и acknowledgment semantics. Он полезен как проверка достижимости SLO и как способ найти hard dependencies, которые нужно смягчить.

После запуска theoretical availability заменяют наблюдаемым request-based SLI, а durability подтверждают integrity scans, reconciliation, loss accounting и restore drills. Если данные о независимости отсутствуют, результат помечают верхней оценкой и не превращают в публичное обещание.

## Источники

- [Availability](https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/availability.html) — AWS Well-Architected Framework, Reliability Pillar, проверено 2026-07-18.
- [Availability Table](https://sre.google/sre-book/availability-table/) — Google, Site Reliability Engineering, таблица допустимой недоступности, проверено 2026-07-18.
- [Data availability and durability](https://cloud.google.com/storage/docs/availability-durability) — Google Cloud Storage, актуальная документация, проверено 2026-07-18.
- [Data Integrity: What You Read Is What You Wrote](https://sre.google/sre-book/data-integrity/) — Google, Site Reliability Engineering, глава 26, проверено 2026-07-18.
- [Composite Cloud Availability](https://cloud.google.com/blog/products/devops-sre/composite-cloud-availability) — Google Cloud, DevOps & SRE, 2022, проверено 2026-07-18.
