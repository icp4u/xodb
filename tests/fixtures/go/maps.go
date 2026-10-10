// Optimized, owned oracle. Map iteration and formatting happen before marker.
package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"reflect"
	"runtime"
)

var retained []any

//go:noinline
func marker() { runtime.KeepAlive(retained) }

type Row struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}
type Oracle struct {
	Name        string `json:"name"`
	Interface   string `json:"interface"`
	Nil         bool   `json:"nil"`
	Length      int    `json:"len"`
	KeyType     string `json:"key_type"`
	ElementType string `json:"element_type"`
	Rows        []Row  `json:"rows"`
}

func main() {
	if len(os.Args) != 2 {
		panic("need oracle path")
	}
	var nilMap map[int]string
	small := map[int]string{1: "one", 2: "two", 9: "nine"}
	deleted := make(map[int]int, 200)
	for i := 0; i < 170; i++ {
		deleted[i] = i * 7
	}
	for i := 0; i < 170; i += 3 {
		delete(deleted, i)
	}
	large := make(map[int]int)
	for i := 0; i < 1800; i++ {
		large[i] = i*i - 17
	}
	for i := 0; i < 1800; i += 5 {
		delete(large, i)
	}
	nan := math.NaN()
	nanMap := map[float64]int{1.25: 7, nan: 11}
	nanMap[nan] = 12
	var bigKey [129]byte
	for i := range bigKey {
		bigKey[i] = byte(i)
	}
	var bigVal [256]byte
	for i := range bigVal {
		bigVal[i] = byte(255 - i)
	}
	largeStorage := map[[129]byte][256]byte{bigKey: bigVal}
	var rows []Oracle
	add := func(name string, value any) {
		retained = append(retained, value)
		// Each interface escapes separately; later append cannot move it.
		box := new(any)
		*box = value
		r := reflect.ValueOf(value)
		item := Oracle{Name: name, Interface: fmt.Sprintf("%p", box), Nil: r.IsNil(), Length: r.Len(), KeyType: r.Type().Key().String(), ElementType: r.Type().Elem().String(), Rows: []Row{}}
		it := r.MapRange()
		for it.Next() {
			item.Rows = append(item.Rows, Row{fmt.Sprint(it.Key().Interface()), fmt.Sprint(it.Value().Interface())})
		}
		rows = append(rows, item)
		// Keep the interface box reachable until the stop.
		retained = append(retained, box)
	}
	add("nil", nilMap)
	add("empty", make(map[int]string))
	add("small", small)
	add("deleted", deleted)
	add("large", large)
	add("nan", nanMap)
	add("zero-value", map[int]struct{}{1: {}, 8: {}})
	add("zero-key", map[struct{}]int{{}: 42})
	add("indirect-both", largeStorage)
	data, err := json.Marshal(rows)
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(os.Args[1], data, 0644); err != nil {
		panic(err)
	}
	marker()
}
