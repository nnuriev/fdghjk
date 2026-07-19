---
aliases:
  - Principle of least privilege
  - Принцип наименьших привилегий
  - Минимальные полномочия
tags:
  - область/бэкенд
  - тема/безопасность
  - принцип/наименьшие-привилегии
статус: проверено
---

# Least privilege

## TL;DR

Least privilege — дать subject только те полномочия, которые нужны для конкретной задачи, над минимальным набором resources, в допустимом контексте и на ограниченное время. «Read-only», внутренняя сеть и одна общая service role не доказывают минимальность: чтение может раскрывать все PII, inherited policy — добавлять admin actions, а shared identity — объединять blast radius всего fleet.

Принцип реализуется как lifecycle. Сначала разделяют identities и data/control plane, затем описывают required actions и resources, выдают narrow policy или short-lived elevation, проверяют effective permissions и negative cases, наблюдают фактическое использование, регулярно убирают лишнее. Отсутствие вызова в коротком audit window не доказывает ненужность права: seasonal jobs, incident recovery и disaster failover моделируют отдельно.

Least privilege уменьшает ущерб после компрометации, но не предотвращает саму уязвимость. Захваченный thumbnail worker всё ещё способен испортить разрешённые thumbnails; задача policy — не дать ему удалить original objects, прочитать другие tenants или менять IAM.

## Ментальная модель

Privilege — возможность вызвать effect. Её область задаётся несколькими измерениями:

```text
(principal, action, resource, conditions, time, delegation)
```

Слишком широким может быть любое из них:

- один principal представляет несколько workloads или людей;
- action записан как `*` или объединяет read с administration;
- resource охватывает все tenants, buckets, tables или keys;
- нет environment conditions, approval или ownership check;
- credential действует год вместо десяти минут;
- subject способен передать роль дальше или изменить policy.

Least privilege отличается от соседних принципов. Deny-by-default говорит, что отсутствие явного разрешения даёт deny. Separation of duties не позволяет одному subject завершить критичную цепочку. Least functionality уменьшает доступные функции и поверхность атаки. Они усиливают друг друга, но не взаимозаменяемы.

## Как устроено

### 1. Начать с effects, а не названий ролей

Для workload или job перечисляют нормальные use cases как effects:

```text
thumbnail-worker:
  read exact uploaded object version
  decrypt it for processing
  write derived thumbnail under server-chosen prefix
  acknowledge one queue message
```

Из этого не следует `storage:*`, `kms:*` или доступ ко всему bucket. Policy строят по действиям, resources и conditions. У каждого permission должен быть owner и объяснение, какой use case сломается после удаления.

Нужно учитывать скрытые действия SDK и control plane: multipart upload, metadata read, queue visibility extension, key unwrap. Самый узкий syntactically valid policy может быть функционально неверным; минимальность проверяется тестом реального workflow.

### 2. Разделить principals и trust domains

Отдельные identities нужны для services, environments и privilege levels. Production и development не делят key. API runtime не получает migration/DDL role. Human operator использует обычный account для повседневной работы и отдельную privileged session для administration. Background job не наследует полномочия всего web process, если ему нужен один queue и table.

Граница identity уменьшает blast radius и делает audit осмысленным. Если сто instances используют один долгоживущий key, лог видит «service», а revoke останавливает всех. Short-lived per-workload credentials из [[20 Бэкенд/Управление секретами|управляемого secrets lifecycle]] сужают время и attribution, но target policy всё равно должна ограничивать actions/resources.

### 3. Ограничить action и resource

Permission задают максимально предметно:

- разделяют data read/write/delete и control-plane policy/configuration;
- используют exact resource IDs, tenant prefixes, table/schema и object versions;
- запрещают list/search, если workload знает точный identifier;
- ограничивают cryptographic key purpose и encryption context;
- задают audience для tokens и destination/egress для network access;
- ограничивают namespace, queue, secret path и environment.

Resource pattern проверяют на обходы: prefix `tenant/t1/*` должен отличаться от client-supplied path normalization; wildcard action способен включить новые provider API после его появления. Effective scope вычисляют по semantics конкретной платформы, а не по визуальной длине policy.

### 4. Добавить context и время

Постоянное право оправдано для постоянной data-plane функции. Редкое administration лучше выдавать just-in-time (JIT): subject проходит stronger authentication/approval, получает short-lived role, выполняет ограниченное действие, а elevation истекает автоматически.

Context conditions включают tenant, resource owner, device/workload identity, region, network path, authentication strength, ticket/change ID и time window. Они относятся к [[20 Бэкенд/RBAC и ABAC|ABAC-части решения]] и должны поступать из доверенных sources.

NIST SP 800-53 Rev. 5 control AC-6 формулирует least privilege для users и процессов. Enhancements отдельно требуют использовать non-privileged account для nonsecurity functions, ограничивать privileged accounts, регулярно review privileges, логировать privileged functions и запрещать их выполнение non-privileged users.

### 5. Ограничить runtime, а не только IAM

IAM policy — один слой. Compromised process использует всё, что ему открывают OS/container identity, filesystem, network и database connections. Поэтому:

- процесс запускают non-root и сбрасывают ненужные OS capabilities;
- filesystem делают read-only, кроме конкретных writable paths;
- secrets монтируют только нужному container/process;
- network egress разрешает требуемые destinations;
- database user имеет permissions нужной schema/tables, без DDL и role management;
- data query всегда ограничивает tenant/object policy;
- admin API и metadata endpoints недоступны data-plane workload.

Изоляция не заменяет application authorization: service с правом прочитать table всё равно обязан проверять resource policy. И наоборот, `if user.isAdmin` в коде не остановит SQL injection, если DB credential может удалить schema.

### 6. Вычислить effective permissions

Реальное право получается после union/intersection нескольких механизмов: direct/role/group assignments, hierarchy, resource policies, permission boundaries, explicit denies, organization policies, session policies и delegation. Review одной inline policy способен пропустить доступ через resource grant или inherited admin role.

Полезны два вида проверки:

- **reachability:** кто способен выполнить sensitive action над resource, включая indirect assume/delegate path;
- **delta:** добавляет ли новая policy доступ по сравнению с approved baseline.

AWS IAM Access Analyzer, например, умеет проверять policy, public/cross-account access и new-access delta. Это vendor-specific tooling, но общий принцип шире: policy-as-code проходит статический анализ, unit decision tests и integration negative tests до rollout.

### 7. Замкнуть feedback loop

После rollout audit показывает used permissions, denied attempts, privileged function use и unused access. По этим данным policy сужают. Но observation неполна: право на restore backup может не использоваться год, а отсутствие event может означать пробел audit. Поэтому удаление сверяют с owners, schedules, runbooks и failure scenarios.

Privilege review отвечает на четыре вопроса:

1. Существует ли ещё principal и его задача?
2. Нужны ли action и resource scope в текущей архитектуре?
3. Можно ли заменить standing privilege на JIT?
4. Есть ли path, по которому principal способен расширить собственные права?

Break-glass account хранится отдельно, защищён stronger authentication, выдаёт alert при использовании и требует post-use review. Если он участвует в обычной работе, это постоянный admin под другим названием.

## Пример или трассировка

Thumbnail worker получает queue job для object `t1/o7`, version `v3`. Изначально service role разрешает `storage:*` для всех buckets и `kms:Decrypt` для любого key. SSRF/RCE в image decoder тогда превращается в доступ ко всему object storage.

Job broker вместо этого выдаёт short-lived capability на 10 минут. Ниже provider-neutral псевдокод: названия effects описывают смысл разрешений, а не синтаксис конкретного IAM:

```text
allow object:read-version  uploads/t1/o7#v3
allow object:write         derived/t1/o7/thumb/*
allow crypto:decrypt       key/media
  when encryption_context.object == "t1/o7"
allow queue:ack            job/93
deny  object:list-container, object:delete, policy:change, crypto:export-key
```

Трассировка:

1. Worker читает ровно version `v3`, decrypt проходит только с ожидаемым encryption context.
2. Записывает thumbnail под server-chosen prefix и подтверждает `job/93`.
3. Exploit пытается перечислить контейнер через `object:list-container` — enforcement отвечает `AccessDenied`.
4. Попытка прочитать `uploads/t2/o8` получает `AccessDenied` из-за resource mismatch.
5. Попытка удалить `uploads/t1/o7` или изменить IAM также отклоняется.
6. Через 10 минут тот же credential не принимается; retry получает новый capability после повторной проверки job state.

Наблюдаемый результат: normal workflow завершается, но компрометация worker ограничена одним input и derived prefix на время job. Остаточный риск сохраняется: attacker способен исказить разрешённый thumbnail или расходовать CPU до job timeout. Content validation, sandbox и resource limits закрывают другие звенья threat model.

## Trade-offs

### Static narrow role или per-job capability

Static role проще, не зависит от broker на каждый job и легче кэшируется. Его resource scope шире всего множества задач worker. Per-job credential уменьшает blast radius по времени и объекту, но добавляет issuance latency, retry/renewal, clock и availability dependency. High-value cross-tenant processing оправдывает эту цену чаще, чем простой внутренний batch.

### Standing access или JIT elevation

Standing permission быстрее при incident и не зависит от approval system, но остаётся доступным attacker всё время. JIT сокращает окно и связывает elevation с actor/ticket, зато требует доступного control plane и emergency path. Для частого data-plane действия JIT на каждый запрос может быть лишним; для prod administration — обычно разумный default.

### Одна service identity или per-instance identity

Общая identity упрощает policy и quotas, но объединяет audit и revoke. Per-instance identity улучшает attribution и selective isolation, увеличивая churn и число bindings. Компромисс — стабильная service identity с short-lived instance credential и instance metadata в audit, если target policy не способен управлять миллионами principals.

### Минимальный policy или operational resilience

Слишком узкая policy без учёта failover, rotation и recovery ломает систему в редкий, но критичный момент. Выход не в вечном wildcard: emergency permission хранится как отдельный audited JIT/break-glass path, а recovery регулярно упражняется.

### Автоматическое сужение по usage или ручной review

Usage mining находит очевидно лишние actions и масштабируется. Он не видит неслучившиеся сценарии и зависит от полноты telemetry. Автоматически генерируемая policy — candidate; owner подтверждает сезонные, recovery и destructive operations, затем negative tests проверяют результат.

## Типичные ошибки

### «Read-only безопасен»

- **Неверное предположение:** отсутствие write исключает серьёзный ущерб.
- **Симптом:** support role выгружает все tenants, secrets или backups.
- **Причина:** resource scope и data classification проигнорированы.
- **Исправление:** ограничить rows/objects/fields, tenant и purpose; sensitive reads аудитировать как privileged effects.

### Общий runtime и migration credential

- **Неверное предположение:** приложению иногда нужен DDL, значит runtime role может иметь его всегда.
- **Симптом:** SQL injection меняет schema или создаёт нового DB user.
- **Причина:** deployment function смешана с request processing.
- **Исправление:** отдельный migration principal, короткий execution window и runtime role только для DML нужных tables.

### Policy проверена локально

- **Неверное предположение:** одна узкая identity policy описывает effective access.
- **Симптом:** resource policy, group hierarchy или assume-role path всё равно даёт admin.
- **Причина:** не вычислен union всех grants и delegation.
- **Исправление:** reachability/new-access analysis на полном policy graph и negative integration test.

### Least privilege сделан один раз

- **Неверное предположение:** permissions не меняются после запуска.
- **Симптом:** удалённый feature оставляет role, new API расширяет wildcard, бывший сотрудник сохраняет group.
- **Причина:** нет owner, expiry и review loop.
- **Исправление:** lifecycle account/role, unused-access analysis и review после архитектурных/организационных изменений.

### Usage log считается спецификацией

- **Неверное предположение:** неиспользованное за 30 дней право точно лишнее.
- **Симптом:** quarterly job, certificate rotation или disaster recovery ломается после автоматического удаления.
- **Причина:** observation window не содержит редкий сценарий.
- **Исправление:** сверить schedules/runbooks, тестировать recovery, standing право при возможности заменить JIT.

### Break-glass стал обычным admin

- **Неверное предположение:** сильный пароль делает постоянное использование emergency account приемлемым.
- **Симптом:** действия плохо атрибутируются, alert игнорируется, credential широко известен.
- **Причина:** обход normal policy превратился в workflow.
- **Исправление:** отдельное хранение, short-lived checkout, approval/alert, post-use review и устранение причин регулярного доступа.

## Когда применять

Least privilege применяют к людям, services, CI/CD, database users, cloud roles, encryption keys, queues, network paths и support tooling. Начинать стоит с control-plane и cross-tenant effects: IAM, secrets, KMS, schema changes, exports, deletion и billing. Затем сужают массовые data-plane roles по actions/resources и времени.

Изменение считается готовым, когда положительный workflow проходит, запрещённые соседние actions получают deny, effective policy не содержит неожиданный indirect path, а revoke/expiry действительно останавливает target effect. Для critical permissions дополнительно проверяют compromise одного workload: какие данные и control-plane actions доступны attacker и как быстро область сокращается.

## Источники

- [NIST SP 800-53 Rev. 5: Security and Privacy Controls for Information Systems and Organizations](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final) — NIST, SP 800-53 Rev. 5, release 5.2.0 от 2025-08-27; control AC-6 и enhancements, проверено 2026-07-18.
- [NIST SP 800-207: Zero Trust Architecture](https://csrc.nist.gov/pubs/sp/800/207/final) — NIST, SP 800-207, август 2020, проверено 2026-07-18.
- [RFC 9700: Best Current Practice for OAuth 2.0 Security](https://www.rfc-editor.org/rfc/rfc9700.html) — IETF, BCP 240 / RFC 9700, январь 2025; section 2.3 об access token privilege restriction, проверено 2026-07-18.
- [AWS IAM: Policies and permissions](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html) — Amazon Web Services, IAM documentation о least privilege и refinement по access activity, проверено 2026-07-18.
- [AWS IAM Access Analyzer: custom policy checks](https://docs.aws.amazon.com/IAM/latest/UserGuide/access-analyzer-checks-validating-policies.html) — Amazon Web Services, IAM Access Analyzer documentation о new/specified/public access checks, проверено 2026-07-18.
- [NIST SP 800-204: Security Strategies for Microservices-based Application Systems](https://csrc.nist.gov/pubs/sp/800/204/final) — NIST, SP 800-204, август 2019, проверено 2026-07-18.
