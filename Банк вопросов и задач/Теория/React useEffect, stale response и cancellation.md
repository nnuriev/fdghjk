---
aliases:
  - "Теоретический вопрос: useEffect и stale response"
tags:
  - область/фронтенд
  - тема/react
  - тип/вопрос
статус: проверено
---

# React useEffect, stale response и cancellation

## Вопрос

Почему старый request из `useEffect` может затереть новое state и чем ignore flag отличается от `AbortController`?

## Короткий ориентир

Если dependency изменилась, старый request может завершиться после нового и записать stale result. Локальный ignore flag, который cleanup переводит в закрытое состояние, защищает state update, но не прекращает network work. `AbortController` передаёт cancellation underlying operation и может освободить ресурсы раньше.

Это разные гарантии: abort просит операцию остановиться, а ignore не позволяет уже полученному или неотменяемому result изменить stale UI. При changed dependency component может оставаться mounted, поэтому одного глобального `isMounted` недостаточно.

Полный проверенный разбор: [[Telegram Собесы/Remotely — 2026-04-27 — 7125 USD/Бланк вопросов и заданий#Frontend и React — `00:09:09–00:14:14`|Remotely, useEffect, stale response и cancellation]].

## Варианты follow-up

- Что произойдёт, если request страницы 1 завершится после request страницы 3?
- Когда нужен одновременно abort и ignore stale result?
- Почему `isMounted` не различает несколько requests одного mounted component?

## Варианты формулировки и происхождение

- «Что произойдёт, если старый запрос завершится после нового? Как остановить request, результат которого уже не нужен?» — [[Telegram Собесы/Remotely — 2026-04-27 — 7125 USD/Бланк вопросов и заданий#Frontend и React — `00:09:09–00:14:14`|Remotely, frontend и React]].

## Источники

- [React: `useEffect`](https://react.dev/reference/react/useEffect) — React project, living documentation, cleanup и stale-response race, проверено 2026-07-18.
- [React: Synchronizing with Effects](https://react.dev/learn/synchronizing-with-effects) — React project, living documentation, cleanup должен abort fetch или игнорировать result, проверено 2026-07-18.
- [DOM Living Standard: AbortController](https://dom.spec.whatwg.org/#abortcontroller-api) — WHATWG, living standard, обновлено 2026-07-18, проверено 2026-07-18.
