---
aliases:
  - "Теоретический вопрос: Конфигурация и feature flags"
tags:
  - область/бэкенд
  - тема/конфигурация
  - тип/вопрос
статус: проверено
---

# Конфигурация и feature flags

## Вопрос

Как работает «Конфигурация и feature flags» и какие ограничения, failure modes и trade-offs нужно учитывать в backend-системе?

## Короткий ориентир

Конфигурация задаёт параметры окружения для одного и того же артефакта: адреса зависимостей, limits, timeouts и режимы интеграции. Feature flag выбирает ветку поведения во время исполнения, иногда по evaluation context конкретного запроса. Это разные контракты: невалидная обязательная конфигурация должна остановить startup, а недоступность flag provider требует заранее выбранного default или последнего корректного snapshot.

Изменение конфигурации и флага — production change. Нужны типизированная схема, атомарное применение целого snapshot, безопасные defaults, аудит, наблюдаемая версия и rollback. Флаг без владельца и даты удаления становится постоянной альтернативной архитектурой; секрет, помещённый в flag context или ConfigMap, становится утечкой.

Полный разбор: [[20 Бэкенд/Конфигурация и feature flags|Конфигурация и feature flags]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «A/B-тесты на сайте — нужно исходное условие; база: Конфигурация и feature flags, Проектирование feature flag и configuration service.» — [[Авито/roadmap#System design и проектирование|Авито/roadmap, раздел «System design и проектирование»]].

## Источники

- [The Twelve-Factor App: Config](https://www.12factor.net/config) — Adam Wiggins, редакция 2017 года, проверено 2026-07-18.
- [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) — Kubernetes, документация v1.36, проверено 2026-07-18.
- [ConfigMap v1 API](https://kubernetes.io/docs/reference/kubernetes-api/core/config-map-v1/) — Kubernetes, API `core/v1` v1.36, проверено 2026-07-18.
- [OpenFeature Specification](https://github.com/open-feature/spec/tree/7886c6af69a2e77c16c84890bcfb02381e1163cf/specification) — OpenFeature, commit `7886c6af69a2e77c16c84890bcfb02381e1163cf`, проверено 2026-07-18.
- [Evaluation Context](https://github.com/open-feature/spec/blob/7886c6af69a2e77c16c84890bcfb02381e1163cf/specification/sections/03-evaluation-context.md) — OpenFeature, commit `7886c6af69a2e77c16c84890bcfb02381e1163cf`, проверено 2026-07-18.
- [Flag Evaluation API](https://github.com/open-feature/spec/blob/7886c6af69a2e77c16c84890bcfb02381e1163cf/specification/sections/01-flag-evaluation.md) — OpenFeature, commit `7886c6af69a2e77c16c84890bcfb02381e1163cf`, проверено 2026-07-18.
