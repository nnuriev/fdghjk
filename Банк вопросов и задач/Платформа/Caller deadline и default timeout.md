---
aliases:
  - "Задача: Caller deadline и default timeout"
tags:
  - область/go
  - тема/собеседование
  - тип/задача
  - источник/cursehunter
статус: проверено
---

# Caller deadline и default timeout

## Каноническая формулировка, контракт и проверенный разбор

![[CurseHunter/7171/02 Конкурентность и паттерны#60. Wrapper с caller deadline и default timeout]]

## Варианты формулировки и происхождение

- [[CurseHunter/7171/02 Конкурентность и паттерны#60. Wrapper с caller deadline и default timeout|60. Wrapper с caller deadline и default timeout]] — канонический проверенный разбор.
- [[CurseHunter/6546/Бланк вопросов и заданий#Cancellation, channels и shared state|Урок 26 курса 6546]] — точное повторное появление того же wrapper-контракта.

## Типичные ошибки и границы решения

Ошибки, edge cases, trade-offs и условия применимости сохранены в проверенных исходных разделах. Различающиеся контракты не переносятся между вариантами автоматически.

## Версионные границы и проверка

Версия Go, среда проверки и статус примеров берутся из вложенных разборов. Карточка не меняет код и не расширяет гарантии исходного контракта.

## Релевантные вопросы из теории

- [[Банк вопросов и задач/Теория/Context, deadlines и распространение отмены|Context, deadlines и распространение отмены]] — контракт отмены задаёт lifetime всей операции.
- [[Банк вопросов и задач/Теория/select, cancellation и timeout|select, cancellation и timeout]] — blocking points должны реагировать на timeout и cancellation.
