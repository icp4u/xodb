# Running target code: `execute_call`

Everything else in xodb reads a stopped process. `execute_call` is the one
path that runs code inside it on purpose: a C or C++ function call on one
thread, like gdb's `call` or `print f(x)`. It is opt-in, bounded, journaled
and recoverable. This milestone covers x86-64 SysV Linux, launched or
attached, in-process or through `--runtime-agent`. Language-level eval (Lua,
Python, Ruby, Perl, JS) is not part of it.

## The safety model

| Rule | What it means |
| --- | --- |
| A separate `execute` scope | `--agent-scope execute` grants control plus calls. It does not grant `write_memory`/`write_register`, and `mutate` does not grant calls. Observers never execute. A shared session needs the controller lease while the human's ceiling is `execute`. |
| Explicit consent per request | MCP clients pass `allow_execution: true`; without it the request is refused (`ExecutionConsentRequired`). |
| Read-only stays read-only | `evaluate_expression`, watches, conditions and logpoints never call: an expression with `f(...)` is refused with `ExecutionRequired`. strace shows no register or memory write and no resume on those paths. |
| One thread runs | Only the selected thread is resumed. Others stay in their ptrace stops, so a callee that needs a lock another thread holds blocks (and times out). |
| Borrowed stack, never target heap | The call frame is built in a checked, bounded range of the thread's own stack below the 128-byte red zone, 16-byte aligned at entry. The range must be in `[stack]` or an anonymous private mapping with 32 KiB below it; a thread stopped on a signal stack inside the heap or a file-backed data segment is refused (`ScratchUnavailable`), since the callee's frames would overwrite live objects below it. A signal stack carved from a larger anonymous buffer is not detected. Nothing is mapped or injected. The return address is the process entry point (`AT_ENTRY`) with a temporary internal breakpoint, so a return never runs target code. A disabled breakpoint already at that address (or at `std::terminate`) cannot serve as the trap, so the call is refused (`ReturnTrapUnavailable`). |
| Exact restore of xodb's state | Before any write, xodb saves the whole general register image, the whole `NT_X86_XSTATE` image (x87, SSE, AVX, AVX-512) and the borrowed bytes. After the call it writes them back, reads them again and compares byte for byte. A mismatch is `restore_failed`, never success. |
| Callee effects stay | Memory, files, locks, allocations and signals the callee caused are not rolled back. |
| Bounded time | 5 s by default, at most 30 s (`timeout_ms`). |
| Audit | Every call bumps the target generation and is journaled (actor, scope, thread, callee, duration, outcome; never argument text or results). `get_execution_state` reads the journal. Debugger event logs and capture archives carry an `execution` marker. |

## Outcomes

| `outcome` | Meaning | Call frame |
| --- | --- | --- |
| `returned` | Returned through the trap; state restored and verified; `value` is the result | ended |
| `timeout` | The thread was interrupted after `timeout_ms`; `blocked_syscall` names a syscall it was in (202 is futex) | active |
| `signal` | A signal arrived inside the call (`signal`, `fault_address`) | active |
| `breakpoint` | A user breakpoint inside the callee was hit | active |
| `exception` | A C++ exception reached `std::terminate` (it would cross the debugger's frame) | active |
| `trap`, `event` | Another trap, or a clone/fork/vfork event | active |
| `exited` | The thread or process exited, or exec'd; nothing to restore | ended |
| `stop_unconfirmed` | The interrupt was sent but no stop seen within 2 s | active |
| `restore_failed` | Restore wrote or read back different bytes (`mismatch` names which) | active |
| `refused` | Refused before any write (`reason`) | none |

While a call frame is active the thread stays stopped inside the callee and
the target refuses `continue`, stepping, detach and another call with
`CallFrameActive`. Resolve it with `resolve_execution`:

- `restore`: write the saved state back and verify it, as for a normal return.
- `abandon`: keep the thread where it is. The return trap becomes an ordinary
  visible breakpoint, so if the callee later returns the thread stops there
  instead of running the entry point. Removing that breakpoint, or detaching,
  before the callee has returned lets the return run the entry point.

Closing an attached process restores a stopped active frame before detaching.

## What can be called

| Callee | How it is found |
| --- | --- |
| A C function or a mangled name | The symbol |
| A PLT import, including a glibc IFUNC (`strlen`, `memcpy`) | The bound GOT slot of an image that imports it. The IFUNC resolver is never called; an unbound one is `UnresolvedIfunc`. |
| A function pointer | A read-only expression in the frame, e.g. `fp` |
| A C++ function | Its demangled name; overloads by parameter list (`overloaded(double)`), templates by instantiation (`maxof<int>`), resolved with DWARF |
| A C++ member | With `this`. A virtual method dispatches through the object's vtable (`Shape::area` on a `Circle` calls `Circle::area`). |

Arguments are read-only expressions in the chosen `frame`; values are
converted as C would (integer widths, int/float). Supported classes: integers,
`bool`, pointers, `float`, `double`, aggregates passed in registers
(INTEGER/SSE eightbytes), aggregates in memory and returned through a hidden
pointer (up to 256 bytes), and arguments spilled to the stack. A prototype
comes from DWARF; a callee without DWARF or a variadic one needs an explicit
`prototype` such as `"size_t(const char *)"` or `"long(int, ...)"`; `%al` is
set for varargs and the extra arguments get default promotions.

Refused with a typed reason, before anything is written: `OverloadAmbiguous`,
`TemplateInstantiationRequired`, `NonTrivialCopyArgument`/`Return` (a by-value
class with a user copy constructor or destructor), `ThisRequired`,
`ThisUnexpected`, `ThisTypeMismatch`, `InvalidThis`, `VirtualThunkUnsupported`,
`VariadicPrototypeRequired`, `PrototypeMismatch`, `PrototypeUnavailable`, `PrototypeTypeUnsupported`,
`LongDoubleUnsupported`, `UnsupportedArgumentType`, `ArgumentCountMismatch`,
`NestedCallUnsupported`, `ScratchUnavailable` (string, character and array
literals need target memory; a stack range too small or not private and
writable), `ShadowStackUnsupported` (CET), `ExecutionStopStateUnsupported` (an
exec/fork/vfork stop, a step in progress), `ExecutionBackendUnavailable`
(GDB remote, or an agent without the capability), `CallFrameActive`.

## Example

```json
{"name":"execute_call","arguments":{"tid":4242,"frame":1,"callee":"strlen","arguments":["buf"],"prototype":"size_t(const char *)","allow_execution":true,"generation":57}}
```

returns, among other fields, `outcome: "returned"`, `resolution: "got"`,
`value.display: "15"`, `restored: true`, `verified: true`, the borrowed range
and the number of register, vector-state and stack bytes compared.

## Not yet

- GUI: no consent dialog or Execute action yet; GUI users see the journal
  only through MCP. The call itself is synchronous (bounded by its timeout).
- Other architectures (aarch64, riscv64), GDB remote targets, Windows/macOS.
- `long double`, `__int128`, vector types, bit-fields, unions with members of
  different classes beyond the SysV merge, multiple or virtual inheritance in
  virtual dispatch, string literals (no scratch mapping), calls that create
  threads or fork (reported as `event`, left active).
- Conditions and logpoints of breakpoints inside the callee are not
  evaluated; any enabled breakpoint stops the call.
