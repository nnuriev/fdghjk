package main

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"
)

type probeFunc func(context.Context, string) (time.Duration, error)

type probeResult struct {
	name     string
	duration time.Duration
}

func getFastestSearcher(
	ctx context.Context,
	searchers []string,
	limit int,
	probe probeFunc,
) (string, time.Duration, error) {
	if len(searchers) == 0 {
		return "", 0, errors.New("empty searcher list")
	}
	if limit <= 0 {
		return "", 0, errors.New("concurrency limit must be positive")
	}
	if probe == nil {
		return "", 0, errors.New("nil probe")
	}
	if limit > len(searchers) {
		limit = len(searchers)
	}

	workerCtx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)

	jobs := make(chan string)
	var wg sync.WaitGroup
	var mu sync.Mutex
	var best probeResult
	haveBest := false

	// The producer belongs to the same lifecycle as the workers: the function
	// does not return while any goroutine started here is still running.
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer close(jobs)
		for _, name := range searchers {
			select {
			case jobs <- name:
			case <-workerCtx.Done():
				return
			}
		}
	}()

	wg.Add(limit)
	for range limit {
		go func() {
			defer wg.Done()
			for {
				select {
				case <-workerCtx.Done():
					return
				case name, ok := <-jobs:
					if !ok {
						return
					}

					duration, err := probe(workerCtx, name)
					if err != nil {
						cancel(fmt.Errorf("probe %q: %w", name, err))
						return
					}

					mu.Lock()
					if !haveBest || duration < best.duration ||
						(duration == best.duration && name < best.name) {
						best = probeResult{name: name, duration: duration}
						haveBest = true
					}
					mu.Unlock()
				}
			}
		}()
	}

	wg.Wait()
	if err := context.Cause(workerCtx); err != nil {
		return "", 0, err
	}
	if !haveBest {
		return "", 0, errors.New("no successful probe")
	}
	return best.name, best.duration, nil
}

func main() {
	durations := map[string]time.Duration{
		"google": 120 * time.Millisecond,
		"yandex": 80 * time.Millisecond,
		"mail":   250 * time.Millisecond,
	}
	probe := func(_ context.Context, name string) (time.Duration, error) {
		return durations[name], nil
	}

	name, duration, err := getFastestSearcher(
		context.Background(),
		[]string{"google", "yandex", "mail"},
		2,
		probe,
	)
	fmt.Println(name, duration, err)
}
