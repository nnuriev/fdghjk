---
aliases:
  - "Теоретический вопрос: Cache policies, TTL, eviction и CDN"
tags:
  - область/бэкенд
  - тема/кэширование
  - тип/вопрос
статус: черновик
---

# Cache policies, TTL, eviction и CDN

## Вопрос

Как выбирать cache policy, TTL, eviction и CDN placement с учётом freshness и failure modes?

## Короткий ориентир

Cache contract задаёт источник истины, способ заполнения, freshness, invalidation и поведение при miss/error. TTL ограничивает reuse по времени, eviction — по resource budget; soft/hard TTL и negative caching меняют доступность и staleness. CDN переносит cache ближе к client, но не отменяет правила origin и invalidation.

Полные разборы:

- [[50 Проектирование систем/Cache и CDN|Cache и CDN]]
- [[CurseHunter/7091/05 Кеширование и высокая доступность|Кеширование и высокая доступность]]

## Варианты follow-up

- Чем read-aside отличается от read-through и write-through?
- Как soft TTL и hard TTL меняют поведение при отказе origin?
- По какому resource budget выбирают eviction policy?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/02 Кэш, API и observability#Кэширование|Кэширование]] — исходный блок выбора cache policy и failure contract.
- [[CurseHunter/5785/02 Кэш, API и observability#Какие данные стоит кэшировать?|Какие данные стоит кэшировать?]] — вопрос о read frequency, recomputation cost, size и staleness.
- [[CurseHunter/5785/02 Кэш, API и observability#Какие failure modes ждёт интервьюер?|Какие failure modes ждёт интервьюер?]] — вопрос о herd, penetration, avalanche и invalidation race.
- [[CurseHunter/5785/04 Распределённое хранение данных#CDN|CDN]] — самостоятельный вопрос о edge caching и invalidation.
- [[CurseHunter/7091/05 Кеширование и высокая доступность#6. Cache avalanche и TTL jitter|6. Cache avalanche и TTL jitter]] — вопрос о синхронном expiry множества keys и распределении TTL.
- [[CurseHunter/5785/02 Кэш, API и observability#Read-aside, read-through и write-through|CourseHunter 5785, cache patterns]].
- [[CurseHunter/7091/05 Кеширование и высокая доступность#5. Soft TTL, hard TTL и negative caching|CourseHunter 7091, TTL и negative caching]].
- [[CurseHunter/7091/05 Кеширование и высокая доступность#9. Eviction policies|CourseHunter 7091, eviction]].

- [[Telegram Собесы/АМТЕХ — 2026-04-06 — 350к/Бланк вопросов и заданий#Cache и invalidation — `01:23:23–01:24:31`|Cache и invalidation — `01:23:23–01:24:31`]] — точная проверенная формулировка технического блока интервью АМТЕХ.

- [[Telegram Собесы/VK Tech — 2025-09-12 — 350к/Бланк вопросов и заданий#PostgreSQL и Redis — `00:24:42–00:26:43`|PostgreSQL и Redis — `00:24:42–00:26:43`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [RFC 9111: HTTP Caching](https://www.rfc-editor.org/rfc/rfc9111.html) — IETF, STD 98 / RFC 9111, июнь 2022, проверено 2026-07-18.
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, STD 97 / RFC 9110, июнь 2022, проверено 2026-07-18.
- [RFC 5861: HTTP Cache-Control Extensions for Stale Content](https://www.rfc-editor.org/rfc/rfc5861.html) — IETF, RFC 5861, май 2010, проверено 2026-07-18.
- [Cache keys](https://developers.cloudflare.com/cache/how-to/cache-keys/) — Cloudflare, online-документация обновлена 2026-04-17, проверено 2026-07-18.
- [Tiered Cache](https://developers.cloudflare.com/cache/how-to/tiered-cache/) — Cloudflare, online-документация обновлена 2026-06-05, проверено 2026-07-18.
- [Use Amazon CloudFront Origin Shield](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/origin-shield.html) — Amazon Web Services, CloudFront online-документация, проверено 2026-07-18.
- [Understand the cache key](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/understanding-the-cache-key.html) — Amazon Web Services, CloudFront online-документация, проверено 2026-07-18.
- [Transactions](https://redis.io/docs/latest/develop/using-commands/transactions/) — Redis Documentation, Redis 8.6 current docs, проверено 2026-07-19.
- [Distributed Locks with Redis](https://redis.io/docs/latest/develop/clients/patterns/distributed-locks/) — Redis Documentation, Redis 8.6 current docs, проверено 2026-07-19.
- [Redis Cluster Specification](https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/) — Redis Documentation, Redis 8.6 current docs, проверено 2026-07-19.
- [High availability with Redis Sentinel](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/) — Redis Documentation, Redis 8.6 current docs, проверено 2026-07-19.
- [Key eviction](https://redis.io/docs/latest/develop/reference/eviction/) — Redis Documentation, Redis 8.6 current docs; LRM отмечен как дополнение 8.6, проверено 2026-07-19.
- [singleflight](https://pkg.go.dev/golang.org/x/sync/singleflight) — Go project, `golang.org/x/sync`, проверено 2026-07-19.
