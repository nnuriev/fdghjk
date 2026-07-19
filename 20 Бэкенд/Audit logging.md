---
aliases:
  - Audit log
  - Журнал аудита
  - Security audit logging
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/наблюдаемость
статус: проверено
---

# Audit logging

## TL;DR

Audit log — журнал доказательств о значимых действиях и решениях системы. Он должен позволять установить actor, действие, target, tenant, момент, authorization decision, фактический outcome и версию policy. Debug log отвечает «почему код упал», access log — «какой HTTP-запрос прошёл», audit — «кто изменил роль пользователя и было ли изменение committed». Один поток не стоит выдавать за все три.

Надёжность audit trail определяется четырьмя свойствами: требуемое событие генерируется у владельца действия, связано с committed state, доставляется без silent loss и защищено от изменения более сильной границей, чем приложение-источник. Для side effects практичный baseline — записать audit intent в той же транзакции, что и business mutation, затем идемпотентно перенести его в отдельный append-only store. Secrets и полный sensitive payload туда не попадают; доступ к самому audit log тоже журналируется и ограничивается retention policy.

## Область применимости

Заметка рассматривает security и business-control audit для backend: authentication и authorization, privileged actions, изменение policy/roles, чтение и export чувствительных данных, key management, deletion, configuration и administrative operations. Общая observability, application debugging, бухгалтерский ledger и юридические правила admissibility остаются вне scope.

NIST SP 800-92 остаётся опубликованным final от сентября 2006 года. NIST SP 800-92 Rev. 1 существует как Initial Public Draft от 2023-10-11; по официальной странице проекта NIST на дату проверки комментарии ещё обрабатываются. Draft полезен как planning playbook, но его нельзя называть финальным стандартом. Состав и защита audit records сверены с NIST SP 800-53 Rev. 5, release 5.2.0 от 2025-08-27, прежде всего с controls AU-2, AU-3, AU-4, AU-5, AU-6, AU-8, AU-9, AU-11 и AU-12.

## Ментальная модель

Audit event — переход от заявления к доказательству:

```text
request/command
  -> authenticated actor
  -> authorization decision
  -> attempted effect
  -> committed/rejected outcome
  -> protected evidence
  -> review, detection or investigation
```

Эти стадии нельзя склеивать. `request received` не доказывает, что policy разрешила действие. `permit` не доказывает, что транзакция committed. Строка `role updated` до ответа базы может зафиксировать эффект, которого не было.

Инварианты рабочего audit pipeline:

- actor берётся из доверенного authentication context, а не из client-supplied поля;
- событие различает attempt, authorization decision и фактический outcome;
- требуемые классы событий не sampling-ятся;
- повторная доставка не создаёт два логических события;
- источник не может переписать или удалить уже принятую каноническую запись;
- доступ, export и изменение retention самого audit store контролируются и аудитируются;
- sensitive payload и credentials не нужны для идентификации действия;
- clock skew, late delivery и отсутствие глобального порядка явно учитываются;
- переполнение buffer или недоступность sink наблюдаемы и приводят к заранее выбранному fail mode.

## Как устроено

### Сначала выбираются события, а не logging library

NIST SP 800-53 AU-2 требует определить типы событий, которые система способна и обязана логировать, и обосновать этот выбор. Список строят из threat model, расследований, business controls и privacy requirements. Обычно в него входят:

- authentication success/failure, MFA и credential lifecycle без самих credentials;
- authorization permit/deny для чувствительных действий;
- создание, изменение и удаление roles, grants, policies и service identities;
- administrative access, impersonation, break-glass и delegated actions;
- чтение, bulk search и export чувствительных data classes;
- изменение encryption keys, secrets metadata, retention, legal hold и deletion jobs;
- изменение security-relevant configuration и отключение logging/detection;
- изменение audit store policy, readers, retention lock и export.

Логировать каждый технический read во всех системах часто слишком дорого. Но «дорого» не объясняет sampling после incident. Для каждого use case фиксируют target coverage: например, все чтения medical record, все bulk exports, все deny административного API, но не каждый cache hit публичного каталога. Решение о coverage версионируется и тестируется.

### Schema отвечает на расследуемые вопросы

NIST SP 800-53 AU-3 требует, чтобы запись позволяла установить тип события, время, место, источник, outcome и связанные identities/entities. Для backend практичная canonical schema содержит:

```text
event_id, schema_version
occurred_at, recorded_at, source_clock
service, environment, region, tenant_id
actor.id, actor.type, actor.authn_context, delegation_chain
action, target.type, target.id
authz.decision, authz.reason_code, authz.policy_version
outcome, failure_code
request_id, trace_id, transaction_id
safe_change_summary
```

`actor` и `target` различаются. При impersonation нужны initiator, effective subject и основание delegation; иначе действие support-оператора выглядит как действие пользователя. Для scheduled job actor — workload identity плюс job definition/version, а не фиктивный человек.

`occurred_at` сообщает время на source, `recorded_at` — приём каноническим sink. Разница показывает delivery lag и clock skew. При строгом порядке добавляют source-local monotonic sequence или transaction version. Один wall-clock timestamp не создаёт глобальный порядок между регионами.

`reason_code` стабилен и безопасен для аналитики; свободный exception text может содержать PII и меняться между releases. `trace_id` помогает найти технический путь в [[50 Проектирование систем/Observability в System Design|telemetry]], но trace sampling не должен удалить канонический audit event.

Schema version хранится в каждой записи. Consumer понимает старые версии, а migration не переписывает исторические events без отдельной, тоже аудируемой процедуры. Иначе изменение поля разрушит смысл прошлого расследования.

### Момент записи связан с business outcome

Есть три основных способа связать audit и действие.

**Synchronous append во внешний sink до подтверждения операции** даёт сильную границу: если evidence не сохранено, sensitive action не выполняется или не подтверждается. Цена — latency и зависимость availability business path от audit service. Если append произошёл до commit, запись должна оставаться `attempted`; после commit нужен отдельный outcome либо протокол, который не выдаёт attempt за success.

**Transactional audit outbox** записывает business mutation и audit event в одной локальной транзакции. После commit consumer идемпотентно переносит событие в независимый store. Паттерн [[40 Распределённые системы/Transactional outbox и Change Data Capture|transactional outbox]] устраняет разрыв «state изменился, event потерялся» для одного transactional resource. Он не защищает от администратора этой базы: до экспорта тот может изменить и state, и outbox. Поэтому canonical audit store должен пересечь отдельную administrative boundary с малым и измеряемым lag.

**Best-effort async emit после операции** дешевле и не блокирует request, но process crash в зазоре теряет событие. Для обязательного audit это не гарантия. Async допустим только поверх durable local spool/outbox либо для некритичной diagnostic копии.

Read-only access не имеет business commit, к которому можно присоединить outbox. Для чувствительного чтения audit ставят в data access boundary: синхронно сохраняют decision/access event до возврата plaintext либо используют durable spool с выбранным fail-closed threshold. Запись только в controller пропускает background jobs, прямые repository calls и admin tools.

### Delivery считается at-least-once

Retry после timeout может повторно доставить event. `event_id` генерируется один раз на логическое действие, а sink применяет unique constraint или идемпотентный put. Нельзя генерировать новый ID в каждом retry: тогда дубликаты выглядят как несколько действий.

Глобальный total order между services обычно недоступен. Для расследования хранят причинные ссылки, resource version, transaction ID и source sequence. Consumer принимает late events и не делает вывод «записано позже — произошло позже» без дополнительных доказательств.

Pipeline измеряет:

- generated, accepted, persisted и rejected events по class/source;
- outbox/spool age и backlog;
- schema validation failures;
- duplicate rate;
- разницу `recorded_at - occurred_at`;
- storage capacity и retention pressure;
- heartbeat от каждого обязательного source.

NIST SP 800-53 AU-4 требует достаточной audit storage capacity. Реакцию на сбой audit logging задаёт AU-5: alert ответственным ролям и дополнительные действия, определённые организацией; enhancement AU-5(4) предусматривает full/partial shutdown или degraded mode для выбранных failures, если нет alternate audit capability. Silent drop при заполненном buffer — нарушение контракта. Для privileged mutations часто выбирают fail closed после bounded grace. Для менее критичных событий возможен durable backlog, но только с лимитом, alert и runbook.

### Канонический store отделён от источника

Application identity получает append-only operation для своего namespace и не получает update/delete/read-all. Security reviewers получают read к нужным partitions. Retention administrators, platform operators и investigators разделены настолько, насколько требует риск.

Audit data передаётся и хранится зашифрованным, но encryption не доказывает неизменность. Защита строится слоями:

- отдельный account/project или security boundary;
- append-only/WORM либо object retention lock;
- versioning и запрет destructive lifecycle change обычным operator;
- replicated durable storage и проверяемый restore;
- audit действий над audit store;
- integrity verification и независимые alerts.

Hash chain обнаруживает разрыв или изменение только относительно доверенного anchor. Если attacker контролирует весь stream и может пересчитать chain с начала, цепочка сама себя не спасает. Для tamper evidence нужны signed checkpoints или roots, регулярно публикуемые в независимой trust domain, плюс контроль полноты sequence. Даже тогда chain не доказывает, что source с самого начала сгенерировал все обязательные events.

### Privacy и расследуемость не требуют payload dump

Audit log часто сам содержит personal data: actor ID, source address, resource relation, время и pattern действий. Его защищают не слабее исходной операции, задают purpose и retention, а поиск и export аудитируют.

Содержимое строят по allowlist. Для изменения профиля достаточно `target=u9`, `fields_changed=[phone]`, before/after classification или masked values; полный номер телефона не нужен. Для export фиксируют query/report ID, data class, row count и destination class, но не копируют выгруженные строки.

Запрещены raw access token, session cookie, API key, password, private key и plaintext secret. Credential ID, key ID или token fingerprint допустимы только если не позволяют аутентифицироваться и реально нужны корреляции. Правила [[20 Бэкенд/Обработка PII|обработки PII]] действуют и для audit datasets.

### Evidence используется, а не складируется

Для каждого события определяют detection или расследовательский вопрос, owner и response. Примеры: массовые decrypt, role escalation с последующим export, break-glass без ticket, disabled logging, повторные cross-tenant deny.

Контроль полноты проверяют end-to-end: synthetic actor выполняет canary action, затем система ожидает canonical event с правильными actor, target, decision и outcome. Unit test вызова `logger.info` не проверяет delivery, retention lock и queryability.

Периодически воспроизводят расследование из сохранённых записей. Если нельзя отличить denied attempt от committed change либо восстановить delegation chain, schema недостаточна независимо от объёма логов.

## Сквозной пример: изменение роли пользователя

Администратор `a42` отправляет команду изменить роль пользователя `u9` в tenant `t7` с `viewer` на `billing_admin`.

1. API получает principal из проверенного credential. Client body содержит только target и requested role; `actor=a42` из body игнорируется.
2. Policy version `p83` принимает решение `permit` для action `role:update`. Отдельный deny-event был бы записан при отказе, без business mutation.
3. Одна database transaction проверяет `tenant=t7`, текущую role/version, обновляет membership и вставляет `audit_outbox` с заранее созданным `event_id=e551`.
4. Event содержит initiator `a42`, target `u9`, action, safe change `viewer -> billing_admin`, decision `permit`, policy `p83`, outcome `committed`, transaction ID и request ID. Email, raw JWT и request headers отсутствуют.
5. После commit consumer отправляет `e551` в security-owned append-only store. Timeout приводит к повтору; unique `event_id` оставляет одну каноническую запись.
6. Sink недоступен. Business state и outbox не расходятся, backlog age растёт. При достижении утверждённого порога сервис приостанавливает новые role changes, но обычные reads продолжаются.
7. Investigator находит `e551`, связывает его с authentication event и последующим billing export. Чтение этого audit partition создаёт отдельное событие.

Если concurrent transaction уже изменила role, optimistic check отклоняет команду. Audit outcome должен быть `rejected_precondition`, а не `committed`: authorization была успешной, эффект — нет.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| Сентябрь 2006 | SP 800-92 final дал общую enterprise guidance по log-management infrastructure и процессам | Документ остаётся действующей финальной публикацией NIST на дату проверки | Использовать как общую основу, не приписывая ему современные cloud-specific механизмы | NIST SP 800-92 |
| Октябрь 2023 → 2026-07-18 | Начат пересмотр SP 800-92 | Rev. 1 опубликован только как Initial Public Draft; NIST обрабатывает comments | Planning playbook полезен, но status `draft` должен быть виден в требованиях и ссылках | NIST SP 800-92 Rev. 1 IPD и Log Management project |
| Август 2025 | SP 800-53 Rev. 5 существовал с предыдущими patch releases | Release 5.2.0 обновил каталог controls; AU-family остаётся актуальной контрольной моделью | В control mapping указывать release 5.2.0 и конкретные AU-controls | NIST SP 800-53 Rev. 5 release 5.2.0 |

## Trade-offs

### Synchronous append или transactional outbox

Synchronous append быстрее пересекает независимую trust boundary и подходит для операций, которые нельзя выполнить без evidence. Он добавляет latency и outage coupling. Outbox атомарен с локальным mutation и переживает sink outage, зато оставляет окно, когда app/database administrator контролирует state и pending event. Чем опаснее тот же administrator в threat model, тем короче допустимый export lag.

### Централизованная schema или domain events

Единая schema облегчает cross-service queries, retention и detection. Слишком общий lowest-common-denominator теряет domain semantics. Полезен canonical envelope с actor/action/target/outcome и versioned domain payload по allowlist. Владелец domain определяет смысл, security platform — обязательную форму и transport.

### Полный diff или минимальная evidence

Полный before/after упрощает forensic reconstruction, но копирует PII/secrets и удваивает sensitive storage. Список изменённых полей, safe enum transitions, object version и ссылка на отдельно защищённый record часто дают достаточно доказательств. Полный snapshot оставляют только для use case с явно обоснованными access и retention.

### Audit каждого read или риск-ориентированное покрытие

Все reads дают максимальную детализацию и огромный объём, cost и privacy exposure. Риск-ориентированная selection уменьшает поток, но требует доказать, какие reads считаются чувствительными. Sampling обязательных reads недопустим; лучше заранее сузить event class по data classification и operation.

## Типичные ошибки

### Success логируется до commit

- **Неверное предположение:** вызов repository означает выполненное действие.
- **Симптом:** audit показывает role change, которого нет в database.
- **Причина:** event создан до commit или без transaction outcome.
- **Исправление:** различать attempt/decision/outcome и связывать committed event с транзакцией либо outbox.

### Actor берётся из request body или header

- **Неверное предположение:** upstream уже проверил `X-User-ID`.
- **Симптом:** attacker создаёт записи от имени другого пользователя.
- **Причина:** недоверенные transport metadata смешаны с authentication context.
- **Исправление:** перезаписывать internal identity на trusted boundary, логировать immutable principal и delegation chain.

### Debug log объявлен audit trail

- **Неверное предположение:** подробный application log автоматически даёт evidence.
- **Симптом:** события sampling-ятся, schema меняется, PII попадает в text, retention слишком короткий.
- **Причина:** debug pipeline оптимизирован для диагностики и стоимости, а не completeness/integrity.
- **Исправление:** отдельные event classes, schema, delivery SLO, access и retention; корреляция через IDs.

### Async emit теряется при crash

- **Неверное предположение:** in-memory queue почти всегда успеет flush.
- **Симптом:** business change есть, audit event отсутствует именно во время outage.
- **Причина:** нет общей durable boundary.
- **Исправление:** transactional outbox, durable spool или synchronous fail-closed append по классу действия.

### Hash chain считается полной защитой

- **Неверное предположение:** связанный hash делает журнал неизменяемым.
- **Симптом:** privileged attacker удаляет suffix или пересчитывает всю цепочку.
- **Причина:** нет независимого anchor и контроля полноты sequence.
- **Исправление:** append-only store, separation of duties, externally anchored checkpoints и gap detection.

### Audit хранится бессрочно

- **Неверное предположение:** больше истории всегда улучшает расследование.
- **Симптом:** растут cost, privacy exposure и число людей, чьи действия можно анализировать без текущей цели.
- **Причина:** retention не связан с use case и обязательством.
- **Исправление:** retention по event class/purpose, legal hold как отдельное состояние, проверяемое expiry и удаление.

## Когда применять

Audit обязателен там, где позже нужно доказать control decision или чувствительный эффект: privilege, money movement, PII access/export, key/secret operations, retention/deletion, configuration и break-glass. Для обычной отладки достаточно structured application logs; переносить в audit всё подряд вредно.

Перед выпуском определяют event catalog, canonical schema, source boundary, commit semantics, delivery SLO, fail mode, storage protection, reviewer access, detections и retention. Затем выполняют end-to-end canary, outage test, duplicate delivery, clock-skew scenario, capacity exhaustion и расследование по сохранённым событиям.

## Источники

- [NIST SP 800-92: Guide to Computer Security Log Management](https://csrc.nist.gov/pubs/sp/800/92/final) — NIST, final от сентября 2006 года, проверено 2026-07-18.
- [NIST SP 800-92 Rev. 1: Cybersecurity Log Management Planning Guide](https://csrc.nist.gov/pubs/sp/800/92/r1/ipd) — NIST, Initial Public Draft от 2023-10-11; не final, проверено 2026-07-18.
- [NIST Log Management project](https://csrc.nist.gov/Projects/log-management) — NIST, официальный статус пересмотра SP 800-92; comments к Rev. 1 обрабатываются, страница обновлена 2025-11-20, проверено 2026-07-18.
- [NIST SP 800-53 Rev. 5: Security and Privacy Controls for Information Systems and Organizations](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final) — NIST, Rev. 5, release 5.2.0 от 2025-08-27; controls AU-2, AU-3, AU-4, AU-5, AU-6, AU-8, AU-9, AU-11 и AU-12, проверено 2026-07-18.
