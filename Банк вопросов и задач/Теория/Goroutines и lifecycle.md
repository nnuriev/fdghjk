---
aliases:
  - "Теоретический вопрос: Goroutines и lifecycle"
tags:
  - область/go
  - тема/конкурентность
  - тип/вопрос
статус: проверено
---

# Goroutines и lifecycle

## Вопрос

Объясните тему «Goroutines и lifecycle» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Оператор `go` запускает функцию независимо от вызывающей goroutine, но не создаёт ни `join`, ни отмену, ни передачу ошибки. Поэтому у каждой goroutine должен быть владелец, условие завершения и способ дождаться остановки; иначе локальная асинхронность превращается в [[60 Go/Goroutine и channel leaks|утечку goroutine]] или незавершённую работу.

Полный разбор: [[60 Go/Goroutines и lifecycle|Goroutines и lifecycle]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- [[CurseHunter/6593/01 Выполнение кода, горутины и планировщик#Когда завершается процесс?|Когда завершается процесс?]] — вопрос о завершении процесса после возврата `main` без ожидания goroutines.
- «Goroutine заканчивается при return её top-level function, `runtime.Goexit` или завершении process. Garbage collector не отменяет заблокированную goroutine только потому, что application больше не ждёт результат. Lifecycle и ownership подробно разобраны в заметке о lifecycle goroutine.» — [[CurseHunter/6609/11 Горутины и планировщик#Урок 75. Goroutine как управляемая runtime задача|CurseHunter/6609/11 Горутины и планировщик, раздел «Урок 75. Goroutine как управляемая runtime задача»]].
- «Goroutines, threads и GMP соответствуют Goroutines и lifecycle, Планировщику GMP, Стекам и escape analysis и Netpoller.» — [[Telegram Собесы/Сбер — 2026-05-28 — 250к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Сбер — 2026-05-28 — 250к, раздел «Сопоставление с материалами vault»]].
- «Горутины в цикле — loop-variable semantics, ожидание завершения и data race на общем максимуме. База: замыкания, lifecycle goroutine, happens-before, race detector, WaitGroup и Mutex.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «Goroutine, OS thread, GMP и точки блокировки: Goroutines и lifecycle, Планировщик GMP, Процесс, поток и goroutine.» — [[Авито/roadmap#Concurrency и runtime|Авито/roadmap, раздел «Concurrency и runtime»]].

## Источники

- [Go Language Specification — Go statements](https://go.dev/ref/spec#Go_statements) — The Go Project, language version Go 1.26, проверено 2026-07-15.
- [Go Language Specification — Program execution](https://go.dev/ref/spec#Program_execution) — The Go Project, language version Go 1.26, проверено 2026-07-15.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
- [Go 1.22 Release Notes: changes to for loops](https://go.dev/doc/go1.22) — The Go Project, Go 1.22, проверено 2026-07-15.
