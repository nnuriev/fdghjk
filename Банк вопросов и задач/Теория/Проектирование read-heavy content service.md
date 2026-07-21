---
aliases:
  - "Теоретический вопрос: Проектирование read-heavy content service"
tags:
  - область/проектирование-систем
  - тип/разбор
  - тема/read-heavy
  - тип/вопрос
статус: проверено
---

# Проектирование read-heavy content service

## Вопрос

Как раскрыть на System Design интервью тему «Проектирование read-heavy content service»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

Система хранит каноническую metadata в транзакционной БД, крупные immutable payload и media — в object storage, а публичные представления раздаёт через CDN. Write path сначала фиксирует управляемое состояние `draft → publishing → published`, затем асинхронно строит производные данные: search document, cache invalidation и preview. Read path почти всегда заканчивается на CDN или distributed cache; origin остаётся источником истины, а не самым быстрым слоем.

Главный компромисс — свежесть против доступности и цены. Для опубликованного immutable content допустимы долгие TTL и stale serving. Permission revoke или удаление требует authoritative deny либо короткоживущего version-bound grant на каждый новый private read. Versioned URL и адресный purge ускоряют переход, но сами не отзывают уже известный старый URL: без отдельной deny-границы быстрый CDN превращается в канал утечки.

Полный разбор: [[50 Проектирование систем/Проектирование read-heavy content service|Проектирование read-heavy content service]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Avito.ru / classified — публикация объявления, карточка, SERP, изображения и асинхронная индексация. База: read-heavy content, поиск, search index, файловое хранилище.» — [[Авито/roadmap#4. System design|Авито/roadmap, раздел «4. System design»]].

## Источники

- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RFC 9111: HTTP Caching](https://www.rfc-editor.org/rfc/rfc9111) — IETF, RFC 9111, июнь 2022, проверено 2026-07-18.
- [What is Amazon S3? — data consistency model](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel) — Amazon Web Services, актуальная редакция Amazon S3 User Guide, проверено 2026-07-18.
- [Uploading and copying objects using multipart upload](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html) — Amazon Web Services, актуальная редакция Amazon S3 User Guide, проверено 2026-07-18.
- [Use signed URLs](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-signed-urls.html) — Amazon Web Services, актуальная редакция Amazon CloudFront Developer Guide; expiration проверяется при начале HTTP request, проверено 2026-07-18.
- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering, издание 2016 года, проверено 2026-07-18.
- [Trace Context](https://www.w3.org/TR/trace-context/) — W3C Recommendation, редакция 23 ноября 2021, проверено 2026-07-18.
