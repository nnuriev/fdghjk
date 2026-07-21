---
aliases:
  - "Теоретический вопрос: Go assembly, ABI и стек вызовов"
tags:
  - область/go
  - тема/runtime
  - тема/производительность
  - тип/вопрос
статус: проверено
---

# Go assembly, ABI и стек вызовов

## Вопрос

Как читать assembly, созданный Go compiler, и связывать инструкции, ABI, stack frame и вызовы функций с исходным Go-кодом?

## Короткий ориентир

Assembly нужен как проверка конкретной гипотезы об исполнении, а не как самостоятельный источник языковых гарантий. Сначала фиксируют toolchain, `GOOS/GOARCH` и flags компиляции, затем находят symbol, prologue/epilogue, передачу аргументов и вызовы runtime. ABI и frame layout версионно зависимы; вывод о производительности подтверждают benchmark и profile, а не одной похожей последовательностью инструкций.

Полные примеры чтения Go/Plan 9 assembly, регистрационной ABI и stack instructions находятся в [[CurseHunter/6817/Бланк вопросов и заданий#Урок 7. Введение в ассемблер Go|уроке 7]] и [[CurseHunter/6817/Бланк вопросов и заданий#Урок 8. Практика Go assembly и задания курса|уроке 8]]. Модель роста goroutine stack и escape дополняет [[Банк вопросов и задач/Теория/Стеки и escape analysis|разбор stack/escape]].

## Варианты follow-up

- Чем Go assembler syntax отличается от машинного encoding целевой ISA?
- Какие части ABI являются implementation detail конкретной toolchain?
- Как отличить stack slot от heap allocation и register-passed argument?
- Почему disassembly и line view нельзя считать точным таймером строки Go?

## Варианты формулировки и происхождение

- [[CurseHunter/6817/Бланк вопросов и заданий#Урок 7. Введение в ассемблер Go|Урок 7. Введение в ассемблер Go]] — проверенный курсный разбор compiler output, ABI и SIMD-гипотез.
- [[CurseHunter/6817/Бланк вопросов и заданий#Урок 8. Практика Go assembly и задания курса|Урок 8. Практика Go assembly и задания курса]] — проверенный разбор call stack, frame layout и stack instructions.

- [[CurseHunter/6817/Бланк вопросов и заданий#1. Можно ли обойтись без frame pointer и как тогда раскручивать стек?|1. Можно ли обойтись без frame pointer и как тогда раскручивать стек?]] — точная формулировка вопроса курса 6817 из «Урок 7. Введение в ассемблер Go».
- [[CurseHunter/6817/Бланк вопросов и заданий#2. Почему Go assembler нельзя читать как обычный Intel или ARM syntax?|2. Почему Go assembler нельзя читать как обычный Intel или ARM syntax?]] — точная формулировка вопроса курса 6817 из «Урок 7. Введение в ассемблер Go».
- [[CurseHunter/6817/Бланк вопросов и заданий#3. Как читать минимальную Go assembly function и что скрывает `TEXT`?|3. Как читать минимальную Go assembly function и что скрывает `TEXT`?]] — точная формулировка вопроса курса 6817 из «Урок 7. Введение в ассемблер Go».
- [[CurseHunter/6817/Бланк вопросов и заданий#4. Почему один `.s` не переносится между amd64 и arm64?|4. Почему один `.s` не переносится между amd64 и arm64?]] — точная формулировка вопроса курса 6817 из «Урок 7. Введение в ассемблер Go».
- [[CurseHunter/6817/Бланк вопросов и заданий#5. Когда SIMD в ручном assembly оправдан?|5. Когда SIMD в ручном assembly оправдан?]] — точная формулировка вопроса курса 6817 из «Урок 7. Введение в ассемблер Go».

## Источники

- [A Quick Guide to Go's Assembler](https://github.com/golang/go/blob/go1.23.4/doc/asm.html) — Go repository, tag `go1.23.4`, проверено 2026-07-19.
- [Go internal ABI specification](https://github.com/golang/go/blob/go1.23.4/src/cmd/compile/abi-internal.md) — Go repository, tag `go1.23.4`, проверено 2026-07-19.
