// Проверено в официальном Go Playground на Go 1.26.5, 2026-07-19.
package main

import (
	"context"
	"fmt"
	"sync"
)

// mergeSorted сохраняет повторы и использует O(len(a)+len(b)) времени.
func mergeSorted(a, b []int) []int {
	result := make([]int, 0, len(a)+len(b))
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		if a[i] <= b[j] {
			result = append(result, a[i])
			i++
		} else {
			result = append(result, b[j])
			j++
		}
	}
	result = append(result, a[i:]...)
	result = append(result, b[j:]...)
	return result
}

// fanIn заканчивает работу при закрытии всех inputs или отмене ctx.
// Если downstream перестал читать, отмена нужна, чтобы forwarding goroutines
// не остались навсегда заблокированными на out <- value.
func fanIn[T any](ctx context.Context, inputs ...<-chan T) <-chan T {
	out := make(chan T)
	var wg sync.WaitGroup
	wg.Add(len(inputs))

	for _, input := range inputs {
		go func(ch <-chan T) {
			defer wg.Done()
			for {
				select {
				case <-ctx.Done():
					return
				case value, ok := <-ch:
					if !ok {
						return
					}
					select {
					case out <- value:
					case <-ctx.Done():
						return
					}
				}
			}
		}(input)
	}

	go func() {
		wg.Wait()
		close(out)
	}()
	return out
}

func closed(values ...int) <-chan int {
	ch := make(chan int, len(values))
	for _, value := range values {
		ch <- value
	}
	close(ch)
	return ch
}

func main() {
	fmt.Println(mergeSorted([]int{1, 2, 3, 4, 5}, []int{4, 5, 6, 7, 8}))

	seen := make(map[int]bool)
	for value := range fanIn(context.Background(), closed(1, 2), closed(3, 4)) {
		seen[value] = true
	}
	fmt.Println(len(seen), seen[1] && seen[2] && seen[3] && seen[4])
}
