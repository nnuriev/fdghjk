---
aliases:
  - PII handling
  - Personally identifiable information
  - Обработка персональных данных
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/приватность
статус: проверено
---

# Обработка PII

## TL;DR

PII (personally identifiable information) нельзя надёжно определить списком полей вроде `email`, `phone` и `passport`. Идентифицируемость зависит от комбинации данных, контекста, доступных дополнительных наборов и назначения обработки. Почтовый индекс в одном отчёте даёт статистику, а в маленькой группе вместе с должностью и датой события способен выделить конкретного человека.

Backend должен управлять не «секретными колонками», а жизненным циклом обработки: зачем поле собирается, на каком основании, кому доступно, куда копируется, какие производные создаёт, сколько хранится и как удаляется. Базовый порядок такой: инвентаризировать data flow, минимизировать сбор, отделить identity от domain data, ограничить доступ по purpose, защитить transport/storage, исключить PII из telemetry и провести [[20 Бэкенд/Data retention и deletion|retention/deletion]] по всем копиям. Encryption и pseudonymisation снижают риск, но не превращают ненужные данные в нужные и обычно не выводят их из privacy scope.

## Область применимости

Термин PII в NIST SP 800-122 относится прежде всего к контексту федеральных ведомств США. GDPR использует более широкое юридическое понятие personal data: любую информацию, относящуюся к идентифицированному или идентифицируемому физическому лицу. Эти определения нельзя автоматически переносить между юрисдикциями.

GDPR здесь служит конкретным нормативным примером. Из него используются определения и принципы Articles 4, 5, 25 и 32 в официальном тексте Regulation (EU) 2016/679. Решение о legal basis, сроках, правах человека, special categories, трансграничной передаче и обязанности уведомления принимает privacy/legal owner для применимой юрисдикции. Заметка описывает инженерные инварианты, а не юридическую консультацию.

Вне scope: полный процесс DPIA, тексты privacy notice, cookie consent, ответы на incident и отраслевые режимы вроде медицинского или платёжного регулирования.

## Ментальная модель

PII — свойство связи данных с человеком, а не свойство имени колонки. Удобно держать две модели одновременно.

Первая — **processing contract**:

```text
purpose + authority
  -> минимально необходимые поля
  -> разрешённые операции и actors
  -> recipients и производные наборы
  -> retention trigger и deletion path
```

Вторая — **data graph**. Узлы — primary records, logs, caches, search indexes, exports, backups и features. Рёбра — копирование, join, enrichment и раскрытие получателю. Если неизвестно хотя бы одно ребро, нельзя доказать minimisation, access scope или deletion completeness.

Технические инварианты следуют из этих моделей:

- у каждого PII-набора есть owner, purpose, classification и retention rule;
- сервис получает только поля, нужные его операции, а не весь профиль «на будущее»;
- pseudonymised record остаётся защищаемым, пока существует реалистичный путь связать его с человеком;
- дополнительная информация для re-identification хранится отдельно и доступна меньшему числу principals;
- sensitive payload не попадает в durable telemetry по умолчанию;
- новая копия или derived feature наследует provenance и privacy policy исходных данных;
- прекращение purpose блокирует дальнейшую обработку и запускает проверяемый deletion workflow.

## Как устроено

### Инвентаризация начинается до первой записи

Data inventory строят от ingress до уничтожения. Для каждого field или data product фиксируют:

- определение и формат, включая допустимые производные;
- человека или группу, к которым данные относятся;
- purpose и утверждённое основание обработки;
- system of record и владельца;
- readers, writers, recipients и sub-processors;
- data residency, storage protections и export paths;
- retention trigger, срок или критерий удаления;
- downstream topics, caches, indexes, logs, backups и analytical products.

Реестр должен быть связан со schema и deployment review, иначе он быстро превращается в устаревшую таблицу. Практичный контроль — schema annotation или data contract, который pipeline переносит в catalog и policy checks. Автоматический scanner находит вероятные email, телефоны и идентификаторы, но служит защитой от пропуска. Он не видит смысл свободного текста и плохо определяет, можно ли идентифицировать человека через join.

NIST SP 800-122 предлагает оценивать identifiability, количество записей, sensitivity полей, context of use, обязательства защиты, access и location. Поэтому бинарного `is_pii` мало. Нужны хотя бы data class и impact: публичный business contact, внутренний pseudonymous identifier, точный location, medical/financial data дают разные последствия и controls.

### Purpose и minimisation формируют schema

GDPR Article 5 задаёт purpose limitation, data minimisation и storage limitation. На уровне backend это означает, что API и таблица не должны принимать поле без отвечающей за него операции.

Для каждого поля задают простой тест:

1. Какое решение или действие невозможно без поля?
2. Нужна ли исходная точность, либо достаточно категории, маски или агрегата?
3. Нужен ли field после выполнения действия?
4. Должны ли все consumers видеть одно представление?

Например, сервис доставки уведомлениям нужен адрес назначения. Analytics обычно достаточно факта доставки, канала и coarse region; копия email не улучшает расчёт метрики. Сохранить email «вдруг пригодится» дешевле сегодня и дороже при каждом incident, export, access request и deletion.

Article 25 GDPR требует data protection by design and by default: по умолчанию обрабатываются только данные, необходимые для конкретной цели, включая объём, период хранения и доступность. Это архитектурный constraint. Privacy review после запуска не удалит уже разошедшиеся copies без lineage.

### Identity отделяется от domain data

Внутренний opaque `subject_id` уменьшает распространение прямых идентификаторов. Mapping `subject_id -> email/phone/name` можно хранить в identity vault с более узкой авторизацией. Domain services используют `subject_id`, пока им не требуется конкретный contact channel.

Есть несколько преобразований с разными гарантиями:

**Masking или redaction** необратимо удаляет часть значения из конкретного представления, например возвращает `a***@example.com` оператору. Исходник всё ещё существует в owner service.

**Tokenisation** заменяет значение случайным token, а обратное отображение держит в отдельном vault. Она уменьшает число систем с direct identifier, но vault становится высокоценной точкой.

**Pseudonymisation** требует дополнительной информации для attribution. Purpose-specific pseudonym вроде `HMAC(k_analytics, subject_id)` мешает напрямую соединить support и marketing datasets, если keys и доступ разделены. Но значение остаётся linkable для владельца key и стабильно внутри purpose.

**Encryption** скрывает значение от стороны без ключа и поддерживает обратимость. Это control confidentiality, а не minimisation: процесс с decrypt по-прежнему обрабатывает исходные personal data. Механизм ключей разбирается в [[20 Бэкенд/Шифрование данных at rest|шифровании at rest]].

**Anonymisation** оценивают с позиции каждой relevant entity, для которой данные должны стать анонимными: с учётом доступных ей и разумно вероятных средств человек не должен оставаться identified или identifiable. Один и тот же набор может быть anonymous для независимого recipient и personal data для controller, который сохраняет mapping; для processor применима перспектива определяющего обработку controller. Простого удаления имени обычно мало. GDPR Recital 26 относит linkable pseudonymised data к данным об идентифицируемом лице, а EDPB Guidelines 02/2026 v1.0 уточняют contextual assessment, `No Record Isolation`, `No Linkage` и `No Inference`.

На 2026-07-18 Guidelines 02/2026 приняты 2026-07-07 только как version 1.0 для public consultation до 2026-10-30, а не как final guidance. Их contextual model согласована с решением CJEU C-413/23 P, но перед юридическим выводом нужно проверить итоговую редакцию и применимую perspective для конкретной операции.

Hash email без секрета — плохая псевдонимизация и почти никогда не анонимизация: пространство вероятных email перебирается, одинаковые значения связываются между наборами. Keyed HMAC повышает стойкость к offline dictionary без key и даёт purpose separation, но результат всё равно надо считать personal data, пока controller может связать его с человеком.

### Доступ ограничивается полем, purpose и объектом

Role `support` ещё не объясняет, зачем сотруднику весь профиль. Решение доступа учитывает tenant, subject relation, action, data class, purpose и контекст сессии. Query сразу выбирает нужные колонки и строки; handler не получает полный record, чтобы затем скрыть поля в response.

Массовые exports, поиск по прямому идентификатору, re-identification и break-glass требуют отдельного permission, reason и [[20 Бэкенд/Audit logging|audit]]. Временный доступ истекает автоматически. Доступ к identity mapping уже обычного чтения domain record, потому что mapping восстанавливает связь сразу для множества datasets.

[[20 Бэкенд/Аутентификация и авторизация на уровне API|AuthN/AuthZ]] защищает online path, а encryption защищает storage path. Нужны оба слоя: украденный backup обходит handler, скомпрометированный handler обходит шифрование после decrypt.

### Telemetry получает безопасное представление до durable write

Логи и traces особенно опасны: они широко реплицируются, индексируются, доступны большему числу инженеров и живут по отдельному retention. Redaction после ingestion оставляет raw copy в collector buffer, object archive или dead-letter queue.

Безопасный baseline — structured logging с allowlist полей. Вместо raw request/response записывают event ID, internal subject reference при обоснованной необходимости, data class, operation, outcome и safe reason code. Не пишут `Authorization`, session cookie, email, phone, document number, свободный ticket text и полный SQL bind payload.

Metric labels не содержат `user_id`, email или request URL с параметрами: это одновременно privacy leak и unbounded cardinality. Trace attributes проходят ту же schema policy. Collector-side scanner полезен как второй барьер и alert, но primary control находится в producer до serialisation. Разделение telemetry и audit подробнее показано в [[50 Проектирование систем/Observability в System Design|заметке об observability]].

### Derived data наследует связь с человеком

Нормализованный адрес, risk score, embedding сообщения, сегмент или prediction не перестают быть personal data только потому, что исходное поле исчезло. Если feature связан с `subject_id`, используется для решения о человеке или может быть присоединён обратно, он остаётся узлом data graph.

Pipeline передаёт provenance: source dataset/version, purpose, permitted consumers, retention ceiling и deletion key. При join применяется наиболее строгая из участвующих policies либо отдельное утверждённое правило. Копия в analytics account не получает новый бесконечный purpose из-за смены команды-владельца.

Публикация aggregate требует оценки small groups и auxiliary information. Даже без direct identifiers редкая комбинация атрибутов способна выделить человека. Порог группировки, suppression и добавление privacy noise выбирают под threat model; слово «aggregate» само гарантии не даёт.

### Rights, retention и incidents опираются на один data map

Тот же inventory нужен, чтобы найти записи человека, исправить их, ограничить processing, сформировать export, удалить copies и определить scope breach. Отдельные scripts для каждого запроса быстро расходятся и пропускают новые systems.

Subject lookup должен принимать несколько identifiers осторожно: совпадение по одному email способно удалить данные другого владельца после переиспользования адреса. Сначала проверяется identity и authority запроса, затем immutable internal subject ID связывает downstream jobs. В deletion evidence сохраняют минимальный job ID и outcomes, а не удаляемый payload.

## Сквозной пример: support и product analytics

Продукту нужны email для уведомлений, текст обращения для support и агрегаты причин обращений для analytics. Исходная схема `users` содержала бы всё в одной строке; вместо неё поток разделён.

1. Identity service хранит `subject_id=u7`, email и phone. Прямые identifiers зашифрованы, а decrypt разрешён notification-service и узкому support action.
2. Ticket service хранит `ticket_id=q9`, `subject_id=u7`, текст и category. Обычный support list возвращает masked contact; раскрытие email — отдельное действие с reason и audit.
3. Analytics pipeline получает category, coarse country и purpose-specific `analytics_subject=HMAC(k_analytics, u7)`. Email, phone и raw ticket text в dataset не входят.
4. Producer пишет в log `ticket_id=q9`, operation и outcome. Request body и contact fields не сериализуются. Collector сигнализирует, если scanner всё же видит формат email.
5. Marketing dataset использует другой key и другой pseudonym. Прямой join с support analytics невозможен без специально разрешённого mapping step.
6. Запрос на удаление после проверки identity адресуется `subject_id=u7`; owner services удаляют direct records, analytics удаляет строки по `analytics_subject`, а processing evidence сохраняет только deletion job ID и результат каждого consumer.

Наблюдаемый результат: компрометация analytics dataset не раскрывает direct identifiers и не даёт готового join с marketing. Риск не исчез: стабильный pseudonym и редкие attributes всё ещё относятся к человеку, поэтому dataset остаётся под access, retention и deletion policy.

## Эволюция и версии

| Версия или период | Было | Стало | Практический эффект | Источник |
| --- | --- | --- | --- | --- |
| WP29 Opinion 05/2014 → EDPB Guidelines 02/2026 v1.0 | Предыдущее европейское руководство описывало anonymisation через критерии singling out, linkability и inference | Принятая для public consultation версия 02/2026 обновляет этот подход: anonymity оценивается для каждой relevant entity, а technical framework использует `No Record Isolation`, `No Linkage` и `No Inference` | Нельзя присваивать dataset один абсолютный статус без списка relevant entities и их reasonably likely means; до финальной версии вывод помечают как основанный на draft | EDPB Guidelines 02/2026 v1.0, 2026-07-07 |

## Trade-offs

### Минимизация при сборе или гибкость будущей аналитики

Минимизация уменьшает blast radius, стоимость rights requests и число controls. Цена — некоторые будущие вопросы нельзя задать к данным, которых нет. Сбор «про запас» сохраняет аналитическую гибкость, но создаёт неограниченный purpose и постоянно растущую обязанность защиты. Практичный компромисс — явно одобренные raw zones с коротким retention и заранее заданными outputs, а не вечный data lake.

### Централизованный identity vault или domain ownership

Vault сокращает copies direct identifiers и облегчает единый access control. Он же становится критичным dependency и крупным blast radius. Domain ownership уменьшает централизованную связность, но размножает mappings и deletion integrations. Часто direct identity централизуют, а domain records оставляют у владельцев с opaque subject ID.

### Pseudonymisation или anonymisation

Pseudonymisation сохраняет возможность исправления, удаления и longitudinal analysis, поэтому полезна в operational systems. Дополнительная информация остаётся, а значит остаётся риск и privacy scope. Anonymisation потенциально выводит dataset из person-level обработки, но требует доказать устойчивость к singling out и linkage; вместе с этим часто теряется utility. Нельзя получить обе гарантии одной заменой ID.

### Allowlist или post-hoc redaction telemetry

Allowlist не пропускает неизвестное поле и хорошо работает со structured events, но требует schema discipline. Redaction легче добавить к legacy logs и ловит известные форматы, зато пропускает free text и оставляет риск raw intermediate copies. Для нового path allowlist служит primary control, scanner/redactor — defense in depth.

## Типичные ошибки

### PII определяется статическим словарём колонок

- **Неверное предположение:** если `name` и `email` отсутствуют, dataset анонимен.
- **Симптом:** человека выделяют по location, timestamp, должности и внешнему источнику.
- **Причина:** классификация игнорирует combinations, context и auxiliary data.
- **Исправление:** оценивать identifiability и linkage на уровне dataset/use case, вести lineage и пересматривать риск при новых joins.

### Hash email объявлен anonymous ID

- **Неверное предположение:** one-way hash необратим, значит связь с человеком исчезла.
- **Симптом:** attacker перебирает известные email или связывает одинаковые hashes между утечками.
- **Причина:** низкоэнтропийный input и глобально стабильный deterministic output.
- **Исправление:** purpose-specific keyed pseudonym либо random token, отдельная key/mapping boundary и сохранение privacy classification.

### Encryption подменяет minimisation

- **Неверное предположение:** можно собирать любое поле, если оно зашифровано.
- **Симптом:** application bug или широкая service role расшифровывает ненужный профиль целиком.
- **Причина:** encryption защищает storage path, но purpose и полномочия процесса не ограничены.
- **Исправление:** не собирать поле без purpose, выдавать projection по операции и сужать decrypt grants.

### Redaction выполняется после отправки логов

- **Неверное предположение:** SIEM scrub удалит PII из telemetry.
- **Симптом:** raw payload остаётся в agent spool, retry queue, archive или vendor diagnostic store.
- **Причина:** sensitive value уже пересекло durable boundary.
- **Исправление:** allowlist в producer до serialisation, запрет body/header dumps, downstream scanner как alert.

### Inventory охватывает только production database

- **Неверное предположение:** system of record равен всем copies.
- **Симптом:** access или deletion request не находит search index, notebook export и backup.
- **Причина:** не отслеживаются data graph и derived datasets.
- **Исправление:** registry sources/recipients, owner на каждом edge, автоматическая регистрация новых sinks и периодическая reconciliation.

### Derived feature считается безопасной после удаления raw field

- **Неверное предположение:** score или embedding уже не относится к человеку.
- **Симптом:** удалённый профиль продолжает влиять на решение либо восстанавливается через join.
- **Причина:** потерян provenance и связь с subject ID.
- **Исправление:** наследовать classification, purpose, retention и deletion key всеми производными records.

## Когда применять

Эта модель нужна любому backend, который принимает, выводит или выводит косвенно данные о людях: accounts, support, telemetry, billing, analytics, fraud, ML features и exports. Начинать следует до проектирования API: определить purpose, минимальный field set, owner, recipients, classification и deletion path.

Перед выпуском проверяют negative access cases, cross-tenant isolation, массовый export, отсутствие PII и credentials в logs/traces/metrics, поведение scanner, backup scope и удаление через все registered sinks. Юридическую применимость и сроки утверждает privacy/legal owner; тесты доказывают только то, что система исполняет выбранную policy.

## Источники

- [NIST SP 800-122: Guide to Protecting the Confidentiality of Personally Identifiable Information](https://csrc.nist.gov/pubs/sp/800/122/final) — NIST, final от апреля 2010 года; определения, impact factors и safeguards для PII в федеральном контексте США, проверено 2026-07-18.
- [Regulation (EU) 2016/679 (GDPR)](https://eur-lex.europa.eu/eli/reg/2016/679/oj/eng) — European Parliament and Council, официальный текст от 2016-04-27; Articles 4, 5, 17, 25, 30 и 32, проверено 2026-07-18.
- [Guidelines 4/2019 on Article 25 Data Protection by Design and by Default](https://www.edpb.europa.eu/documents/guideline/guidelines-42019-on-article-25-data-protection-by-design-and-by-default_en) — European Data Protection Board, final version от 2020-10-20, проверено 2026-07-18.
- [Guidelines 02/2026 on Anonymisation](https://www.edpb.europa.eu/system/files/2026-07/edpb_guidelines_202602_anonymisation_v1_en_0.pdf) — European Data Protection Board, version 1.0, принята 2026-07-07 для public consultation до 2026-10-30; не final, проверено 2026-07-18.
- [NIST SP 800-53 Rev. 5: Security and Privacy Controls for Information Systems and Organizations](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final) — NIST, Rev. 5, release 5.2.0 от 2025-08-27; families PT, AC, AU, SC и control SI-12, проверено 2026-07-18.
