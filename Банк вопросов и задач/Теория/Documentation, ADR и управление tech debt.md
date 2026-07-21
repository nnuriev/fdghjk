---
aliases:
  - "Теоретический вопрос: documentation и tech debt"
tags:
  - область/бэкенд
  - тема/инженерные-практики
  - тип/вопрос
статус: черновик
---

# Documentation, ADR и управление tech debt

## Вопрос

Какую documentation поддерживать рядом с системой и как управлять tech debt, когда product ожидает новые features?

## Короткий ориентир

Documentation полезна, когда отвечает не вместо кода, а на другой вопрос: prerequisites, команды запуска и recovery, operational invariants, ownership и rationale решения. Воспроизводимые части лучше проверять автоматически; decision rationale можно хранить рядом с change в коротком ADR с owner и trigger для пересмотра.

Tech debt удобнее вести как очередь с observable impact: incident risk, lead time, support cost, security, performance и blocked roadmap. Малое исправление можно включить в feature, крупному нужны business case, success metric и staged migration. Формула «иногда выделяем день» не управляет systemic debt, а полное переписывание без промежуточной отдачи трудно защитить перед product.

Полный наблюдаемый разбор: [[Telegram Собесы/Remotely — 2026-04-27 — 7125 USD/Бланк вопросов и заданий#Documentation и tech debt — `00:21:36–00:26:38`|Remotely, documentation и tech debt]]. Статус черновой: это инженерные эвристики, а не единый нормативный protocol; отдельные утверждения требуют дополнительной первичной опоры.

## Варианты follow-up

- Что должно быть source of truth: код, generated artifact, runbook или ADR?
- По каким метрикам объяснить product стоимость крупного debt item?
- Как провести staged migration без скрытого big-bang rewrite?

## Варианты формулировки и происхождение

- «Какую documentation вы считаете полезной и как не дать ей устареть? Как работать с долгосрочным tech debt?» — [[Telegram Собесы/Remotely — 2026-04-27 — 7125 USD/Бланк вопросов и заданий#Documentation и tech debt — `00:21:36–00:26:38`|Remotely, documentation и tech debt]].

- [[Telegram Собесы/Lunar Rails — 2026-04-27 — 7800 USD/Бланк вопросов и заданий#Collaboration и рабочие практики — `00:28:20–00:43:15`|Collaboration и рабочие практики — `00:28:20–00:43:15`]] — technical project prompts этого смешанного блока сохранены здесь; behavioral, motivation и culture-fit часть исключена из банка.
- [[Telegram Собесы/Remotely — 2026-04-27 — 7125 USD/Бланк вопросов и заданий#Предпочтения, обучение и Go — `00:14:49–00:21:36`|Предпочтения, обучение и Go — `00:14:49–00:21:36`]] — technical project prompts этого смешанного блока сохранены здесь; behavioral, motivation и culture-fit часть исключена из банка.

## Источники

- [[Telegram Собесы/Remotely — 2026-04-27 — 7125 USD/Бланк вопросов и заданий#Documentation и tech debt — `00:21:36–00:26:38`|Проверенный разбор интервью Remotely]] — наблюдаемые вопросы и границы ответа, проверено 2026-07-18.
