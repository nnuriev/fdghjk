---
aliases:
  - "Задача: Data race на channel variable"
tags:
  - область/go
  - тема/собеседование
  - тип/задача
  - источник/cursehunter
статус: проверено
---

# Data race на channel variable

## Каноническая формулировка, контракт и проверенный разбор

![[CurseHunter/6609/13 Каналы#Data race на channel variable]]

## Варианты формулировки и происхождение

- [[CurseHunter/6609/13 Каналы#Data race на channel variable|Data race на channel variable]] — канонический проверенный разбор.

- [[CurseHunter/7146/Бланк вопросов и заданий#4. Goroutine leaks и deadlocks|4. Goroutine leaks и deadlocks]] — дополнительное проверенное появление этой ментальной модели.
- [[CurseHunter/7146/Бланк вопросов и заданий#«Channel thread-safe» не относится к переменной|«Channel thread-safe» не относится к переменной]] — точный вопрос о race при переназначении shared channel variable.

## Типичные ошибки и границы решения

Ошибки, edge cases, trade-offs и условия применимости сохранены в проверенных исходных разделах. Различающиеся контракты не переносятся между вариантами автоматически.

## Версионные границы и проверка

Версия Go, среда проверки и статус примеров берутся из вложенных разборов. Карточка не меняет код и не расширяет гарантии исходного контракта.

## Релевантные вопросы из теории

- [[Банк вопросов и задач/Теория/Worker pool, fan-in, fan-out и bounded concurrency|Worker pool, fan-in, fan-out и bounded concurrency]] — модель задаёт ограничение параллелизма и координацию workers.
- [[Банк вопросов и задач/Теория/Буферизация, ownership и закрытие каналов|Буферизация, ownership и закрытие каналов]] — владение определяет, кто и когда закрывает channel.
- [[Банк вопросов и задач/Теория/Goroutine и channel leaks|Goroutine и channel leaks]] — ошибка lifecycle часто оставляет заблокированную goroutine.
