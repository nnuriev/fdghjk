---
aliases:
  - "Теоретический вопрос: Графы и union-find"
tags:
  - область/основы-cs
  - тема/алгоритмы
  - тема/структуры-данных
  - тип/вопрос
статус: проверено
---

# Графы и union-find

## Вопрос

Объясните тему «Графы и union-find»: как устроен механизм, какие инварианты определяют поведение и где проходят практические границы?

## Короткий ориентир

Вопрос заметки: как представить отношения между объектами и когда connectivity можно свести к слиянию непересекающихся множеств?

Graph состоит из vertices и edges; direction, weight, parallel edges и self-loops входят в контракт. Adjacency list занимает `Θ(|V|+|E|)` и подходит для sparse graph, matrix тратит `Θ(|V|²)` и даёт `Θ(1)` edge lookup. Union-find, или disjoint-set union (DSU), хранит partition элементов и быстро отвечает, принадлежат ли два элемента одной компоненте после последовательности `union`.

DSU с union by rank/size и path compression обрабатывает последовательность операций за `O(m α(n))`, где `α` — inverse Ackermann function. Это amortized guarantee. Структура работает для монотонного объединения undirected connectivity; она не восстанавливает path, не решает directed reachability и не поддерживает произвольное удаление edges без более сложного offline/rollback design.

Полный разбор: [[10 Основы CS/Графы и union-find|Графы и union-find]].

## Варианты follow-up

- С какой ближайшей альтернативой сравнивается подход и по какому признаку выбирать?
- Какое неверное предположение приводит к наиболее опасному failure mode?
- В каких условиях подход полезен, а в каких опасен?

## Варианты формулировки и происхождение

- «Поиск маршрута по билетам — граф, map.» — [[Авито/roadmap#5. Остальные алгоритмы|Авито/roadmap, раздел «5. Остальные алгоритмы»]].
- «Topological order — специальный случай directed acyclic graph (DAG); базовые понятия направленности и обхода есть в заметке о графах.» — [[Авито/Решения/Алгоритмы/Печать зависимостей в порядке импорта#Table-driven tests|Авито/Решения/Алгоритмы/Печать зависимостей в порядке импорта, раздел «Table-driven tests»]].
- «Эта задача использует directed graph, но не требует общего обхода: ограничения степеней сводят его к chain. Общая модель и failure modes графов есть в заметке о графах.» — [[Авито/Решения/Алгоритмы/Поиск маршрута#Table-driven tests|Авито/Решения/Алгоритмы/Поиск маршрута, раздел «Table-driven tests»]].

## Источники

- [Introduction to Algorithms](https://mitpress.mit.edu/9780262046305/introduction-to-algorithms/) — The MIT Press, 4-е издание, 2022, главы 19, 20 и 21, проверено 2026-07-18.
- [Lecture Notes: BFS and DFS](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-spring-2020/resources/lecture-notes/) — MIT OpenCourseWare, 6.006 Spring 2020, lectures 9–10, graph representations и traversals, проверено 2026-07-18.
- [Efficiency of a Good But Not Linear Set Union Algorithm](https://doi.org/10.1145/321879.321884) — Robert E. Tarjan, Journal of the ACM, volume 22 issue 2, 1975, проверено 2026-07-18.
- [Efficiency of a Good But Not Linear Set Union Algorithm, technical report](https://www2.eecs.berkeley.edu/Pubs/TechRpts/1974/28764.html) — UC Berkeley EECS, ERL-M434, 1974, проверено 2026-07-18.
