# Lua values and stacks

Run `scripts/demo-lua`, press **Space** to reach `print`, then
**E**, `L`, **Return**. The watch shows the Lua state's top value. **Space**
advances through numbers, a string, a table and a closure. In another terminal,
`scripts/demo-lua stack` prints the Lua frames and bounded value previews.
The demo prefers `/opt/debug/bin/lua5.4`, falling back to `lua5.4` on `PATH`.
Set `LUA` to another debug-built interpreter; `LUA=/opt/debug/bin/lua5.2`
selects the other supported version. A system interpreter without DWARF cannot provide the
native `L` argument or verified state layout. The demo warns when embedded
DWARF is absent; a verified matching debug companion can also supply it.

Like the Node, Python and Perl demos, it chooses `XODB`, then this checkout's
`zig-out/bin/xodb`, then `xodb` on `PATH`. It prints both executables and rejects an xodb build that
does not advertise the Lua reader. Set `XODB` explicitly to choose another build.

The current profiles cover PUC Lua **5.4.9** and **5.2.4**, x86-64 Linux,
little endian, standard 64-bit pointers and double precision numbers. The
interpreter needs DWARF; static embedded C/C++ hosts work too, with Lua itself
compiled as C. Lua compiled as C++ is unsupported because its core symbol names
are mangled. Offsets and
strides come from the identified image's DWARF. The loaded build-id and
`lua_ident` bytes must agree with that image. Results distinguish same-image
DWARF from a build-id matched debug companion. Every layout type, including
`StackValue`, must come from a compilation unit defining Lua's VM or version
object. Unrelated host types are ignored even when their fields resemble Lua's.
Differing valid definitions within the runtime's own units remain ambiguous.
Distinct `lua_ident` or `luaV_execute` definitions in the main image cause
`LuaRuntimeMultiple`, including hidden static copies and copies with identical
layouts. Symbol tables and DWARF definitions are checked before reading states;
the reader does not choose whichever version happens to appear first.
Shared-library runtimes, LuaJIT, stripped layouts without a companion, different versions, NaN-boxed
5.2 builds and other architectures are not covered by these profiles.

A `TValue *` (or Lua 5.4 `StackValue *` / `StkId`) shows nil, booleans, integers (5.4), numbers, byte strings, tables,
closures with upvalues, C functions, userdata or threads. A `lua_State *`
shows its top stack value and up to eight stack slots, even when the native
frame has only an opaque public-header declaration. A complete native type
must agree with the runtime layout. Strings escape non-ASCII and control bytes.
The reader never calls Lua APIs, metamethods, formatters or target code.

For an agent:

```json
{"name":"get_language_stack","arguments":{"tid":1234,"language":"lua"}}
```

Omit `state` to recover native `lua_State *` parameters. Supply a hexadecimal
`state` address to inspect a particular coroutine. Each distinct state remains
a separate observation, including multiple state arguments in one native frame.
A frame with missing or unusable locals adds a `native_argument_diagnostics`
entry while lower Lua frames can still provide states. If none can be recovered,
those diagnostics accompany an empty segment list. Up to eight states and 256
candidate arguments are retained; reaching a limit preserves the partial result.
CallInfo links provide logical ordering and C function
boundaries. Saved PCs and Lua line tables provide current source lines,
including Lua 5.4 absolute-line entries. A saved PC at function entry is labelled
`LuaFrameNotStarted` with the definition line, rather than invalid memory.
Tail-call flags do not reconstruct
eliminated callers. Suspended coroutines are explicitly marked; the 5.2 reader
interprets the saved function offset without changing the target.

Names that cannot be proved remain `<Lua function:LINE>` with
`LuaFunctionNameUnavailable`. Native anchors record recovered state arguments;
they do not establish an exact merge between each Lua frame and each native
activation. Those segments remain partial. Optimized-out state arguments need
an explicit state address.

Bounds are 128 frames, eight preview items, 128 string bytes, 8,192 memory reads
and 2 MiB per reader operation. Large or inconsistent line tables, cycles,
unreadable objects and unsupported layouts carry diagnostics. Table capacities
are slot counts, not Lua's `#` operator or a complete entry count. Lua 5.2's
hash capacity includes its shared nil dummy slot. Only a bounded set of slots
is inspected.

Layout discovery has a separate budget: 8,192 compilation units and 4 million
DWARF work steps, returning `LuaDwarfUnitLimit` or `LuaDwarfWorkLimit` when
exhausted. A work step is not a compilation unit; complex C++ units can exhaust
the budget well below the unit limit. Symbol identity checks inspect at most
1 million symbol entries and otherwise return `LuaSymbolWorkLimit`. The current
module snapshot also limits an executable to 256 MiB. Large embedded hosts can
therefore be refused before any Lua value is inspected; these profiles do not
yet provide ranged DWARF loading for larger files.

Header consistency cannot prove allocation extents or GC liveness. An unchanged
stale allocation can still look readable; a corrupt length may include nearby
readable bytes within the preview bound. String lengths that exceed Lua's size
limit or the supported canonical user address space are refused as
`LuaStringLengthInvalid`. Longer strings and uninspected table capacity instead
carry `LuaStringExtentUnproved` or `LuaTableExtentUnproved`, with `advisory: true`:
the bounded preview remains available, while its full allocation is unproved.
Child items carry their own diagnostics and advisory flag. A detected tag
mismatch is a refusal, not proof that every freed object can be recognized.

The semantic rules follow upstream [5.4 objects](https://www.lua.org/source/5.4/lobject.h.html),
[5.4 states](https://www.lua.org/source/5.4/lstate.h.html),
[5.4 line information](https://www.lua.org/source/5.4/ldebug.c.html), and their
[5.2 object](https://www.lua.org/source/5.2/lobject.h.html),
[state](https://www.lua.org/source/5.2/lstate.h.html) and
[debug](https://www.lua.org/source/5.2/ldebug.c.html) counterparts.

## Named locals at a retained stop

Select a Lua logical frame in the Lua tab. Its lower pane lists active `LocVar`
bindings at the saved bytecode PC, followed by closure upvalues. Names, scopes and
1-based ordinals keep shadowed locals distinct. Scroll in that pane to page the
list. **E**, a bare name, **Return** resolves the innermost active local, then an
upvalue. This reads memory; it never invokes Lua, metamethods or native functions.
Only ASCII identifiers are supported currently; calls, operators and implicit
global lookup are explicitly unavailable. Missing or truncated names cannot be
used as evidence that a shadowing binding does not exist.

For example, run `scripts/demo-lua`, press **Space** to a `print` stop, **Tab** to
Lua, and click a Lua frame below the C `print` frame. Read a listed name with **E**.
**E** in the C/C++ tab still inspects native expressions such as `L`.

MCP observers use `get_language_locals` with `generation`, `tid`, `language: "lua"`,
`segment` and logical `frame`; `start`/`limit` page up to 32 rows. The companion
`evaluate_language_expression` accepts the same frame identity and `expression`
instead of pagination. Both require the current generation and accept no raw
frame addresses. They do not require the controller lease. Values reuse the
bounded Lua renderer, including advisory table/object previews and child values.

The supported debug builds remain Lua 5.4.9 and 5.2.4. LocVar and upvalue layout
comes from the runtime's identified DWARF, including a verified build-ID companion.
C frames, missing/stripped names, unstarted frames and malformed scope/stack
metadata have explicit diagnostics. Suspended coroutines are separate canonical
segments. Every returned storage address is valid only as evidence from that
retained stop; resume, stack relocation and GC require another resolution.

A native function-entry breakpoint can precede the store of a parameter into its
DWARF-described stack slot. For a cooperating C callback that passes `lua_State *`,
stop at a known source line after the prologue when validating parameter-based
state discovery. Register ABI guesses are not used to repair missing proof.

Unnamed extra arguments appear as a single `(vararg) ×N` summary row. Its name
is empty, scope is `vararg`, count is available in `value.count`, and it has no
storage address or expression name. The count comes from the verified frame
layout and is checked against stack bounds; invalid metadata stays unavailable.
Click the native-objects section header to collapse or expand it, independently
of named locals and the logical stack.

## Runtime watches

Run `scripts/demo-lua`, press **Space**, choose **Lua**, and select the loop frame
at `lua-demo.lua:9`. **Shift+E**, `value`, **Return** adds an expression watch;
**Space** reaches the next printed value. **V** toggles events and runtime
watches. Click a watch then **Delete** to remove it; **[ ]** scrolls the list.
The C/C++ tab keeps its native watch view.

Clicking a named row and pressing **W** watches that exact local declaration or
upvalue, including an outer binding shadowed by another row of the same name.
**Shift+E** follows ordinary lexical name lookup at each stop. Neither operation
executes Lua or installs a raw heap watchpoint. Native decoded previews and the
vararg summary do not provide a named watch binding.

The reader resolves the coroutine, CallInfo, prototype and binding again at every
stop. Stack relocation and GC cannot leave a saved value-slot address in use.
An observed return retires the watch permanently. An unobserved coroutine or an
unreadable frame stays unavailable, retaining the last complete value. Matching
frame locations and prototypes does not prove that a call survived continuously
between stops; a returned call can reuse its location entirely between stops.
The C comparison result and MCP `comparison` therefore say `same_slot_equal`
or `same_slot_different`, never that an activation survived. `changed` describes
the complete byte difference at that slot. The GUI labels differences **DIFF
(activation unproved)** and keeps the old and new values visible. Seeing a frame
absent on a complete walk permanently retires its watch, so a later reused slot
cannot revive it. An unobserved coroutine is not proof of a returned frame.

Comparison covers nil, booleans, integers, floating-point representations and
complete strings up to 4096 bytes. Floating-point comparison uses exact bits
(including signed zero and NaN payloads), not Lua operator semantics. A change
outside the displayed string prefix still marks the watch changed. Longer
strings, tables, functions and other objects have explicit unavailability
reasons. A path can select a scalar inside a table as described below.
Sixteen watches per process allocate storage as needed. Missing observations
never count as equality; old/new generations identify the last complete baseline.
These watches report changes **when execution stops**, and do not cause a stop.

MCP `add_language_watch` takes the current `generation`, `language: "lua"`,
`tid`, `segment`, `frame`, and exactly one of `expression` or `row` (the absolute
index in `get_language_locals`). `remove_language_watch` takes `generation` and
`id`. Both require the controller lease in a shared session. Observers can call
`get_language_watches` without a lease; it reads cached comparison results with
current/previous generations, state and a reason, and performs no target reads.

### Table paths

With a debug-built Lua 5.4.9 or 5.2.4 on PATH:

```sh
xodb --break luaB_print -- lua5.4 examples/lua-path-demo.lua
```

Press **Space**, choose **Lua**, and select the Lua frame at the `print` line.
**Shift+E**, `state.player.score`, **Return** creates a watch. Press **Space**
again, then **V**: the score changes even though the program replaced `player`.
**E** reads the same path once; **Delete** removes a selected watch.

Paths start with an ASCII local/upvalue name and contain at most four selectors:
`.identifier` or `[signed decimal integer]`, with indices from -2147483648 to
2147483647 and a total length of 128 bytes. For example, `items[2].name`.
Each stop resolves the root through current lexical scopes, then reads each
current table. It retains neither a table pointer nor a value-slot pointer.

These are raw storage reads. Any traversed table with a metatable returns
`LuaPathMetatableUnsupported`, including keys present in that table. A missing
final key is nil; missing or non-table intermediate values return
`LuaPathNotTable`. Hash lookups inspect at most 128 slots, returning
`LuaPathWorkLimit` before accepting an incomplete scan; array indices within
proved capacity do not scan the hash. Duplicate hash keys refuse as ambiguous.
Quoted/arbitrary keys, calls, arithmetic and metamethods are unsupported.
The ordinary scalar limits and activation-identity caveat still apply.

Syntactically unsupported watch paths refuse at creation with
`LuaExpressionUnsupported`, leaving the watch count unchanged. A valid path
whose root is currently absent or whose table cannot be read can still be added
as an unavailable watch and recover at a later stop.
