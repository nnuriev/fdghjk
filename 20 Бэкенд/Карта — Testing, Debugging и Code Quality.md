---
aliases:
  - Testing, Debugging и Code Quality [Core]
  - Testing Debugging Code Quality Core
tags:
  - тип/карта
  - область/тестирование-отладка-качество-кода
статус: черновик
---

# Testing, Debugging и Code Quality [Core]

## Назначение

Карта связывает три инженерных задачи: доказать корректность до релиза, локализовать причину деградации в работающей системе и сохранить код изменяемым. Единица выбора здесь — риск и граница наблюдения: unit test изолирует локальную логику, integration и contract tests проверяют стыки, end-to-end test подтверждает пользовательский путь, а production-debugging сопоставляет симптом с ресурсом, ожиданием или внешней зависимостью.

## Входные знания

- Жизненный цикл backend-запроса, API-контракты и модель ошибок по [[20 Бэкенд/Карта — Бэкенд|карте бэкенда]].
- Конкурентность, runtime и инструменты диагностики по [[60 Go/Карта — Go|карте Go]].
- Метрики, профили и причинный разбор инцидентов по [[70 Практические кейсы/Карта — Reliability, Performance и Operations|карте Reliability, Performance и Operations]].

## Маршрут

- [[01 Маршруты/Backend — от основ к архитектуре|Backend — от основ к архитектуре]]

## Программа

- [[20 Бэкенд/Unit tests|Unit tests]].
- [[20 Бэкенд/Integration tests|Integration tests]].
- [[20 Бэкенд/Contract tests|Contract tests]].
- [[20 Бэкенд/End-to-end tests|End-to-end tests]].
- [[60 Go/Table-driven tests в Go|Table-driven tests в Go]].
- [[20 Бэкенд/Mocks vs fakes|Mocks vs fakes]].
- [[20 Бэкенд/Property-based testing|Property-based testing]].
- [[60 Go/Fuzzing|Fuzz testing]].
- [[60 Go/Детерминированное тестирование concurrent code|Deterministic testing concurrent code]].
- [[60 Go/Race detector|Race testing]].
- [[70 Практические кейсы/Load и stress testing|Load и stress testing]].
- [[70 Практические кейсы/Fault injection и chaos basics|Fault injection/chaos basics [L5]]].
- [[70 Практические кейсы/Диагностика CPU spikes|Debugging CPU spikes]].
- [[70 Практические кейсы/Диагностика memory leaks|Debugging memory leaks]].
- [[70 Практические кейсы/Диагностика goroutine leaks|Debugging goroutine leaks]].
- [[70 Практические кейсы/Диагностика latency regression|Debugging latency regression]].
- [[70 Практические кейсы/Диагностика database bottlenecks|Debugging database bottlenecks]].
- [[70 Практические кейсы/Диагностика queue backlog|Debugging queue backlog]].
- [[50 Проектирование систем/Code readability|Code readability]].
- [[50 Проектирование систем/Maintainability|Maintainability]].
- [[20 Бэкенд/Защитная обработка невалидного ввода|Defensive handling of invalid input]].
- [[20 Бэкенд/Тестирование границ и failure paths|Boundary и failure-path testing]].

## Готовые заметки

### Стратегия и уровни тестирования

- [[20 Бэкенд/Стратегия тестирования backend]] — выбор набора проверок по риску, наблюдаемой границе и стоимости обратной связи.
- [[20 Бэкенд/Unit tests]]
- [[20 Бэкенд/Integration tests]]
- [[20 Бэкенд/Contract tests]]
- [[20 Бэкенд/End-to-end tests]]
- [[20 Бэкенд/Mocks vs fakes]]
- [[60 Go/Fuzzing|Fuzz testing]]
- [[60 Go/Race detector|Race testing]]
- [[70 Практические кейсы/Load и stress testing]]

### Диагностика

- [[70 Практические кейсы/Диагностика CPU spikes]]
- [[70 Практические кейсы/Диагностика memory leaks]]
- [[70 Практические кейсы/Диагностика goroutine leaks]]
- [[70 Практические кейсы/Диагностика latency regression]]
- [[70 Практические кейсы/Диагностика database bottlenecks]]
- [[70 Практические кейсы/Диагностика queue backlog]]

### Качество кода

- [[50 Проектирование систем/Code readability]]
- [[50 Проектирование систем/Maintainability]]

## План заметок

Материал страниц ниже заполнен и подтверждён первичными источниками. Go-примеры в table-driven, property-based и concurrent testing не удалось запустить без локальной toolchain; chaos-сценарий не проводился, а трассировки invalid input и failure paths остались иллюстративными. Поэтому до воспроизводимой проверки эти страницы остаются черновиками.

- [[60 Go/Table-driven tests в Go]]
- [[20 Бэкенд/Property-based testing]]
- [[60 Go/Детерминированное тестирование concurrent code]]
- [[70 Практические кейсы/Fault injection и chaos basics]]
- [[20 Бэкенд/Защитная обработка невалидного ввода]]
- [[20 Бэкенд/Тестирование границ и failure paths]]

## Опорные заметки

- [[60 Go/Тестирование и httptest]] — механика Go-тестов и HTTP-specific test fixtures без повторения общей стратегии уровней.
- [[50 Проектирование систем/Testability Go-компонента]] — архитектурные seams, управление зависимостями и наблюдаемость компонента.
- [[70 Практические кейсы/Performance profiling и bottleneck analysis]] — выбор профиля и переход от метрики к узкому месту до применения конкретного runbook.
- [[70 Практические кейсы/Root-cause analysis]] — проверка причинной гипотезы и отделение причины от коррелирующего симптома.

## Связанные карты

- [[20 Бэкенд/Карта — Бэкенд|Бэкенд]]
- [[50 Проектирование систем/Карта — Low-Level Design|Low-Level Design / Object-Oriented Design]]
- [[60 Go/Карта — Go|Go]]
- [[70 Практические кейсы/Карта — Reliability, Performance и Operations|Reliability, Performance и Operations]]
