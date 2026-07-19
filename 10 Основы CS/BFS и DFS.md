---
aliases:
  - Breadth-first search and depth-first search
  - Обход графа в ширину и глубину
tags:
  - область/основы-cs
  - тема/алгоритмы
  - механизм/обход-графа
статус: проверено
---

# BFS и DFS

## TL;DR

Вопрос заметки: как порядок frontier меняет гарантии обхода графа и когда выбирать BFS, а когда DFS?

Breadth-first search (BFS) использует FIFO queue и исследует вершины слоями по числу рёбер от старта. Поэтому first discovery даёт shortest path в невзвешенном графе или при одинаковом положительном весе каждого ребра. Depth-first search (DFS) использует call stack либо explicit LIFO stack, завершает одну ветвь и только потом возвращается; он даёт структуру вложенности и времена входа/выхода, но не гарантирует кратчайший путь.

На adjacency lists оба обхода работают за `Θ(V+E)` на охваченном графе и требуют `Θ(V)` дополнительного state. Для disconnected graph один запуск покрывает только компоненту достижимости старта; полный forest требует внешнего цикла по всем вершинам.

## Ментальная модель

Оба алгоритма поддерживают границу между уже открытой и ещё неизвестной частью графа. Различается только дисциплина frontier:

```text
BFS: достать самый ранний frontier item → FIFO → слои
DFS: достать самый поздний frontier item → LIFO → одна ветвь
```

`seen` превращает произвольный граф с циклами в конечный поиск: каждая вершина проходит из состояния «не открыта» в «открыта» один раз. В BFS её обычно помечают при enqueue, чтобы несколько predecessors не положили один vertex в queue. В recursive DFS вершину помечают при входе; в iterative DFS допустима отметка при push или при pop, но от выбора зависят duplicates во stack и порядок traversal.

Adjacency order влияет на конкретный порядок посещения и выбранный из нескольких равных путей. Reachability, BFS-distance и асимптотическая граница от него не зависят.

## Как устроено

### BFS и инвариант слоёв

Пусть `dist[s]=0`. Когда BFS обрабатывает вершину с расстоянием `d`, все ещё не открытые соседи получают `d+1` и parent равный текущей вершине. FIFO гарантирует: до вершины слоя `d+1` из queue будут вынуты все ранее поставленные вершины слоя `d`.

Инвариант: vertices покидают queue в неубывающем `dist`, а при первом открытии `v` уже найден путь с минимальным числом рёбер. Если бы существовал более короткий путь, его предпоследняя вершина находилась бы на меньшем слое и открыла бы `v` раньше.

Гарантия относится к числу рёбер. Если веса различаются, путь из одного дорогого ребра может стоить больше пути из трёх дешёвых; тогда нужен алгоритм из [[10 Основы CS/Кратчайшие пути|заметки о кратчайших путях]].

### DFS и интервалы жизни

Recursive DFS входит в вершину, рекурсивно обходит unseen neighbors и фиксирует выход после завершения всех потомков. Получается DFS forest. В directed graph состояние `gray` для активного call stack отличает back edge в предка от ребра в уже полностью завершённую `black`-вершину. Back edge указывает на directed cycle.

Время входа и выхода образует вложенные интервалы для ancestor/descendant. На этом строятся topological sort, strongly connected components и многие bridge/articulation algorithms. Простого множества `seen` достаточно для reachability, но недостаточно, когда нужно классифицировать ребро по состоянию активной рекурсии.

### Стоимость представления

На adjacency list каждая вершина открывается один раз, а список каждого обработанного vertex сканируется один раз. Directed edge рассматривается один раз, undirected edge хранится обычно в двух списках и рассматривается дважды; обе записи дают `Θ(V+E)`.

Adjacency matrix заставляет просмотреть строку длины `V` для каждой вершины, поэтому traversal занимает `Θ(V²)`, даже если edges мало. BFS queue может удерживать `Θ(V)` vertices на широком слое. DFS stack достигает `Θ(V)` на длинном path. Эти структуры на Go разобраны в [[60 Go/Самостоятельная реализация структур данных и обходов графа в Go|практической заметке о структурах и обходах]].

### Parent forest

Сохранение `parent[v]=u` при первом открытии восстанавливает witness: путь от `v` к root. В BFS это shortest path по числу рёбер. В DFS это путь в DFS tree, не обязательно кратчайший. Если требуется только boolean reachability, parents можно не хранить; `seen` всё равно нужен для циклического графа.

## Пример или трассировка

Directed adjacency lists заданы в таком порядке:

```text
A: B, C
B: D
C: E
D: E
E: ∅
```

BFS помечает vertex при enqueue:

| Шаг | Извлечён | Queue после добавлений | Новые `dist` |
| ---: | --- | --- | --- |
| 0 | — | `[A]` | `A=0` |
| 1 | A | `[B,C]` | `B=1`, `C=1` |
| 2 | B | `[C,D]` | `D=2` |
| 3 | C | `[D,E]` | `E=2` |
| 4 | D | `[E]` | E уже открыта |
| 5 | E | `[]` | — |

Порядок BFS: `A,B,C,D,E`; shortest distance до `E` равна `2`, путь восстанавливается как `A→C→E`.

DFS при том же adjacency order идёт `A→B→D→E`, затем возвращается к `C`. Порядок входа: `A,B,D,E,C`. Первый найденный DFS path до `E` содержит три ребра, хотя путь из двух рёбер существует. Трассировка сразу показывает границу гарантии: DFS отвечает на reachability, но first discovery не минимизирует число рёбер.

## Trade-offs

BFS выбирают для unweighted shortest paths, уровней, минимального числа шагов и поиска ближайшей цели. Цена — queue шириной до целого слоя; на branching tree она может быть заметно больше глубины.

DFS удобен для structural properties: cycles, topological order, компоненты, backtracking по графу. Он часто хранит лишь текущий путь, но на глубоком графе этот путь имеет длину `Θ(V)`. Recursive form короче, explicit stack делает memory state явным и избегает зависимости от call-stack depth.

Bidirectional BFS может сократить число посещённых vertices при известной цели и дешёвом обратном переходе, но требует корректного условия встречи frontier и двух таблиц расстояний. Он не меняет требования одинакового веса рёбер.

## Типичные ошибки

- **«BFS даёт shortest path в любом графе» → возвращается путь с меньшим числом дорогих рёбер, но большей стоимостью → FIFO упорядочивает edge count, а не сумму weights → использовать Dijkstra, DAG relaxation или Bellman–Ford по условиям весов.**
- **«Пометим вершину при dequeue» → одна вершина многократно попадает в queue → разные predecessors видят её unseen до первого dequeue → mark at enqueue.**
- **«DFS first path и есть кратчайший» → результат зависит от adjacency order и бывает длиннее → LIFO завершает ветвь без сравнения альтернативных расстояний → применять BFS на unit weights.**
- **«Один запуск обходит весь граф» → vertices другой компоненты отсутствуют → frontier достижим только по рёбрам из start → добавить внешний цикл по unseen vertices.**
- **«`seen` достаточно для directed cycle detection» → edge в завершённую вершину ошибочно объявляется циклом или back edge теряется → смешаны active и finished vertices → использовать white/gray/black либо аналогичный active-stack marker.**
- **«Traversal всегда `O(V+E)`» → на adjacency matrix фактическая работа `Θ(V²)` → bound зависит от представления и способа перечислить neighbors → назвать representation вместе со сложностью.**

## Когда применять

- BFS: unit/unweighted shortest paths, level order, минимальное число переходов, multi-source distances.
- DFS: reachability, cycle structure, finishing order, recursive search и decomposition algorithms.
- Для всего disconnected graph запускайте forest traversal; для одной component оставляйте один start.
- До кода зафиксируйте directed/undirected semantics, adjacency order, момент маркировки и требуемый witness.

## Источники

- [6.006 Lecture 13: Breadth-First Search](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-fall-2011/resources/lecture-13-breadth-first-search-bfs/) — MIT OpenCourseWare, Fall 2011, BFS layer invariant, shortest paths и `Θ(V+E)`, проверено 2026-07-18.
- [6.006 Lecture 14: Depth-First Search and Topological Sort](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-fall-2011/resources/lecture-14-depth-first-search-dfs-topological-sort/) — MIT OpenCourseWare, Fall 2011, DFS forest, edge classification и topological ordering, проверено 2026-07-18.
- [Depth-First Search and Linear Graph Algorithms](https://doi.org/10.1137/0201010) — Robert Tarjan, SIAM Journal on Computing 1(2), 1972, DFS как основа linear-time graph algorithms, проверено 2026-07-18.
