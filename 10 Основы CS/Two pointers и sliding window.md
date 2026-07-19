---
aliases:
  - Two pointers and sliding window
  - Два указателя и скользящее окно
tags:
  - область/основы-cs
  - тема/алгоритмы
  - механизм/два-указателя
статус: проверено
---

# Two pointers и sliding window

## TL;DR

Вопрос заметки: когда два monotonic indexes заменяют перебор пар или подмассивов и почему внешне вложенный цикл остаётся линейным?

Two pointers работает, если движение одного pointer позволяет навсегда исключить группу кандидатов: благодаря sorted order, разным скоростям либо read/write invariant. Sliding window — частный вариант для contiguous segment: right добавляет элемент, left удаляет, а summary окна обновляется инкрементально. Время `O(n)` следует из общего числа движений: каждый pointer проходит вход не больше одного раза.

Variable-size window корректна, когда feasibility меняется монотонно при расширении и восстанавливается движением left. Для суммы это обычно требует non-negative values. Negative numbers ломают рассуждение «сумма слишком велика — сдвинь left»: удаление отрицательного элемента увеличит сумму. Тогда нужны prefix sums, hash map, deque либо другой algorithm.

## Ментальная модель

Brute force возвращается к уже отвергнутым границам. Two pointers закрывает дверь за каждым движением.

```text
left  ->             <- right   opposite ends
left  -> right ->                same direction/window
slow  -> fast  ->->              different speeds
```

Для каждого движения нужен elimination proof. В sorted two-sum, если `a[left]+a[right]` слишком велико, никакой pair с тем же `right` и большим left не поможет, поэтому `right` можно уменьшить навсегда. В window algorithm удалённая левая граница больше не станет оптимальной, если predicate monotone.

Фраза «два pointers дают `O(n)`» без такого доказательства неверна. Pointers могут двигаться назад, переобрабатывать элементы или запускать полный scan на каждом шаге.

## Как устроено

### Pointers с разных концов

На sorted array часто поддерживают interval кандидатов `[left,right]`. Comparison с target определяет, какую границу сдвинуть. Примеры: pair sum, palindrome check, partition around predicate, выбор максимальной площади при монотонном ограничении.

Если вход не sorted, можно сначала отсортировать за `O(n log n)` и затем пройти за `O(n)`. Цена: порядок изменится, original indexes придётся хранить отдельно. Hash set решает exact two-sum за expected `O(n)` и `O(n)` space без sorting. Two pointers после sorting использует `O(1)` дополнительной памяти, если reorder допустим.

### Pointers в одном направлении

Read/write pattern отделяет обработанную часть от ещё не просмотренной. Например, при stable compaction `read` сканирует все элементы, `write` указывает на следующую позицию результата. Invariant: prefix `[0,write)` уже содержит ровно подходящие элементы из `[0,read)` в исходном порядке.

Fast/slow pointers в linked list используют относительную скорость. В cycle detection fast проходит по два edges, slow по одному; после входа обоих в cycle разность позиций меняется на один modulo cycle length, поэтому встреча неизбежна. Это другой механизм, чем window, хотя переменных тоже две.

### Fixed-size sliding window

Для каждого segment длины `k` не нужно пересчитывать summary. При сдвиге вправо один элемент выходит и один входит:

```text
state' = remove(state, a[left])
state'' = add(state', a[right+1])
```

Sum обновляется за `Θ(1)`. Frequency map — expected `Θ(1)` на update. Median требует ordered multiset/heaps и уже стоит `O(log k)`. Sliding window экономит повторную работу, но не обещает constant update для любого summary.

### Variable-size sliding window

Right расширяет окно. Пока invariant нарушен, left сдвигается вправо и удаляет элементы. Затем current window используют для min/max length либо count.

Для задачи «максимальная длина с суммой `≤ K`» на non-negative values сумма не уменьшается при расширении right и не увеличивается при удалении left. Поэтому если `[left,right]` invalid, никакой более широкий interval с тем же right не valid; left можно двигать. После восстановления текущий left — самая ранняя допустимая граница среди ещё не исключённых.

Для «не больше K distinct» state хранит counts и число keys с positive count. Для «без повторов» left сдвигается после предыдущей позиции duplicate. В обоих случаях нужно сформулировать, почему discarded starts не понадобятся снова.

### Почему вложенный while не даёт quadratic time

Outer loop двигает `right` не больше `n` раз. Inner loop за всё выполнение двигает `left` тоже не больше `n` раз, потому что left не уменьшается. Суммарно выполняется `O(n)` pointer moves. Это aggregate analysis, тот же принцип, что у amortized bounds.

Если inner loop сбрасывает left назад для каждого right, аргумент исчезает и worst-case может стать `Θ(n²)`.

## Пример или трассировка

### Two-sum на sorted array

Дан array `[1,2,4,7,11]`, target `9`.

| `left` | `right` | Сумма | Вывод |
| ---: | ---: | ---: | --- |
| 0 (`1`) | 4 (`11`) | 12 | слишком много; убрать `right=4` |
| 0 (`1`) | 3 (`7`) | 8 | слишком мало; убрать `left=0` |
| 1 (`2`) | 3 (`7`) | 9 | pair найден |

Первый шаг безопасен: `1+11 > 9`, а с любым большим left сумма с `11` будет ещё больше. Второй безопасен: `1+7 < 9`, а с любым меньшим right сумма с `1` будет не больше. Найден pair `(2,7)` за три comparisons.

### Variable window

Найдём максимальную длину subarray с суммой `≤7` для non-negative array `[2,1,5,1,3]`.

| `right` | Добавили | Сумма до shrink | Shrink | Допустимое окно | Best |
| ---: | ---: | ---: | --- | --- | ---: |
| 0 | 2 | 2 | — | `[2]` | 1 |
| 1 | 1 | 3 | — | `[2,1]` | 2 |
| 2 | 5 | 8 | убрать `2` | `[1,5]`, сумма 6 | 2 |
| 3 | 1 | 7 | — | `[1,5,1]` | 3 |
| 4 | 3 | 10 | убрать `1`, затем `5` | `[1,3]`, сумма 4 | 3 |

Right сделал пять движений, left — три. Результат `3`, окно `[1,5,1]`. Если заменить первый `2` на `-10`, правило shrink по большой сумме уже не сможет исключать раннюю границу: negative value способен сделать более широкое окно допустимым.

## Trade-offs

| Подход | Time | Space | Предусловие |
| --- | --- | --- | --- |
| Brute-force pairs/windows | `Θ(n²)` и выше | часто `O(1)` | нет monotonicity |
| Sort + opposite pointers | `O(n log n)` | зависит от sort | reorder и comparable order допустимы |
| Hash set/map | expected `O(n)` | `O(n)` | exact membership, порядок не нужен |
| Sliding window | `O(n·update)` | state окна | contiguous segment и monotone boundary |
| Prefix sums | preprocessing `O(n)` | `O(n)` | быстрые static range sums; variable search требует доп. структуры |

Window выигрывает, когда соседние candidates сильно перекрываются и state можно обновить при add/remove. Prefix sums проще для fixed range sum и допускают negative values, но сами по себе не находят variable boundary линейно. Hash map лучше, если решение зависит от ранее встреченного prefix value, а не от монотонного left.

## Типичные ошибки

- **«Любой nested while означает `O(n²)`» → линейное решение отвергают → считается форма кода, а не суммарные движения → доказать, что каждый pointer только возрастает и делает не больше `n` шагов.**
- **«Sliding window работает с любой суммой» → valid interval пропускается на negative input → сумма не монотонна при движении границ → перейти к prefix sums/hash/deque либо ограничить input non-negative.**
- **«После sorting вернём текущие indexes» → ответ указывает на позиции sorted copy → identity потеряна → сортировать `(value, originalIndex)` или использовать hash approach.**
- **«При shrink достаточно уменьшить left» → frequency/distinct state расходится с окном → удаляемый элемент не вычтен → обновлять state до/вместе с boundary и удалять zero counts.**
- **«Первое valid окно оптимально» → minimum/maximum objective обновляется не в той фазе → invariant не связывает current window с optimum → явно определить, обновлять answer до shrink, после shrink или на каждом удалении.**
- **«Fast pointer проверит `next.next` позже» → nil dereference на acyclic list → guard не соответствует двум шагам → перед каждым fast advance доказать существование требуемых links.**

## Когда применять

Ищите two pointers, когда input sorted, нужен contiguous segment, два streams сливаются либо pointer movement навсегда исключает кандидатов. Перед кодом произнесите invariant одной фразой и докажите направление каждого движения.

Для sliding window выпишите четыре операции: что добавляет right, что удаляет left, когда окно valid и в какой момент обновляется answer. Затем отдельно проверьте empty input, `k=0`, duplicate keys, negative values и window, который никогда не становится valid.

## Источники

- [Introduction to Algorithms](https://mitpress.mit.edu/9780262046305/introduction-to-algorithms/) — The MIT Press, 4-е издание, 2022, анализ циклов, sorting, hashing и amortized analysis, проверено 2026-07-18.
- [Recitation 2](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-spring-2020/c08a3b63dfe5f6f6b32257d35f86ae63_MIT6_006S20_r02.pdf) — MIT OpenCourseWare, 6.006 Spring 2020, fast/slow pointers для linked-list cycle, проверено 2026-07-18.
- [Binary Search and Two Pointers](https://www.cs.dartmouth.edu/~deepc/LecNotes/cs31/lec3-tptr.pdf) — Dartmouth College, CS 31 Lecture 3, PDF без указанной даты, binary search и two-pointers invariants, проверено 2026-07-18.
- [Introduction to Competitive Programming](https://www.cs.purdue.edu/homes/ninghui/courses/390_Fall19/lectures.html) — Purdue University, CS 390 Fall 2019, two pointers и sliding window, проверено 2026-07-18.
