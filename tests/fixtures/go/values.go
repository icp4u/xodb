// Owned value oracle. Build with the default optimized Go toolchain and DWARF.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"runtime"
	"strings"
	"time"
)

type Pair struct{ Left, Right int }
type LateNotice string

func (n LateNotice) Error() string { return string(n) }

//go:noinline
func dynamicError(v any) error { return v.(error) }

var DynamicError error
var DynamicType any

type Notice string

func (n Notice) Error() string { return string(n) }

var number = 37
var AnyNil any
var AnyInt any = 73
var AnyString any = "sample"
var AnyPair any = Pair{11, 29}
var AnyPointer any = &number
var AnyTypedNil any = (*Pair)(nil)
var ErrorNil error
var ErrorText error = Notice("notice")
var NilChannel chan int
var Buffered = make(chan int, 5)
var Closed = make(chan string, 3)
var ZeroSize = make(chan struct{}, 4)
var Senders = make(chan int)
var Receivers = make(chan int)
var SelectA = make(chan int)
var SelectB = make(chan int)
var Full = make(chan int, 2)

//go:noinline
func blockedSend() { Senders <- 1 }

//go:noinline
func blockedReceive() { <-Receivers }

//go:noinline
func blockedFull() { Full <- 3 }

//go:noinline
func blockedSelect() {
	select {
	case <-SelectA:
	case <-SelectB:
	}
}

//go:noinline
func marker() { runtime.KeepAlive(AnyPair) }

type Oracle struct {
	Reason   string `json:"reason"`
	Name     string `json:"name"`
	Kind     string `json:"kind"`
	Address  string `json:"address"`
	Type     string `json:"type"`
	Nil      bool   `json:"nil"`
	NonEmpty bool   `json:"nonempty"`
	Length   int    `json:"len"`
	Capacity int    `json:"cap"`
	Closed   bool   `json:"closed"`
	Send     int    `json:"send"`
	Receive  int    `json:"receive"`
	Select   int    `json:"select"`
}

func main() {
	if len(os.Args) != 2 {
		panic("need oracle output")
	}
	Buffered <- 10
	Buffered <- 20
	Closed <- "held"
	close(Closed)
	ZeroSize <- struct{}{}
	ZeroSize <- struct{}{}
	Full <- 1
	Full <- 2
	go blockedSend()
	go blockedSend()
	go blockedReceive()
	go blockedFull()
	go blockedSelect()
	stack := make([]byte, 1<<20)
	for {
		s := string(stack[:runtime.Stack(stack, true)])
		counts := map[string]int{}
		for _, block := range strings.Split(s, "\n\n") {
			for _, f := range []string{"blockedSend", "blockedReceive", "blockedFull", "blockedSelect"} {
				if strings.Contains(block, "main."+f+"(") && (strings.Contains(block, "[chan send]") || strings.Contains(block, "[chan receive]") || strings.Contains(block, "[select]")) {
					counts[f]++
				}
			}
		}
		if counts["blockedSend"] == 2 && counts["blockedReceive"] == 1 && counts["blockedFull"] == 1 && counts["blockedSelect"] == 1 {
			break
		}
		runtime.Gosched()
	}
	DynamicError = dynamicError(LateNotice("late"))
	DynamicType = reflect.New(reflect.StructOf([]reflect.StructField{{Name: "Sample", Type: reflect.TypeOf(0)}})).Elem().Interface()
	timer := time.NewTimer(time.Hour)
	defer timer.Stop()
	var rows []Oracle
	iface := func(name string, addr any, value any, nonempty bool) {
		row := Oracle{Name: name, Kind: "interface", Address: fmt.Sprintf("%p", addr), Nil: value == nil, NonEmpty: nonempty}
		if value != nil {
			row.Type = reflect.TypeOf(value).String()
		}
		rows = append(rows, row)
	}
	iface("nil", &AnyNil, AnyNil, false)
	iface("int", &AnyInt, AnyInt, false)
	iface("string", &AnyString, AnyString, false)
	iface("pair", &AnyPair, AnyPair, false)
	iface("pointer", &AnyPointer, AnyPointer, false)
	iface("typed-nil", &AnyTypedNil, AnyTypedNil, false)
	iface("error-nil", &ErrorNil, ErrorNil, true)
	iface("error-text", &ErrorText, ErrorText, true)
	iface("dynamic-error", &DynamicError, DynamicError, true)
	rows[len(rows)-1].Reason = "GoInterfaceHashUnproved"
	iface("dynamic-type", &DynamicType, DynamicType, false)
	rows[len(rows)-1].Reason = "GoRuntimeTypeUnmapped"
	channel := func(name string, v any, closed bool, send, receive, selects int) {
		r := reflect.ValueOf(v)
		rows = append(rows, Oracle{Name: name, Kind: "channel", Address: fmt.Sprintf("0x%x", r.Pointer()), Type: r.Type().Elem().String(), Nil: r.IsNil(), Length: r.Len(), Capacity: r.Cap(), Closed: closed, Send: send, Receive: receive, Select: selects})
	}
	channel("nil", NilChannel, false, 0, 0, 0)
	channel("buffered", Buffered, false, 0, 0, 0)
	channel("closed", Closed, true, 0, 0, 0)
	channel("zero-size", ZeroSize, false, 0, 0, 0)
	channel("senders", Senders, false, 2, 0, 0)
	channel("receivers", Receivers, false, 0, 1, 0)
	channel("select-a", SelectA, false, 0, 1, 1)
	channel("select-b", SelectB, false, 0, 1, 1)
	channel("full", Full, false, 1, 0, 0)
	channel("timer", timer.C, false, 0, 0, 0)
	rows[len(rows)-1].Reason = "GoChannelTimerUnproved"
	data, err := json.Marshal(rows)
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(os.Args[1], data, 0644); err != nil {
		panic(err)
	}
	marker()
}
