---
aliases:
  - Root cause analysis
  - RCA
  - Анализ первопричин
  - Анализ причин инцидента
tags:
  - область/reliability-performance-operations
  - тема/инциденты
статус: проверено
---

# Root-cause analysis

## TL;DR

Root-cause analysis восстанавливает причинный механизм инцидента и превращает его в проверяемые изменения. В сложной системе редко полезна одна «коренная причина»: отдельно нужны trigger, latent conditions, amplification loops, detection/mitigation gaps и факторы масштаба ущерба.

RCA строится по evidence и контрфактическим проверкам. Timeline сам по себе показывает последовательность, а не причинность. Хороший результат объясняет наблюдения, называет границы уверенности и создаёт action items, которые предотвращают повтор, ограничивают impact или ускоряют обнаружение и восстановление.

## Ментальная модель

Инцидент удобнее представить causal graph:

```text
latent condition + trigger -> failure -> amplifier -> user impact
             detection gap -----------^       |
             mitigation gap ------------------+
```

«Оператор запустил команду» описывает событие. RCA спрашивает, почему одна допустимая команда имела такой blast radius, почему guard её пропустил, почему сигнал пришёл поздно и почему recovery заняла столько времени. Blameless-подход не означает безответственность: решения и ownership описываются точно, но действия людей рассматриваются в контексте доступной им информации и системных ограничений.

## Как устроено

### Зафиксировать impact и scope

До объяснений собирают измеримые факты: затронутые операции/пользователи/regions, начало и конец, data loss/correctness, violated SLO и recovery debt. Разделяют event time, detection time, mitigation start и recovery. Это не позволяет подменить пользовательский ущерб ярким внутренним симптомом.

### Построить timeline из независимых источников

Change log, deployment events, config audit, metrics, traces, logs, queue offsets и database history приводят к одной временной шкале. Для каждого факта указывают источник и степень уверенности. Missing telemetry остаётся gap, а не заполняется памятью участника.

Timeline включает state transitions и отрицательные факты: когда healthy control не деградировал, в каком region симптома не было, какой retry не сработал. Такие сравнения помогают отсечь гипотезы.

### Разделить классы причин

- **Trigger:** событие, после которого latent defect проявился, например rollout или traffic spike.
- **Proximate failure:** непосредственный технический отказ, например connection pool exhaustion.
- **Latent conditions:** архитектурные и process-свойства, без которых trigger не дал бы такой impact.
- **Amplifiers:** retries, queues, failover, health restarts или shared pools, усилившие отказ.
- **Detection gaps:** SLI/alert/telemetry не показали ранний симптом.
- **Mitigation gaps:** отсутствовали flag, isolation, permissions или проверенный [[70 Практические кейсы/Runbooks|runbook]].

Слова «человеческая ошибка», «network issue» и «race condition» обычно останавливают анализ слишком рано. Они не объясняют boundary, interleaving, guard и путь распространения.

### Проверить причинность

Гипотеза должна:

1. объяснять весь набор наблюдений, включая здоровые cohort;
2. совпадать с временным порядком;
3. иметь механизм от причины к симптому;
4. давать контрфактический прогноз;
5. по возможности воспроизводиться тестом, replay или simulation.

Контрфактический вопрос: «Если убрать X при остальных факторах, возник бы тот же impact?» Он отличает необходимый вклад от корреляции. В распределённой системе несколько факторов могут быть совместно достаточны, а по отдельности безопасны.

Метод Five Whys полезен как prompt углубления, но линейная цепочка теряет параллельные causes. Для нелинейного инцидента causal graph, fault tree или event timeline точнее.

### Action items закрывают разные разрывы

Нужны меры четырёх типов:

- prevent: убрать defect или опасное состояние;
- contain: сократить blast radius bulkhead/canary/limit;
- detect: раньше увидеть user impact или precursor;
- recover: сократить MTTR через automation, access и runbook.

У каждого action есть owner, priority, due date и проверяемый end state. «Быть внимательнее» не меняет систему. У задачи «запретить rollout при pool wait > 50 ms и проверить fault test» есть наблюдаемый критерий завершения.

## Пример или трассировка

После config change timeout внешней dependency вырос с `0,5 s` до `5 s`. API принимает 20 пользовательских requests/s, каждый делает fan-out в 20 partitions. Пять процентов partition-вызовов попадают в blackhole, то есть медленными становятся 20 calls/s. Дополнительная средняя concurrency зависших вызовов по закону Литтла:

```text
20 slow calls/s * 5 s = 100 worker slots
```

Pool имеет 80 slots и общий для критичного API. Он исчерпывается, queue растёт, client deadlines вызывают retry, а полезный throughput падает. Average dependency latency остаётся умеренной, потому что 95% вызовов быстрые; alert по average не срабатывает.

Causal graph:

```text
trigger: timeout 0,5 -> 5 s
latent: fan-out ждёт все partitions + shared pool 80
amplifier: client retries
detection gap: average вместо tail/in-flight
mitigation gap: нет per-dependency bulkhead/partial result
```

Контрфактический test подтверждает механизм: при том же 5% blackhole, но deadline `0,5 s`, занято не более 10 slots и SLO сохраняется; при 5 s и отдельном bulkhead 20 slots деградирует только optional result. Наблюдения объяснены без ложного вывода «dependency была root cause»: её медленный ответ стал trigger, а глобальный impact создали локальные design gaps.

## Trade-offs

Глубокий RCA снижает повторяемость сложных отказов, но задерживает action, если команда ждёт абсолютной уверенности. Можно выпускать подтверждённые containment fixes раньше финальной модели, явно сохранив гипотезу и test plan.

Одна root cause проста для отчётности, зато провоцирует одну хрупкую меру. Causal graph сложнее, но даёт defense in depth. Five Whys дешёв для линейной procedure; fault tree и replay нужны, когда есть concurrency, distributed timing или несколько failure domains.

Blameless language повышает качество evidence и обучения. Она не запрещает называть нарушение процесса или рискованное решение. Разница в action: изменить guard, interface, review и feedback, а не объявить человека ненадёжным компонентом.

## Типичные ошибки

- **Неверное предположение:** первое событие перед outage было причиной. **Симптом:** откат не воспроизводит исправление. **Причина:** sequence принята за causality. **Исправление:** механизм, control cohort и контрфактический test.
- **Неверное предположение:** один low-level symptom завершает RCA. **Симптом:** после увеличения pool outage повторяется на другом ресурсе. **Причина:** не найден feedback loop. **Исправление:** causal graph до user impact и recovery.
- **Неверное предположение:** «human error» объясняет отказ. **Симптом:** action сводится к обучению, команда повторяет сценарий. **Причина:** не исследованы permissions, defaults, review и blast radius. **Исправление:** анализ local rationality и системных guards.
- **Неверное предположение:** action list равен обучению. **Симптом:** десятки задач не меняют риск. **Причина:** нет owner, priority и verified end state. **Исправление:** prevent/contain/detect/recover items с тестом результата.
- **Неверное предположение:** отсутствие logs доказывает отсутствие события. **Симптом:** timeline слишком уверенный. **Причина:** telemetry gap принят за отрицательный факт. **Исправление:** маркировать uncertainty и добавить instrumentation action.

## Когда применять

Формальный RCA нужен после user-visible outage/degradation выше порога, data loss, серьёзного near miss, ручного аварийного вмешательства или провала мониторинга. Критерии [[70 Практические кейсы/Incident mitigation|объявления и завершения инцидента]] задают заранее.

Анализ завершён, когда причинная модель прошла review владельцев затронутых систем, объясняет impact и recovery, а самые сильные action items имеют owner и проверку. Документ без последующих изменений сохраняет историю, но не снижает риск.

## Источники

- [Postmortem Culture: Learning from Failure](https://sre.google/sre-book/postmortem-culture/) — Google, Site Reliability Engineering, глава 15, contributing causes, blamelessness и preventive actions, проверено 2026-07-18.
- [Postmortem Culture: Learning from Failure](https://sre.google/workbook/postmortem-culture/) — Google, The Site Reliability Workbook, глава 10, depth и measurable action items, проверено 2026-07-18.
- [Example Postmortem](https://sre.google/sre-book/example-postmortem/) — Google, Site Reliability Engineering, пример impact, trigger, root causes, timeline и actions, проверено 2026-07-18.
