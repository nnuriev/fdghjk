---
aliases:
  - Runbook
  - Operational runbook
  - Операционный runbook
  - Руководство дежурного
tags:
  - область/reliability-performance-operations
  - тема/операции
статус: проверено
---

# Runbooks

## TL;DR

Runbook превращает известное operational состояние в безопасную последовательность решений и действий. Он связывает trigger с preconditions, commands/operations, ожидаемыми наблюдениями, ветвлениями, stop conditions, rollback, escalation и финальной проверкой. Список команд без проверки состояния опаснее отсутствия документа: его легко выполнить уверенно и не в том failure mode.

Runbook живёт вместе с системой. У него есть owner, version, permissions model, дата последней проверки и exercise. Повторяемые шаги автоматизируют, но destructive transitions сохраняют явные guards, ограничение scope и audit.

## Ментальная модель

Runbook: маленькая программа для оператора:

```text
trigger -> preconditions -> action -> expected observation
                  |                    |
                  + stop/escalate <----+
                            \-> verify -> exit
```

Текст должен помогать человеку с ограниченным attention budget предсказать следующий state. Хороший runbook нельзя выполнить «до конца» вслепую: каждый шаг разрешён только после проверки результата предыдущего.

## Как устроено

### Контракт документа

Минимальный runbook содержит:

- назначение, scope и случаи, для которых он не подходит;
- trigger/alert и user impact, который процедура должна уменьшить;
- owner, escalation path и требуемые роли;
- доступы, environment/account/region и безопасный способ получить credentials;
- preconditions и запреты, особенно data authority и maintenance state;
- шаги с точным input, ожидаемым output и timeout;
- decision branches для отклонений;
- stop conditions, rollback/abort и destructive warnings;
- verification по user SLI и domain invariants;
- cleanup, reconciliation и возврат временных overrides;
- version, last reviewed/tested, ссылки на dashboards и architecture context.

Wiki-link на dashboard недостаточен: надо назвать panel, разрез и ожидаемый диапазон. Команда «проверьте базу» превращается в «primary epoch = X, replication lag < 30 s, oldest unreplicated LSN зафиксирован». Конкретика уменьшает ambiguity.

### Preconditions важнее happy-path steps

Одна команда promotion может быть технически корректна и создать split brain, если старый writer не fenced. Scale-out может ухудшить outage, если исчерпан downstream pool. Runbook сначала проверяет модель отказа и authority, затем разрешает действие.

Destructive шаг отделяют визуально обычным Markdown, требуют явного подтверждения target и backup/recovery point. Не используют широкий wildcard или неразрешённую переменную. Least-privilege role ограничивает возможный blast radius.

### Automation сохраняет те же границы

Automation полезна для детерминированных проверок, сбора evidence, rate-limited changes и повторяемой verification. Она должна быть idempotent или хранить execution state, уметь останавливаться, ограничивать concurrency/error count и писать audit log.

Человек оставляет за собой решение, когда context влияет на необратимый переход: promotion replica, удаление corrupt data, глобальный traffic switch. Постепенно manual procedure можно превратить в executable runbook, но сначала её тестируют в sandbox/game day.

### Документ проверяется выполнением

Static review ловит опечатки и устаревшие ссылки. Exercise ловит исчезнувшие permissions, другие outputs, новый topology и неверные time estimates. После каждого применения [[70 Практические кейсы/Root-cause analysis|RCA]] обновляет steps и architecture, а не добавляет бесконечные примечания без удаления старого пути.

Организация может различать термины по-своему. Практичная граница: runbook детально ведёт по известной операции, playbook описывает стратегии и развилки для класса инцидентов, checklist подтверждает набор условий. Не стоит спорить о названии, если контракт и ownership ясны.

## Пример или трассировка

Alert: `consumer oldest_age > 10 min for 5 min`. Runbook «Drain backlog без перегрузки DB» начинается с preconditions:

1. пользовательские writes durable в broker, data loss не подтверждена;
2. DB CPU < 60%, connections < 60% и replication lag < 30 s;
3. причина не poison message; DLQ rate в baseline;
4. operations owner назначен, batch producer можно приостановить.

Наблюдения: arrival `1 200 msg/s`, четыре consumers обрабатывают по `250 msg/s`, backlog `240 000`.

Сначала приостанавливается batch, который даёт `300 msg/s`. Online arrival остаётся `900 msg/s`. Затем consumers масштабируются `4 -> 8` по две единицы с двухминутным gate по DB saturation. На первом шаге шесть consumers дают service rate `1 500 msg/s` и за две минуты уменьшают backlog на `72 000` сообщений. После успешного gate восемь consumers завершают drain:

```text
stage 1: (6 * 250 - 900) * 120 s = 72 000 messages
remaining: 240 000 - 72 000 = 168 000 messages
stage 2 net drain: 8 * 250 - 900 = 1 100 msg/s
stage 2 time: 168 000 / 1 100 ~= 153 s
total time: 120 + 153 = 273 s ~= 4,5 min
```

Ветвление: если DB connections > 75% или replication lag > 60 s, rollout scale-out останавливается и возвращается к предыдущему числу consumers; если DLQ растёт, переходят к poison-message playbook. Exit: backlog < 1 000, oldest age < 2 min в течение 10 min, lag и DB вернулись к baseline. После этого batch возобновляется ступенями.

Наблюдаемый результат совпадает с моделью: backlog убывает примерно за 4,5 минуты с учётом ramp. Если после выхода на восемь consumers фактический drain заметно ниже `1 100 msg/s`, runbook запрещает слепо добавлять consumers и направляет к проверке partition parallelism или DB bottleneck.

## Trade-offs

Подробный runbook снижает ошибки редкой операции, но быстро устаревает и перегружает опытного on-call. Короткий checklist легче поддерживать, зато не обучает ветвлениям. Правильная глубина зависит от частоты, необратимости и стоимости ошибки.

Полная automation быстрее, воспроизводима и работает ночью. Цена: bug или неверный trigger действует с машинной скоростью. Manual approval замедляет recovery, но полезен на irreversible boundary. Компромисс: automation собирает evidence и готовит bounded plan, человек разрешает переход.

Runbook лечит известный сценарий, но не заменяет архитектурную простоту и observability. Если каждую неделю оператор вручную восстанавливает pool, процедура превращает defect в toil. Она должна создать engineering action, а не нормализовать поломку.

## Типичные ошибки

- **Неверное предположение:** набор команд достаточно скопировать. **Симптом:** команда выполнена в другом region/account. **Причина:** нет scope и preconditions. **Исправление:** явный target, identity check и expected output перед mutation.
- **Неверное предположение:** шаг всегда завершается успешно. **Симптом:** оператор продолжает после partial failure. **Причина:** нет gate и branch. **Исправление:** outcome/timeout/stop condition у каждого перехода.
- **Неверное предположение:** документ верен после review. **Симптом:** во время incident не работают permissions и endpoints. **Причина:** runbook не выполняли. **Исправление:** game day, last-tested date и owner.
- **Неверное предположение:** automation автоматически безопаснее. **Симптом:** ошибочный trigger меняет все regions. **Причина:** нет rate limit, canary и abort. **Исправление:** bounded scope, staged execution, audit и human gate для destructive step.
- **Неверное предположение:** recovery заканчивается после основной команды. **Симптом:** временный flag остаётся навсегда или данные расходятся. **Причина:** отсутствуют cleanup/reconciliation. **Исправление:** exit criteria и отдельный владелец остаточных действий.

## Когда применять

Runbook нужен для редкой, рискованной или многошаговой операции: failover/failback, rollback, certificate/secret rotation, queue recovery, replica repair, capacity emergency и degraded mode. Частую безопасную процедуру лучше автоматизировать, сохранив runbook как контракт и escape hatch.

Документ готов, когда дежурный, не писавший его, выполнил exercise и получил ожидаемый state без устных подсказок. Для disaster recovery копия должна быть доступна вне failure domain, который она восстанавливает.

## Источники

- [AWS Systems Manager Automation](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-automation.html) — Amazon Web Services, current documentation, parameterized sequential runbooks и execution controls, проверено 2026-07-18.
- [Managing Incidents](https://sre.google/sre-book/managing-incidents/) — Google, Site Reliability Engineering, глава 14, live state, ownership и handoff, проверено 2026-07-18.
- [Disaster Recovery Planning Guide](https://csrc.nist.gov/pubs/sp/800/34/r1/upd1/final) — NIST, Special Publication 800-34 Revision 1, contingency procedures, tests и exercises, проверено 2026-07-18.
