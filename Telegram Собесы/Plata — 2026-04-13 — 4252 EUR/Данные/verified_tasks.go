package main

import (
	"fmt"
	"math/big"
	"sync"
)

// filterSet matches the candidate's set-subtraction semantics.
func filterSet(suspects, innocents []int) []int {
	excluded := make(map[int]struct{}, len(innocents))
	for _, innocent := range innocents {
		excluded[innocent] = struct{}{}
	}

	result := make([]int, 0, len(suspects))
	for _, suspect := range suspects {
		if _, found := excluded[suspect]; found {
			continue
		}
		result = append(result, suspect)
	}
	return result
}

// filterSorted uses the sorted-input invariant and preserves duplicate
// suspects unless their value occurs at least once in innocents.
func filterSorted(suspects, innocents []int) []int {
	result := make([]int, 0, len(suspects))
	innocentIndex := 0
	for _, suspect := range suspects {
		for innocentIndex < len(innocents) && innocents[innocentIndex] < suspect {
			innocentIndex++
		}
		if innocentIndex < len(innocents) && innocents[innocentIndex] == suspect {
			continue
		}
		result = append(result, suspect)
	}
	return result
}

// concurrentSum is a finite, deterministic equivalent of the channel task.
// Producers and the closer run concurrently with the consumer, so the
// channel capacity is not a correctness requirement. math/big avoids sum
// overflow.
func concurrentSum(repetitions []int) *big.Int {
	values := make(chan int, 2)
	var producers sync.WaitGroup
	for value, repeat := range repetitions {
		value, repeat := value, repeat
		producers.Go(func() {
			for range repeat {
				values <- value
			}
		})
	}

	go func() {
		producers.Wait()
		close(values)
	}()

	total := new(big.Int)
	for value := range values {
		total.Add(total, big.NewInt(int64(value)))
	}
	return total
}

func main() {
	first := []int{1, 2, 3, 4, 5}
	second := []int{2, 4}
	fmt.Println(filterSet(first, second))
	fmt.Println(filterSorted(first, second))
	fmt.Println(filterSorted([]int{1, 2, 2, 3, 4}, []int{2, 4}))
	fmt.Println(concurrentSum([]int{3, 2, 1}))
}
