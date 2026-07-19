---
aliases:
  - Object storage
  - Blob storage
  - Объектное хранилище
tags:
  - область/данные
  - тема/выбор-хранилища
статус: проверено
---

# Object и blob storage

## TL;DR

Object/blob storage хранит opaque byte sequence под key вместе с metadata. Оно рассчитано на большие payload, высокий aggregate throughput, независимый lifecycle и дешёвое масштабирование capacity. База данных при этом обычно хранит business metadata, ownership и ссылку на object key.

Object — не файл и не строка таблицы. У него нет привычного in-place append, POSIX rename и произвольной транзакции через несколько keys. Обновление публикует новый object/version целиком, multipart upload становится видимым после completion, а согласование с metadata database требует protocol для retries, orphan cleanup и удаления.

## Область применимости

Конкретные гарантии показаны на Amazon S3 service documentation, проверенной 2026-07-18. S3 даёт strong read-after-write consistency для успешных PUT/DELETE и LIST; update одного key атомарен для readers, которые видят старое или новое значение, но не частично записанный object. Bucket configuration имеет отдельные consistency нюансы. Другие S3-compatible и cloud blob stores не обязаны повторять эти гарантии.

S3 account и test bucket не использовались. Upload sequence ниже — failure trace, а не результат интеграционного теста; API semantics сверены с официальной документацией на дату проверки.

## Ментальная модель

Object store — огромная keyspace с операциями над целыми values:

```text
(bucket, key, version?) -> bytes + metadata
```

Key похож на адрес, а не на директорию. Slash в `images/2026/42.jpg` помогает prefix listing и lifecycle rules, но не создаёт POSIX hierarchy. При проектировании важны namespace, immutability/versioning и publication protocol, а не layout таблиц.

## Как устроено

### Object и metadata

Object содержит bytes, system metadata, user metadata, tags и checksum/ETag semantics конкретного API. Object store не индексирует произвольное содержимое как database. Запрос «все изображения tenant 9 с шириной больше 1000» требует catalog table или отдельный [[30 Данные/Search index|search index]].

### Целая запись и range read

PUT заменяет значение key целиком; readers после успешного write получают цельную старую или новую версию. Для больших objects клиент использует multipart upload: инициирует upload, независимо передаёт parts, затем `CompleteMultipartUpload` собирает и публикует object. Незавершённые parts занимают место и оплачиваются, пока upload не abort-нут или lifecycle rule не очистит его.

GET умеет byte ranges, что позволяет читать часть большого формата. Это не произвольная mutation: изменить середину object обычно означает построить и загрузить новый object либо использовать format из самостоятельных chunks/objects.

### Integrity и conditional writes

Checksum проверяет bytes при upload/download; ETag нельзя универсально трактовать как MD5, особенно для multipart и encryption. Conditional `If-None-Match`/`If-Match` защищает create-if-absent или compare-and-swap конкретного key. Он не превращает несколько objects и SQL row в одну транзакцию.

### Versioning и lifecycle

В S3 versioning выключен по умолчанию. После включения overwrite создаёт новую version, а delete без version ID обычно добавляет delete marker. Каждая version хранится и тарифицируется как целый object. Lifecycle удаляет/перемещает текущие, старые versions и незавершённые uploads по отдельным правилам; retention policy нужно тестировать на этих состояниях.

## Сквозной пример: публикация вложения

Сервис принимает видео для `asset_id=42`.

1. Генерирует immutable key `assets/42/01J...bin`, не зависящий от исходного filename.
2. Делает multipart upload с checksum. Повтор parts идемпотентно адресуется `upload_id + part_number`; после всех parts вызывает complete.
3. Только после успешного `HEAD/complete` вставляет в SQL транзакции row `(asset_id, object_key, checksum, size, status='ready')`.
4. Download сначала авторизуется по row, затем получает object или signed URL.
5. Если процесс падает после upload, но до SQL commit, object остаётся orphan. Periodic reconciliation удаляет старые staging/orphan keys после safety window. Если SQL commit прошёл, а ответ клиенту потерялся, повтор запроса находит тот же idempotency record и не создаёт вторую business row.

Наблюдаемый результат: пользователь не видит частично загруженный object, SQL остаётся источником ownership, а crash в любом месте имеет определённый recovery path. Попытка «сначала row, потом как-нибудь upload» оставила бы `ready` metadata без bytes; попытка атомарно переименовать staging key опиралась бы на файловую операцию, которой object API не обещает.

## Trade-offs

### Object store или database blob

Blob в SQL сохраняет одну transaction boundary с metadata и удобен для небольших values с умеренной нагрузкой. Большие payload раздувают WAL, backups, replicas и buffer/cache pressure. Object store отделяет byte throughput и lifecycle, но добавляет cross-system consistency protocol.

### Object store или filesystem

Filesystem даёт directories, rename, locking и часто низкую latency рядом с процессом. Object store даёт service-level namespace, independent durability/capacity и HTTP API, но request latency/cost и semantics отличаются от syscalls. FUSE/NFS gateway не стирает эти различия, а лишь переводит interface.

### Mutable key или immutable versions

Перезапись стабильного key упрощает URL, но caches и concurrent writers сложнее согласовать. Content-addressed/UUID key плюс маленький mutable pointer делает публикацию и rollback явными, ценой metadata lookup и garbage collection.

## Типичные ошибки

- **Неверное предположение:** object store ведёт себя как POSIX filesystem. **Симптом:** copy-plus-delete «rename» оставляет два keys или ни одного при сбое workflow. **Причина:** API не даёт общей atomic rename transaction. **Исправление:** immutable key, publication pointer и идемпотентный cleanup.
- **Неверное предположение:** ETag всегда MD5 содержимого. **Симптом:** integrity check отклоняет корректный multipart/encrypted object. **Причина:** ETag semantics зависят от upload и encryption. **Исправление:** использовать явный поддерживаемый checksum и хранить algorithm рядом со значением.
- **Неверное предположение:** versioning включён и бесплатен. **Симптом:** overwrite невосстановим либо storage bill растёт из-за старых versions/delete markers. **Причина:** versioning по умолчанию выключен, а каждая version — полный object. **Исправление:** явно включить, проверить lifecycle и мониторить versioned bytes.
- **Неверное предположение:** успешный upload и SQL commit атомарны вместе. **Симптом:** orphan object или metadata без bytes. **Причина:** два независимых commit domains. **Исправление:** staged state machine, idempotency, source of truth и reconciliation.
- **Неверное предположение:** завершение multipart автоматически очищает все неудачные попытки. **Симптом:** растёт billed storage незавершённых parts. **Причина:** abandoned upload не был abort-нут. **Исправление:** abort в normal path и lifecycle rule для старых incomplete uploads.

## Когда применять

Object/blob storage подходит для media, backups, archives, ML artifacts, data-lake files и других больших immutable или versioned payload. До выбора зафиксируйте object size distribution, access frequency, byte ranges, checksum, namespace, overwrite/versioning, retention, encryption, egress и restore semantics.

Не складывайте туда мелкие mutable records, если основная операция — частичное update и фильтрация по полям. Для metadata используйте [[30 Данные/SQL или key-value|SQL или key-value]], для full-text — search index. Object store решает byte storage; бизнес-модель и cross-object invariants остаются снаружи.

## Источники

- [What is Amazon S3?](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html) — Amazon Web Services, Amazon S3 service documentation, consistency model, проверено 2026-07-18.
- [Uploading and copying objects using multipart upload](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html) — Amazon Web Services, Amazon S3 service documentation, проверено 2026-07-18.
- [Checking object integrity for data uploads](https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity-upload.html) — Amazon Web Services, Amazon S3 checksum contract, проверено 2026-07-18.
- [Retaining multiple versions with S3 Versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html) — Amazon Web Services, Amazon S3 service documentation, проверено 2026-07-18.
- [Conditional requests](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-requests.html) — Amazon Web Services, Amazon S3 service documentation, проверено 2026-07-18.
- [Data protection in Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/DataDurability.html) — Amazon Web Services, Amazon S3 service documentation, проверено 2026-07-18.
