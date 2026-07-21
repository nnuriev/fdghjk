---
aliases:
  - "Теоретический вопрос: слои backend-приложения и feature-first layout"
tags:
  - область/бэкенд
  - тема/архитектура
  - тип/вопрос
статус: черновик
---

# Архитектурные слои, feature-first layout и overengineering

## Вопрос

Когда разделение handler, business logic и database access помогает изменять и тестировать backend, а когда дополнительные layers и interfaces становятся overengineering?

## Короткий ориентир

Граница полезна, если у частей различаются contracts и причины изменения: handler отвечает за transport, business code — за decisions и invariants, repository или adapter — за внешнее состояние. Feature-first layout помогает держать один vertical slice рядом, но physical folders не обязаны механически повторять каждое архитектурное понятие.

Interface оправдан в месте реальной вариативности или test seam со стороны consumer. Interface «на каждый struct» добавляет indirection, но не создаёт новый contract. Решение проверяют конкретным change scenario: какая зависимость остаётся concrete, какое изменение требует abstraction и какой observable test становится проще.

Полный разбор наблюдаемого кейса: [[Telegram Собесы/Remotely — 2026-04-27 — 7125 USD/Бланк вопросов и заданий#Знакомство и backend challenge — `00:03:16–00:09:09`|Remotely, backend challenge]]. Общая граница abstraction раскрыта в [[Банк вопросов и задач/Теория/Dependency inversion|вопросе о Dependency Inversion]]. Статус черновой: исходный contract take-home challenge сохранился не полностью.

## Варианты follow-up

- Какой change оправдает новый interface, а какой проще выполнить в concrete type?
- Где должен находиться transaction boundary: в handler, service или repository?
- Как отличить полезный vertical slice от дублирования инфраструктурного кода?

## Варианты формулировки и происхождение

- «Почему код разделён по features, business logic и database access? Когда layers и interfaces становятся overengineering?» — [[Telegram Собесы/Remotely — 2026-04-27 — 7125 USD/Бланк вопросов и заданий#Знакомство и backend challenge — `00:03:16–00:09:09`|Remotely, backend challenge]].

## Источники

- [[Telegram Собесы/Remotely — 2026-04-27 — 7125 USD/Бланк вопросов и заданий#Знакомство и backend challenge — `00:03:16–00:09:09`|Проверенный разбор исходного кейса Remotely]] — требования challenge восстановлены только в наблюдаемой части, проверено 2026-07-18.
