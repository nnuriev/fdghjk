---
aliases:
  - Reliability performance cost improvement story
tags:
  - тип/кейс
  - область/подготовка-к-интервью
статус: черновик
---

# Улучшение reliability/performance/cost

## TL;DR

Выберите одну главную ось улучшения: reliability, performance или cost. Две остальные задают guardrails. История должна пройти полный цикл: пользовательски значимый baseline → измерение и причинная гипотеза → сравнение вариантов → безопасное изменение production → устойчивый результат на сопоставимом окне. «Переписали сервис» или «добавили cache» описывает output, пока не доказаны outcome и цена.

## Какой эпизод выбрать

Сильный эпизод содержит:

- реальную проблему, заметную пользователю, бизнесу или on-call;
- baseline до вашего вмешательства и воспроизводимый способ измерения;
- найденный bottleneck, failure mode или cost driver, а не оптимизацию по вкусу;
- ваше решение выходило за пределы локального patch и меняло систему или работу команды;
- rollout, rollback, observability и владельца после запуска;
- достаточно длинное окно после изменения, чтобы отличить устойчивый эффект от разового всплеска.

Для общего технического механизма используйте [[70 Практические кейсы/Карта — Reliability, Performance и Operations|карту Reliability, Performance и Operations]]. В истории оставьте только те детали, которые объясняют ваш judgment.

## Короткая формулировка

> У `[сервиса/user journey]` метрика `[главная SLI, latency или normalized cost]` была `[baseline]`, что приводило к `[impact]`. Я доказал, что основной driver — `[причина]`, сравнил `[реальные варианты]` и повёл команду по пути `[решение]`. После `[rollout]` метрика стала `[результат]`, а guardrails `[reliability/performance/cost]` остались `[значение]` на окне `[период]`.

## Привязка к resume

- Компания, роль, система и период: `[вставьте]`.
- Resume bullet: `[вставьте дословно]`.
- Какая часть числа относится ко всей инициативе: `[вставьте]`.
- Какое решение или действие принадлежало лично вам: `[вставьте]`.
- Можно ли раскрывать абсолютные значения; если нет, какой честный proxy допустим: `[вставьте]`.

## Контекст и масштаб

Зафиксируйте:

- user journey и критический путь: `[вставьте]`;
- traffic, payload, data volume, tenants, regions и dependency fan-out: `[вставьте]`;
- SLO или другой пользовательский контракт: `[вставьте]`;
- команда, число зависимых владельцев и ваш срок: `[вставьте]`;
- наблюдаемый ущерб: errors, tail latency, toil, capacity risk, cloud spend или потерянная возможность: `[вставьте]`.

Для reliability определяйте good event и окно по модели из [[50 Проектирование систем/SLO в System Design|заметки об SLO]]. Для performance указывайте percentile, population и точку измерения; среднее без распределения часто скрывает пользовательский хвост. Для cost нормализуйте расход на полезную единицу: request, active user, job, stored GB или business transaction.

## Личная ответственность

- Как вы обнаружили или переопределили проблему: `[вставьте]`.
- Какие измерения, profiles, traces или cost breakdown сделали лично: `[вставьте]`.
- Какое техническое направление предложили и кто принял финальное решение: `[вставьте]`.
- Как организовали работу команды и зависимых owners: `[вставьте]`.
- За что отвечали после production: `[dashboard, on-call, capacity review, regression budget]`.
- Что реализовали другие инженеры: `[вставьте]`.

На L5-сигнал работает не объём написанного кода, а качество модели: вы связали symptom с причиной, выбрали leverage point, управляли риском и сделали результат повторяемым для команды.

## Цель, baseline и критерий успеха

Выберите одну primary metric и несколько guardrails.

| Роль метрики | Определение | Baseline | Target | Окно |
| --- | --- | --- | --- | --- |
| Primary | `[availability / p99 latency / cost per useful unit]` | `[вставьте]` | `[вставьте]` | `[вставьте]` |
| User/business outcome | `[conversion, successful jobs, support contacts, retained traffic]` | `[вставьте]` | `[вставьте]` | `[вставьте]` |
| Guardrail 1 | `[не ухудшить соседнюю ось]` | `[вставьте]` | `[граница]` | `[вставьте]` |
| Guardrail 2 | `[correctness, freshness, capacity, developer toil]` | `[вставьте]` | `[граница]` | `[вставьте]` |

Target нельзя выбирать только потому, что он красиво выглядит в resume. Объясните, какой пользовательский или финансовый эффект делал его достаточным.

## Ограничения

Оставьте ограничения, которые меняли дизайн:

- нельзя останавливать сервис или нарушать SLO;
- ограниченный headroom, budget или engineer capacity;
- legacy protocol, data layout или hardware;
- неполная observability и дорогой experiment;
- сезонность, неравномерный traffic или noisy neighbors;
- consistency, durability, security и compliance;
- deadline, после которого opportunity исчезала.

Каждое ограничение соедините с архитектурным последствием. Например, запрет downtime требует staged migration, а нехватка capacity делает rollback budget частью плана.

## Рассмотренные альтернативы

Перечисляйте фактические варианты, а не ретроспективных «соломенных человечков».

| Вариант | Ожидаемый выигрыш | Cost и риск | Как проверяли | Решение |
| --- | --- | --- | --- | --- |
| `[точечная оптимизация hot path]` | `[вставьте]` | `[вставьте]` | `[profile/benchmark/experiment]` | `[вставьте]` |
| `[scale up/out]` | `[вставьте]` | `[recurring cost, предел scaling, operational load]` | `[capacity model]` | `[вставьте]` |
| `[cache/index/data-layout change]` | `[вставьте]` | `[freshness, write amplification, migration]` | `[prototype/load test]` | `[вставьте]` |
| `[изменение architecture или workload]` | `[вставьте]` | `[delivery time, complexity, blast radius]` | `[shadow/canary]` | `[вставьте]` |
| `[ничего не менять сейчас]` | `[сохраняет capacity команды]` | `[продолжающийся impact и opportunity cost]` | `[forecast/error budget]` | `[вставьте]` |

## Почему было принято конкретное решение

> Профили и production measurements показали `[driver]`, поэтому вариант `[выбор]` давал наибольший ожидаемый выигрыш на единицу delivery и operational cost. Мы сознательно приняли `[негативный trade-off]`, ограничили его через `[guardrail]` и оставили exit через `[rollback/migration trigger]`.

Если решение выбиралось под неопределённостью, назовите assumption и способ быстро его опровергнуть.

## Выполнение от решения до production

1. Зафиксировали population, workload и baseline до изменения.
2. Локализовали bottleneck или cost driver через [[70 Практические кейсы/Performance profiling и bottleneck analysis|profiling и bottleneck analysis]], traces, saturation или bill decomposition.
3. Проверили причинность минимальным experiment, benchmark или controlled traffic slice.
4. Спроектировали capacity, failure modes, observability и rollback.
5. Запустили shadow, canary или staged rollout по правилам [[70 Практические кейсы/Canary, blue-green и rolling deployment|безопасного deployment]].
6. Сравнили primary metric и guardrails на сопоставимом traffic mix.
7. Убрали временные режимы, закрепили owner, alert и regression test или budget.

## Метрики до и после

Для каждого числа укажите определение, denominator, окно и источник.

| Метрика | До | После | Сопоставимость и confidence |
| --- | --- | --- | --- |
| Primary | `[вставьте]` | `[вставьте]` | `[одинаковый traffic/payload/season; experiment или before-after]` |
| User/business | `[вставьте]` | `[вставьте]` | `[атрибуция и возможные confounders]` |
| Guardrail | `[вставьте]` | `[вставьте]` | `[граница не нарушена / известная деградация]` |
| Sustainability | `[вставьте]` | `[вставьте]` | `[окно после launch, повторная проверка]` |

Для cost сравнивайте normalized и total cost: цена на request могла упасть, а общий bill вырасти из-за traffic growth. Для performance не смешивайте p50 и p99. Для reliability отделяйте process uptime от доли полезных user operations.

## Ошибки и выводы

Подходящие ошибки: оптимизировали не тот path, доверились synthetic benchmark, не сегментировали workload, пропустили rebound load, купили latency ценой correctness, не учли migration cost или слишком рано объявили победу.

Запишите:

> Неверное предположение `[вставьте]` дало симптом `[вставьте]`. Причиной оказалась `[вставьте]`. Мы исправили `[система/процесс]` и добавили `[измерение, guardrail, тест или review]`, чтобы ошибка не зависела от памяти одного инженера.

## Что было бы сделано иначе

Выберите конкретный ранний шаг: сначала определить user-level SLI, снять профиль на production-like workload, включить FinOps breakdown, согласовать guardrails или профинансировать migration tooling. Объясните, сколько uncertainty или wasted work он бы снял и какой имел бы собственный cost.

## L5-сигналы

- **Техническое направление:** вы задали модель bottleneck или failure, критерии и последовательность работы команды.
- **Управление рисками:** измерения, guardrails, staged rollout и rollback ограничили blast radius.
- **Operational ownership:** результат остался наблюдаемым и поддерживаемым после релиза.
- **Краткосрочное и долгосрочное:** быстрый выигрыш не закрыл путь к target architecture и не создал скрытый toil.
- **Cross-team impact:** изменения contracts, capacity или ownership были согласованы с зависимыми командами.

## Доказательства и границы точности

- Dashboard/query и определение метрики: `[вставьте]`.
- Profile, trace, benchmark или cost report: `[вставьте]`.
- Design/decision doc: `[вставьте]`.
- Rollout и rollback evidence: `[вставьте]`.
- Окно после launch: `[вставьте]`.
- Числа exact, approximate или confidential: `[пометьте]`.

## Версии ответа

- **Заголовок:** baseline и impact → доказанный driver → решение → primary result и guardrail.
- **Основной ответ:** measurement → alternatives → decision → rollout → before/after → reflection.
- **Deep dive:** workload, SLI, bottleneck evidence, architecture, capacity, failure modes, migration, атрибуция и долгосрочный owner.

## Ожидаемые follow-up вопросы

- Почему вы уверены, что нашли причину, а не корреляцию?
- Почему не масштабировали hardware или capacity?
- Как определяли baseline и сравнимость окон?
- Какой отрицательный эффект имело улучшение?
- Что происходило при rollback или cold start?
- Сохранился ли результат после роста traffic?
- Какую часть outcome можно приписать вашему решению?

## Типичные ошибки

- **Неверное предположение:** большая относительная цифра сама доказывает impact. **Симптом:** неизвестны denominator и baseline. **Причина:** headline metric оторвана от определения. **Исправление:** назвать population, окно, абсолютный порядок и user/business следствие.
- **Неверное предположение:** benchmark равен production outcome. **Симптом:** microbenchmark ускорился, а end-to-end SLI не изменился. **Причина:** измеряли некритический участок или другой workload. **Исправление:** связать локальное измерение с production trace и end-to-end guardrail.
- **Неверное предположение:** оптимизация завершена после deploy. **Симптом:** выигрыш исчезает при росте нагрузки или следующем релизе. **Причина:** нет owner, regression budget и повторного измерения. **Исправление:** закрепить SLI, alert, capacity review и проверку устойчивости.

## Источники

- [What is Impact?](https://dropbox.github.io/dbx-career-framework/what_is_impact.html) — Dropbox Engineering Career Framework, business impact, reliability, efficiency и cost, guideline `v2.9.1`, проверено 2026-07-18.
- [IC4 Software Engineer](https://dropbox.github.io/dbx-career-framework/ic4_software_engineer.html) — Dropbox Engineering Career Framework, success metrics и operational ownership в публичной Senior-калибровке, проверено 2026-07-18.
- [Service Level Objectives](https://sre.google/sre-book/service-level-objectives/) — Google, Site Reliability Engineering, глава 4, проверено 2026-07-18.
- [Implementing SLOs](https://sre.google/workbook/implementing-slos/) — Google, The Site Reliability Workbook, глава 2, проверено 2026-07-18.
- [SDE III Interview Prep](https://www.amazon.jobs/content/en/how-we-hire/sde-iii-interview-prep) — Amazon Jobs, метрики, trade-offs и Senior behavioral preparation, проверено 2026-07-18.
