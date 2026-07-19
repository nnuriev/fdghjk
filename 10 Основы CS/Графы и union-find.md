---
aliases:
  - Graphs and union-find
  - Графы и disjoint-set union
tags:
  - область/основы-cs
  - тема/алгоритмы
  - тема/структуры-данных
статус: проверено
---

# Графы и union-find

## TL;DR

Вопрос заметки: как представить отношения между объектами и когда connectivity можно свести к слиянию непересекающихся множеств?

Graph состоит из vertices и edges; direction, weight, parallel edges и self-loops входят в контракт. Adjacency list занимает `Θ(|V|+|E|)` и подходит для sparse graph, matrix тратит `Θ(|V|²)` и даёт `Θ(1)` edge lookup. Union-find, или disjoint-set union (DSU), хранит partition элементов и быстро отвечает, принадлежат ли два элемента одной компоненте после последовательности `union`.

DSU с union by rank/size и path compression обрабатывает последовательность операций за `O(m α(n))`, где `α` — inverse Ackermann function. Это amortized guarantee. Структура работает для монотонного объединения undirected connectivity; она не восстанавливает path, не решает directed reachability и не поддерживает произвольное удаление edges без более сложного offline/rollback design.

## Ментальная модель

Graph описывает отношения, DSU забывает почти все детали и оставляет только equivalence classes.

```text
graph: кто с кем соединён и каким edge?
DSU:   находятся ли x и y в одной уже объединённой группе?
```

Это осознанная потеря информации. После `union(A,B)` и `union(B,C)` DSU знает, что `A ~ C`, но не обязан помнить edges `(A,B)` и `(B,C)`. Поэтому он очень быстр для connectivity и бесполезен, если нужен actual route.

Для undirected connectivity отношение рефлексивно, симметрично и транзитивно, то есть образует partition. Directed reachability несимметрична: из `A → B` не следует `B → A`, поэтому обычный DSU к ней неприменим.

## Как устроено

### Сначала определить вид graph

Одна и та же пара labels может означать разные структуры:

- directed edge `(u,v)` разрешает движение только `u → v`;
- undirected edge `{u,v}` соединяет обе стороны;
- weighted edge хранит cost/capacity;
- multigraph допускает несколько edges между парой vertices;
- self-loop соединяет vertex с собой.

Алгоритм должен знать, допускаются ли duplicate edges и vertices без edges. Если vertices приходят как произвольные IDs, сначала нужен устойчивый mapping `ID → dense index` либо map-based representation. В Go эти варианты строятся на [[60 Go/Массивы и слайсы|слайсах]] и [[60 Go/Map|map]], но их language semantics не меняют graph invariant.

### Representation определяет цену операции

Adjacency list хранит список neighbors для каждого vertex. Space равен `Θ(|V|+|E|)` для directed graph; undirected edge обычно записывается дважды, что меняет константу, но не класс. Iteration по neighbors `v` стоит `Θ(deg(v))`, полный traversal — `Θ(|V|+|E|)`.

Adjacency matrix хранит cell для каждой ordered pair. Space `Θ(|V|²)`, edge existence проверяется за `Θ(1)`, перечисление neighbors одного vertex — `Θ(|V|)`. Она разумна для dense graph или matrix algorithms. Edge list компактно хранит `Θ(|E|)` records и удобно для algorithms, которые сортируют/сканируют edges, но lookup конкретного edge без index дорог.

### DSU хранит forest представителей

`make-set(x)` создаёт singleton. `find(x)` поднимается по parent links до root-representative. `union(x,y)` находит roots и, если они различны, связывает один root с другим.

Без эвристик последовательность union может создать цепочку высоты `Θ(n)`. Union by size/rank прикрепляет меньший или менее высокий tree под больший. Path compression во время `find` переподвешивает посещённые nodes ближе к root. Вместе эти эвристики дают почти constant amortized time: для `m` операций на `n` элементах standard bound равен `O(m α(n))`.

Rank после path compression не обязан совпадать с текущей height. Это upper-bound metadata для выбора root; пересчитывать его после каждого compression не нужно. Representative тоже не несёт domain meaning, если policy явно не закрепляет canonical root.

### Где DSU уместен

Типичные случаи: incremental connectivity, cycle detection в undirected graph, component counting, Kruskal minimum spanning tree, группировка equivalence constraints. Для удаления edges DSU не умеет «разъединить» class. Offline algorithms обходят это через reverse processing либо rollback DSU, но это другой contract.

## Пример или трассировка

Есть vertices `A,B,C,D` и undirected edges поступают в порядке `(A,B)`, `(C,D)`, `(B,C)`. Используем union by rank; при равном rank второй root подвешиваем под первый.

Начало:

```text
parent: A->A B->B C->C D->D
rank:      0    0    0    0
```

1. `union(A,B)`: roots `A` и `B` равны по rank. Получаем `B→A`, `rank(A)=1`.
2. `union(C,D)`: получаем `D→C`, `rank(C)=1`. Пока `find(A) != find(D)`, components две.
3. `union(B,C)`: `find(B)` проходит `B→A`; `find(C)=C`. Ranks roots равны, поэтому `C→A`, `rank(A)=2`.
4. `find(D)` проходит `D→C→A` и compress path: после операции `D→A`.

Финальное состояние может выглядеть так:

```text
parent: A->A B->A C->A D->A
```

Все четыре vertices связаны, `find(B)=find(D)=A`. DSU не может ответить, что path в исходном graph был `D-C-B-A`: parent links — служебный forest, а не подмножество graph edges после compression.

Ручная проверка cycle detection: если следующим приходит `(A,D)`, roots уже равны. Добавление edge соединяет vertices внутри одной component, значит в undirected graph возникает cycle.

## Trade-offs

| Инструмент | Хранит | Сильный запрос | Не умеет |
| --- | --- | --- | --- |
| Adjacency list + traversal | edges и neighbors | reachability, path, components | constant edge lookup без доп. index |
| Adjacency matrix | все пары | edge lookup, dense algorithms | экономить space на sparse graph |
| DSU | partition и representatives | incremental undirected connectivity | path, direction, arbitrary delete |

Traversal хранит больше информации и отвечает на более богатые вопросы за `Θ(|V|+|E|)`. DSU выигрывает, если workflow состоит из множества union/connectivity queries и edges только добавляются. Matrix меняет memory на быстрый edge lookup; при `|E| ≪ |V|²` этот обмен часто невыгоден.

## Типичные ошибки

- **«Undirected edge достаточно добавить один раз» → traversal из второй вершины не видит связь → adjacency list реализовал directed graph → записать обе дуги либо централизовать helper `addUndirected`.**
- **«DSU найдёт path» → parent chain выдаётся как маршрут, которого нет в graph → path compression строит служебные links → хранить graph и parent/predecessor traversal отдельно.**
- **«DSU работает для directed reachability» → `A→B` ошибочно делает связь симметричной → reachability не equivalence relation → использовать directed traversal/SCC/topological machinery.**
- **«Union можно делать по исходным nodes» → trees соединяются внутренними вершинами и rank invariant теряется → не вызваны `find` → объединять только roots.**
- **«Rank равен текущей высоте» → после compression код пытается уменьшать rank и ломает heuristic → rank служит upper-bound metadata → обновлять его только по правилу union by rank.**
- **«В graph нет isolated vertices, раз нет edges» → component count и traversal пропускают объекты → edge list не перечисляет полный `V` → принимать vertex set отдельно.**

## Когда применять

Сначала запишите graph contract: directed/undirected, weighted, duplicates, self-loops, dense/sparse и нужны ли paths. Затем выберите representation. DSU добавляйте только если запрос сводится к partition и updates монотонно объединяют classes.

Для интервью полезно отдельно проговорить две сложности: storage graph и работу algorithm. `Θ(|V|+|E|)` относится к adjacency-list traversal, а `O(m α(n))` — к последовательности DSU operations. Смешивать параметры нельзя.

## Источники

- [Introduction to Algorithms](https://mitpress.mit.edu/9780262046305/introduction-to-algorithms/) — The MIT Press, 4-е издание, 2022, главы 19, 20 и 21, проверено 2026-07-18.
- [Lecture Notes: BFS and DFS](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-spring-2020/resources/lecture-notes/) — MIT OpenCourseWare, 6.006 Spring 2020, lectures 9–10, graph representations и traversals, проверено 2026-07-18.
- [Efficiency of a Good But Not Linear Set Union Algorithm](https://doi.org/10.1145/321879.321884) — Robert E. Tarjan, Journal of the ACM, volume 22 issue 2, 1975, проверено 2026-07-18.
- [Efficiency of a Good But Not Linear Set Union Algorithm, technical report](https://www2.eecs.berkeley.edu/Pubs/TechRpts/1974/28764.html) — UC Berkeley EECS, ERL-M434, 1974, проверено 2026-07-18.
