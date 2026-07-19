---
aliases:
  - Trees, BST, trie, heap and priority queue
  - Деревья, BST, trie, heap и priority queue
tags:
  - область/основы-cs
  - тема/алгоритмы
  - тема/структуры-данных
статус: проверено
---

# Деревья, BST, trie, кучи и приоритетные очереди

## TL;DR

Вопрос заметки: какое дерево выбирать, если запросу нужен полный порядок, общий prefix либо только следующий extremum?

Tree задаёт иерархию. Binary search tree (BST) добавляет глобальный order invariant и поддерживает ordered lookup; bounds зависят от height, поэтому несбалансированный BST деградирует до `Θ(n)`. Trie раскладывает key по symbols и ищет за `Θ(L)` относительно длины key, платя числом prefix nodes. Binary heap хранит только parent-child order, зато получает extremum за `Θ(1)`, insert и extract за `Θ(log n)`, а build из массива за `Θ(n)`. Priority queue — интерфейс; binary heap — одна из его реализаций.

Структуры нельзя подменять друг другом по внешней форме. Heap нарисован как binary tree, но произвольный key в нём ищется за `Θ(n)`. BST хранит order, но без дополнительного pointer на minimum не даёт постоянный `find-min`. Trie использует длину key, а не `log n`, однако memory и branch representation становятся частью решения.

## Ментальная модель

Каждая структура обещает свой объём порядка:

```text
BST:  всё левое subtree < node < всё правое subtree
trie: path от root кодирует prefix key
heap: parent не больше children (min-heap)
```

Чем сильнее invariant, тем больше запросов он поддерживает и тем дороже его сохранять. Heap знает лишь локальный order. Этого хватает, чтобы root был global minimum, но недостаточно для binary search. Trie вообще не сравнивает целые keys: следующий symbol выбирает edge.

У generic rooted tree свои понятия: parent, children, depth и height. Высота определяет стоимость path-based operation. Complete shape binary heap ограничивает height значением `Θ(log n)`. Plain BST такой shape guarantee не имеет.

## Как устроено

### BST: порядок зависит от высоты

Для каждого node BST все keys в left subtree меньше key node, а в right subtree — больше; policy для duplicates нужно определить отдельно. Search сравнивает key и выбирает одну ветвь, поэтому занимает `Θ(h)`, где `h` — height.

На balanced BST `h = Θ(log n)`. Если вставить отсортированные keys `1,2,3,4,5` в обычный BST, получится цепочка высоты `n-1`, а search/insert станут `Θ(n)`. AVL и red-black tree ограничивают height через rotations и metadata. Sorted array даёт тот же `Θ(log n)` lookup с лучшей locality, но insertion в середину требует `Θ(n)` сдвигов.

In-order traversal BST возвращает keys в sorted order за `Θ(n)`. Это свойство делает BST полезным для predecessor, successor и range query. Обычный hash table такого порядка не хранит.

Дисковые [[30 Данные/B-tree и B+tree|B-tree и B+tree]] решают соседнюю задачу: увеличивают branching factor, чтобы один node совпадал со storage page. Их не следует путать с binary search tree в RAM.

### Trie: key разбирается по symbols

Trie root соответствует empty prefix. Edge помечен symbol, node — prefix. Terminal marker отделяет полный key от префикса другого key: после вставки `car` и `cart` node `car` одновременно terminal и internal.

Search/insert key длины `L` посещает `L` edges, то есть занимает `Θ(L)` при constant-time child lookup. Это не означает constant time относительно размера input: длинный key стоит дорого. Children можно хранить fixed array по alphabet, map либо compact sorted vector. Fixed array ускоряет переход, но расходует `Θ(|Σ|)` slots на node; map экономит sparse branches ценой hashing и metadata.

Trie подходит для prefix enumeration и autocomplete. Production-варианты, FST и search index разобраны в [[50 Проектирование систем/Проектирование поиска и автодополнения|заметке о поиске и автодополнении]].

### Heap и priority queue

Binary heap совмещает два invariants:

1. shape: complete binary tree, все уровни кроме последнего полны, последний заполняется слева;
2. heap order: в min-heap key parent не больше keys children.

Complete shape позволяет хранить heap в array. При zero-based indexing children находятся в `2i+1` и `2i+2`, parent — в `(i-1)/2` с integer floor. Root — minimum. Второй minimum находится среди children root, но остальные siblings/subtrees не упорядочены между собой.

Insert добавляет leaf в конец и выполняет sift-up. Extract-min заменяет root последним элементом и выполняет sift-down. Оба проходят не больше height, то есть `Θ(log n)`. `peek` стоит `Θ(1)`. Произвольный search остаётся `Θ(n)`.

Bottom-up build-heap вызывает sift-down от последних internal nodes к root и занимает `Θ(n)`, хотя отдельный sift-down имеет `O(log n)`. Причина в распределении высот: nodes большой высоты мало, а большинство nodes — leaves либо находятся рядом с ними. Сумма работ по всем heights линейна.

Priority queue задаёт операции `insert`, `peek-min/max`, `extract-min/max`, иногда `decrease-key` и `delete(handle)`. Binary heap хорошо реализует базовый набор. Для `decrease-key` нужен устойчивый handle/index; поиск элемента по value не становится логарифмическим автоматически. Go API `container/heap` и прикладной scheduler уже разобраны в [[50 Проектирование систем/Проектирование и реализация in-process scheduler в Go|заметке об in-process scheduler]].

## Пример или трассировка

Пусть min-heap хранится как array `[2, 5, 4, 9, 7]`.

Проверка invariant:

- `2 ≤ 5` и `2 ≤ 4`;
- `5 ≤ 9` и `5 ≤ 7`;
- node `4` не имеет children.

Вставляем `3`:

1. complete shape требует добавить элемент в конец: `[2, 5, 4, 9, 7, 3]`;
2. parent позиции `5` находится в позиции `2` и равен `4`; меняем `3` и `4`: `[2, 5, 3, 9, 7, 4]`;
3. parent `3` равен `2`, order восстановлен.

Теперь извлекаем minimum:

1. ответ `2`; последний `4` переносится в root: `[4, 5, 3, 9, 7]`;
2. меньший child root равен `3`, меняем их: `[3, 5, 4, 9, 7]`;
3. у `4` нет children, sift-down завершён.

Результат ручной трассировки: извлечено `2`, новый minimum равен `3`, оба invariants сохранены. Обратите внимание: array `[3,5,4,9,7]` не sorted. Heap и не обещал сортировку всего массива.

## Trade-offs

| Структура | Основной запрос | Время | Ограничение |
| --- | --- | --- | --- |
| Balanced BST | ordered lookup/range | `Θ(log n)` update/search | rotations, pointers, хуже locality |
| Sorted array | lookup/range по static data | `Θ(log n)` lookup | `Θ(n)` insertion/delete |
| Trie | lookup/prefix по key длины `L` | `Θ(L)` | память на prefix nodes/children |
| Binary heap | следующий min/max | `Θ(1)` peek, `Θ(log n)` update | arbitrary search `Θ(n)`, нет full order |
| Hash table | exact lookup | expected `Θ(1)` | нет order/prefix, worst-case `Θ(n)` |

BST выбирают, когда updates сочетаются с order/range. Trie — когда prefix входит в контракт и keys имеют управляемую длину/alphabet. Heap — когда потребитель каждый раз просит следующий extremum. Если data static, sorted array часто проще и компактнее любой pointer tree.

## Типичные ошибки

- **«BST всегда работает за `O(log n)`» → sorted insertion создаёт линейную цепочку → balance invariant отсутствует → использовать balanced tree, randomized shape либо сортированный массив для static data.**
- **«Heap поддерживает binary search» → поиск произвольного value сканирует почти весь heap → siblings и разные subtrees не упорядочены → использовать map/BST либо хранить отдельный index.**
- **«Build heap равен `n log n`» → preprocessing переоценён → применено `n` раз максимальное значение height → суммировать фактические heights и получить `Θ(n)`.**
- **«Trie lookup `O(1)`» → длинные keys дают линейную по bytes/code points работу → параметр `L` потерян → писать `Θ(L)` и определить единицу symbol.**
- **«Prefix найден, значит word найден» → `car` ошибочно считается сохранённым после вставки только `cart` → нет terminal marker → разделить node existence и end-of-key.**
- **«Priority queue удалит item по value за `O(log n)`» → сначала выполняется линейный search → API heap требует handle/index для адресного update → хранить index map и поддерживать его при каждом swap.**

## Когда применять

Начните с требуемого query: exact key, ordered neighbor/range, prefix или extremum. Затем назовите invariant и его цену. Для дерева отдельно укажите height guarantee, duplicate policy и ownership links. Для trie — единицу symbol и child representation. Для heap — min/max direction, tie-breaking и необходимость handles.

После каждой mutation проверяйте structural invariant и semantic invariant раздельно. У heap это complete shape и heap order; у BST — links/parent плюс global order; у trie — path labels и terminal markers.

## Источники

- [Introduction to Algorithms](https://mitpress.mit.edu/9780262046305/introduction-to-algorithms/) — The MIT Press, 4-е издание, 2022, главы 6, 10, 12 и 13, проверено 2026-07-18.
- [Lecture 6: Binary Trees, Part 1](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-spring-2020/376714cc85c6c784d90eec9c575ec027_MIT6_006S20_lec6.pdf) — MIT OpenCourseWare, 6.006 Spring 2020, проверено 2026-07-18.
- [Lecture 8: Binary Heaps](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-spring-2020/40d4851e550507ca14dc778b9b2266cc_MIT6_006S20_lec8.pdf) — MIT OpenCourseWare, 6.006 Spring 2020, проверено 2026-07-18.
- [Trie memory](https://doi.org/10.1145/367390.367400) — Edward Fredkin, Communications of the ACM, volume 3 issue 9, 1960, проверено 2026-07-18.
- [Package container/heap](https://pkg.go.dev/container/heap@go1.26.5) — The Go Project, стандартная библиотека Go 1.26.5, проверено 2026-07-18.
