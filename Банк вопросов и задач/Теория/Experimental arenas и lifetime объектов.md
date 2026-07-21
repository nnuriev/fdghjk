---
aliases:
  - "Теоретический вопрос: Experimental arenas и lifetime объектов"
tags:
  - область/go
  - тема/память
  - тип/вопрос
статус: черновик
---

# Experimental arenas и lifetime объектов

## Вопрос

Как experimental arenas меняют allocation lifetime и почему их нельзя считать стабильным ручным `free` для Go?

## Короткий ориентир

Arena группирует allocations и освобождает их общим lifetime, поэтому ни одна используемая ссылка не должна пережить освобождение region. В Go 1.26.5 package `arena` остаётся под `goexperiment.arenas`; proposal отложен, а API не входит в стабильный контракт стандартной библиотеки.

Полные разборы:

- [[Telegram Собесы/Adcamp — 2026-03-23 — 280к/Бланк вопросов и заданий#Stack, heap, GC, `sync.Pool` и arenas — `00:15:35–00:21:30`|Adcamp: arenas]]

## Варианты follow-up

- Какой lifetime invariant нужен для ссылок на arena objects?
- Является ли `arena` стабильным package Go 1.26?
- Почему arena optimization требует profile и benchmark?

## Варианты формулировки и происхождение

- [[Telegram Собесы/Adcamp — 2026-03-23 — 280к/Бланк вопросов и заданий#Stack, heap, GC, `sync.Pool` и arenas — `00:15:35–00:21:30`|Adcamp, arenas]].

- [[CurseHunter/6817/Бланк вопросов и заданий#5. Чем `AddCleanup` отличается от finalizer и явного `Close`?|5. Чем `AddCleanup` отличается от finalizer и явного `Close`?]] — точная формулировка вопроса курса 6817 из «Урок 10. Оптимизации в Go».

## Источники

- [Package arena source](https://github.com/golang/go/blob/go1.26.5/src/arena/arena.go) — репозиторий `golang/go`, tag `go1.26.5`, `goexperiment.arenas` и experimental API; проверено `2026-07-18`.
- [Proposal discussion: memory regions](https://github.com/golang/go/discussions/70257) — Go team, исходное arena proposal отложено на неопределённый срок и заменено исследованием composable memory regions; проверено `2026-07-18`.
