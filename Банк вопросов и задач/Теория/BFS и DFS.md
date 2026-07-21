---
aliases:
  - "Теоретический вопрос: BFS и DFS"
tags:
  - область/основы-cs
  - тема/алгоритмы
  - механизм/обход-графа
  - тип/вопрос
статус: проверено
---

# BFS и DFS

## Вопрос

Объясните тему «BFS и DFS»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

Вопрос заметки: как порядок frontier меняет гарантии обхода графа и когда выбирать BFS, а когда DFS?

Breadth-first search (BFS) использует FIFO queue и исследует вершины слоями по числу рёбер от старта. Поэтому first discovery даёт shortest path в невзвешенном графе или при одинаковом положительном весе каждого ребра. Depth-first search (DFS) использует call stack либо explicit LIFO stack, завершает одну ветвь и только потом возвращается; он даёт структуру вложенности и времена входа/выхода, но не гарантирует кратчайший путь.

На adjacency lists оба обхода работают за `Θ(V+E)` на охваченном графе и требуют `Θ(V)` дополнительного state. Для disconnected graph один запуск покрывает только компоненту достижимости старта; полный forest требует внешнего цикла по всем вершинам.

Полный разбор: [[10 Основы CS/BFS и DFS|BFS и DFS]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Печать конечных нод рубрикатора — деревья, DFS.» — [[Авито/roadmap#5. Остальные алгоритмы|Авито/roadmap, раздел «5. Остальные алгоритмы»]].

## Источники

- [6.006 Lecture 13: Breadth-First Search](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-fall-2011/resources/lecture-13-breadth-first-search-bfs/) — MIT OpenCourseWare, Fall 2011, BFS layer invariant, shortest paths и `Θ(V+E)`, проверено 2026-07-18.
- [6.006 Lecture 14: Depth-First Search and Topological Sort](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-fall-2011/resources/lecture-14-depth-first-search-dfs-topological-sort/) — MIT OpenCourseWare, Fall 2011, DFS forest, edge classification и topological ordering, проверено 2026-07-18.
- [Depth-First Search and Linear Graph Algorithms](https://doi.org/10.1137/0201010) — Robert Tarjan, SIAM Journal on Computing 1(2), 1972, DFS как основа linear-time graph algorithms, проверено 2026-07-18.
