---
aliases:
  - Role-Based Access Control and Attribute-Based Access Control
  - Role-based и attribute-based access control
  - Ролевой и атрибутный контроль доступа
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/авторизация
статус: проверено
---

# RBAC и ABAC

## TL;DR

Role-Based Access Control (RBAC) назначает permissions ролям, а users или workloads связывает с ролями. Это уменьшает административную сложность, когда права следуют устойчивым обязанностям: accountant, support-reader, deployer. Attribute-Based Access Control (ABAC) вычисляет решение по атрибутам subject, object, action и environment; он естественно выражает tenant, ownership, classification, region, время и состояние ресурса.

RBAC проще обозревать и сертифицировать, но попытка закодировать каждое условие новой ролью приводит к role explosion. ABAC выразительнее, зато переносит сложность в качество атрибутов, policy semantics, тестирование и объяснимость. В backend часто выигрывает гибрид: роль или scope разрешает класс действий, а attributes ограничивают конкретный object и контекст. Любая модель требует deny-by-default, полного mediation на каждом entry point, доверенного происхождения атрибутов, versioned policy и атомарной проверки изменяемого состояния.

## Ментальная модель

Авторизация отвечает на один конкретный вопрос:

```text
decision = policy(subject, action, resource, environment)
```

RBAC предварительно группирует permissions через организационный смысл:

```text
users U --UA--> roles R --PA--> permissions P
```

Где `UA ⊆ U × R` — user-role assignment, `PA ⊆ P × R` — permission-role assignment. В core RBAC session активирует подмножество назначенных пользователю roles. Иерархия roles добавляет inheritance, а constraints задают separation of duty.

ABAC не требует роли как обязательной промежуточной сущности:

```text
permit if
  subject.department == resource.department
  and subject.clearance >= resource.classification
  and action == "read"
  and environment.network_zone == "managed"
```

Роль при этом может быть одним из subject attributes. Граница между моделями определяется не синтаксисом policy, а тем, из чего выводится право и как им управляют.

## Как устроено

### Общий authorization pipeline

Независимо от модели решение проходит одни и те же стадии:

```text
authenticated principal
  -> trusted subject attributes / active roles
  -> resource lookup with object attributes
  -> policy decision + reason + policy version
  -> enforcement before effect
  -> audit
```

Policy Enforcement Point (PEP) перехватывает действие. Policy Decision Point (PDP) вычисляет permit, deny или ошибку. Policy Information Point (PIP) поставляет attributes, а Policy Administration Point (PAP) управляет policy. Эти роли могут жить в одной библиотеке; разделение описывает ответственность, а не обязательные микросервисы.

Инварианты:

- без явного permit результат deny;
- policy вызывается на каждом security-relevant path, включая jobs и admin tools;
- client input не становится доверенным subject/resource attribute;
- отсутствующий, устаревший или конфликтующий attribute обрабатывается по выбранному safe rule;
- решение привязано к точному action и resource, а не к названию HTTP endpoint;
- меняющееся состояние проверяется рядом с commit, чтобы избежать TOCTOU.

### Core RBAC

Permission полезно моделировать как пару `(operation, object type/scope)`, например `invoice.approve` для production tenant. Role объединяет permissions по job function. User получает role через управляемый assignment, а в session активирует нужное подмножество. Последний шаг поддерживает least privilege: сотрудник с несколькими ролями не обязан постоянно работать со всеми полномочиями.

Hierarchical RBAC задаёт partial order ролей. Senior role наследует permissions junior role, поэтому иерархия уменьшает повторы, но расширяет blast radius ошибки: один неверный edge способен добавить десятки транзитивных permissions. Иерархию проверяют как effective permissions, а не по локальной записи роли.

Separation of duty (SoD) бывает:

- **static**: несовместимые roles нельзя назначить одному subject;
- **dynamic**: roles можно назначить, но нельзя активировать вместе в одной session или transaction;
- **object/history-aware**: инициатор конкретной операции не может её же утвердить.

Последний вариант уже требует resource/history attributes и часто выходит за чистый RBAC. Название role не должно скрывать object-level rule.

### Attribute-Based Access Control

NIST SP 800-162 определяет ABAC как решение по attributes subject, object, requested operation и, при необходимости, environment conditions относительно policy, rules или relationships. Выразительность появляется только вместе с контрактом атрибутов.

Для каждого security-relevant attribute задают:

| Свойство | Пример вопроса |
| --- | --- |
| Authority | Кто имеет право утверждать `employment_status` или `tenant_id`? |
| Provenance | Attribute пришёл из IdP, resource DB, device service или request body? |
| Freshness | Как долго допустимо кэшировать role, risk score или object owner? |
| Cardinality | Одно значение, множество, hierarchy или unknown? |
| Semantics | `region=EU` означает место user, data residency или deployment? |
| Failure rule | Missing/timeout даёт deny, cached decision или restricted mode? |

Subject claims из JWT удобны, но фиксируют snapshot на время issuance. Object attributes обычно читаются у владельца ресурса. Environment attributes вроде времени и network zone должны приходить из доверенного enforcement context, а не из заголовка клиента.

Policy language обязана определить combining semantics. Если одна rule говорит permit, а другая deny, результат зависит от `deny-overrides`, `permit-overrides`, first-applicable или другого алгоритма. OASIS XACML 3.0 формализует PDP/PEP, request attributes, decisions, obligations и combining algorithms, но тот же контракт нужен и собственной DSL.

### Гибрид RBAC + ABAC

Обычный backend сначала проверяет coarse permission, затем resource conditions:

```text
role=invoice_manager grants invoice.approve
AND subject.tenant_id == invoice.tenant_id
AND subject.approval_limit >= invoice.amount
AND subject.id != invoice.created_by
AND invoice.state == submitted
```

Роль отвечает на устойчивый вопрос «какую функцию выполняет subject», attributes — «допустимо ли это действие над этим объектом в момент решения». Такая декомпозиция сдерживает role explosion и оставляет понятный каталог business capabilities.

### Enforcement, время и consistency

Gateway способен проверить token и coarse permission, но обычно не владеет актуальными object attributes. Окончательный PEP располагают у business invariant. Прямой SQL query тоже ограничивают tenant/resource scope, чтобы unauthorized row не попала в application memory.

Для mutation отдельная проверка и последующий `UPDATE` создают окно:

```text
authorize(invoice.state == "submitted")
// другой transaction меняет state
UPDATE invoices SET state = "approved" WHERE id = ?
```

Исправление включает изменяемые resource-local preconditions в atomic write:

```sql
UPDATE invoices
SET state = 'approved', approved_by = :subject
WHERE id = :id
  AND tenant_id = :tenant
  AND state = 'submitted'
  AND created_by <> :subject;
```

Affected rows `0` означает, что resource-предусловие больше не истинно; решение нельзя считать ранее выданным permit. Но этот `UPDATE` атомарно защищает только `tenant_id`, `state` и `created_by`. Даже если authoritative membership и attributes живут в той же БД, один `EXISTS` при обычном `READ COMMITTED` видит statement snapshot: concurrent revoke способен изменить другую строку после чтения, но до commit.

Для строгого порядка effect и revoke должны участвовать в одном coordination protocol. Например, transaction блокирует membership row, проверяет revision/attributes, затем меняет invoice; revoke/update membership обязан взять конфликтующий lock:

```sql
BEGIN;
SELECT revision, role, department, approval_limit
FROM tenant_memberships
WHERE subject_id = :subject AND tenant_id = :tenant
FOR SHARE;
-- проверить revision=17, role, department и approval_limit
UPDATE invoices ... WHERE id=:id AND tenant_id=:tenant
  AND state='submitted' AND created_by<>:subject;
COMMIT;
```

[[30 Данные/Уровни изоляции транзакций|`SERIALIZABLE`]] с обязательным retry может дать другой строгий вариант, если конкретная СУБД обнаруживает конфликт чтения membership и записи invoice. Если role, department, approval limit или membership находятся во внешнем policy store, общей атомарности уже нет. Нужен явный freshness contract: accepted stale window, authorization lease или согласованная revision/lock у commit boundary. Обычная повторная network-проверка прямо перед `UPDATE` лишь сужает TOCTOU, но не устраняет его; требование мгновенного revoke оплачивается координацией с authoritative store.

Audit event хранит subject, action, resource ID, outcome, reason code, policy version и значимые attribute versions без raw secrets/PII. «Denied by policy» недостаточно для расследования rollout; `approval_limit_exceeded` или `tenant_mismatch` объясняет поведение, не раскрывая лишнее клиенту.

## Пример или трассировка

Policy для утверждения invoice:

```text
RBAC:
  invoice_manager -> invoice.approve

ABAC constraints:
  subject.tenant_id == invoice.tenant_id
  subject.department == invoice.department
  subject.approval_limit >= invoice.amount
  subject.id != invoice.created_by
  invoice.state == "submitted"
```

Invoice `i7`: tenant `t1`, department `finance`, amount `120000`, state `submitted`, creator `alice`.

1. Alice имеет role `invoice_clerk`, а не `invoice_manager`. Coarse RBAC даёт deny: permission отсутствует.
2. Bob имеет `invoice_manager`, tenant/department совпадают, но `approval_limit=100000`. ABAC даёт deny с reason `approval_limit_exceeded`.
3. Carol имеет `invoice_manager`, tenant `t1`, department `finance`, limit `250000`, и она не creator. PDP даёт permit для policy version `42` и subject-attribute revision `17`.
4. В этом примере authoritative membership хранится в той же БД. Transaction берёт `FOR SHARE` на membership Carol, проверяет revision `17`, затем выполняет conditional `UPDATE` invoice. Revoke должен обновить ту же membership row и потому получает однозначный порядок до либо после effect. Изменена одна invoice row; audit фиксирует permit, policy `42` и attribute revision `17`.
5. Повтор того же запроса Carol получает conflict/deny: state уже `approved`, affected rows `0`.

Наблюдаемый результат: role открывает capability, но не обходит amount, tenant и separation-of-duty constraints. Concurrent request не может применить устаревший permit к уже изменившемуся invoice.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| 1992–2000 | Ранние NIST RBAC models формализовали роли, permissions и constraints в нескольких вариантах | Unified NIST model 2000 года выделил core, hierarchical, constrained и symmetric RBAC | Появился общий словарь, на котором основан стандарт | NIST RBAC model |
| ANSI/INCITS 359-2004 → INCITS 359-2012 | Первая американская consensus specification RBAC | Стандарт обновлён в 2012 году; NIST project на 2026-07-18 называет INCITS 359-2012 текущей редакцией | При сравнении реализаций нужно уточнять поддержку core, hierarchy и SoD, а не довольствоваться словом RBAC | NIST RBAC project |
| NIST SP 800-162, 2014 → update 2, 2019 | Опубликовано определение и considerations ABAC | Финальная публикация включает updates по 2019-08-02 | Версионные ссылки на NIST ABAC должны указывать обновлённую редакцию | NIST SP 800-162 |

## Trade-offs

### RBAC или ABAC

RBAC выигрывает при небольшом числе устойчивых job functions: effective access легко показать как user → roles → permissions, а review понятен владельцам бизнеса. Он проигрывает, когда role начинает кодировать комбинацию tenant × region × project × time. ABAC выражает эти условия напрямую, но требует attribute governance, policy tests и хороших reason codes.

### Чистая модель или гибрид

Чистый RBAC проще стандартизировать, чистый ABAC единообразно выражает динамические rules. Гибрид добавляет два слоя решения, зато роли остаются бизнес-понятными, а object conditions не размножают их. Важно не создать две противоречивые policy: coarse layer только сужает множество кандидатов, owner resource принимает окончательное решение.

### Локальная policy library или удалённый PDP

Library даёт низкую latency и не создаёт network dependency, но rollout policy связан с artifact/snapshot distribution. Удалённый PDP централизует governance и decision logs, однако становится availability dependency. Компромисс — подписанные versioned bundles с локальным evaluator; тогда нужны expiry, anti-rollback и безопасное поведение при устаревании.

### Live attributes или claims snapshot

Live lookup быстрее отражает revoke и state change, но добавляет latency и coupling. Claims в short-lived token автономны, зато устаревают до expiry. Для high-risk mutation критичные object/state attributes проверяют live; стабильные identity facts допустимо переносить в token с ограниченным lifetime.

## Типичные ошибки

### Role кодирует каждый контекст

- **Неверное предположение:** любое новое условие нужно выразить новой ролью.
- **Симптом:** `eu_t1_invoice_manager_under_100k` и тысячи комбинаций, которые нельзя обозреть.
- **Причина:** dynamic/object attributes смешаны с job function.
- **Исправление:** оставить capability в RBAC, а tenant, region, amount и state перенести в ABAC constraints.

### Attribute берётся из request

- **Неверное предположение:** authenticated user честно передаст свой tenant или clearance.
- **Симптом:** смена header расширяет доступ.
- **Причина:** value не имеет trusted authority/provenance.
- **Исправление:** subject attributes брать из проверенной identity/membership, object attributes — у владельца ресурса; client input только идентифицирует запрашиваемый объект.

### Default permit при missing attribute

- **Неверное предположение:** неизвестное значение можно трактовать как отсутствие ограничения.
- **Симптом:** outage PIP или новая схема данных открывает доступ.
- **Причина:** three-valued result collapsed в permit.
- **Исправление:** явно определить `missing`, `indeterminate` и combining rule; sensitive action при неопределённости отклонять.

### Проверка только в gateway

- **Неверное предположение:** все entry points проходят edge и gateway знает resource state.
- **Симптом:** consumer, job или direct internal call обходит object policy.
- **Причина:** PEP оторван от business effect.
- **Исправление:** gateway оставляет coarse filter, owner resource выполняет обязательный decision на каждом path.

### Permit живёт дольше состояния

- **Неверное предположение:** результат authorization можно свободно применять позже.
- **Симптом:** approve выполняется после смены owner/state или отзыва membership.
- **Причина:** TOCTOU и незафиксированная revision attributes.
- **Исправление:** atomic condition, transaction lock или version check рядом с commit.

## Когда применять

RBAC выбирают для управляемого каталога business capabilities, устойчивых должностных функций, delegated administration и separation of duties. ABAC добавляют, когда решение зависит от tenant, ownership, classification, location, risk, amount, времени или lifecycle state ресурса. Если доступ следует отношениям в графе, например member folder или viewer document через parent, стоит отдельно оценить relationship-based access control (ReBAC), а не маскировать граф сотнями attributes.

Перед rollout строят decision table с permit и deny cases, проверяют effective permissions после hierarchy/combining, cross-tenant negatives, missing/stale attributes, policy rollback и PDP outage. Модель готова не тогда, когда happy path разрешён, а когда непредусмотренный path надёжно отклоняется и решение можно объяснить.

## Источники

- [The NIST Model for Role-Based Access Control: Towards a Unified Standard](https://www.nist.gov/publications/nist-model-role-based-access-control-towards-unified-standard) — NIST, unified RBAC model, июль 2000, проверено 2026-07-18.
- [NIST Role Based Access Control project](https://csrc.nist.gov/projects/role-based-access-control) — NIST, archived project; указывает INCITS 359-2012 как текущую редакцию стандарта, страница обновлена 2026-03-04, проверено 2026-07-18.
- [NIST SP 800-162: Guide to Attribute Based Access Control Definition and Considerations](https://csrc.nist.gov/pubs/sp/800/162/upd2/final) — NIST, SP 800-162 от января 2014 с updates по 2019-08-02, проверено 2026-07-18.
- [Adding Attributes to Role-Based Access Control](https://www.nist.gov/publications/adding-attributes-role-based-access-control) — NIST, Kuhn, Coyne, Weil, июнь 2010, проверено 2026-07-18.
- [eXtensible Access Control Markup Language Version 3.0](https://docs.oasis-open.org/xacml/3.0/xacml-3.0-core-spec-os-en.html) — OASIS, XACML 3.0 OASIS Standard от 2013-01-22, проверено 2026-07-18.
- [NIST SP 800-53 Rev. 5: Security and Privacy Controls for Information Systems and Organizations](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final) — NIST, SP 800-53 Rev. 5, release 5.2.0 от 2025-08-27; controls AC-3, AC-5 и AC-6, проверено 2026-07-18.
