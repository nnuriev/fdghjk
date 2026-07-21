---
aliases:
  - "Теоретический вопрос: Docker Compose и service discovery"
tags:
  - область/бэкенд
  - тема/контейнеры
  - тип/вопрос
статус: черновик
---

# Docker Compose и service discovery

## Вопрос

Как Compose-сервисы находят друг друга и чем startup order отличается от readiness dependency?

## Короткий ориентир

Compose создаёт project network, где service name служит стабильным именем, а container IP может измениться после recreate. Между containers используют container port; публикация host port нужна только для доступа извне. `depends_on` задаёт порядок запуска, но готовность dependency проверяют healthcheck и retry policy клиента.

Полные разборы:

- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Docker Compose и service discovery — `00:26:46–00:29:21`|MERLION: Docker Compose]]
- [[40 Распределённые системы/Service discovery|Service discovery]]

## Варианты follow-up

- Какой hostname стабилен: service name или container IP?
- Какой port используют services внутри Compose network?
- Почему `depends_on` не доказывает readiness базы?

## Варианты формулировки и происхождение

- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Docker Compose и service discovery — `00:26:46–00:29:21`|MERLION, Docker Compose]].

## Источники

- [Networking in Compose](https://docs.docker.com/compose/how-tos/networking/) — Docker, current documentation, проверено `2026-07-19`.
- [RFC 1034: Domain Names — Concepts and Facilities](https://www.rfc-editor.org/rfc/rfc1034.html) — IETF, STD 13 / RFC 1034, ноябрь 1987, проверено 2026-07-18.
- [RFC 2782: A DNS RR for specifying the location of services](https://www.rfc-editor.org/rfc/rfc2782.html) — IETF, RFC 2782, февраль 2000, проверено 2026-07-18.
- [Service discovery](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/upstream/service_discovery) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Health checking](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/upstream/health_checking.html) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Service](https://kubernetes.io/docs/concepts/services-networking/service/) — Kubernetes, документация v1.36, проверено 2026-07-18.
- [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/) — Kubernetes, документация v1.36, проверено 2026-07-18.
