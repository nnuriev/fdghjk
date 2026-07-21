---
aliases:
  - "Задача: Read-through cache с синхронизацией и retries"
tags:
  - область/go
  - тема/собеседование
  - тип/задача
  - источник/cursehunter
статус: проверено
---

# Read-through cache с синхронизацией и retries

## Каноническая формулировка, контракт и проверенный разбор

![[CurseHunter/6609/15 Concurrency-паттерны#Урок 115. Синхронизация cache]]

## Варианты формулировки и происхождение

- [[CurseHunter/6593/06 Практические реализации и учебная БД#Live coding 4: Redis cache с синхронизацией|Live coding 4: Redis cache с синхронизацией]] — дополнительное появление того же cache/retry contract.
- [[CurseHunter/6593/06 Практические реализации и учебная БД#Условие курса|Условие курса — Redis cache с синхронизацией]] — точная постановка четвёртого live-coding задания.
- [[CurseHunter/6593/06 Практические реализации и учебная БД#Ошибки и недостающие решения|Ошибки и недостающие решения Redis cache]] — failure modes retry, snapshot replacement, stampede и shutdown.
- [[CurseHunter/6609/15 Concurrency-паттерны#Урок 115. Синхронизация cache|Урок 115. Синхронизация cache]] — канонический проверенный разбор.

## Типичные ошибки и границы решения

Ошибки, edge cases, trade-offs и условия применимости сохранены в проверенных исходных разделах. Различающиеся контракты не переносятся между вариантами автоматически.

## Версионные границы и проверка

Версия Go, среда проверки и статус примеров берутся из вложенных разборов. Карточка не меняет код и не расширяет гарантии исходного контракта.

## Релевантные вопросы из теории

- [[Банк вопросов и задач/Теория/Проектирование и реализация in-memory cache в Go|Проектирование и реализация in-memory cache в Go]] — cache policy задаёт miss, refresh, staleness и synchronization.
- [[Банк вопросов и задач/Теория/Retry, exponential backoff и jitter|Retry, exponential backoff и jitter]] — retry loop обязан учитывать cancellation, последнюю попытку и jitter.
- [[Банк вопросов и задач/Теория/Thundering herd|Thundering herd]] — одновременные misses требуют singleflight или bounded refresh.
