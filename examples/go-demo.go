// Owned Go fixture for xodb: a worker pool with channels, a select, a
// goroutine blocked on a sync.Mutex and one sleeping. Before the marker the
// program records runtime.Stack(buf, true) as ground truth (to stdout, or to
// the file named by its first argument), then calls marker(), which a
// debugger can break on.
package main

import (
	"fmt"
	"os"
	"runtime"
	"strings"
	"sync"
	"time"
)

type Item struct {
	ID    int
	Name  string
	Ready bool
}

type Pool struct {
	jobs    chan int
	results chan int
	quit    chan struct{}
	mu      sync.Mutex
	wg      sync.WaitGroup
}

var (
	gate     sync.Mutex
	sink     int
	snapshot = make([]byte, 1<<16)
)

//go:noinline
func marker(stage int, label string, items []Item, ratio float64, ok bool, p *Pool,
	first Item, counts map[string]int, err error, results chan int) int {
	sink += stage + len(label) + len(items) + first.ID + len(counts) + len(results)
	if ok && ratio > 0 && p != nil && err != nil {
		sink++
	}
	return sink
}

//go:noinline
func worker(id int, p *Pool) {
	defer p.wg.Done()
	for {
		select {
		case job, ok := <-p.jobs:
			if !ok {
				return
			}
			p.mu.Lock()
			p.results <- job * id
			p.mu.Unlock()
		case <-p.quit:
			return
		}
	}
}

//go:noinline
func (p *Pool) Run(n int) {
	for i := 0; i < n; i++ {
		p.wg.Add(1)
		go worker(i+1, p)
	}
}

//go:noinline
func blocked(done chan<- struct{}) {
	gate.Lock()
	gate.Unlock()
	done <- struct{}{}
}

//go:noinline
func sleeper() {
	time.Sleep(time.Hour)
}

func main() {
	pool := &Pool{jobs: make(chan int), results: make(chan int, 16), quit: make(chan struct{})}
	pool.Run(3)
	for i := 1; i <= 4; i++ {
		pool.jobs <- i
	}
	total := 0
	for i := 0; i < 4; i++ {
		total += <-pool.results
	}
	gate.Lock()
	done := make(chan struct{})
	go blocked(done)
	go sleeper()
	items := []Item{{1, "alpha", true}, {2, "beta", false}, {3, "gamma", true}}
	ratio := float64(total) / 4
	ok := total > 0
	// Take the ground-truth snapshot once every helper goroutine has parked.
	var n int
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); time.Sleep(time.Millisecond) {
		n = runtime.Stack(snapshot, true)
		text := string(snapshot[:n])
		if strings.Count(text, "[select]") == 3 && strings.Contains(text, "[sync.Mutex.Lock]") && strings.Contains(text, "[sleep]") {
			break
		}
	}
	if len(os.Args) > 1 {
		os.WriteFile(os.Args[1], snapshot[:n], 0o644)
	} else {
		os.Stdout.Write(snapshot[:n])
	}
	fmt.Println("--- marker", total)
	counts := map[string]int{"alpha": 1, "beta": 2}
	marker(total, "ready", items, ratio, ok, pool, items[0], counts, fmt.Errorf("demo %d", total), pool.results)
	gate.Unlock()
	<-done
	close(pool.quit)
	pool.wg.Wait()
	fmt.Println("done", sink)
}
