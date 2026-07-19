---
aliases:
  - Avito — K максимальных элементов
  - Top K через min-heap
tags:
  - область/основы-cs
  - тема/алгоритмы
  - тема/куча
  - компания/авито
статус: проверено
---

# Максимальные элементы в массиве — Top K

## TL;DR

Поддерживаем min-heap не больше чем из `K` элементов. Пока heap не заполнен, добавляем числа; затем заменяем корень только числом больше текущего минимума. Корень — худший из уже выбранных кандидатов, поэтому после полного прохода heap содержит ровно `K` максимальных элементов.

## Нормализованное условие и контракт

Для `nums` и `0 <= K <= len(nums)` нужно вернуть новый слайс из `K` наибольших элементов с сохранением кратности. Исходник разрешает любой порядок; здесь контракт усилен до невозрастающего порядка ради детерминированности. Вход не изменяется. Некорректный `K` возвращает ошибку.

### Неоднозначности исходника

- «Вынимает» может означать mutation исходного массива. Здесь это только выборка: `nums` остаётся прежним.
- Дубликаты в примере входят в ответ дважды, поэтому решается задача по multiset, а не по множеству уникальных значений.
- В исходнике baseline назван `N + log N`; точная сложность полной сортировки — `O(N log N)`.

## Ментальная модель

Heap — турникет на `K` мест. В корне всегда сидит самый слабый из прошедших кандидатов. Новое число, которое не сильнее корня, не входит в глобальный Top K; более сильное вытесняет корень.

## Алгоритм и корректность

Инвариант после обработки первых `i` чисел: heap содержит `min(i,K)` максимальных элементов префикса, а его корень — минимум среди них.

- Пока элементов меньше `K`, добавление очевидно сохраняет инвариант.
- При заполненном heap число `x <= root` не может войти в Top K: уже есть `K` элементов не меньше корня и, следовательно, не меньше `x`.
- Если `x > root`, старый корень перестаёт входить в Top K префикса, а `x` входит; замена и `siftDown` восстанавливают heap.

После последнего элемента инвариант даёт требуемый multiset. Финальная сортировка меняет только порядок представления, но не состав.

## Код Go 1.26.5

`solution.go`:

```go
package topk

import (
	"errors"
	"sort"
)

func LargestK(nums []int, k int) ([]int, error) {
	if k < 0 || k > len(nums) {
		return nil, errors.New("k must be between zero and len(nums)")
	}
	if k == 0 {
		return []int{}, nil
	}

	heap := make([]int, 0, k)
	for _, value := range nums {
		if len(heap) < k {
			heap = append(heap, value)
			siftUp(heap, len(heap)-1)
			continue
		}
		if value > heap[0] {
			heap[0] = value
			siftDown(heap, 0)
		}
	}
	sort.Sort(sort.Reverse(sort.IntSlice(heap)))
	return heap, nil
}

func siftUp(heap []int, child int) {
	for child > 0 {
		parent := (child - 1) / 2
		if heap[parent] <= heap[child] {
			return
		}
		heap[parent], heap[child] = heap[child], heap[parent]
		child = parent
	}
}

func siftDown(heap []int, parent int) {
	for {
		left := 2*parent + 1
		if left >= len(heap) {
			return
		}
		smallest := left
		right := left + 1
		if right < len(heap) && heap[right] < heap[left] {
			smallest = right
		}
		if heap[parent] <= heap[smallest] {
			return
		}
		heap[parent], heap[smallest] = heap[smallest], heap[parent]
		parent = smallest
	}
}
```

## Table-driven tests

`solution_test.go`:

```go
package topk

import (
	"reflect"
	"testing"
)

func TestLargestK(t *testing.T) {
	tests := []struct {
		name    string
		nums    []int
		k       int
		want    []int
		wantErr bool
	}{
		{
			name: "source example keeps duplicates",
			nums: []int{100, 50, 0, 150, 100, 0, -30, 70},
			k:    3, want: []int{150, 100, 100},
		},
		{name: "all values", nums: []int{3, 1, 2}, k: 3, want: []int{3, 2, 1}},
		{name: "zero", nums: []int{3, 1}, k: 0, want: []int{}},
		{name: "negative values", nums: []int{-5, -2, -9}, k: 2, want: []int{-2, -5}},
		{name: "k too large", nums: []int{1}, k: 2, wantErr: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := LargestK(tc.nums, tc.k)
			if (err != nil) != tc.wantErr {
				t.Fatalf("error = %v, wantErr %v", err, tc.wantErr)
			}
			if !tc.wantErr && !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("got %v, want %v", got, tc.want)
			}
		})
	}
}
```

Heap как структура и его инварианты подробнее разобраны в [[10 Основы CS/Деревья, BST, trie, кучи и приоритетные очереди|заметке о кучах]].

## Сложность

Построение и обновления занимают `O(N log K)`, финальная сортировка — `O(K log K)`, что не меняет итоговый класс. Память — `O(K)`. При `K=0` функция завершается за `O(1)`.

## Trade-offs

Quickselect даёт `O(N)` в среднем и `O(N²)` в худшем случае для простого pivot, обычно мутирует копию и не сортирует выбранную часть. Heap даёт предсказуемое `O(N log K)` и особенно выгоден при `K << N` или streaming-входе. Полная сортировка проще, когда `K` близко к `N` и отсортированный результат всё равно нужен.

## Типичные ошибки

- **Использовать max-heap размера `K` → корень — лучший, а вытеснять нужно худший → граница Top K недоступна за `O(1)` → использовать min-heap.**
- **Удалять дубликаты через map → ответ короче `K` → задача о значениях с кратностью → хранить каждое вхождение.**
- **Вернуть внутренний heap как «отсортированный» → гарантирован только parent-child порядок → heap не задаёт полную сортировку → отдельно сортировать, если контракт требует порядок.**

## Источники

- [[90 Вложения/Авито/Авито. Алгоритмы.txt|Авито. Алгоритмы]] — предоставленная подборка условий и пример с дубликатами, состояние на конец 2024 года, проверено 2026-07-18.
- [Package sort](https://pkg.go.dev/sort@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, `Reverse` и `IntSlice`, проверено 2026-07-18.
- [Package testing](https://pkg.go.dev/testing@go1.26.5) — стандартная библиотека Go, tag `go1.26.5`, проверено 2026-07-18.
