---
aliases:
  - "Теоретический вопрос: frontend testing strategy"
tags:
  - область/фронтенд
  - тема/тестирование
  - тип/вопрос
статус: черновик
---

# Стратегия frontend-тестирования

## Вопрос

Что проверять на unit, component/integration, browser/E2E и visual-regression уровнях frontend-приложения?

## Короткий ориентир

Уровень выбирают по риску observable behavior, а не по количеству arithmetic. Unit test подходит pure transformation и validation; component или integration test — формам, permissions, loading/error/empty states и keyboard interaction; browser/E2E — критическому journey через routing, API и реальный browser. Visual regression полезен, когда layout сам является contract.

Проверка «component существует» слаба, если фиксирует implementation detail. Запрос элемента по accessible role/name, действие пользователя и проверка результата одновременно проверяют behavior и часть accessibility contract. Ручной просмотр остаётся exploratory check, но не воспроизводимой защитой от regression.

Полный проверенный разбор: [[Telegram Собесы/Remotely — 2026-04-27 — 7125 USD/Бланк вопросов и заданий#Frontend и React — `00:09:09–00:14:14`|Remotely, frontend testing]]. Статус черновой: карточка объединяет несколько уровней тестирования, а primary source фиксирует прежде всего user-centric testing principle.

## Варианты follow-up

- Почему test наличия component может не проверять пользовательский contract?
- Что оставить component test, а что поднять до browser/E2E?
- Когда visual regression даёт сигнал, а когда создаёт шумные snapshots?

## Варианты формулировки и происхождение

- «Есть ли опыт frontend testing и что именно стоит проверять?» — [[Telegram Собесы/Remotely — 2026-04-27 — 7125 USD/Бланк вопросов и заданий#Frontend и React — `00:09:09–00:14:14`|Remotely, frontend и React]].

## Источники

- [Testing Library: Introduction](https://testing-library.com/docs/) — Testing Library project, user-centric testing principles, страница обновлена 2026-01-22, проверено 2026-07-18.
