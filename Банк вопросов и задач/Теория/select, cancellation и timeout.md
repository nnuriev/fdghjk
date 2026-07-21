---
aliases:
  - "Теоретический вопрос: select, cancellation и timeout"
tags:
  - область/go
  - тема/конкурентность
  - тип/вопрос
статус: проверено
---

# select, cancellation и timeout

## Вопрос

Объясните тему «select, cancellation и timeout» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

`select` ждёт первую готовую channel operation и позволяет одной goroutine реагировать на результат, отмену и timeout. Если готовы несколько cases, язык выбирает один псевдослучайно: порядок cases не задаёт приоритет. Поэтому ветка cancellation должна останавливать дальнейшую работу; рассчитывать, что она окажется «более важной», нельзя.

Полный разбор: [[60 Go/select, cancellation и timeout|select, cancellation и timeout]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- «Channel protocol и synchronization покрыты в Буферизации и закрытии каналов, select и cancellation, Каналах или mutex, Mutex и RWMutex и sync/atomic.» — [[Telegram Собесы/Сбер — 2026-05-28 — 250к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Сбер — 2026-05-28 — 250к, раздел «Сопоставление с материалами vault»]].
- «Timeout-wrapper над неотменяемой функцией — bounded wait не означает отмену работы; buffered result channel не оставляет producer заблокированным. База: select и timeout, goroutine leaks, буферизация каналов.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «Buffered/unbuffered/closed/nil channels и `select`: Буферизация, ownership и закрытие каналов, select, cancellation и timeout, Каналы или mutex.» — [[Авито/roadmap#Concurrency и runtime|Авито/roadmap, раздел «Concurrency и runtime»]].
- «`context.WithTimeout` наследует более ранний parent deadline. `defer cancel()` освобождает связанные timer resources при любом исходе. Сам механизм deadline и закрытия channel разобран в заметке о select и cancellation.» — [[Авито/Решения/Go-платформа/Timeout-wrapper над неотменяемой функцией#Ментальная модель|Авито/Решения/Go-платформа/Timeout-wrapper над неотменяемой функцией, раздел «Ментальная модель»]].

## Источники

- [Go Language Specification — Select statements](https://go.dev/ref/spec#Select_statements) — The Go Project, language version Go 1.26, проверено 2026-07-15.
- [Package time](https://pkg.go.dev/time@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
- [Go 1.23 Release Notes — Timer changes](https://go.dev/doc/go1.23#timer-changes) — The Go Project, Go 1.23, проверено 2026-07-15.
- [The Go Memory Model — Channel communication](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
