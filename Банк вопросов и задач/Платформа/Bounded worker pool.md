---
aliases:
  - "Задача: Bounded worker pool"
tags:
  - область/go
  - тема/собеседование
  - тип/задача
  - источник/cursehunter
статус: проверено
---

# Bounded worker pool

## Каноническая формулировка, контракт и проверенный разбор

![[CurseHunter/6609/15 Concurrency-паттерны#Урок 113. Worker pool]]

![[CurseHunter/6593/06 Практические реализации и учебная БД#Live coding 1: bounded worker pool]]

![[CurseHunter/7171/02 Конкурентность и паттерны#74. Worker pool для обработки изображений]]

![[Telegram Собесы/CoinsPaid — 2026-04-27 — 6633 EUR/Бланк вопросов и заданий#Задача 1. CPU-bound worker pool — `01:04:45–01:08:43`]]

## Варианты формулировки и происхождение

- [[CurseHunter/6593/06 Практические реализации и учебная БД#Условие курса|Условие курса — bounded worker pool]] — точная постановка первого live-coding задания.
- [[CurseHunter/6593/06 Практические реализации и учебная БД#Что должен спросить кандидат|Что должен спросить кандидат]] — уточнения queue, backpressure, panic и close semantics.
- [[CurseHunter/6593/06 Практические реализации и учебная БД#Ошибка решения|Ошибка решения bounded worker pool]] — failure mode с lost wake-up и lifecycle.
- [[CurseHunter/6609/15 Concurrency-паттерны#Урок 113. Worker pool|Урок 113. Worker pool]] — канонический проверенный разбор.
- [[CurseHunter/6593/06 Практические реализации и учебная БД#Live coding 1: bounded worker pool|Live coding 1: bounded worker pool]] — вариант или дополнительное появление.
- [[CurseHunter/7171/02 Конкурентность и паттерны#74. Worker pool для обработки изображений|74. Worker pool для обработки изображений]] — вариант или дополнительное появление.
- [[CurseHunter/6546/Бланк вопросов и заданий#Coordination patterns|Урок 32 курса 6546]] — точное повторное появление этой задачи.

- [[Telegram Собесы/CoinsPaid — 2026-04-27 — 6633 EUR/Бланк вопросов и заданий#Задача 1. CPU-bound worker pool — `01:04:45–01:08:43`|Задача 1. CPU-bound worker pool — `01:04:45–01:08:43`]] — дополнительное проверенное появление того же контракта.
- [[CurseHunter/6860/04 Планировщик, синхронизация и каналы#Задание 14. Bounded worker pool|Задание 14. Bounded worker pool]] — точное появление bounded worker-pool задания курса 6860.

- [[CurseHunter/7171/03 Code review на собеседовании#81. Worker pool с panic и незакрытыми каналами|81. Worker pool с panic и незакрытыми каналами]] — точное появление code-review варианта с panic и нарушенным channel lifecycle.

## Типичные ошибки и границы решения

Ошибки, edge cases, trade-offs и условия применимости сохранены в проверенных исходных разделах. Различающиеся контракты не переносятся между вариантами автоматически.

## Версионные границы и проверка

Версия Go, среда проверки и статус примеров берутся из вложенных разборов. Карточка не меняет код и не расширяет гарантии исходного контракта.

## Релевантные вопросы из теории

- [[Банк вопросов и задач/Теория/Worker pool, fan-in, fan-out и bounded concurrency|Worker pool, fan-in, fan-out и bounded concurrency]] — модель задаёт ограничение параллелизма и координацию workers.
- [[Банк вопросов и задач/Теория/Буферизация, ownership и закрытие каналов|Буферизация, ownership и закрытие каналов]] — владение определяет, кто и когда закрывает channel.
- [[Банк вопросов и задач/Теория/Goroutine и channel leaks|Goroutine и channel leaks]] — ошибка lifecycle часто оставляет заблокированную goroutine.
