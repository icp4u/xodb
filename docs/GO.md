# Go goroutines, stacks and values

Run `scripts/demo-go`, press **Space** to reach `main.marker`, then choose the
**Go** tab. Each goroutine is a row such as `goroutine 38 [sync.Mutex.Lock]`,
followed by its frames; the goroutine on the stopped thread comes first, then
user goroutines, then the runtime's own (marked `(runtime)`). Select
`main.blocked` to see the parked stack, including the inlined
`sync.(*Mutex).Lock` frames. `GO=path` selects a toolchain; `XODB=path` selects
xodb. Agents ask `get_language_stack` with `language` `go`.

## What is supported

- **Toolchain:** go1.27.1, linux/amd64, a default `go build` (DWARF and frame
  pointers on, statically linked, GNU build ID present). Other versions report
  `GoVersionUnsupported`; other architectures `GoArchitectureUnsupported`.
- **Native debugging:** `--break main.worker` and method names such as
  `main.(*Pool).Run`, source view, line stepping, locals, and backtraces that
  end in `runtime.goexit`. Go's preemption signal (SIGURG) is passed to the
  program without a stop, as gdb does.
- **Goroutines** come from `runtime.allgs`; the count is cross-checked with the
  runtime's separate `runtime.allglen`. Each has its id, status and wait reason
  (the runtime's own `gStatusStrings`/`waitReasonStrings`, read from the
  target), the scan bit, whether Go considers it a system goroutine, and its
  creation site (`gopc` → function and line, shown as Go's "created by").
  Dead goroutines are counted, not listed.
- **Stacks.** Parked and syscall goroutines are unwound from `g.sched` (or
  `syscallpc/sp/bp`) by the amd64 frame-pointer chain. Every step must stay
  inside the goroutine's `[stack.lo, stack.hi)` and move up; the chain is
  `complete` only when it reaches `runtime.goexit`. A running goroutine is
  unwound from its thread's registers (`m.procid`, with `m.curg` checked).
  Function names come from the binary's pclntab (the `_func` entry must agree
  with the function table); file, line and inlined frames come from DWARF. Each
  frame says whether Go's own traceback would show it, so the visible frames
  read like `runtime.Stack` output while runtime frames stay available.
- **Layout** is read from the binary's DWARF: `runtime.g`, `runtime.m`,
  `runtime.moduledata`, `runtime.functab`, `runtime._func`, `string` and
  `[]*runtime.g`. Status and FuncID constants must equal the DWARF constants or
  the tab refuses (`GoConstantMismatch`). The tab prints the version key
  (`go1.27.1`) and build ID. No offsets are written by hand.
- **Values (C/C++ tab and expressions):** integers, floats, bools and pointers;
  strings as `"ready" [5 bytes]`; slices as `len 3 cap 3 [main.Item] @ 0x…`
  with bounded element pages; structs by DWARF field. Stack-passed arguments
  read as unavailable (`PrologueNotComplete`) until the function's prologue
  has run.

## Not yet (M2) and explicit refusals

- **Maps, interfaces and channels** display `partial: M2 (Go … preview not
  implemented)`. Swiss-table maps, dynamic interface types (itab/_type) and
  channel state are later work; raw words are never shown as values.
- No named Go locals inside the Go tab yet (use the C/C++ tab).
- Not shown: which M/P a goroutine is on, CGO and signal frames (a running
  goroutine on a system stack reports `GoRunningOnSystemStack`), plugins or
  additional Go modules (`GoPcOutsideModule`), more than 128 goroutines
  (`truncated`), more than 48 frames (`GoFrameLimit`).
- Reasons you may see: `GoFramePcUnmapped` (a saved PC outside the binary),
  `GoFramePointerOutOfStack`, `GoStackUnreadable`, `GoPclntabMismatch`,
  `GoAllgsInconsistent`, `GoThreadNotTraced`, `GoReadLimit`.

Nothing runs in the target: the reader only reads stopped memory.

## Tests

- `tests/go-reader.c` (in `scripts/build test`): synthetic runtime image with
  planted corruptions (bad saved PC, frame pointer leaving the stack, read
  failures at every position, pclntab disagreement, inconsistent goroutine
  count).
- `tests/go-language.py --go PATH`: builds `examples/go-demo.go`, stops at
  `main.marker` and compares goroutine ids, states, top three visible frames
  and creation sites with the program's own `runtime.Stack(buf, true)`; checks
  value previews; `--strace` audits that only reads happen.
- `tests/go-gui.py --go PATH`: private headless compositor screenshot of the
  goroutine list and a parked stack.
- `scripts/release-check host|gui|all --go /opt/debug/bin/go` runs them.
