---
aliases:
  - "Теоретический вопрос: L4 и L7 load balancing, service discovery и health checks"
tags:
  - область/основы-cs
  - тема/сети
  - тип/вопрос
статус: черновик
---

# L4 и L7 load balancing, service discovery и health checks

## Вопрос

Где проходят границы L4/L7 balancing, service discovery и health/readiness checks?

## Короткий ориентир

L4 балансирует connections по transport metadata, L7 понимает application request и может маршрутизировать по HTTP-level признакам. Service discovery отвечает, какие endpoints доступны для выбора, а health/readiness проверяют, можно ли направлять трафик конкретному instance; один механизм не заменяет остальные.

Полные разборы:

- [[10 Основы CS/Балансировка сетевой нагрузки|Балансировка сетевой нагрузки]]
- [[40 Распределённые системы/Service discovery|Service discovery]]
- [[70 Практические кейсы/Health checks и readiness|Health checks и readiness]]

## Варианты follow-up

- Какие routing decisions доступны L7 и недоступны L4 balancer?
- Почему service discovery не доказывает readiness endpoint?
- Чем liveness probe отличается от readiness probe?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/01 Интервью, требования и нагрузка#Балансировка и proxy|Балансировка и proxy]] — исходный блок вопросов о размещении и выборе балансировки.
- [[CurseHunter/5785/01 Интервью, требования и нагрузка#Как выбрать алгоритм балансировки?|Как выбрать алгоритм балансировки?]] — вопрос о round robin, least connections, hashing и locality.
- [[CurseHunter/5785/01 Интервью, требования и нагрузка#L4 и L7 — где граница?|CourseHunter 5785, L4/L7]].
- [[CurseHunter/5785/01 Интервью, требования и нагрузка#Зачем service discovery и health checks?|CourseHunter 5785, discovery и health]].
- [[CurseHunter/7091/01 Основы отказоустойчивости и SRE#4. Kubernetes probes как разные контракты|CourseHunter 7091, probes]].

## Источники

- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110.html) — IETF, RFC 9110, июнь 2022, проверено 2026-07-18.
- [Load Balancing](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/upstream/load_balancing/load_balancing) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Supported load balancers](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/upstream/load_balancing/load_balancers.html) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Health checking](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/upstream/health_checking.html) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Draining](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/operations/draining.html) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [EndpointSlices](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/) — Kubernetes, документация v1.36, проверено 2026-07-18.
- [Liveness, Readiness, and Startup Probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/) — Kubernetes, документация v1.36.2, проверено 2026-07-18.
- [RFC 1034: Domain Names — Concepts and Facilities](https://www.rfc-editor.org/rfc/rfc1034.html) — IETF, STD 13 / RFC 1034, ноябрь 1987, проверено 2026-07-18.
- [RFC 2782: A DNS RR for specifying the location of services](https://www.rfc-editor.org/rfc/rfc2782.html) — IETF, RFC 2782, февраль 2000, проверено 2026-07-18.
- [Service discovery](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/upstream/service_discovery) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Service](https://kubernetes.io/docs/concepts/services-networking/service/) — Kubernetes, документация v1.36, проверено 2026-07-18.
- [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/) — Kubernetes, документация ветки 1.36, проверено 2026-07-18.
- [EndpointSlice v1 API](https://kubernetes.io/docs/reference/kubernetes-api/discovery/endpoint-slice-v1/) — Kubernetes, API reference 1.36, проверено 2026-07-18.
- [Kubernetes 1.20 release announcement](https://kubernetes.io/blog/2020/12/08/kubernetes-1-20-release-announcement/) — Kubernetes, 1.20, проверено 2026-07-18.
- [Kubernetes v1.27 release](https://kubernetes.io/blog/2023/04/11/kubernetes-v1-27-release/) — Kubernetes, 1.27, проверено 2026-07-18.
- [Health Checking](https://grpc.io/docs/guides/health-checking/) — gRPC, Health Checking Protocol `grpc.health.v1`, проверено 2026-07-18.
- [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/) — Google, Site Reliability Engineering, глава 6, проверено 2026-07-18.
