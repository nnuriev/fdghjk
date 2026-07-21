---
aliases:
  - "Теоретический вопрос: Проектирование rate limiter"
tags:
  - тип/разбор
  - область/проектирование-систем
  - тема/устойчивость
  - тип/вопрос
статус: проверено
---

# Проектирование rate limiter

## Вопрос

Как раскрыть на System Design интервью тему «Проектирование rate limiter»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

Rate limiter ставится до дорогой работы и принимает решение по серверной identity, scope, policy version и cost. Быстрый путь и управление политиками разделены: control plane хранит и распространяет versioned policies, а data plane использует локальные token buckets и лишь для общего бюджета обращается к regional allocator.

Точный глобальный счётчик на каждый запрос превращает limiter в синхронную зависимость всего API. Практичный L5-компромисс — иерархические бюджеты: глобальный владелец выдаёт регионам и instances ограниченные leases на tokens. Решение остаётся локальным, а возможный overshoot заранее ограничен суммой ещё не потраченных leases. Для операций, где превышение недопустимо даже на один unit, нужен сериализованный authoritative reservation path с более низкой availability.

Полный разбор: [[50 Проектирование систем/Проектирование rate limiter|Проектирование rate limiter]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Проектирование rate limiter и проектирование ratelimiter-а — нужно исходное условие; это семантический дубль в списке. База: Проектирование rate limiter, Rate limiting и quotas.» — [[Авито/roadmap#System design и проектирование|Авито/roadmap, раздел «System design и проектирование»]].

## Источники

- [RFC 6585: Additional HTTP Status Codes](https://www.rfc-editor.org/rfc/rfc6585.html) — IETF, RFC 6585, апрель 2012, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [RateLimit header fields for HTTP](https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-ratelimit-headers-11) — IETF HTTPAPI Working Group, Internet-Draft `-11` от мая 2026 года, не RFC, проверено 2026-07-18.
- [Local rate limit](https://www.envoyproxy.io/docs/envoy/v1.38.3/configuration/http/http_filters/local_rate_limit_filter) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Request throttling for the Amazon EC2 API](https://docs.aws.amazon.com/ec2/latest/devguide/ec2-api-throttling.html) — Amazon Web Services, официальная документация EC2 API, проверено 2026-07-18.
