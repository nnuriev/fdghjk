---
aliases:
  - "Теоретический вопрос: Битовые операции, системы счисления и endianness"
tags:
  - область/основы-cs
  - тема/битовые-операции
  - тип/вопрос
статус: черновик
---

# Битовые операции, системы счисления и endianness

## Вопрос

Как рассуждать о masks, shifts, системах счисления и byte order без смешения числового значения с его представлением?

## Короткий ориентир

Битовые операции работают над фиксированной последовательностью bits выбранного integer type; width и signedness определяют результат shifts и complement. Система счисления меняет запись числа, а endianness — порядок bytes в memory или wire representation, но не само числовое значение.

Полные разборы:

- [[10 Основы CS/Битовые операции и базовая математика|Битовые операции и базовая математика]]

## Варианты follow-up

- Почему `x & (x-1)` очищает младший установленный bit?
- Как width и signedness влияют на complement и shifts?
- Чем endianness отличается от порядка bits внутри byte?

## Варианты формулировки и происхождение

- [[CurseHunter/7500/01 Битовые операции и задачи#Битовые операции: минимальная модель|CourseHunter 7500, битовые операции]].
- [[CurseHunter/6609/01 Типы данных#Урок 6. Endianness|CourseHunter 6609, endianness]].

## Источники

- [The Go Programming Language Specification](https://go.dev/ref/spec) — The Go Project, language version go1.26 от 2026-01-12, integer operations, overflow, division, shifts и conversions, проверено 2026-07-18.
- [Go Release History](https://go.dev/doc/devel/release) — The Go Project, Go 1.26.5 от 2026-07-07, проверено 2026-07-18.
- [Package math/bits](https://pkg.go.dev/math/bits@go1.26.5) — стандартная библиотека Go, tag go1.26.5, bit counting, rotations и arithmetic with carry, проверено 2026-07-18.
- [math/bits source](https://github.com/golang/go/blob/go1.26.5/src/math/bits/bits.go) — репозиторий Go, tag go1.26.5, API contracts и fixed-width implementations, проверено 2026-07-18.
- [Mathematics for Computer Science](https://ocw.mit.edu/courses/6-042j-mathematics-for-computer-science-spring-2015/mit6_042js15_textbook.pdf) — MIT OpenCourseWare, Spring 2015, number theory, modular arithmetic и invariants, проверено 2026-07-18.
- [6.042J Recitation 4: Number Theory](https://ocw.mit.edu/courses/6-042j-mathematics-for-computer-science-fall-2010/4f6767747decf6209215cfe789cef5f6_MIT6_042JF10_rec04_sol.pdf) — MIT OpenCourseWare, Fall 2010, Euclidean и extended Euclidean algorithms, проверено 2026-07-18.
