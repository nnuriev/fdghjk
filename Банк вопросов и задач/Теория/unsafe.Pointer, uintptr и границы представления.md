---
aliases:
  - "Теоретический вопрос: unsafe.Pointer, uintptr и границы представления"
tags:
  - область/go
  - тема/unsafe
  - тип/вопрос
статус: черновик
---

# unsafe.Pointer, uintptr и границы представления

## Вопрос

Какие преобразования допускает `unsafe.Pointer`, почему `uintptr` не удерживает объект живым и где ломается переносимость?

## Короткий ориентир

`unsafe.Pointer` позволяет переходить между pointer representations только по документированным patterns. `uintptr` — integer, а не pointer: GC не обязан считать его ссылкой на объект, поэтому сохранение адреса в `uintptr` разрывает lifetime guarantee. Ответ всегда привязан к Go version, layout assumptions и конкретной операции.

Полные разборы:

- [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#`unsafe` — `00:21:12–00:23:40`|X5: unsafe]]
- [[CurseHunter/6609/01 Типы данных#Урок 5. Почему `uintptr` не является pointer|CourseHunter 6609: uintptr]]

## Варианты follow-up

- Чем `unsafe.Pointer` отличается от обычного typed pointer?
- Почему `uintptr` не является GC root?
- Какие documented conversion patterns разрешены package `unsafe`?

## Варианты формулировки и происхождение

- [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#`unsafe` — `00:21:12–00:23:40`|X5, unsafe]].
- [[CurseHunter/6609/01 Типы данных#Урок 5. Почему `uintptr` не является pointer|CourseHunter 6609, uintptr]].

- [[CurseHunter/6817/Бланк вопросов и заданий#7. Что хранит slice и почему нельзя конструировать `reflect.SliceHeader` вручную?|7. Что хранит slice и почему нельзя конструировать `reflect.SliceHeader` вручную?]] — точная формулировка вопроса курса 6817 из «Урок 9. Устройство памяти Go и бенчмарки».
- [[CurseHunter/6817/Бланк вопросов и заданий#8. Что на самом деле делает zero-copy conversion через `unsafe.String`?|8. Что на самом деле делает zero-copy conversion через `unsafe.String`?]] — точная формулировка вопроса курса 6817 из «Урок 9. Устройство памяти Go и бенчмарки».

## Источники

- [The Go Programming Language Specification](https://go.dev/ref/spec) — Go project, language version Go 1.26, проверено 2026-07-19.
- [Package unsafe](https://pkg.go.dev/unsafe@go1.26.5) — Go standard library, Go 1.26.5, проверено 2026-07-19.
