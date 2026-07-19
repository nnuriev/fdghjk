// Проверено в официальном Go Playground на Go 1.26.5, 2026-07-18.
package main

import (
	"context"
	"encoding/csv"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
)

// Progress даёт race-free снимок результата во время обработки.
// При падении всего процесса значение исчезнет: для durability нужен внешний checkpoint.
type Progress struct {
	success atomic.Uint64
}

func (p *Progress) Success() uint64 {
	return p.success.Load()
}

// countChunks предполагает, что chunks уже начинаются и заканчиваются на границах
// CSV records. Произвольно резать файл по byte offset нельзя: quoted field может
// содержать перевод строки.
func countChunks(ctx context.Context, chunks []io.Reader, p *Progress) {
	var wg sync.WaitGroup
	for _, chunk := range chunks {
		wg.Add(1)
		go func(src io.Reader) {
			defer wg.Done()
			r := csv.NewReader(src)
			r.FieldsPerRecord = -1

			for {
				select {
				case <-ctx.Done():
					return
				default:
				}

				record, err := r.Read()
				if err == io.EOF {
					return
				}
				if err != nil || !valid(record) {
					continue
				}
				p.success.Add(1)
			}
		}(chunk)
	}
	wg.Wait()
}

func valid(record []string) bool {
	if len(record) != 2 {
		return false
	}
	_, err := strconv.Atoi(record[1])
	return err == nil
}

func main() {
	chunks := []io.Reader{
		strings.NewReader("a,1\nb,bad\nc,3\n"),
		strings.NewReader("d,4\nbroken\ne,5\n"),
		strings.NewReader("f,6\n"),
	}
	var progress Progress
	countChunks(context.Background(), chunks, &progress)
	fmt.Println(progress.Success())
}
