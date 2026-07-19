---
aliases:
  - Reliability, Performance и Operations [Core]
  - Reliability Performance Operations Core
  - RPO Core
tags:
  - тип/карта
  - область/reliability-performance-operations
статус: проверено
---

# Reliability, Performance и Operations [Core]

## Назначение

Карта связывает пользовательские цели надёжности с измерениями, управлением ёмкостью, безопасными изменениями и разбором production-инцидентов. Её граница — эксплуатационное решение: как определить норму, заметить нарушение, ограничить ущерб, восстановить сервис и доказать причину.

## Входные знания

- Жизненный цикл backend-запроса и зависимости между сервисами.
- Базовые модели частичных отказов, очередей, репликации и конкурентности.
- Основы Go runtime для диагностики CPU, памяти и goroutines.

## Маршрут

- [[01 Маршруты/Backend — от основ к архитектуре|Backend — от основ к архитектуре]]

## Готовые заметки

- [[50 Проектирование систем/SLO в System Design|SLI, SLO, SLA.]]
- [[70 Практические кейсы/Error budgets|Error budgets.]]
- [[70 Практические кейсы/Availability и durability calculations|Availability и durability calculations.]]
- [[70 Практические кейсы/p50, p95 и p99 latency|p50, p95, p99 latency.]]
- [[70 Практические кейсы/Throughput и saturation|Throughput и saturation.]]
- [[50 Проектирование систем/Observability в System Design|Metrics, logs, traces.]]
- [[70 Практические кейсы/Dashboards и actionable alerts|Dashboards и actionable alerts.]]
- [[70 Практические кейсы/Health checks и readiness|Health checks и readiness.]]
- [[50 Проектирование систем/Оценка нагрузки и ёмкости|Capacity planning.]]
- [[70 Практические кейсы/Load и stress testing|Load и stress testing.]]
- [[70 Практические кейсы/Horizontal и vertical scaling|Horizontal и vertical scaling.]]
- [[70 Практические кейсы/Canary, blue-green и rolling deployment|Canary, blue/green, rolling deployment.]]
- [[70 Практические кейсы/Rollback|Rollback.]]
- [[70 Практические кейсы/Graceful degradation|Graceful degradation.]]
- [[70 Практические кейсы/Bulkheads и dependency isolation|Bulkheads и dependency isolation.]]
- [[70 Практические кейсы/Incident mitigation|Incident mitigation.]]
- [[70 Практические кейсы/Root-cause analysis|Root-cause analysis.]]
- [[70 Практические кейсы/Runbooks|Runbooks.]]
- [[70 Практические кейсы/Thundering herd|Thundering herd.]]
- [[40 Распределённые системы/Retry storms и cascading failures|Retry storm.]]
- [[40 Распределённые системы/Backpressure и queue buildup|Queue backlog.]]
- [[30 Данные/Hot partitions и hot keys|Hot shard/key.]]
- [[70 Практические кейсы/Memory, CPU и goroutine leaks|Memory, CPU и goroutine leaks.]]
- [[60 Go/Пакет database-sql и пулы соединений|Database connection pool exhaustion.]]
- [[70 Практические кейсы/Performance profiling и bottleneck analysis|Performance profiling и bottleneck analysis.]]
- [[70 Практические кейсы/Диагностика CPU spikes|Debugging CPU spikes.]]
- [[70 Практические кейсы/Диагностика memory leaks|Debugging memory leaks.]]
- [[70 Практические кейсы/Диагностика goroutine leaks|Debugging goroutine leaks.]]
- [[70 Практические кейсы/Диагностика latency regression|Debugging latency regression.]]
- [[70 Практические кейсы/Диагностика database bottlenecks|Debugging database bottlenecks.]]
- [[70 Практические кейсы/Диагностика queue backlog|Debugging queue backlog.]]

## План заметок

Эксперимент в заметке ниже спроектирован и подтверждён первичными источниками, но не запускался в реальной среде. До воспроизводимой проверки заметка остаётся черновиком.

- [[70 Практические кейсы/Fault injection и chaos basics]]

## Связанные карты

- [[30 Данные/Карта — Данные|Данные]]
- [[40 Распределённые системы/Карта — Распределённые системы|Распределённые системы]]
- [[20 Бэкенд/Карта — Testing, Debugging и Code Quality|Testing, Debugging и Code Quality]]
- [[50 Проектирование систем/Карта — Проектирование систем|High-Level System Design]]
- [[60 Go/Карта — Go|Go]]
- [[70 Практические кейсы/Карта — Практические кейсы|Практические кейсы]]
- [[70 Практические кейсы/Карта — Behavioral, Resume и Project Deep Dive|Behavioral, Resume и Project Deep Dive [Core]]]
