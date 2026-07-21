---
aliases:
  - "Теоретический вопрос: Two pointers и sliding window"
tags:
  - область/основы-cs
  - тема/алгоритмы
  - механизм/два-указателя
  - тип/вопрос
статус: проверено
---

# Two pointers и sliding window

## Вопрос

Объясните тему «Two pointers и sliding window»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

Вопрос заметки: когда два monotonic indexes заменяют перебор пар или подмассивов и почему внешне вложенный цикл остаётся линейным?

Two pointers работает, если движение одного pointer позволяет навсегда исключить группу кандидатов: благодаря sorted order, разным скоростям либо read/write invariant. Sliding window — частный вариант для contiguous segment: right добавляет элемент, left удаляет, а summary окна обновляется инкрементально. Время `O(n)` следует из общего числа движений: каждый pointer проходит вход не больше одного раза.

Variable-size window корректна, когда feasibility меняется монотонно при расширении и восстанавливается движением left. Для суммы это обычно требует non-negative values. Negative numbers ломают рассуждение «сумма слишком велика — сдвинь left»: удаление отрицательного элемента увеличит сумму. Тогда нужны prefix sums, hash map, deque либо другой algorithm.

Полный разбор: [[10 Основы CS/Two pointers и sliding window|Two pointers и sliding window]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Суммарная неудовлетворённость покупателей — сортировка, prefix reasoning и два указателя. База: сортировка, два указателя, доказательство инварианта.» — [[Авито/roadmap#1. Рекомендованные алгоритмы|Авито/roadmap, раздел «1. Рекомендованные алгоритмы»]].
- «Слияние двух отсортированных массивов — два указателя.» — [[Авито/roadmap#5. Остальные алгоритмы|Авито/roadmap, раздел «5. Остальные алгоритмы»]].
- «Поиск пар с заданной суммой — hash map, two pointers.» — [[Авито/roadmap#5. Остальные алгоритмы|Авито/roadmap, раздел «5. Остальные алгоритмы»]].
- «Пора в отпуск — sliding window.» — [[Авито/roadmap#5. Остальные алгоритмы|Авито/roadmap, раздел «5. Остальные алгоритмы»]].
- «Удаление нулей inplace — два указателя.» — [[Авито/roadmap#5. Остальные алгоритмы|Авито/roadmap, раздел «5. Остальные алгоритмы»]].

## Источники

- [Introduction to Algorithms](https://mitpress.mit.edu/9780262046305/introduction-to-algorithms/) — The MIT Press, 4-е издание, 2022, анализ циклов, sorting, hashing и amortized analysis, проверено 2026-07-18.
- [Recitation 2](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-spring-2020/c08a3b63dfe5f6f6b32257d35f86ae63_MIT6_006S20_r02.pdf) — MIT OpenCourseWare, 6.006 Spring 2020, fast/slow pointers для linked-list cycle, проверено 2026-07-18.
- [Binary Search and Two Pointers](https://www.cs.dartmouth.edu/~deepc/LecNotes/cs31/lec3-tptr.pdf) — Dartmouth College, CS 31 Lecture 3, PDF без указанной даты, binary search и two-pointers invariants, проверено 2026-07-18.
- [Introduction to Competitive Programming](https://www.cs.purdue.edu/homes/ninghui/courses/390_Fall19/lectures.html) — Purdue University, CS 390 Fall 2019, two pointers и sliding window, проверено 2026-07-18.
