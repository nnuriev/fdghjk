---
aliases:
  - "Теоретический вопрос: Circuit breaker"
tags:
  - область/распределённые-системы
  - тема/устойчивость
  - тип/вопрос
статус: проверено
---

# Circuit breaker

## Вопрос

Как работает «Circuit breaker»: какие гарантии сохраняются при сбоях, где проходят границы применимости и с какой ближайшей альтернативой это сравнивать?

## Короткий ориентир

Circuit breaker запоминает недавний результат вызовов зависимости и временно запрещает новые, когда вероятность успеха слишком мала. Fail-fast освобождает threads, connections и deadline budget, а ограниченное число probes проверяет восстановление.

Breaker не заменяет timeout, bounded concurrency и retry policy. Он реагирует только на завершившиеся наблюдения; без timeout зависшие вызовы не пополняют статистику, а без bulkhead успевают исчерпать ресурсы до открытия. Вдобавок термин неоднозначен: библиотечный breaker обычно работает как `CLOSED → OPEN → HALF_OPEN`, тогда как Envoy называет circuit breakers лимиты connections, pending requests, active requests и retries.

Полный разбор: [[40 Распределённые системы/Circuit breaker|Circuit breaker]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- [[CurseHunter/5785/05 Архитектура, устойчивость и консенсус#Circuit breaker|Circuit breaker]] — формулировка вопроса о state machine breaker и scope.
- [[CurseHunter/7091/02 Ошибки, повторы и деградация#6. Circuit breaker|6. Circuit breaker]] — вопрос о closed/open/half-open, generations и failure-domain scope.
- «Сборка сниппета — две независимые цепочки вызовов, общий deadline и политика ошибок. База: fan-out/fan-in, context, ошибки, retry, circuit breaker.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «При множестве dependencies одного глобального limit мало: отдельные per-host bulkheads и circuit breakers защищают разные failure domains.» — [[Авито/Решения/Go-платформа/Параллельный запрос URL#Trade-offs и альтернативы|Авито/Решения/Go-платформа/Параллельный запрос URL, раздел «Trade-offs и альтернативы»]].

## Источники

- [Circuit Breaking](https://www.envoyproxy.io/docs/envoy/v1.38.3/intro/arch_overview/upstream/circuit_breaking) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Circuit breakers](https://www.envoyproxy.io/docs/envoy/v1.38.3/configuration/upstream/cluster_manager/cluster_circuit_breakers) — Envoy Proxy, версия 1.38.3, проверено 2026-07-18.
- [Circuit Breaker configuration proto](https://www.envoyproxy.io/docs/envoy/v1.38.3/api-v3/config/cluster/v3/circuit_breaker.proto.html) — Envoy Proxy, API v3 в версии 1.38.3, проверено 2026-07-18.
- [Release v2.4.0](https://github.com/resilience4j/resilience4j/releases/tag/v2.4.0) — resilience4j/resilience4j, tag `v2.4.0`, опубликован 2026-03-14, проверено 2026-07-18.
- [CircuitBreakerStateMachine.java](https://github.com/resilience4j/resilience4j/blob/v2.4.0/resilience4j-circuitbreaker/src/main/java/io/github/resilience4j/circuitbreaker/internal/CircuitBreakerStateMachine.java) — resilience4j/resilience4j, tag `v2.4.0`, проверено 2026-07-18.
