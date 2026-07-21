---
aliases:
  - "Задача: False sharing"
tags:
  - область/go
  - тема/собеседование
  - тип/задача
  - источник/cursehunter
статус: проверено
---

# False sharing

## Каноническая формулировка, контракт и проверенный разбор

![[CurseHunter/6609/12 Примитивы синхронизации#Урок 94. False sharing]]

![[CurseHunter/6817/Бланк вопросов и заданий#Задание 4. Найти false sharing]]

![[CurseHunter/6817/Бланк вопросов и заданий#Задание 3. Найти false sharing в Go]]

## Варианты формулировки и происхождение

- [[CurseHunter/6593/02 Примитивы синхронизации#False sharing|False sharing]] — дополнительное появление вопроса о cache-line contention независимых counters.
- [[CurseHunter/6609/12 Примитивы синхронизации#Урок 94. False sharing|Урок 94. False sharing]] — канонический проверенный разбор.
- [[CurseHunter/7147/Бланк вопросов и заданий#8. False sharing и корректный benchmark|8. False sharing и корректный benchmark]] — вариант или дополнительное появление.
- [[CurseHunter/6817/Бланк вопросов и заданий#Задание 4. Найти false sharing|Задание 4. Найти false sharing]] — практическое появление с target-aware separation и проверкой hardware events.
- [[CurseHunter/6817/Бланк вопросов и заданий#Задание 3. Найти false sharing в Go|Задание 3. Найти false sharing в Go]] — вариант с фиксацией topology, toolchain и сравнением с local aggregation.

## Типичные ошибки и границы решения

Ошибки, edge cases, trade-offs и условия применимости сохранены в проверенных исходных разделах. Различающиеся контракты не переносятся между вариантами автоматически.

## Версионные границы и проверка

Версия Go, среда проверки и статус примеров берутся из вложенных разборов. Карточка не меняет код и не расширяет гарантии исходного контракта.

## Релевантные вопросы из теории

- [[Банк вопросов и задач/Теория/Модель памяти Go и happens-before|Модель памяти Go и happens-before]] — без happens-before нельзя обосновать наблюдаемость shared state.
- [[Банк вопросов и задач/Теория/Data races, deadlocks и livelocks|Data races, deadlocks и livelocks]] — failure mode связан с safety или liveness конкурентного кода.
- [[Банк вопросов и задач/Теория/Mutex, RWMutex и примитивы координации sync|Mutex, RWMutex и примитивы координации sync]] — нужно выбрать primitive под общий инвариант.
