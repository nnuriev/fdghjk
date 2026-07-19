---
aliases:
  - Data retention
  - Data deletion
  - Политика хранения и удаления данных
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/приватность
статус: проверено
---

# Data retention и deletion

## TL;DR

Retention — исполняемая policy: какие данные, ради какой цели, с какого события и до какого момента разрешено хранить. Deletion — распределённый workflow, который прекращает доступ, удаляет live copies и derivatives, предотвращает resurrection из replica/backup и оставляет минимальное доказательство выполнения. `DELETE FROM users` закрывает только одну строку в одном хранилище.

Надёжная схема использует authoritative deletion intent и tombstone/generation. Сначала система блокирует новые reads/writes по удаляемому scope, затем идемпотентно очищает primary stores, object versions, indexes, caches, analytics и очереди, собирает acknowledgements и выполняет reconciliation. Immutable backups могут исчезать по отдельному bounded schedule; любой restore обязан применить deletion ledger до возврата трафика. Legal hold — отдельное авторизованное состояние, а не флаг без owner и срока.

## Область применимости

Заметка охватывает lifecycle policy прикладных данных, удаление одного subject/tenant, derived copies, replicas, caches, backups, cryptographic erase и media sanitization. Архивирование как продуктовая функция, records management конкретной отрасли, бухгалтерские сроки и юридическое толкование запросов остаются вне scope.

GDPR используется как конкретный пример jurisdiction-specific требований. Article 5(1)(e) задаёт storage limitation, Article 17 — основания права на erasure и исключения, Article 19 — уведомление recipients о rectification/erasure/restriction с оговорёнными исключениями. Регламент не задаёт одну универсальную цифру retention для всех данных. Applicable purpose, authority, срок и legal hold утверждают privacy/legal/records owners.

NIST SP 800-88 Rev. 2 от сентября 2025 года задаёт рекомендации по media sanitization при reuse/disposal и supersedes Rev. 1 от декабря 2014 года. Это не спецификация удаления строки пользователя из распределённого приложения и само по себе не универсальное регуляторное требование. Руководство становится релевантным, когда нужно сделать target data на information storage media (ISM) невосстановимыми либо применить cryptographic erase; обязательность конкретного метода задаёт применимая policy или норма.

## Ментальная модель

Retention и deletion образуют state machine, а не cron-скрипт:

```text
active
  -> expired_or_requested
  -> access_blocked
  -> purge_live_in_progress
  -> purged_live
  -> backup_horizon_passed
  -> verified_complete

legal_hold: отдельное ограничение, которое приостанавливает допустимые purge-шаги
```

Состояния `access_blocked` и `physically gone` различаются. Первое быстро прекращает обычную обработку. Второе требует удалить copies, дождаться replicas, учесть immutable backups и проверить результат.

Инварианты:

- у каждого data class есть owner, purpose, retention trigger и проверяемый expiry rule;
- истёкшие данные недоступны business path независимо от скорости физической очистки;
- deletion command имеет стабильные scope и generation, поэтому retry безопасен;
- late event, lagging replica или restore не могут воскресить более старую generation;
- каждая долговечная копия зарегистрирована либо имеет доказанный верхний предел жизни;
- legal hold ограничен authority, scope, reason, review date и audit;
- completion подтверждается acknowledgements и независимой reconciliation, а не отправкой сообщения;
- evidence не сохраняет удаляемый payload под новым именем.

## Как устроено

### Retention policy представляется данными

Фраза «храним 90 дней» неполна. Для каждого класса policy фиксирует:

- data class и system of record;
- purpose и применимую authority;
- owner и downstream processors/recipients;
- start event: creation, contract end, last interaction, case closure или другой доменный факт;
- duration либо критерий, включая timezone и calendar semantics;
- grace/recovery window, если она разрешена;
- срок прекращения online access и срок purge live copies;
- backup horizon и поведение restore;
- deletion/sanitization method по типу copy;
- legal hold precedence, approver и review;
- evidence, validation и escalation при failure.

Trigger хранится как доменное событие или вычисляемая дата с версией policy. Иначе изменение правила задним числом даёт неоднозначный результат. Поле `expires_at` полезно для исполнения, но должно быть воспроизводимо из `trigger + policy_version` либо явно мигрировано.

GDPR Article 30 требует, где возможно, указывать envisaged time limits for erasure по категориям данных в records of processing. Для backend это хорошо совпадает с machine-readable catalog. Но конкретная policy определяется применимыми нормами и purpose, а не самим Article 30.

### Soft delete, hard delete и sanitization решают разные задачи

**Soft delete** ставит `deleted_at` или статус. Он быстро скрывает record и даёт undo, но bytes, indexes и backups остаются. Без фильтра на одном query path soft-deleted data снова видны. Это product/recovery state, а не доказательство erasure.

**Logical hard delete** удаляет row/object через интерфейс хранилища. СУБД может оставить старую page version в WAL, MVCC, free space, snapshot или replica. На SSD wear levelling скрывает физические cells от обычного overwrite. Hard delete нужен для live lifecycle, но не равен media sanitization.

**Media sanitization** работает с target data на носителе. NIST SP 800-88 Rev. 2 различает:

- `clear`: логические техники для всех user-addressable locations, защищающие от простого non-invasive recovery через обычный interface;
- `purge`: логические или физические техники, после которых recovery infeasible даже state-of-the-art laboratory methods, а media потенциально остаётся пригодным;
- `destroy`: recovery infeasible и media больше нельзя использовать для хранения.

Метод выбирают по confidentiality, типу media и дальнейшему использованию. Обычный overwrite не достигает всех spare cells SSD; NIST рекомендует matching technique к конкретному media и актуальным standards/vendor capabilities. Verification проверяет, что technique завершилась, validation решает, достаточен ли результат для риска.

### Deletion начинается с authoritative intent

Запрос сначала аутентифицируют, авторизуют и связывают с устойчивым internal identifier. Email или username могут быть переиспользованы и не должны единолично задавать scope. Policy engine проверяет purpose, legal hold и применимые исключения.

Координатор создаёт:

```text
deletion_job_id
scope: subject/tenant/object + generation
policy_version, authority, requested_at
required_consumers
state и per-consumer acknowledgements
```

В той же транзакции owner записывает tombstone/generation и outbox event. Tombstone немедленно запрещает новые business reads/writes и остаётся дольше максимального lag/replay window, иначе старый event способен создать данные заново. Доставка deletion event строится поверх [[40 Распределённые системы/Transactional outbox и Change Data Capture|transactional outbox]], а consumers применяют его at-least-once и идемпотентно.

Одного вызова `DELETE` недостаточно. Consumer перечисляет свои copies: primary rows, secondary indexes, object versions, materialized views, local cache, search, feature store, queue/DLQ и exports под его контролем. Ack включает job/generation, policy version, обработанный scope, outcome и время. Счётчик удалённых строк полезен для диагностики, но `0` может означать и «уже удалено», и «неверный ключ»; нужна ожидаемая semantics и reconciliation.

Coordinator завершает live phase только после required acks и negative checks. Периодический reconciler сравнивает registry, tombstones и фактические stores, ловит consumer, который пропустил event или появился после запуска policy.

### Replicas и caches требуют защиты от resurrection

В leader-replica storage удаление проходит обычный replication path. Пока replica отстаёт, read routing не должен отдавать старое значение после access cutoff. Либо reads проверяют authoritative tombstone/generation, либо удаляемый scope перестаёт обслуживаться на stale replicas.

В eventually consistent хранилище tombstone нельзя собирать раньше, чем все допустимые replicas и anti-entropy paths увидели deletion. Иначе старая версия побеждает отсутствующее значение. Этот механизм связан с [[30 Данные/Репликация данных|replication и конфликтами версий]].

Cache eviction ускоряет исчезновение copy, но не даёт строгой глобальной границы без bounded invalidation. Для private content authoritative read path проверяет deletion generation или короткоживущий grant; старый versioned URL сам по себе остаётся известным. Ограничения purge разобраны в [[50 Проектирование систем/Cache и CDN|заметке о Cache и CDN]].

Очереди и event logs требуют отдельного решения. Удалить сообщение из append-only stream выборочно часто нельзя. Consumer обязан проверять tombstone при materialization, а retention stream задаёт верхний предел raw copy. Compaction по key помогает только если формат и broker действительно гарантируют удаление старых values в нужный срок; название `compacted` не равно немедленному purge.

### Backup хранит прошлое, поэтому restore обязан знать удаления

Immutable backup полезен против ransomware и ошибочного массового delete. Выборочно переписать его трудно и иногда разрушает immutability guarantee. Распространённый технический контракт:

1. backup изолирован, доступен только recovery role и имеет bounded retention;
2. deleted data не возвращаются в ordinary processing из backup;
3. deletion ledger/tombstones хранятся дольше максимального backup horizon;
4. restore поднимается в quarantine;
5. до открытия traffic применяются все deletions и retention rules, произошедшие после backup point;
6. проводится negative verification по удалённым scopes.

Этот контракт не устанавливает юридическую допустимость хранения конкретных данных в backup: её определяет применимая policy. Он устраняет техническую ошибку, когда valid backup молча отменяет более новое удаление.

Backup completion отслеживается отдельно от live purge. Успешный job может иметь состояния `live_complete` и `final_complete_after_backup_horizon`. Пользователю и auditor нельзя обещать физическое исчезновение всех copies раньше доказанного срока.

### Cryptographic erase работает только при подходящей гранулярности ключа

Cryptographic erase (CE) делает ciphertext недоступным через sanitization target cryptographic keys. Он особенно полезен для virtual/cloud storage, где владелец не управляет физическим media. Быстрота CE не отменяет preconditions NIST SP 800-88 Rev. 2:

- sensitive data никогда не сохранялись plaintext на этом media после последней sanitization;
- cryptographic implementation и key generation обладают нужной assurance;
- можно уничтожить все copies целевого key либо ключей ниже выбранного уровня;
- escrow, backup, injected keys и ранее unwrapped copies учтены;
- долгоживущая confidentiality допускает зависимость от стойкости ciphertext в будущем;
- операция key sanitization документируется, проверяется и валидируется.

Per-object DEK позволяет удалить один объект уничтожением единственного wrapped DEK, если больше нет recoverable copies DEK/plaintext. Per-tenant KEK подходит для полного offboarding tenant. Глобальный KEK нельзя уничтожить ради одного пользователя: исчезнут чужие данные. Подробный key lifecycle описан в [[20 Бэкенд/Шифрование данных at rest|заметке о шифровании at rest]].

Rotation не равна CE. KMS обычно оставляет старые versions для decrypt, пока operator их не уничтожит. Удаление alias, запрет новых encrypt или выпуск нового KEK не делает старый ciphertext недоступным.

### Legal hold ограничивает удаление, но не расширяет использование

GDPR Article 17 содержит основания erasure и исключения, в том числе обработку, необходимую для legal obligation, public-interest tasks, некоторых архивных/исследовательских целей и legal claims. Поэтому команда backend не должна переводить любой запрос пользователя прямо в безусловный physical delete и не должна сама изобретать исключение.

Legal/records owner выпускает hold с authority, reason, precise scope, start, approver, review/expiry и allowed processing. Hold блокирует несовместимые purge-шаги, но не открывает data для обычной аналитики или product use. Доступ сужается, а постановка, продление и снятие hold попадают в [[20 Бэкенд/Audit logging|audit log]].

Если данные раскрывались recipients, GDPR Article 19 требует сообщить им о rectification/erasure/restriction, кроме случаев невозможности или disproportionate effort. Технически recipient registry и outbound event становятся частью workflow; юридическую применимость исключения решает не consumer retry loop.

### Доказательство удаления тоже минимизируется

Evidence содержит job ID, authority/policy version, data classes, systems, requested/started/completed times, outcomes, errors, key/sanitization operation references и verification result. Raw identifier или payload удаляемого человека туда не копируют. Если нужна корреляция, внутренний subject reference отделяют от evidence и удаляют/ограничивают по отдельной утверждённой policy.

Hash low-entropy email не решает задачу: его можно перебрать и снова связать с человеком. Минимальный opaque job ID подтверждает процесс без сохранения исходного address. Срок evidence определяется отдельным purpose и обязательством; audit не должен становиться вечным обходным archive.

## Сквозной пример: удаление tenant

Для примера policy сервиса задаёт: ordinary access блокируется сразу после принятого запроса, live systems очищаются не позднее 24 часов, immutable backup copies стареют максимум 35 дней. Это параметры сценария, а не требование GDPR или NIST.

1. После проверки authority coordinator создаёт `job=d81`, scope `{tenant=t7, generation=44}`. Hold отсутствует.
2. В транзакции tenant переводится в `deletion_pending`, записывается generation `44` и outbox event. Gateway и data owners отказывают в новых reads/writes tenant `t7`, даже если replica ещё хранит строки.
3. Account, billing, object, search и analytics consumers получают один и тот же job. Повтор event безопасен: каждый хранит highest applied deletion generation.
4. Object service удаляет все object versions и wrapped per-object DEKs; search удаляет documents; analytics удаляет purpose pseudonyms; cache invalidates keys. Каждый consumer ack-ает результат. Raw PII в ack нет. Per-tenant KEK остаётся доступным для восстановления допустимых backup copies до шага 7.
5. Reconciler делает negative lookups и сравнивает registry с required consumers. Только после всех acks coordinator ставит `live_complete`.
6. Backup catalog показывает последний snapshot с tenant `t7` и его expiry. Deletion ledger хранится за пределами snapshots. Если recovery случится завтра, restore остаётся в quarantine, replay применяет generation `44`, validation подтверждает отсутствие tenant, и лишь затем возвращается traffic.
7. После исчезновения последнего backup и проверки key references coordinator уничтожает выделенный tenant `t7` KEK, валидирует недоступность ciphertext, затем job получает `verified_complete`. Audit evidence сохраняет `d81`, policy version и outcomes, но не email владельца и не удалённые invoices.

Если на шаге 1 обнаружен действующий hold, system переходит в `restricted_on_hold`: ordinary processing прекращается, разрешённые hold-access остаются узкими, а job не заявляет deletion complete.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| Декабрь 2014 | NIST SP 800-88 Rev. 1 содержал подробную media-specific guidance | Rev. 2 supersedes Rev. 1 с сентября 2025 года | Новые требования и документы должны ссылаться на Rev. 2 | NIST SP 800-88 Rev. 2 |
| Сентябрь 2025 | Guidance была сильнее сосредоточена на отдельных sanitization decisions и techniques | Rev. 2 переносит фокус на enterprise media sanitization program, trust к vendor implementation и актуальные external standards; CE получил отдельное расширенное руководство | Нельзя механически копировать старые overwrite tables; нужны program, media-specific current standard, verification и validation | NIST announcement о Rev. 2 |
| Август 2025 | NIST SP 800-53 Rev. 5 использовался в предыдущем patch release | Release 5.2.0 — актуальная версия control catalog на дату проверки | Control mapping для retention/sanitization указывает release 5.2.0 и controls SI-12, MP-6, CP-9, AU-11 | NIST SP 800-53 Rev. 5 release 5.2.0 |

## Trade-offs

### Soft delete или немедленный hard delete

Soft delete даёт undo и защищает от operator error, но сохраняет data и риск обхода фильтра. Hard delete уменьшает live footprint, зато recovery требует backup и усложняет расследование ошибочного запроса. Если grace разрешён policy, soft state имеет короткий явный срок и недоступен ordinary reads; бесконечная «корзина» retention не выполняет.

### TTL в каждом store или координатор удаления

Локальный TTL прост, дешёв и хорошо подходит данным с независимым `expires_at`. Он не доказывает одновременное удаление derivatives и recipients. Координатор даёт status, retries и evidence, но создаёт control-plane dependency и registry. Часто TTL очищает локальные bytes, а coordinator управляет cross-system intent и completeness.

### Immutable backup или selective deletion

Immutable backup сильнее защищает recovery от attacker и массовой ошибки. Selective rewrite сокращает retention конкретного subject, но дорого, создаёт новые backup versions и расширяет права оператора. Bounded backup lifetime плюс deletion-on-restore сохраняет immutability; подходит ли этот контракт правовым требованиям, утверждает policy owner.

### Cryptographic erase или physical/logical purge

CE быстро работает на encrypted virtual storage и может дать точечность при per-object/per-tenant key. Он зависит от key provenance и всех копий; ошибки key scope приводят к массовой потере или ложному удалению. Storage-native purge/destroy меньше зависит от будущей криптостойкости, но на shared cloud media часто недоступен data owner и хуже подходит выборочному объекту.

### Централизованный deletion service или domain ownership

Центральный coordinator видит прогресс и единообразно применяет policy. Он не знает внутренние copies каждого domain. Domain owners должны исполнять и подтверждать deletion; coordinator хранит contract, required set и evidence. Полная централизация data access ради удаления обычно создаёт более опасный privilege.

## Типичные ошибки

### TTL есть только в primary table

- **Неверное предположение:** expiry строки удалит весь lifecycle.
- **Симптом:** record исчезает из API, но остаётся в search, object versions и analytics.
- **Причина:** retention задан storage-механизму, а не data graph.
- **Исправление:** registered consumers, deletion key, bounded copy retention, acknowledgements и reconciliation.

### Tombstone удаляется раньше lagging copies

- **Неверное предположение:** отсутствие значения сильнее старой версии.
- **Симптом:** repair или late event воссоздаёт удалённый объект.
- **Причина:** нет generation, а tombstone хранится меньше максимального replay/anti-entropy window.
- **Исправление:** монотонная deletion generation, reject stale writes и подтверждение convergence до tombstone GC.

### Restore возвращает удалённые данные

- **Неверное предположение:** valid backup можно сразу открыть пользователям.
- **Симптом:** после disaster recovery снова виден удалённый account.
- **Причина:** deletion ledger находился только внутри восстановленного snapshot либо не replay-ился.
- **Исправление:** независимый durable ledger, quarantine restore, replay и negative validation до traffic.

### Rotation названа cryptographic erase

- **Неверное предположение:** новый KMS key делает старый ciphertext нечитаемым.
- **Симптом:** старый key version продолжает успешно decrypt.
- **Причина:** rotation сохраняет historical key material, а все copies target key не sanitised.
- **Исправление:** проверить CE preconditions, уничтожить нужный wrapped DEK/key copies и валидировать недоступность.

### Legal hold не имеет срока и владельца

- **Неверное предположение:** безопаснее никогда ничего не удалять при потенциальном споре.
- **Симптом:** данные навсегда остаются в обычных systems и используются вне причины hold.
- **Причина:** hold реализован как необъяснимый boolean.
- **Исправление:** authority, exact scope, reason, approver, review/expiry, restricted access и audit каждого изменения.

### Evidence сохраняет удалённый identifier

- **Неверное предположение:** hash email нужен, чтобы доказать удаление.
- **Симптом:** audit dataset позволяет перебрать и восстановить связь с человеком.
- **Причина:** low-entropy identifier перенесён в новый бессрочный store.
- **Исправление:** opaque job ID, минимальные outcomes и отдельная ограниченная mapping policy только при доказанной необходимости.

### Filesystem overwrite применяется к SSD

- **Неверное предположение:** запись нулей в файл затронула все физические cells.
- **Симптом:** остатки остаются в overprovisioned/wear-levelled областях.
- **Причина:** user interface не адресует всё media.
- **Исправление:** актуальная media-specific purge technique/vendor command, CE с выполненными preconditions либо destroy; затем verification и validation.

## Когда применять

Retention policy нужна каждому долговечному data class, а deletion workflow — везде, где данные копируются более чем в один independently managed store. Чем больше replicas, exports, feature pipelines и immutable backups, тем меньше пользы от локального `DELETE` без coordinator и restore protocol.

Перед выпуском фиксируют policy schema, trigger semantics, data registry, tombstone/generation, consumer contract, retry/idempotency, legal hold state, backup horizon, CE/media method и evidence retention. Проверка включает replay старого event, lagging replica, недоступный consumer, duplicate deletion, восстановление backup, premature key destruction и reconciliation новой незарегистрированной copy.

## Источники

- [Regulation (EU) 2016/679 (GDPR)](https://eur-lex.europa.eu/eli/reg/2016/679/oj/eng) — European Parliament and Council, официальный текст от 2016-04-27; Articles 5, 17, 19, 25 и 30, проверено 2026-07-18.
- [NIST SP 800-88 Rev. 2: Guidelines for Media Sanitization](https://csrc.nist.gov/pubs/sp/800/88/r2/final) — NIST, final от сентября 2025 года, supersedes Rev. 1 от декабря 2014 года, проверено 2026-07-18.
- [NIST publishes Guidelines for Media Sanitization Rev. 2](https://csrc.nist.gov/News/2025/guidelines-for-media-sanitization-rev-2) — NIST, announcement от 2025-09-26 с перечнем изменений Rev. 2, проверено 2026-07-18.
- [NIST SP 800-53 Rev. 5: Security and Privacy Controls for Information Systems and Organizations](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final) — NIST, Rev. 5, release 5.2.0 от 2025-08-27; controls SI-12, MP-6, CP-9 и AU-11, проверено 2026-07-18.
