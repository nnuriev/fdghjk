---
aliases:
  - "Теоретический вопрос: Проектирование feature flag и configuration service"
tags:
  - тип/разбор
  - область/проектирование-систем
  - тема/конфигурация
  - тип/вопрос
статус: проверено
---

# Проектирование feature flag и configuration service

## Вопрос

Как раскрыть на System Design интервью тему «Проектирование feature flag и configuration service»: какие требования, инварианты и trade-offs определяют решение?

## Короткий ориентир

Configuration service хранит и распространяет versioned snapshots, а SDK оценивает feature flags локально. Центральный RPC на каждую evaluation создаёт зависимость в самом чувствительном месте: любой отказ control plane останавливает приложения. Поэтому data plane — last-known-good snapshot в process, детерминированный evaluator и безопасный default; control plane — RBAC, validation, publish, audit и rollback.

Consistency здесь не означает одновременное переключение всей fleet. Реалистичная гарантия — monotonically increasing revision на клиенте и измеряемое propagation window. Если операция требует атомарного глобального cutover, feature flag не тот механизм: нужен совместимый двухфазный rollout или координированный protocol.

Полный разбор: [[50 Проектирование систем/Проектирование feature flag и configuration service|Проектирование feature flag и configuration service]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «A/B-тесты на сайте — нужно исходное условие; база: Конфигурация и feature flags, Проектирование feature flag и configuration service.» — [[Авито/roadmap#System design и проектирование|Авито/roadmap, раздел «System design и проектирование»]].

## Источники

- [OpenFeature Specification](https://github.com/open-feature/spec/tree/7886c6af69a2e77c16c84890bcfb02381e1163cf/specification) — OpenFeature, commit `7886c6af69a2e77c16c84890bcfb02381e1163cf`, проверено 2026-07-18.
- [Flag Evaluation API](https://github.com/open-feature/spec/blob/7886c6af69a2e77c16c84890bcfb02381e1163cf/specification/sections/01-flag-evaluation.md) — OpenFeature, commit `7886c6af69a2e77c16c84890bcfb02381e1163cf`, проверено 2026-07-18.
- [Evaluation Context](https://github.com/open-feature/spec/blob/7886c6af69a2e77c16c84890bcfb02381e1163cf/specification/sections/03-evaluation-context.md) — OpenFeature, commit `7886c6af69a2e77c16c84890bcfb02381e1163cf`, проверено 2026-07-18.
- [ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/) — Kubernetes, документация v1.36, проверено 2026-07-18.
- [etcd API](https://etcd.io/docs/v3.6/learning/api/) — etcd, документация v3.6, проверено 2026-07-18.
- [Canarying Releases](https://sre.google/workbook/canarying-releases/) — Google SRE Workbook, проверено 2026-07-18.
