# project brief: linux-native ai-first debugging workstation

## mission

build a new linux-first debugging and program-analysis environment inspired by the best architectural ideas in raddebugger, ida, binary ninja, ghidra, perf, rr, bpf tooling, and modern graphical developer tools.

this is not intended to be a thin gui over gdb, a chat panel bolted onto a debugger, or an ida clone.

the product should unify:

- source-level debugging
- native binary debugging
- disassembly and decompilation-oriented analysis
- reverse engineering
- profiling
- tracing
- runtime introspection
- memory analysis
- allocation and lifetime analysis
- system-call and scheduler observability
- kernel-assisted instrumentation
- ai-driven investigation and experimentation

the central idea is that humans and agents operate on the same structured semantic model of a running or static program.

the product should feel unusually fast, graphical, immediate, exploratory, and linux-native.

---

# guiding principles

## graphical, fast, flashy

the ui is a first-class part of the product.

prioritize:

- extremely low interaction latency
- fluid native rendering
- keyboard-driven workflows
- graphical representations of execution, memory, objects, threads, cpu activity, and causality
- instant navigation between source, assembly, data, history, and analysis
- dense information without looking like a 1990s debugger
- tasteful animation where it helps establish spatial or temporal continuity
- no webview/electron architecture
- no generic widget toolkit unless a compelling reason emerges

the target visual character should align with omarchy:

- dark, minimal, high-contrast
- restrained chrome
- excellent typography
- keyboard-centric
- tiled/panel-oriented
- visually technical rather than corporate
- information density without clutter
- motion and graphical effects should feel deliberate, not ornamental

do not merely imitate raddebugger's appearance. preserve its immediacy while designing a substantially richer graphical environment.

---

# linux first

linux is the primary operating system, not a portability target.

take advantage of linux-specific facilities aggressively where useful.

candidate interfaces include:

- `ptrace`
- `waitpid` / `waitid`
- `pidfd_*`
- `process_vm_readv`
- `process_vm_writev`
- `/proc`
- `perf_event_open`
- ebpf
- uprobes
- kprobes
- tracepoints
- ftrace
- hardware performance counters
- seccomp
- userfaultfd
- cgroups
- pressure stall information
- fanotify/inotify where useful
- io_uring where it provides a concrete benefit
- kernel modules when user-space interfaces cannot provide the fidelity or performance we want

kernel components are explicitly on the table.

however, do not move functionality into the kernel merely because we can. prefer stable user-space kernel interfaces unless a kernel component provides a concrete capability, performance, or observability advantage.

wayland is the primary graphical platform.

x11 may be supported later but architectural decisions should not be constrained by x11.

---

# implementation language and platform

the preferred implementation language is zig.

the preferred initial graphics stack is:

```text
zig
wayland
vulkan
freetype
harfbuzz
```

use system libraries where they substantially reduce pointless work, but keep major product semantics under our control.

do not reimplement mature primitives merely for ideological purity.

good candidates for external libraries include:

- font rasterization
- text shaping
- instruction decoding
- compression
- platform-independent binary-format helpers where appropriate

evaluate dependencies individually.

keep dependency surfaces narrow and wrap them behind internal interfaces.

---

# portability

linux-specific capabilities are welcome and expected.

at the same time, do not unnecessarily tie core program representations to:

- x86-64
- little endian
- a particular pointer width
- elf
- dwarf
- linux kernel structures

the first supported target should be:

```text
host: linux x86-64
target: linux x86-64
binary: elf
debug info: dwarf
```

but core interfaces should make future support practical for:

- aarch64
- riscv64
- other architectures
- remote targets
- non-linux target processes
- alternate object formats and debug-info formats

architecture-specific functionality belongs behind explicit target interfaces.

Where convienent it's ok to abstract for future ports to win/mac but never constrain
functionality in pursuit of that goal. (We would instead add capability to new
platforms if we ever go that route)

---

# architecture

use a layered design with strict boundaries.

a useful initial decomposition is:

```text
                        ┌──────────────────────┐
                        │      graphical ui    │
                        └──────────┬───────────┘
                                   │
                        ┌──────────▼───────────┐
                        │   semantic model     │
                        └──────────┬───────────┘
                                   │
             ┌─────────────────────┼─────────────────────┐
             │                     │                     │
             ▼                     ▼                     ▼
       debugger engine       analysis engine       observability
             │                     │                     │
             ▼                     ▼                     ▼
      target/process         binary analysis       perf/bpf/etc.
          control
             │
             ▼
           linux

                        ┌──────────────────────┐
                        │     agent api        │
                        │      + mcp           │
                        └──────────┬───────────┘
                                   │
                                   ▼
                           semantic model
```

the ui and ai must consume the SAME semantic representation.

do not construct an ai layer that screen-scrapes the debugger.

do not construct an ai layer that primarily parses textual gdb output.

---

# semantic debug model

build a normalized internal representation of program state.

everything important should have stable ids.

candidate entities:

```text
Session
Process
Thread
Module
BinaryImage
Architecture
RegisterFile
Frame
Scope
Symbol
Function
SourceFile
SourceLocation
Type
Value
Object
MemoryRegion
Allocation
Breakpoint
Watchpoint
Probe
Event
Trace
Experiment
Hypothesis
Runtime
RuntimeFrame
ProfileSample
CallEdge
```

example hierarchy:

```text
session
 ├─ process[]
 │   ├─ module[]
 │   │   ├─ symbol[]
 │   │   └─ type[]
 │   ├─ thread[]
 │   │   ├─ registers
 │   │   └─ frame[]
 │   │       ├─ scope
 │   │       ├─ local[]
 │   │       └─ source location
 │   ├─ memory region[]
 │   └─ allocation[]
 ├─ breakpoint[]
 ├─ watchpoint[]
 ├─ probe[]
 ├─ event[]
 └─ hypothesis[]
```

avoid exposing raw implementation pointers to external clients or agents.

use stable ids or handles.

---

# debug-info normalization

take inspiration from a raddebugger/ghidra approach to debug info abstraction

dwarf should not leak through every subsystem.

build a normalized internal debug-information representation.

roughly:

```text
dwarf
  │
  ▼
decoder / normalizer
  │
  ▼
internal debug database
  │
  ├─ source mappings
  ├─ functions
  ├─ lexical scopes
  ├─ variables
  ├─ location expressions
  ├─ types
  ├─ inline call information
  ├─ call-frame information
  └─ unwind metadata
```

later:

```text
pdb ─────┐
dwarf ───┼──> normalized debug database
other ───┘
```

implement dwarf deterministically.

ai may accelerate implementation, test generation, fuzzing, comparison, and diagnosis, but runtime correctness must not depend on probabilistic interpretation.

---

# dwarf work plan

treat dwarf as a collection of tractable subsystems rather than one monolith.

implement and test independently:

1. elf section discovery
2. compilation units
3. abbreviations
4. dies and attributes
5. string/reference forms
6. address tables
7. line programs
8. source-to-address and address-to-source lookup
9. type graph reconstruction
10. lexical scopes
11. variable location expressions
12. location lists
13. range lists
14. inline call information
15. call-frame information
16. stack unwinding
17. split dwarf where useful
18. dwarf 4 and dwarf 5 compatibility
19. compiler-specific extensions encountered in practice

create fixture binaries with:

- clang
- gcc
- zig
- rustc

at:

```text
-O0
-O1
-O2
-O3
-g
-gline-tables-only where relevant
```

create fixtures deliberately covering:

- inlining
- tail calls
- optimized-out variables
- register-resident variables
- stack-resident variables
- variable location changes
- templates/generics
- closures
- async code
- exceptions/unwinding
- shared libraries
- dlopen
- stripped and partially stripped binaries

compare our interpretation against established tools where useful.

every bug becomes a permanent fixture.

---

# debugger kernel

the first debugger engine should support:

- launch
- attach
- detach
- stop
- continue
- kill
- single-step
- step into
- step over
- step out
- software breakpoints
- hardware breakpoints
- hardware watchpoints
- thread enumeration
- register read/write
- memory read/write
- module enumeration
- signal handling
- stack unwinding
- source lookup
- symbol lookup
- expression evaluation

the distinction between low-level process control and high-level debugging semantics must be explicit.

example:

```text
process control:
    single-step one machine instruction

debugger semantics:
    step over one source statement
```

do not conflate them.

---

# expression evaluation

implement a structured expression engine rather than shelling out to gdb.

eventual pipeline:

```text
source expression
    │
    ▼
lexer
    │
    ▼
parser
    │
    ▼
typed expression tree
    │
    ▼
lowered evaluation ir
    │
    ▼
evaluation against process/frame state
    │
    ▼
structured Value
```

the resulting value should support:

- type
- address
- scalar value
- children
- source provenance
- lvalue/rvalue distinction where useful
- dereference
- expansion
- visualization adapters

language-specific syntax may eventually use separate frontends over a common evaluation substrate.

---

# runtime and language adapters

do not hard-code language-specific behavior into the machine debugger.

provide a runtime/language adapter interface.

examples:

## c / c++

- native source frames
- types
- templates
- exceptions
- standard-library container visualizers

## rust

understand:

- enums
- `Option`
- `Result`
- slices
- fat pointers
- trait objects
- standard collections
- async state machines
- closures
- mangling
- compiler-generated types

## zig

understand:

- slices
- optionals
- error unions
- tagged unions
- sentinel pointers
- compiler-generated types
- name mangling
- async/runtime features as they evolve

## python

python requires runtime introspection, not merely dwarf.

model things such as:

```text
native process
 └─ cpython runtime
     ├─ interpreter
     ├─ python thread[]
     ├─ python frame[]
     ├─ code object[]
     ├─ pyobject graph
     ├─ gc state
     └─ refcounts
```

allow native and python call stacks to coexist and be correlated.

future adapters may cover:

- go
- jvm
- javascript runtimes
- lua
- ruby
- wasm runtimes

possible interface shape:

```zig
pub const RuntimeAdapter = struct {
    detect: *const fn (...) bool,
    enumerateFrames: *const fn (...),
    decodeValue: *const fn (...),
    enumerateObjects: *const fn (...),
    resolveSource: *const fn (...),
    inspectRuntimeState: *const fn (...),
};
```

do not freeze this api prematurely.

---

# static binary analysis

the product should grow into ida/ghidra/binary-ninja territory.

support a static-analysis pipeline that can operate with or without debug symbols.

major concepts:

```text
binary bytes
   │
   ▼
instruction decoder
   │
   ▼
control-flow graph
   │
   ▼
machine-independent ir
   │
   ▼
data-flow analysis
   │
   ├─ function recovery
   ├─ variable recovery
   ├─ constant propagation
   ├─ type inference
   ├─ calling-convention recovery
   └─ higher-level representation
```

study:

- ghidra p-code
- ghidra sleigh
- binary ninja intermediate languages
- radare2 esil
- rizin
- ida's publicly documented analysis model

do not copy proprietary implementation code.

open-source implementations may be studied and reused subject to their licenses.

the internal ir should be architecture-neutral enough to support future targets.

---

# inferred semantic information

when authoritative debug information is absent, permit inferred information.

keep it explicitly separate from compiler-provided facts.

for example:

```text
symbol:
    name: inferred_socket
    provenance: inferred
    confidence: 0.83
```

possible provenance classes:

```text
compiler
binary
runtime observation
user
agent inference
heuristic
```

agents should be able to iteratively refine inferred:

- function names
- function boundaries
- variable roles
- types
- structures
- calling conventions
- ownership relationships
- object layouts

runtime observations can validate or falsify static guesses.

this is an important bridge between debugger and reverse-engineering workflows.

---

# observability and profiling

do not constrain the product to stop-and-inspect debugging.

build an observability engine for running processes.

initial areas:

- cpu sampling
- stack sampling
- hardware counters
- function tracing
- syscall tracing
- scheduler events
- thread wake/sleep behavior
- lock contention
- page faults
- io latency
- allocation/free activity
- heap growth
- module loading
- gc/runtime events where adapters provide them
- network activity where useful

sources may include:

```text
perf_event_open
ebpf
uprobes
kprobes
tracepoints
ftrace
allocator hooks
runtime hooks
```

the debugger and profiler should share identity.

a function in a flame graph should be the same semantic function object shown in source, disassembly, call graphs, and agent queries.

---

# event model and time

make history first-class.

the traditional debugger asks:

```text
what is true now?
```

this product should additionally ask:

```text
what happened?
when did it happen?
what caused it?
what changed immediately before it?
```

begin with a lightweight event timeline rather than attempting full deterministic replay immediately.

possible events:

```text
process start
process exit
thread start
thread exit
module load
module unload
signal
exception
breakpoint hit
watchpoint hit
probe hit
syscall
context switch
allocation
free
sample
gc event
user annotation
agent action
```

later investigate deeper recording/replay integration.

rr interoperability should be considered.

do not unnecessarily reinvent deterministic replay before the rest of the product is compelling.

---

# causal analysis

make causal relationships a core concept.

example:

```text
allocation
    ↓
pointer assignment
    ↓
mutation
    ↓
free
    ↓
stale read
    ↓
segfault
```

the ui should be able to visualize this sequence.

the agent should be able to ask the system for supporting observations rather than hallucinating causal explanations.

---

# agent-native architecture

ai is not an accessory panel.

the agent must be able to perform real investigations.

the internal api should expose semantic operations such as:

```text
list_processes
list_threads
get_thread
get_stack
get_frame
get_registers
read_memory
write_memory
evaluate_expression
find_symbol
find_type
find_source
disassemble
set_breakpoint
remove_breakpoint
set_watchpoint
continue
interrupt
step_into
step_over
step_out
query_events
start_profile
stop_profile
install_probe
remove_probe
inspect_allocation
inspect_object
find_references
query_callers
query_callees
```

these names are illustrative, not final.

tools should return structured data.

avoid tools whose result is primarily terminal-formatted text.

---

# mcp

provide an mcp server as a first-class external agent interface.

mcp is an adapter over the semantic api, not the semantic api itself.

possible topology:

```text
                    ┌──────── gui
                    │
debug/analysis core ├──────── internal agent
                    │
                    ├──────── mcp server
                    │
                    └──────── scripting api
```

keep the underlying interfaces independent from mcp so other protocols can be added later.

mcp should provide high-fidelity "eyes and fingers" into the target and analysis state.

prefer operations such as:

```text
inspect this frame
find writes to this object
profile this function
set a watchpoint on this field
show me all observed callers
trace this syscall
```

over:

```text
run arbitrary shell command
```

a raw shell can exist separately when explicitly requested.

---

# observation versus mutation

classify agent operations by effect.

## read-only / observation

examples:

- read registers
- read memory
- inspect symbols
- inspect stack
- evaluate a side-effect-free expression
- query profiler data
- query timeline
- disassemble
- analyze binary

these should generally be easy to automate.

## execution-control mutation

examples:

- continue
- interrupt
- step
- set/remove breakpoint
- set/remove probe
- set/remove watchpoint

make these visible and auditable.

## target-state mutation

examples:

- write memory
- write registers
- inject code
- call arbitrary functions in the inferior
- alter control flow

treat these as a distinct capability class.

the architecture should make it possible to enforce policy at these boundaries.

---

# agent investigations

support investigations as durable objects rather than ephemeral chat.

an investigation might contain:

```text
question
hypotheses
evidence
counterevidence
experiments
observations
conclusion
artifacts
```

provide a native hypothesis object.

example:

```text
hypothesis:
    "meshnode is used after free"

confidence:
    0.78

evidence:
    - pointer references allocation #4821
    - allocation #4821 was freed at event #99127
    - dereference occurs at event #99154

counterevidence:
    - allocator reuse has not yet been excluded

suggested experiment:
    rerun with watchpoint and allocation tracing
```

the agent can request an experiment.

the debugger executes it.

the results become structured evidence.

this is preferable to a chatbot simply asserting an explanation.

---

# graphical views

minimum traditional views:

- source
- assembly
- mixed source/assembly
- registers
- locals
- watches
- stack
- threads
- memory
- modules
- symbols
- breakpoints
- probes
- output/logging

additional first-class graphical views should include:

## execution timeline

show:

- threads
- samples
- signals
- syscalls
- context switches
- breakpoints
- allocations
- agent actions
- annotations

## call graph

interactive static/dynamic call graph.

allow overlays for:

- cpu cost
- sample count
- allocation cost
- latency
- observed runtime edges
- inferred static edges

## object graph

visualize pointer/reference relationships.

example:

```text
World
 ├── Player
 │    └── Inventory
 │         └── Sword
 ├── Map
 │    └── Region[27]
 └── NPC[]
```

## memory map

show:

- mappings
- permissions
- executable regions
- stacks
- heaps
- shared libraries
- mapped files
- guard pages

## memory heatmap

possible overlays:

- read activity
- write activity
- allocation density
- freed regions
- cache behavior
- page faults
- object types

## flame graph / profile view

integrate directly with source and disassembly navigation.

## causal graph

display the evidence chain for a bug or hypothesis.

---

# ui architecture

build a custom immediate-mode or retained/immediate hybrid ui appropriate to the product.

the renderer should remain narrow.

typical rendering requirements are modest:

- rectangles
- borders
- text
- icons
- curves
- graphs
- timelines
- selection/highlighting
- potentially large amounts of text

vulkan is appropriate.

do not turn the vulkan layer into a graphics-engine science project.

the difficult product work is elsewhere.

important ui capabilities:

- dockable/tiled panes
- detachable workspaces if useful
- keyboard navigation
- fuzzy command launcher
- contextual command palette
- fast tables
- virtualized lists
- large source files
- large disassemblies
- graph rendering
- timeline zoom/pan
- GPU-accelerated text and primitive rendering
- persistent layouts
- multiple monitors
- high-dpi support

---

# source and editor philosophy

this is a debugger and analysis environment, not necessarily an ide.

source editing may be added, but debugging/navigation quality takes priority.

allow opening source trees and repositories.

do not allow editor scope creep to block the debugger.

---

# performance philosophy

the tool should feel instantaneous.

design for:

- asynchronous loading of debug information
- background symbol indexing
- incremental analysis
- caching
- memory mapping where appropriate
- zero-copy or low-copy data paths where useful
- virtualized graphical views
- responsive ui even while analysis is running

never block the ui on a giant dwarf parse if partial results can be shown immediately.

---

# process isolation

strongly consider splitting major components into separate processes.

candidate architecture:

```text
gui process

debug-agent process
    owns ptrace relationship where practical

analysis workers

symbol/debug-info workers

bpf/perf collector

optional model/agent process
```

benefits:

- crash containment
- security boundaries
- cleaner asynchronous architecture
- possible remote debugging
- easier privilege separation
- easier testing

do not prematurely distribute everything into microservices.

use processes where the operating-system boundary provides concrete value.

---

# privilege model

kernel observability may require elevated privileges or specific capabilities.

design for least privilege.

possible privileged helper:

```text
debug-helper
```

with narrowly defined operations.

avoid requiring the entire ui or ai agent to run as root.

investigate linux capabilities and bpf security constraints.

---

# remote debugging

design ids/protocols such that a debug engine can eventually run remotely.

possible future arrangement:

```text
workstation gui
      │
      │ structured protocol
      ▼
remote linux machine
      │
      └── debug/observability daemon
```

do not make remote support a milestone-one requirement.

avoid architecture that makes it impossible.

---

# static versus live analysis

the same semantic model should accommodate:

```text
static binary analysis
live process state
recorded timeline
core dump
crash dump
replay session
```

users should be able to move naturally among them.

example:

```text
profile identifies hot function
    ↓
open function
    ↓
inspect source + disassembly
    ↓
view recovered types
    ↓
set probe
    ↓
capture live arguments
    ↓
agent forms hypothesis
    ↓
rerun with watchpoint
```

this unified workflow is a core differentiator.

---

# initial milestone

do NOT initially attempt the entire vision.

build one narrow, magical vertical slice.

target:

```text
linux x86-64
zig
wayland
vulkan
elf
dwarf
c/c++ test programs
```

milestone 1 should allow:

1. launch an executable
2. attach to an executable
3. enumerate threads
4. stop/continue
5. set a breakpoint by source line or symbol
6. hit the breakpoint
7. show source
8. show assembly
9. show registers
10. show stack frames
11. show locals
12. evaluate basic expressions
13. single-step
14. step over
15. set a hardware watchpoint
16. display a simple event timeline
17. expose these operations through the internal semantic api
18. expose a useful subset through mcp
19. let an agent answer:

```text
why did this value change?
```

by conducting a real debugger experiment.

if this workflow feels excellent, proceed.

---

# milestone 2

add:

- cpu sampling with `perf_event_open`
- flame graphs
- profiler/source/disassembly linkage
- initial uprobes
- syscall tracing
- allocation tracking
- richer timeline
- rust and zig value visualization
- static control-flow graphs
- function recovery
- initial architecture-neutral analysis ir

---

# milestone 3

add:

- richer ebpf integration
- object graphs
- memory heatmaps
- causal graph views
- runtime adapters
- python/cpython inspection
- inferred type system for stripped binaries
- hybrid static/dynamic type recovery
- deeper agent-driven experiment loops

---

# milestone 4 and beyond

potential areas:

- deterministic replay
- rr integration or equivalent functionality
- remote debugging
- aarch64
- riscv64
- kernel debugging
- kernel-module instrumentation
- heap snapshots
- leak diagnosis
- lock/deadlock analysis
- network causality
- distributed tracing correlation
- automatic crash minimization
- fuzzing integration
- core dump analysis
- decompiler
- binary patching
- live patch experiments

do not assume all of these belong in the final product.

build toward demonstrated workflows.

---

# reference projects

study aggressively.

## raddebugger

particularly useful for:

- debugger architecture
- separation of process control and higher debugger semantics
- custom ui
- debug-info normalization
- expression evaluation
- value visualization
- performance-oriented implementation

do not inherit its assumptions blindly.

our product is linux-first, observability-first, and ai-native.

## ghidra

study:

- sleigh
- p-code
- architecture descriptions
- decompiler pipeline
- data-flow analysis
- type recovery
- function recovery
- plugin architecture

## binary ninja

study publicly documented:

- intermediate-language layering
- analysis APIs
- interaction model
- plugin model
- mcp integration

do not copy proprietary implementation.

## ida

study public interfaces and concepts:

- interactive reverse-engineering workflows
- type recovery
- cross references
- function analysis
- decompiler/debugger integration

do not copy proprietary implementation.

## radare2 / rizin

study:

- esil
- command architecture
- analysis APIs
- plugin architecture
- binary formats
- mcp/ai experiments

## rr

study:

- recording
- replay
- deterministic execution
- reverse execution
- interaction with ptrace/perf

## perf / bpftrace / libbpf / bcc

study:

- kernel observability
- sampling
- event collection
- probe lifecycle
- efficient data transport

---

# testing strategy

testing is non-negotiable.

agents can produce code rapidly; tests prevent that speed from turning into a swamp.

build layers of tests:

## unit tests

for:

- binary parsing
- dwarf forms
- line tables
- expression evaluation
- target-independent types
- instruction decoding wrappers
- semantic-model transformations

## fixture tests

compile intentionally small programs and assert debugger behavior.

## differential tests

compare selected results against:

- gdb
- lldb
- readelf
- llvm-dwarfdump
- objdump
- perf
- other trusted tools

do not require exact textual equality.

compare semantic results.

## fuzz tests

especially for:

- elf parser
- dwarf parser
- expression parser
- protocol decoders
- static-analysis ir

never trust binary input.

## integration tests

automatically:

- launch target
- set breakpoint
- continue
- verify stop
- inspect variable
- modify program state where relevant
- step
- exit

## visual tests

capture ui frames for stable scenarios where practical.

---

# agent development workflow

astra/codex should work in small, independently testable increments.

for each subsystem:

1. identify the smallest useful contract
2. inspect relevant specifications and reference implementations
3. write tests/fixtures
4. implement the minimal path
5. run tests
6. compare against established tools
7. investigate discrepancies
8. turn every discovered edge case into a permanent test
9. refactor only after behavior is well captured

do not estimate work based on traditional human implementation timelines.

instead, aggressively prototype.

however, do not mistake rapid code generation for correctness.

for binary formats, debugger control, unwinding, and kernel interfaces, verification matters more than plausible-looking code.

---

# source-tree sketch

possible starting point:

```text
src/
  app/
  ui/
  render/
  platform/
    linux/
      wayland/
      input/
  target/
    arch/
      x86_64/
      aarch64/
    linux/
  debug/
    control/
    breakpoints/
    stepping/
    unwind/
    eval/
  binary/
    elf/
    dwarf/
    symbols/
  model/
  analysis/
    ir/
    cfg/
    dataflow/
    types/
  runtime/
    c/
    cpp/
    rust/
    zig/
    python/
  trace/
    perf/
    bpf/
    syscall/
    alloc/
  timeline/
  agent/
  mcp/
  protocol/
  common/

tests/
  fixtures/
  unit/
  integration/
  differential/
```

this is a sketch, not a mandate.

change it when implementation experience provides evidence for something better.

---

# coding philosophy

prefer:

- plain data
- explicit ownership
- explicit lifetimes
- narrow interfaces
- deterministic behavior
- inspectable state
- low coupling
- small modules
- testable functions
- instrumentation
- assertions
- aggressive debug builds

avoid:

- giant inheritance hierarchies
- opaque framework magic
- hidden global state
- broad dependencies
- stringly typed internal protocols
- parsing command-line output as a primary integration strategy
- premature plugin abstractions
- premature distributed architecture

---

# instrumentation of the debugger itself

the debugger must be easy to debug.

include internal tracing from early development.

measure:

- dwarf parse time
- symbol lookup latency
- frame-unwind latency
- process-control round trips
- rendering frame time
- profiler event loss
- mcp call latency
- agent operation duration

provide an internal diagnostics view.

a debugger that cannot explain its own stalls will become miserable quickly.

---

# product character

the final result should feel less like:

```text
gdb with windows
```

and more like:

```text
a live visual instrument for understanding software
```

the user should be able to point at almost anything and ask:

```text
what is this?
where did it come from?
what changed it?
who calls it?
what does it point to?
why is it slow?
why is this blocked?
when was this allocated?
who freed it?
what happened immediately before this?
what hypothesis best explains this failure?
how can we test that?
```

and the system should have enough structured access to actually investigate those questions.

the key product loop is:

```text
observe
   ↓
form hypothesis
   ↓
instrument
   ↓
run experiment
   ↓
collect evidence
   ↓
visualize
   ↓
refine
```

both the human and the agent participate in that same loop.

---

# first task for astra/codex

before implementing broad functionality:

1. create the zig project skeleton.
2. establish the module boundaries above in a minimal form.
3. implement a native wayland window.
4. create a minimal vulkan renderer.
5. render text using freetype/harfbuzz.
6. implement a simple dock/tile ui with:
   - source pane
   - assembly pane
   - threads pane
   - event/timeline pane
7. build a tiny linux x86-64 target-control library capable of:
   - launch
   - attach
   - interrupt
   - continue
   - enumerate threads
   - read registers
   - read memory
8. expose those capabilities through typed internal interfaces.
9. construct a minimal semantic model above them.
10. create a tiny mcp server exposing read-only inspection first.
11. write integration tests against fixture programs.
12. only then begin dwarf/source-level support.

keep the executable runnable throughout development.

we want a product taking shape continuously, not eighteen libraries followed by a ui six months later.

---

# final design rule

when choosing between two designs, prefer the one that improves all three simultaneously:

1. human understanding
2. agent understanding
3. machine-verifiable semantics

the agent is not a separate user bolted onto the application.

the graphical debugger, static analyzer, profiler, tracing system, and agent are different interfaces onto one model of program behavior.
