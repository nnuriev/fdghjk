---
aliases:
  - "Теоретический вопрос: Каналы или mutex"
tags:
  - область/go
  - тема/конкурентность
  - тип/вопрос
статус: проверено
---

# Каналы или mutex

## Вопрос

Объясните тему «Каналы или mutex» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Выбирайте не по лозунгу, а по ownership. Mutex подходит, когда несколько goroutines должны кратко обращаться к одному состоянию. Channel подходит, когда значение или команда передаётся владельцу, а ordering, backpressure и lifecycle являются частью протокола. Channel не делает shared state автоматически проще, а mutex не мешает хорошо изолировать данные.

Полный разбор: [[60 Go/Каналы или mutex|Каналы или mutex]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Channel protocol, map synchronization и диагностика покрывают Каналы или mutex, Map, Mutex и RWMutex и Race detector.» — [[Telegram Собесы/Lamoda — 2026-06-10 — 400к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Lamoda — 2026-06-10 — 400к, раздел «Сопоставление с материалами vault»]].
- «Практическая задача напрямую проверяет ментальную модель из Каналы или mutex: channel может передавать ownership и создавать happens-before relation, но сам по себе не предотвращает неверный протокол завершения.» — [[Telegram Собесы/Редлаб — 2026-06-30 — 300к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Редлаб — 2026-06-30 — 300к, раздел «Сопоставление с материалами vault»]].
- «Channel protocol и synchronization покрыты в Буферизации и закрытии каналов, select и cancellation, Каналах или mutex, Mutex и RWMutex и sync/atomic.» — [[Telegram Собесы/Сбер — 2026-05-28 — 250к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Сбер — 2026-05-28 — 250к, раздел «Сопоставление с материалами vault»]].
- «Buffered/unbuffered/closed/nil channels и `select`: Буферизация, ownership и закрытие каналов, select, cancellation и timeout, Каналы или mutex.» — [[Авито/roadmap#Concurrency и runtime|Авито/roadmap, раздел «Concurrency и runtime»]].
- «Ни одна mutable variable не записывается двумя goroutines. Ownership передаётся через channels, поэтому отдельный mutex для результатов не нужен; выбор каналов вместо lock соответствует критерию из заметки о channels и mutex.» — [[Авито/Решения/Go-платформа/Сборка сниппета#Concurrency invariants|Авито/Решения/Go-платформа/Сборка сниппета, раздел «Concurrency invariants»]].

- [[CurseHunter/7146/Бланк вопросов и заданий#5. Когда channel, а когда mutex|5. Когда channel, а когда mutex]] — проверенная формулировка вопроса и критерий выбора primitive из курса по каналам.

## Источники

- [Package sync](https://pkg.go.dev/sync@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-15.
- [Go Language Specification — Channel types](https://go.dev/ref/spec#Channel_types) — The Go Project, language version Go 1.26, проверено 2026-07-15.
- [The Go Memory Model](https://go.dev/ref/mem) — The Go Project, версия от 2022-06-06, применима к Go 1.26, проверено 2026-07-15.
