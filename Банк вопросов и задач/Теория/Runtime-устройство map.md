---
aliases:
  - "Теоретический вопрос: Runtime-устройство map"
tags:
  - область/go
  - тема/runtime
  - тема/производительность
  - тип/вопрос
статус: проверено
---

# Runtime-устройство map

## Вопрос

Объясните тему «Runtime-устройство map» на уровне языкового контракта или runtime: как работает механизм, какие ошибки он провоцирует и от каких версий зависит ответ?

## Короткий ориентир

В Go 1.26.5 builtin `map` реализован вариантом Swiss Table: slots собраны в groups по восемь, control word позволяет параллельно отфильтровать кандидатов по 7-bit H2 части hash, а H1 задаёт probing и выбор table. Малые maps до восьми entries могут храниться в одной group; большие используют tables и directory с extendible hashing. Это объясняет locality, grow cost и влияние tombstones, однако языковой контракт такого устройства не гарантирует. Порядок iteration, точный layout, load factor и стратегия growth могут измениться; API-решения должны опираться на [[60 Go/Map|языковую семантику map]], а performance — на [[60 Go/Бенчмарки|benchmark]] конкретной toolchain.

Полный разбор: [[60 Go/Runtime-устройство map|Runtime-устройство map]].

## Варианты follow-up

- Какие версионные границы меняют практический ответ?
- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?

## Варианты формулировки и происхождение

- [[CurseHunter/6860/01 Базовые типы, коллекции и строки#Словари|Словари]] — вопросы о collisions, probing, tombstones, growth, iteration и переходе builtin `map` к Swiss Tables.
- [[CurseHunter/6860/05 Контексты, итераторы и Swiss Tables#Swiss Tables в Go 1.24|Swiss Tables в Go 1.24]] — версионный разбор groups, H1/H2, tombstones, directory и bounded growth начиная с Go 1.24.
- [[CurseHunter/6609/04 Map#Урок 30. Hash table как модель|Урок 30. Hash table как модель]] — точная постановка вопроса о модели hash table.
- [[CurseHunter/6609/04 Map#Урок 31. Устройство built-in `map`|Урок 31. Устройство built-in `map`]] — точная постановка runtime-вопроса о built-in map.

- «Языковой контракт и текущий runtime разнесены в заметке о map и заметке о runtime map. Это особенно важно здесь: видео снято на Go `1.23.4` перед заменой реализации.» — [[CurseHunter/6609/04 Map#Map: теория и 6 задач курса|CurseHunter/6609/04 Map, раздел «Map: теория и 6 задач курса»]].
- «Для Go 1.23 bucket-описание кандидата было уместно. Однако интервьюер отдельно проверял Go 1.24 change: builtin map перешла на Swiss Table. Критичная ошибка кандидата — совет использовать `new`: он создаёт pointer на nil map; для записи нужна `make` или literal. Несколько reads безопасны, пока нет ни одной конкурентной записи. См. семантику map и runtime-устройство map.» — [[Telegram Собесы/X5 — 2025-12-02 — 300к/Бланк вопросов и заданий#Built-in map — `00:06:25–00:08:13`|Telegram Собесы/X5 — 2025-12-02 — 300к, раздел «Built-in map — `00:06:25–00:08:13`»]].
- «Map и Runtime-устройство map — contract и versioned implementation.» — [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Минимальный маршрут по vault|Telegram Собесы/Магнит — 2025-08-19 — 460к, раздел «Минимальный маршрут по vault»]].
- «Map-вопросы следует готовить по Map и Runtime-устройству map, обязательно сохраняя различие Go `1.23` и Go `1.24+`.» — [[Telegram Собесы/Сбер — 2026-05-28 — 250к/Бланк вопросов и заданий#Сопоставление с материалами vault|Telegram Собесы/Сбер — 2026-05-28 — 250к, раздел «Сопоставление с материалами vault»]].
- «Ожидаемая, а не гарантированная, стоимость map lookup; set через `map[T]struct{}`: Map, Runtime-устройство map.» — [[Авито/roadmap#Язык Go|Авито/roadmap, раздел «Язык Go»]].

- [[Telegram Собесы/CoinsPaid — 2026-04-27 — 6633 EUR/Бланк вопросов и заданий#`map`: вопрос, который устарел вместе с runtime — `00:29:55–00:46:18`|`map`: вопрос, который устарел вместе с runtime — `00:29:55–00:46:18`]] — точная проверенная формулировка соответствующего технического блока интервью.
- [[Telegram Собесы/FLANT — 2026-06-30 — 400к/Бланк вопросов и заданий#Go, структуры данных и проектирование — `00:43:25–00:53:23`|Go, структуры данных и проектирование — `00:43:25–00:53:23`]] — точная проверенная формулировка соответствующего технического блока интервью.
- [[Telegram Собесы/FLANT — 2026-06-30 — 400к/Бланк вопросов и заданий#Go и проектирование|Go и проектирование]] — точная проверенная формулировка соответствующего технического блока интервью.

- [[Telegram Собесы/MagnitTech — 2026-04-13 — 400200 руб/Бланк вопросов и заданий#Go: типы, размеры, строки, arrays, slices и map — `00:05:27–00:16:51`|Go: типы, размеры, строки, arrays, slices и map — `00:05:27–00:16:51`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Plata — 2026-04-13 — 4252 EUR/Бланк вопросов и заданий#Slices, `append`, map keys и Swiss Tables — `00:21:58–00:28:48`|Slices, `append`, map keys и Swiss Tables — `00:21:58–00:28:48`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Магнит — 2025-08-19 — 460к/Бланк вопросов и заданий#Map: контракт и реализация — `00:25:12–00:30:20`|Map: контракт и реализация — `00:25:12–00:30:20`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Магнит — 2025-12-26 — 400к/Бланк вопросов и заданий#Maps — `00:59:09–01:07:05`|Maps — `00:59:09–01:07:05`]] — точная проверенная формулировка самостоятельного технического блока интервью.
- [[Telegram Собесы/Сбер — 2026-05-28 — 250к/Бланк вопросов и заданий#Map, nil map, hashing и collisions — `00:22:25–00:32:10`|Map, nil map, hashing и collisions — `00:22:25–00:32:10`]] — точная проверенная формулировка самостоятельного технического блока интервью.

## Источники

- [The Go Programming Language Specification: Map types and range](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, проверено 2026-07-15.
- [Go 1.24 Release Notes: Swiss Table map](https://go.dev/doc/go1.24) — The Go Project, Go 1.24, проверено 2026-07-15.
- [internal/runtime/maps/map.go: design, Map, lookup и growth](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/runtime/maps/map.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [internal/runtime/maps/table.go: table probing и split](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/runtime/maps/table.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [internal/runtime/maps/group.go: control groups](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/runtime/maps/group.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [internal/abi/map.go: MapGroupSlots](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/abi/map.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
- [internal/runtime/maps/runtime.go: indirect element allocation](https://go.googlesource.com/go/+/refs/tags/go1.26.5/src/internal/runtime/maps/runtime.go) — репозиторий Go, tag go1.26.5, commit c19862e5f8415b4f24b189d065ed739517c548ba, проверено 2026-07-15.
