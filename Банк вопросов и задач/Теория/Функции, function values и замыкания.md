---
aliases:
  - "Теоретический вопрос: Функции, function values и замыкания"
tags:
  - область/go
  - тема/семантика-языка
  - тип/вопрос
статус: проверено
---

# Функции, function values и замыкания

## Вопрос

Объясните тему «Функции, function values и замыкания» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

Функция в Go — значение своего function type. Её можно сохранить в переменной, передать аргументом, вернуть из другой функции и связать с данными через замыкание (closure). Method value сохраняет вычисленный receiver, а method expression делает receiver явным первым аргументом.

У function value есть `nil` как zero value, но вызвать `nil` нельзя: будет panic. Сравнивать две функции тоже нельзя — допустимо только сравнение функции с `nil`. Замыкание захватывает переменные, а не моментальный снимок их значений; если несколько goroutines обращаются к общей захваченной переменной, им нужна обычная синхронизация.

Полный разбор: [[60 Go/Функции, function values и замыкания|Функции, function values и замыкания]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- [[CurseHunter/6860/02 Функции, структуры, интерфейсы и ошибки#Функции|Функции]] — вопросы о signatures, variadic parameters, function values, closures, `defer`, recursion и ABI.
- «Фраза «`defer` замораживает всё» опасна: она не объясняет разницу между параметром deferred call и переменной, которую closure читает позже. Точная семантика связана с моментом вычисления deferred call и захватом переменных closure.» — [[Telegram Собесы/Ozon — 2026-07-03 — 300к/Бланк вопросов и заданий#Правильная модель|Telegram Собесы/Ozon — 2026-07-03 — 300к, раздел «Правильная модель»]].
- «Задача с goroutine closure напрямую связана с Функциями и замыканиями, но материал при повторении нужно читать с версионной границей Go `1.22`.» — [[Telegram Собесы/Сбер — 2026-05-28 — 250к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Сбер — 2026-05-28 — 250к, раздел «Сопоставление с материалами vault»]].
- «Горутины в цикле — loop-variable semantics, ожидание завершения и data race на общем максимуме. База: замыкания, lifecycle goroutine, happens-before, race detector, WaitGroup и Mutex.» — [[Авито/roadmap#2. Backend Platform Go|Авито/roadmap, раздел «2. Backend Platform Go»]].
- «Function types, функции как значения и аргументы, method values/expressions, lifetime замыканий и граница loop variables в Go 1.22: Функции, function values и замыкания.» — [[Авито/roadmap#Язык Go|Авито/roadmap, раздел «Язык Go»]].

- [[Telegram Собесы/Adcamp — 2026-03-23 — 280к/Бланк вопросов и заданий#Closures и loop variables — `00:24:00–00:24:59`|Closures и loop variables — `00:24:00–00:24:59`]] — точная проверенная формулировка соответствующего технического блока интервью.

## Источники

- [The Go Programming Language Specification](https://go.dev/ref/spec#Function_types) — The Go Project, спецификация языка Go 1.26, function types и function values, проверено 2026-07-18.
- [Method values](https://go.dev/ref/spec#Method_values) — The Go Project, спецификация языка Go 1.26, сохранение receiver в method value, проверено 2026-07-18.
- [Method expressions](https://go.dev/ref/spec#Method_expressions) — The Go Project, спецификация языка Go 1.26, receiver как первый аргумент, проверено 2026-07-18.
- [Comparison operators](https://go.dev/ref/spec#Comparison_operators) — The Go Project, спецификация языка Go 1.26, сравнимость function values только с `nil`, проверено 2026-07-18.
- [For statements](https://go.dev/ref/spec#For_statements) — The Go Project, спецификация языка Go 1.26, iteration variables и версионная пометка Go 1.22, проверено 2026-07-18.
- [Go 1.22 Release Notes](https://go.dev/doc/go1.22) — The Go Project, Go 1.22, новая семантика loop variables, проверено 2026-07-18.
- [Package testing](https://pkg.go.dev/testing@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, проверено 2026-07-18.
