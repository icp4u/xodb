// Owned optimized fixture: all oracles are produced before each debugger stop.
package main

import (
	"encoding/json"
	"os"
	"reflect"
	"runtime"
	"time"
)

type Pair struct{ Left, Right int }
type OnePointer struct{ P *int }
type LateNotice string

func (n LateNotice) Error() string { return string(n) }

//go:noinline
func dynamicError(v any) error { return v.(error) }

type Notice string

func (n Notice) Error() string { return string(n) }

type Values struct {
	Dynamic                                                                            any
	Late                                                                               error
	Timer                                                                              <-chan time.Time
	Small                                                                              map[int]string
	Large                                                                              map[int]int
	NilMap                                                                             map[int]string
	AnyNil, AnyInt, AnyString, AnyPair, AnyPointer, AnyTypedNil, AnyOnePointer, AnyMap any
	Error, ErrorNil                                                                    error
	Buffered                                                                           chan int
	Closed                                                                             chan string
	NilChannel                                                                         chan int
}

var sink int

//go:noinline
func marker(v *Values, direct any, nonempty error) {
	sink++
	runtime.KeepAlive(v)
	runtime.KeepAlive(direct)
	runtime.KeepAlive(nonempty)
}
func main() {
	if len(os.Args) != 2 {
		panic("need oracle path")
	}
	number := 37
	v := &Values{
		Small: map[int]string{1: "one", 2: "two", 9: "nine"}, Large: make(map[int]int),
		AnyInt: 73, AnyString: "sample", AnyPair: Pair{11, 29}, AnyPointer: &number,
		AnyTypedNil: (*Pair)(nil), AnyOnePointer: OnePointer{&number}, Error: Notice("notice"),
		Buffered: make(chan int, 5), Closed: make(chan string, 3),
	}
	timer := time.NewTimer(time.Hour)
	defer timer.Stop()
	v.Timer = timer.C
	v.Late = dynamicError(LateNotice("late"))
	v.Dynamic = reflect.New(reflect.StructOf([]reflect.StructField{{Name: "Sample", Type: reflect.TypeOf(0)}})).Elem().Interface()
	for i := 0; i < 96; i++ {
		v.Large[i] = i*i - 17
	}
	for i := 0; i < 96; i += 5 {
		delete(v.Large, i)
	}
	v.AnyMap = v.Small
	v.Buffered <- 10
	v.Buffered <- 20
	v.Closed <- "held"
	close(v.Closed)
	for stage := 0; stage < 2; stage++ {
		truth := map[string]any{"small": v.Small, "large": v.Large, "int": v.AnyInt,
			"pair": v.AnyPair, "string": v.AnyString, "pointer": reflect.ValueOf(v.AnyPointer).Pointer(),
			"channel_len": len(v.Buffered), "channel_cap": cap(v.Buffered), "closed_len": len(v.Closed),
			"closed_cap": cap(v.Closed), "stage": stage}
		data, err := json.Marshal(truth)
		if err != nil {
			panic(err)
		}
		if err = os.WriteFile(os.Args[1], data, 0644); err != nil {
			panic(err)
		}
		marker(v, v.AnyInt, v.Error)
		v.Small[7] = "seven"
		v.AnyInt = 91
		v.Buffered <- 30
	}
}
