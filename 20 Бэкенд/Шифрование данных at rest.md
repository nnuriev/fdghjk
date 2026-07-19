---
aliases:
  - Encryption at rest
  - Data-at-rest encryption
  - Шифрование хранимых данных
tags:
  - область/бэкенд
  - тема/безопасность
  - тема/криптография
статус: проверено
---

# Шифрование данных at rest

## TL;DR

Шифрование данных at rest защищает сохранённые байты, если атакующий получил диск, raw snapshot/backup или ciphertext за пределами decrypt boundary, но не получил logical restore/read и право на key/decrypt. Оно не защищает от скомпрометированного процесса, который уже может запросить расшифрование, от SQL injection под полномочиями приложения и от утечки plaintext в лог, export или memory dump.

Практическая схема для backend — envelope encryption. Данные шифруются локальным data encryption key (DEK), DEK шифруется key encryption key (KEK) в KMS, а рядом с ciphertext хранятся wrapped DEK, версии ключей, nonce и authentication tag. Безопасность определяется не названием алгоритма, а всей границей: где появляется plaintext, кто может вызвать decrypt, как ciphertext связан с tenant и объектом, какие копии попадают в backup и что произойдёт при rotation, компрометации или потере ключа.

## Область применимости

Заметка рассматривает диски и volumes, файлы базы и WAL, object storage, snapshots, backups и application-level field/object encryption. Транспортное шифрование, password hashing, end-to-end encryption между пользователями и управление секретами остаются вне scope.

NIST SP 800-111 описывает full-disk, volume/virtual-disk и file/folder encryption для end-user devices по состоянию на ноябрь 2007 года. Его полезно применять как модель слоёв и угроз, но не как спецификацию современного cloud KMS. Актуальные общие controls взяты из NIST SP 800-53 Rev. 5, release 5.2.0 от августа 2025 года; точный envelope-flow сверён с документацией Google Cloud KMS, обновлённой 2026-07-10.

## Ментальная модель

Шифрование переносит доверие из data plane в пару `ciphertext + право получить ключ`:

```text
plaintext
  -> encrypt with DEK
  -> ciphertext + nonce + tag

DEK
  -> wrap with KEK in KMS
  -> wrapped DEK + KEK version
```

Украденный ciphertext бесполезен, пока атакующий не пересёк key boundary. Если тот же principal без дополнительных условий читает storage и вызывает KMS `Decrypt` для любого объекта, граница почти исчезает: компрометация приложения даёт обе половины.

Отсюда следуют инварианты:

- plaintext не должен сохраняться вне объявленной trusted boundary;
- доступ к ciphertext сам по себе не должен давать доступ к KEK;
- decrypt разрешается конкретному workload и контексту, а не любому владельцу cloud account;
- ciphertext криптографически связывается с tenant, object ID и schema version;
- каждый сохранённый объект указывает, каким algorithm/key version он зашифрован;
- потеря последней пригодной версии ключа считается необратимой потерей данных;
- rotation считается завершённой только после инвентаризации старых ciphertext и проверки restore.

## Как устроено

### Сначала фиксируется угроза

Encryption at rest обычно закрывает четыре пути: потерю физического носителя, чтение decommissioned media, кражу raw snapshot/backup и доступ к ciphertext storage без logical read/decrypt capability. Restore через provider API или TDE/database read часто уже находится внутри decrypt boundary и возвращает plaintext. NIST SP 800-53 SC-28 требует защищать конфиденциальность и целостность информации at rest, но выбор механизма зависит от threat model и классификации данных.

После unlock диска full-disk encryption прозрачно отдаёт plaintext операционной системе. TDE прозрачно отдаёт строки SQL-клиенту. Application-level encryption отдаёт plaintext процессу после KMS-вызова. Ни один из этих слоёв не остановит разрешённый запрос с украденной service identity. Поэтому [[20 Бэкенд/Аутентификация и авторизация на уровне API|авторизация API]] и ограничения KMS policy остаются отдельными проверками.

Нужно явно перечислить, что не закрыто: memory и swap, temporary files, core dumps, debug endpoints, query results, clipboard администратора, логи, traces, exports и передача по сети. Если plaintext оказался там, шифрование основной таблицы уже не помогает.

### Слой задаёт защищаемую границу

**Full-disk или volume encryption** шифрует блоки и обычно почти не меняет приложение. Оно хорошо защищает выключенный или отсоединённый носитель. После загрузки узла и разблокировки volume процессы с файловым доступом видят plaintext; один ключ часто имеет большой blast radius. XTS-AES стандартизован NIST SP 800-38E именно как режим confidentiality для storage devices и не аутентифицирует данные либо их источник.

**Database/storage-service encryption** защищает файлы движка, WAL и snapshots в пределах гарантий конкретного продукта. Здесь легко ошибиться в scope: encrypted primary не доказывает, что тем же ключом и без plaintext зашифрованы logical dump, replica, temporary tables и client-side export. Контракт проверяют на каждом artefact, а не по флагу `encryption=true`.

**Application-level field или object encryption** шифрует данные до передачи хранилищу. При отдельном key plane этот слой способен защищать от чтения database administrator и ошибочно опубликованного backup. Цена — изменение schema, миграции ключей, обработка tag failure и потеря обычного поиска, сортировки и индексации по ciphertext.

Слои можно сочетать. Volume encryption закрывает потерянный диск, application-level encryption сужает доверие к storage operator. Одинаковое слово «encrypted» при этом описывает разные угрозы.

### Envelope encryption разделяет данные и корневые ключи

KMS рассчитан на управление KEK и policy, а не на потоковую обработку каждого большого объекта. При записи приложение:

1. генерирует случайный DEK в доверенном процессе;
2. шифрует payload локально authenticated encryption with associated data (AEAD);
3. просит KMS зашифровать, то есть wrap, этот DEK выбранным KEK;
4. сохраняет ciphertext, wrapped DEK, nonce, tag, algorithm suite, KEK reference и format version;
5. удаляет plaintext DEK из доступной памяти настолько быстро и надёжно, насколько позволяет runtime.

При чтении порядок обратный: после авторизации приложение получает object metadata, KMS unwrap-ит DEK, AEAD сначала проверяет tag и только затем возвращает plaintext. В описанном Google Cloud KMS flow KEK не покидает KMS; рядом с данными хранится только wrapped DEK.

KEK обычно защищает много DEK. Это удерживает число объектов KMS управляемым, но гранулярность KEK всё равно важна. Один глобальный KEK упрощает эксплуатацию и увеличивает blast radius policy error. KEK по environment, data class или tenant сужает область, зато умножает keys, grants, alarms и сценарии восстановления.

### Confidentiality без привязки контекста недостаточна

Для application-level encryption нужен AEAD mode, например GCM при корректном управлении nonce. NIST SP 800-38D требует уникальности IV для одного ключа; повтор IV с тем же key разрушает гарантию GCM. Надёжная библиотека должна генерировать или выдавать nonce по схеме, чьи пределы известны и тестируются.

Associated authenticated data (AAD) не шифруется, но входит в вычисление tag. В AAD помещают стабильные поля, которые нельзя менять независимо от ciphertext: `tenant_id`, `object_id`, `field_name`, `schema_version`, иногда classification. Тогда перенос зашифрованного значения из tenant `t1` в `t2` приводит к tag failure, даже если атакующий скопировал всю строку целиком.

AAD не заменяет authorization. Оно ловит подмену контекста после шифрования; до KMS-вызова сервис всё равно обязан доказать, что principal может читать объект. Ошибка tag обрабатывается как нарушение целостности или повреждение данных, без возврата частичного plaintext и без подробного oracle клиенту.

### Key lifecycle длиннее вызова Encrypt

Для каждого класса ключей фиксируются owner, purpose, scope, algorithm, creation time, activation, cryptoperiod, allowed operations, backup/recovery и способ отзыва. NIST SP 800-57 Part 1 Rev. 5 рассматривает именно этот жизненный цикл и защиту keying material.

Обычная rotation проходит по схеме `new writes -> new key version`, а старые версии временно остаются только для чтения. Затем система инвентаризирует старые ciphertext, rewrap-ит DEK новым KEK или re-encrypt-ит payload новым DEK, проверяет чтение и лишь после этого выводит старый key version из эксплуатации.

Rewrap и re-encrypt решают разные задачи:

- при замене KEK достаточно расшифровать wrapped DEK старым KEK и завернуть новым, не трогая большой payload;
- при компрометации DEK, смене data algorithm или изменении DEK scope payload шифруют заново;
- rotation key metadata в KMS сама по себе не мигрирует существующие данные. Google Cloud KMS прямо сохраняет старые key versions активными, пока оператор не выполнит re-encryption и не докажет, что старый version больше не нужен.

Удалить старый key до окончания inventory означает превратить rotation в data-loss incident. Сохранить скомпрометированный key навсегда означает оставить старый ciphertext расшифровываемым. Между этими рисками нужен измеримый migration state: число объектов на каждом version, ошибки rewrap, последний успешный restore и дата planned disable.

### Key plane добавляет availability dependency

Недоступный KMS блокирует cold reads и новые writes, которым нужен DEK. Потерянный key блокирует их навсегда. Система заранее выбирает поведение:

- короткий in-memory cache unwrapped DEK уменьшает latency и переживает краткий outage, но продлевает время, когда ключ находится в памяти;
- regional key placement уменьшает сетевую задержку, но усложняет residency и disaster recovery;
- plaintext fallback сохраняет availability ценой нарушения главного инварианта и потому не должен включаться автоматически;
- backup ключей повышает recoverability, но создаёт ещё одну защищаемую копию key material.

Key administrators и data readers разделяются. Администратор ключа может менять policy и schedule rotation, но не обязан читать ciphertext. Workload получает только операции над нужными keys. Использование key и изменение policy журналируются отдельно; граница полномочий должна совпадать с [[50 Проектирование систем/Границы сервисов|владением данными]], а не с удобством одной общей service role.

### Шифруются все долговечные копии

Primary database — лишь одна копия. Проверяются replicas, WAL, snapshots, logical dumps, object versions, search indexes, analytics extracts, queues, dead-letter storage, CI fixtures и support exports. Backup обязан оставаться расшифровываемым во время всего заявленного retention, поэтому restore test поднимает и данные, и требуемые key versions в изолированной среде.

Если приложение шифрует поле, но пишет plaintext этого поля в structured log, защита обойдена. Если backup зашифрован тем же доступом, что production, компрометация одного principal раскрывает оба. Шифрование должно уменьшать общий путь доступа, а не добавлять одинаковый cipher вокруг каждой копии.

## Сквозной пример: зашифрованное вложение tenant

Сервис хранит attachment `obj-42` tenant `t7`. Storage operator не должен видеть содержимое; приложение использует AEAD и envelope encryption.

1. После проверки права `attachment:create` сервис генерирует новый DEK и nonce.
2. Payload шифруется локально. AAD равно стабильной canonical encoding структуры `{format: 3, tenant: "t7", object: "obj-42", field: "body"}`.
3. KMS wrap-ит DEK ключом `attachments/t7`, version `11`. В object storage уходят ciphertext и tag; в metadata — nonce, wrapped DEK, `kek_version=11`, `format=3`.
4. На чтении repository сначала делает tenant-scoped lookup. Только затем workload с правом на `attachments/t7` просит unwrap и проверяет AEAD tag.
5. Злоумышленник копирует ciphertext и metadata другого объекта `t7/obj-99` в запись `t7/obj-42`. Unwrap тем же tenant KEK проходит, но ожидаемый AAD содержит `obj-42`, поэтому AEAD завершается tag failure и plaintext не возвращается. Копия из `t8` должна быть остановлена ещё раньше key policy, а AAD остаётся независимым слоем защиты.
6. При выпуске KEK version `12` новые DEK wrap-ятся им сразу. Фоновая миграция rewrap-ит version `11`, считает оставшиеся ссылки и проверяет sample reads. Version `11` отключается только после полного inventory и restore test.

Наблюдаемый результат: утечка bucket даёт ciphertext и wrapped DEK, но не право KMS decrypt. Перенос ciphertext между объектами обнаруживается tag, а cross-tenant доступ дополнительно ограничен key policy. Компрометация самого attachment-service всё ещё опасна: процесс имеет storage и KMS access, поэтому нужны короткоживущая workload identity, узкая key policy, audit и ограничение массового decrypt.

## Trade-offs

### Volume/TDE или application-level encryption

Volume и TDE проще внедрить, прозрачны для queries и обычно дешевле по latency. Они защищают носитель и файлы, но оставляют доверенными database engine, storage account и приложение. Application-level encryption сужает эту границу и поддерживает field-specific keys, зато усложняет migrations, индексы, debugging и recovery. Выбор делают по атакующему: украденный диск требует нижнего слоя, недоверенный storage operator — верхнего.

### Provider-managed, customer-managed или externally managed key

Provider-managed key уменьшает операционную нагрузку и риск случайной потери. Customer-managed key даёт отдельную policy, audit и возможность отключения, но создаёт KMS dependency и ответственность за lifecycle. External key добавляет независимую administrative boundary и latency; его outage способен остановить data path. Название ownership ничего не гарантирует без проверки, кто реально может делегировать decrypt.

### Один DEK, DEK на tenant или DEK на объект

Крупный scope уменьшает metadata и KMS traffic, но увеличивает blast radius и объём re-encryption. Per-object DEK хорошо сочетается с envelope encryption и точечным уничтожением, однако создаёт миллионы wrapped keys и требует надёжного inventory. Per-tenant scope удобен для isolation и offboarding, пока один tenant не становится настолько большим, что ключ снова получает огромный blast radius.

### Обычный AEAD или возможность поиска

Randomized AEAD скрывает равенство plaintext, поэтому обычный database index по ciphertext бесполезен. Deterministic encryption или blind index поддерживает equality lookup, но раскрывает повторяемость и частотность; low-entropy поля можно угадывать. Иногда честнее хранить отдельный purpose-bound keyed index с узким API, чем обещать «searchable encryption» без формальной leakage model.

## Типичные ошибки

### Флаг шифрования принят за полную границу

- **Неверное предположение:** включённый TDE означает, что все данные сервиса защищены.
- **Симптом:** plaintext находится в dump, log, temporary file или analytics export.
- **Причина:** inventory ограничили основной таблицей, а не полным data flow.
- **Исправление:** описать все persistence points, проверить каждый artefact и сканировать восстановленную среду на plaintext.

### KMS и ciphertext доступны одной широкой роли

- **Неверное предположение:** внешний KMS автоматически отделяет ключ от данных.
- **Симптом:** украденная service credential массово скачивает и расшифровывает объекты.
- **Причина:** один principal имеет `storage:*` и `kms:Decrypt` для всех tenants без context conditions.
- **Исправление:** workload identity, resource-scoped grants, tenant/data-class key scope, rate/volume detection и отдельные administrative roles.

### Ciphertext можно переносить между объектами

- **Неверное предположение:** authentication tag защищает контекст хранения сам по себе.
- **Симптом:** корректно зашифрованное значение другого tenant проходит проверку.
- **Причина:** tenant и object identity не вошли в AAD либо canonical encoding меняется.
- **Исправление:** versioned canonical AAD со стабильной object identity и cross-tenant negative tests.

### Rotation объявлена по созданию нового key version

- **Неверное предположение:** KMS автоматически перевёл старый ciphertext на новый материал.
- **Симптом:** старый key нельзя отключить; compromised DEK продолжает открывать исторические данные.
- **Причина:** нет inventory и различия между rotation, rewrap и re-encryption.
- **Исправление:** new-write cutover, измеряемая миграция, reference count старых versions, restore test и controlled disable.

### KMS outage включает plaintext fallback

- **Неверное предположение:** краткая деградация безопасности лучше отказа записи.
- **Симптом:** часть данных сохраняется незашифрованной и незаметно переживает incident.
- **Причина:** availability policy не была выбрана заранее.
- **Исправление:** fail closed для защищаемого класса, bounded in-memory cache только по policy и отдельный alert на unavailable key plane.

### Key удаляется без recovery proof

- **Неверное предположение:** отсутствие ошибок в production означает, что старый key больше не нужен.
- **Симптом:** backup восстанавливается, но historical rows не расшифровываются.
- **Причина:** production inventory не включал snapshots и backup retention.
- **Исправление:** учитывать все copies и versions, выполнить изолированный restore, затем отключить key с reversible grace period перед окончательным уничтожением.

## Когда применять

Baseline storage encryption нужен для устройств, volumes, managed databases, object storage и backups с чувствительными данными. Application-level encryption добавляют, когда raw storage, database administrator, cloud snapshot или cross-tenant ошибка входят в threat model и должны оставаться за границей доверия.

Перед внедрением фиксируют: защищаемого атакующего, plaintext boundary, список копий, DEK/KEK granularity, AAD schema, nonce strategy, key policy, rotation/compromise runbook, KMS outage semantics и restore test. Если на эти вопросы нет ответа, выбран алгоритм ещё не образует систему защиты.

## Источники

- [NIST SP 800-111: Guide to Storage Encryption Technologies for End User Devices](https://csrc.nist.gov/pubs/sp/800/111/final) — NIST, final от ноября 2007 года, проверено 2026-07-18.
- [NIST SP 800-57 Part 1 Rev. 5: Recommendation for Key Management](https://csrc.nist.gov/pubs/sp/800/57/pt1/r5/final) — NIST, final от мая 2020 года, проверено 2026-07-18.
- [NIST SP 800-53 Rev. 5: Security and Privacy Controls for Information Systems and Organizations](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final) — NIST, Rev. 5, release 5.2.0 от 2025-08-27; controls SC-12 и SC-28, проверено 2026-07-18.
- [NIST SP 800-38D: Galois/Counter Mode and GMAC](https://csrc.nist.gov/pubs/sp/800/38/d/final) — NIST, final от ноября 2007 года, принято решение о пересмотре в марте 2024 года, проверено 2026-07-18.
- [NIST SP 800-38E: XTS-AES Mode for Confidentiality on Storage Devices](https://csrc.nist.gov/pubs/sp/800/38/e/final) — NIST, final от января 2010 года, принято решение о пересмотре в марте 2024 года, проверено 2026-07-18.
- [Envelope encryption](https://docs.cloud.google.com/kms/docs/envelope-encryption) — Google Cloud KMS, официальная документация, обновлено 2026-07-10, проверено 2026-07-18.
- [Key rotation](https://docs.cloud.google.com/kms/docs/key-rotation) — Google Cloud KMS, официальная документация, обновлено 2026-07-10, проверено 2026-07-18.
