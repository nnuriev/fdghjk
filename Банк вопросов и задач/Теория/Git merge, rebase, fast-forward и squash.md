---
aliases:
  - "Теоретический вопрос: Git merge, rebase, fast-forward и squash"
tags:
  - область/основы-cs
  - тема/git
  - тип/вопрос
статус: черновик
---

# Git merge, rebase, fast-forward и squash

## Вопрос

Как merge, rebase, fast-forward и squash преобразуют commit graph и какие риски возникают для общей ветки?

## Короткий ориентир

Merge соединяет histories и сохраняет ancestry; fast-forward только передвигает ref, когда divergence нет. Rebase воспроизводит commits на новой базе и создаёт новые object IDs, поэтому переписывание shared history требует координации. Squash сворачивает несколько изменений в один commit и теряет их отдельную историю.

Полные разборы:

- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Git merge, rebase и squash — `00:32:09–00:35:10`|MERLION: Git merge и rebase]]

## Варианты follow-up

- Когда merge выполняется как fast-forward?
- Почему commit IDs меняются после rebase?
- Когда rebase shared branch опасен?

## Варианты формулировки и происхождение

- [[Telegram Собесы/MERLION — 2025-07-29 — 300к/Бланк вопросов и заданий#Git merge, rebase и squash — `00:32:09–00:35:10`|MERLION, Git]].

## Источники

- [git-rebase](https://git-scm.com/docs/git-rebase) — Git project, current documentation, проверено `2026-07-19`.
- [Git User Manual: How to merge](https://git-scm.com/docs/user-manual#_how_to_merge) — Git project, current documentation, проверено `2026-07-19`.
