---
aliases:
  - "Теоретический вопрос: Object и blob storage"
tags:
  - область/данные
  - тема/выбор-хранилища
  - тип/вопрос
статус: проверено
---

# Object и blob storage

## Вопрос

Объясните тему «Object и blob storage»: какие гарантии даёт механизм и какой ценой для чтения, записи и эксплуатации?

## Короткий ориентир

Object/blob storage хранит opaque byte sequence под key вместе с metadata. Оно рассчитано на большие payload, высокий aggregate throughput, независимый lifecycle и дешёвое масштабирование capacity. База данных при этом обычно хранит business metadata, ownership и ссылку на object key.

Object — не файл и не строка таблицы. У него нет привычного in-place append, POSIX rename и произвольной транзакции через несколько keys. Обновление публикует новый object/version целиком, multipart upload становится видимым после completion, а согласование с metadata database требует protocol для retries, orphan cleanup и удаления.

Полный разбор: [[30 Данные/Object и blob storage|Object и blob storage]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Messenger BE — P2P-чаты вокруг объявления, hot sellers, доставка, push и изображения. База: чат, уведомления, blob storage.» — [[Авито/roadmap#4. System design|Авито/roadmap, раздел «4. System design»]].
- «Image storage — нужно исходное условие; база: Object и blob storage, Проектирование файлового хранилища.» — [[Авито/roadmap#System design и проектирование|Авито/roadmap, раздел «System design и проектирование»]].

## Источники

- [What is Amazon S3?](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html) — Amazon Web Services, Amazon S3 service documentation, consistency model, проверено 2026-07-18.
- [Uploading and copying objects using multipart upload](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html) — Amazon Web Services, Amazon S3 service documentation, проверено 2026-07-18.
- [Checking object integrity for data uploads](https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity-upload.html) — Amazon Web Services, Amazon S3 checksum contract, проверено 2026-07-18.
- [Retaining multiple versions with S3 Versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html) — Amazon Web Services, Amazon S3 service documentation, проверено 2026-07-18.
- [Conditional requests](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-requests.html) — Amazon Web Services, Amazon S3 service documentation, проверено 2026-07-18.
- [Data protection in Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/userguide/DataDurability.html) — Amazon Web Services, Amazon S3 service documentation, проверено 2026-07-18.
