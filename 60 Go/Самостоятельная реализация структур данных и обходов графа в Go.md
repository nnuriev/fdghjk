---
aliases:
  - Heap queue stack graph traversal in Go
  - Базовые структуры данных в Go
tags:
  - область/go
  - тема/алгоритмы
  - тема/структуры-данных
статус: черновик
---

# Самостоятельная реализация структур данных и обходов графа в Go

## TL;DR

На интервью достаточно четырёх инвариантов: stack снимает последний добавленный элемент; queue снимает самый ранний необработанный; min-heap держит parent не больше children; graph traversal помечает вершину так, чтобы не обрабатывать её повторно. В Go все четыре структуры удобно строятся поверх slices.

Ручная реализация нужна для демонстрации механизма, а не для production-переизобретения standard library. В production приоритетная очередь обычно использует `container/heap`, а очередь может потребовать ring buffer и явную политику retention.

## Область применимости

- Версия Go: 1.26; стабильная toolchain для проверки — Go 1.26.5.
- GOOS/GOARCH: семантика одинакова; размеры `int` и allocation behavior зависят от target/toolchain.
- Представление graph: adjacency list `[][]int`, вершины `0..len(g)-1`, все соседние индексы валидны.

## Ментальная модель

Каждая операция меняет маленькую область state:

- stack: хвост slice;
- queue: `data[head]` и затем `head++`;
- heap: один путь между leaf и root;
- BFS/DFS: frontier плюс `seen`.

Отсюда следуют стоимости. Stack push/pop амортизированно `O(1)`. Queue с head index не сдвигает элементы и также даёт амортизированное `O(1)`. Heap затрагивает высоту complete binary tree, то есть `O(log n)`. BFS/DFS на adjacency lists посещают каждую вершину и просматривают каждое ребро ограниченное число раз: `O(V+E)`.

## Как устроено

### Stack и queue

Stack добавляет через `append` и удаляет `s[len(s)-1]`. Перед reslice последний slot обнуляют для pointer-containing types, иначе backing array может удерживать object.

Queue не должна делать `q = q[1:]` бесконечно без политики владения: маленькое окно может удерживать большой backing array. Head index убирает `O(n)` shifting; для pointer-containing element consumed slot обнуляют до `head++`. Длинноживущая production queue периодически compact-ит либо использует ring buffer.

### Min-heap

Для index `i` parent равен `(i-1)/2`, children — `2*i+1` и `2*i+2`. `Push` добавляет leaf и поднимает его, пока parent больше. `Pop` заменяет root последним элементом и опускает его к меньшему child. Все остальные связи уже удовлетворяли heap invariant.

### BFS и DFS

BFS ставит start в FIFO queue и помечает вершину при enqueue. Поэтому одна вершина попадает в queue один раз, а first discovery идёт по неубывающему числу рёбер.

Iterative DFS использует LIFO stack. В примере вершина помечается при pop; одна и та же вершина может временно попасть в stack через несколько рёбер, но каждое ребро создаёт не более одной такой попытки, поэтому время остаётся `O(V+E)`. Цена этой политики — до `O(E)` записей в stack в худшем случае. Mark at push запрещает дубликаты и ограничивает frontier величиной `O(V)`, но момент маркировки и порядок добавления соседей должны соответствовать выбранному traversal contract. В примере соседи push-ятся в обратном порядке, чтобы traversal совпадал с обычным recursive preorder для заданного adjacency order.

## Код

```go
package main

import "fmt"

type Stack struct{ data []int }

func (s *Stack) Push(x int) { s.data = append(s.data, x) }

func (s *Stack) Pop() (int, bool) {
	if len(s.data) == 0 {
		return 0, false
	}
	i := len(s.data) - 1
	x := s.data[i]
	s.data = s.data[:i]
	return x, true
}

type Queue struct {
	data []int
	head int
}

func (q *Queue) Push(x int) { q.data = append(q.data, x) }

func (q *Queue) Pop() (int, bool) {
	if q.head == len(q.data) {
		return 0, false
	}
	x := q.data[q.head]
	q.head++
	if q.head == len(q.data) {
		q.data = q.data[:0]
		q.head = 0
	}
	return x, true
}

type MinHeap struct{ data []int }

func (h *MinHeap) Push(x int) {
	h.data = append(h.data, x)
	for i := len(h.data) - 1; i > 0; {
		p := (i - 1) / 2
		if h.data[p] <= h.data[i] {
			break
		}
		h.data[p], h.data[i] = h.data[i], h.data[p]
		i = p
	}
}

func (h *MinHeap) Pop() (int, bool) {
	if len(h.data) == 0 {
		return 0, false
	}
	root := h.data[0]
	last := len(h.data) - 1
	h.data[0] = h.data[last]
	h.data = h.data[:last]

	for i := 0; i < len(h.data); {
		left := 2*i + 1
		if left >= len(h.data) {
			break
		}
		right := left + 1
		small := left
		if right < len(h.data) && h.data[right] < h.data[left] {
			small = right
		}
		if h.data[i] <= h.data[small] {
			break
		}
		h.data[i], h.data[small] = h.data[small], h.data[i]
		i = small
	}
	return root, true
}

func BFS(g [][]int, start int) []int {
	if start < 0 || start >= len(g) {
		return nil
	}
	seen := make([]bool, len(g))
	var q Queue
	q.Push(start)
	seen[start] = true
	order := make([]int, 0, len(g))

	for {
		u, ok := q.Pop()
		if !ok {
			return order
		}
		order = append(order, u)
		for _, v := range g[u] {
			if !seen[v] {
				seen[v] = true
				q.Push(v)
			}
		}
	}
}

func DFS(g [][]int, start int) []int {
	if start < 0 || start >= len(g) {
		return nil
	}
	seen := make([]bool, len(g))
	stack := Stack{data: []int{start}}
	order := make([]int, 0, len(g))

	for {
		u, ok := stack.Pop()
		if !ok {
			return order
		}
		if seen[u] {
			continue
		}
		seen[u] = true
		order = append(order, u)
		for i := len(g[u]) - 1; i >= 0; i-- {
			v := g[u][i]
			if !seen[v] {
				stack.Push(v)
			}
		}
	}
}

func main() {
	var s Stack
	s.Push(10)
	s.Push(20)
	a, _ := s.Pop()
	b, _ := s.Pop()
	fmt.Println("stack:", a, b)

	var q Queue
	q.Push(10)
	q.Push(20)
	a, _ = q.Pop()
	b, _ = q.Pop()
	fmt.Println("queue:", a, b)

	var h MinHeap
	for _, x := range []int{5, 1, 3} {
		h.Push(x)
	}
	first := true
	for len(h.data) > 0 {
		x, _ := h.Pop()
		if !first {
			fmt.Print(" ")
		}
		fmt.Print(x)
		first = false
	}
	fmt.Println()

	g := [][]int{{1, 2}, {3}, {3}, {}}
	fmt.Println("bfs:", BFS(g, 0))
	fmt.Println("dfs:", DFS(g, 0))
}
```

## Ожидаемый результат

```text
stack: 20 10
queue: 10 20
1 3 5
bfs: [0 1 2 3]
dfs: [0 1 3 2]
```

Локальная Go toolchain недоступна; пример проверен статически, но компиляция и наблюдаемый вывод пока не подтверждены. Поэтому статус заметки остаётся `черновик`.

Порядок DFS зависит от порядка adjacency lists; reachability и отсутствие повторной обработки от него не зависят.

## Trade-offs

Slice-backed stack почти всегда достаточен. Queue с head index проста и быстра, но удерживает capacity; ring buffer ограничивает retention и повторно использует slots ценой modular arithmetic и более сложного resize.

Manual heap полезен на интервью и когда нужен нестандартный tightly controlled layout. `container/heap` уже реализует reheapification и уменьшает риск ошибки, но требует интерфейсных методов и type assertion в `Push/Pop`. Прикладной пример стандартной очереди приоритетов есть в [[50 Проектирование систем/Проектирование и реализация in-process scheduler в Go|in-process scheduler]].

Recursive DFS короче, explicit stack контролирует memory state и не зависит от глубины call stack. Оба варианта требуют одинаковой политики `seen` и обработки disconnected graph через внешний цикл по всем вершинам.

## Типичные ошибки

**Неверное предположение:** queue можно удалять через `append(q[:0], q[1:]...)`. **Симптом:** каждый pop становится `O(n)`. **Причина:** элементы сдвигаются. **Исправление:** head index или ring buffer.

**Неверное предположение:** heap — полностью отсортированный slice. **Симптом:** код ищет второй minimum по соседнему индексу или сортирует после каждого push. **Причина:** invariant гарантирует только отношение parent/children. **Исправление:** использовать root для minimum и sift operations для изменений.

**Неверное предположение:** BFS можно помечать только при dequeue. **Симптом:** вершина многократно попадает в queue, память растёт на dense graph. **Причина:** несколько predecessors успевают enqueue один vertex. **Исправление:** mark at enqueue.

**Неверное предположение:** один запуск traversal обходит disconnected graph. **Симптом:** часть вершин отсутствует в результате. **Причина:** frontier строится только из start component. **Исправление:** внешний цикл запускает обход из каждой unseen vertex, если нужен весь forest.

## Когда применять

- Реализуйте эти структуры вручную на тренировке, пока invariants и boundary cases не воспроизводятся без подсказок.
- В interview-решении выбирайте минимальную структуру, которая поддерживает нужные операции.
- В production предпочитайте standard library или проверенный container, если custom behavior не даёт измеримой пользы.
- Для graph input явно фиксируйте directed/undirected semantics, допустимость соседей и порядок traversal.

## Источники

- [The Go Programming Language Specification](https://go.dev/ref/spec) — The Go Project, спецификация Go 1.26, slices, built-ins и control flow, проверено 2026-07-18.
- [Package heap](https://pkg.go.dev/container/heap@go1.26.5) — стандартная библиотека Go, tag go1.26.5, heap invariant и complexity операций, проверено 2026-07-18.
- [container/heap source](https://cs.opensource.google/go/go/+/refs/tags/go1.26.5:src/container/heap/heap.go) — репозиторий Go, tag go1.26.5, sift-up/down implementation, проверено 2026-07-18.
- [6.006 Lecture 13: Breadth-First Search](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-fall-2011/resources/lecture-13-breadth-first-search-bfs/) — MIT OpenCourseWare, Fall 2011, BFS invariant и `O(V+E)`, проверено 2026-07-18.
- [6.006 Lecture 14: Depth-First Search and Topological Sort](https://ocw.mit.edu/courses/6-006-introduction-to-algorithms-fall-2011/resources/lecture-14-depth-first-search-dfs-topological-sort/) — MIT OpenCourseWare, Fall 2011, DFS forest и traversal complexity, проверено 2026-07-18.
