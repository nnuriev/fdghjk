---
aliases:
  - "Теоретический вопрос: Thundering herd"
tags:
  - область/reliability-performance-operations
  - тема/устойчивость
  - механизм/синхронизация-нагрузки
  - тип/вопрос
статус: проверено
---

# Thundering herd

## Вопрос

Разберите тему «Thundering herd»: какая ментальная модель помогает принять решение, какие trade-offs и failure modes нужно проверить?

## Короткий ориентир

**Thundering herd** возникает, когда одно событие одновременно будит множество клиентов или workers, а полезную работу способен выполнить лишь один или небольшой bounded-набор участников. Остальные конкурируют за тот же cache key, lock, connection, leader или backend capacity. Средний трафик при этом может выглядеть нормальным: систему ломает короткий коррелированный пик.

Лечение разрывает синхронность и подавляет дубликаты. Для одинаковой работы применяют request coalescing, для cache refresh — stale serving и разнесённые TTL, для периодических действий и reconnect — jitter, для дорогой зависимости — bounded concurrency и load shedding. Масштабирование помогает только тогда, когда общий ресурс действительно масштабируется и успевает подняться до всплеска.

Полный разбор: [[70 Практические кейсы/Thundering herd|Thundering herd]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/7091/05 Кеширование и высокая доступность#4. Thundering herd и singleflight|4. Thundering herd и singleflight]] — вопрос о hot-key expiry, request coalescing и process-local scope `singleflight`.
- «Прогноз погоды и cache — TTL-cache, concurrent access, warm-up и stampede. База: in-memory cache, thundering herd, time.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «Warmup полезен только для известного hot set. Прогрев всего key space переносит нагрузку на startup, замедляет readiness и может сам вызвать thundering herd.» — [[Авито/Решения/Go-платформа/Прогноз погоды и cache#Trade-offs и альтернативы|Авито/Решения/Go-платформа/Прогноз погоды и cache, раздел «Trade-offs и альтернативы»]].

- [[Telegram Собесы/M.Tech — 2026-07-17 — 350к/Бланк вопросов и заданий#Кеширование и contract-first|Кеширование и contract-first]] — точный prompt cluster о cache stampede, `singleflight` и concurrent misses.

## Источники

- [Minimizing correlated failures in distributed systems](https://aws.amazon.com/builders-library/minimizing-correlated-failures-in-distributed-systems/) — Amazon Web Services, Amazon Builders’ Library, проверено 2026-07-18.
- [Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/) — Google, Site Reliability Engineering book, 2016, проверено 2026-07-18.
- [Package singleflight](https://pkg.go.dev/golang.org/x/sync@v0.22.0/singleflight) — Go project, `golang.org/x/sync` v0.22.0, проверено 2026-07-18.
- [singleflight.go](https://github.com/golang/sync/blob/v0.22.0/singleflight/singleflight.go) — репозиторий `golang/sync`, tag `v0.22.0`, проверено 2026-07-18.
- [RFC 5861: HTTP Cache-Control Extensions for Stale Content](https://www.rfc-editor.org/rfc/rfc5861.html) — IETF, RFC 5861, май 2010, проверено 2026-07-18.
- [epoll(7)](https://man7.org/linux/man-pages/man7/epoll.7.html) — Linux man-pages project, man-pages 6.18, проверено 2026-07-18.
