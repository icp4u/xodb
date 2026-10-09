# CPython values and logical stacks

At a native stop in CPython, xodb shows Python objects through **Locals**, **E**
expression watches and MCP `evaluate_expression`, and reads the Python stack
through MCP `get_language_stack`. Everything comes from the stopped process's
memory: no code runs in the target, no `__repr__`, no `sys._getframe`.

Supported: Linux x86-64, little-endian, GIL (not free-threaded) builds of
CPython **3.14** final releases and the **3.16** development series. Other
versions and free-threaded builds are refused.

## Try the demo

```sh
scripts/demo-python
```

It attaches the GUI to `examples/python-demo.py`, whose nested functions keep
storing a fresh list into a dict. It needs a CPython with DWARF; the default is
`/opt/debug/bin/python3` (set `PYTHON=` for another). The store
`table[key] = items` is specialized to `STORE_SUBSCR_DICT`, which calls
`_PyDict_SetItem_Take2(mp, key, value)` on every iteration.

1. Press **Space**. xodb stops in `_PyDict_SetItem_Take2`; Locals show
   `mp` as `dict (2 items) (refcnt 2)` and `key` as `str 'answer' (refcnt 4)`.
2. **E** `value` **Return**: `list (8 items) (refcnt 2)`.
3. In a second terminal, `scripts/demo-python stack` prints

   ```
   Python 3.16.0a0 interpreter 0x55…: complete, anchored at native frame #1 _PyEval_EvalFrameDefault
     record       examples/python-demo.py:9
     tick         examples/python-demo.py:14
     <module>     examples/python-demo.py:21
   key = str 'answer' (refcnt 4)
   value = list (8 items) (refcnt 2)
       [0]: 17222
       [1]: 1180591620717411320646
       [2]: 3.25
       [3]: 'héllo'
       [4]: b'raw\x00bytes'
       [5]: None
       [6]: True
       [7]: tuple (2 items)
   mp = dict (2 items) (refcnt 2)
       'greeting': 'hi'
       'answer': list (8 items)
   ```

4. **Space** again: the next round; `[0]` is one higher.

`scripts/demo-cpython` is the older native-only demo (a break in
`list_ass_subscript`); this one adds the Python level.

`stack` is an observer client of the demo's shared session (a private socket
under `$XDG_RUNTIME_DIR`); it never resumes the target. Before the first
**Space** it shows wherever the attach stopped the loop.

## Named locals in the Python tab

Run `scripts/demo-python`, press **Space**, **Tab** to **Python**, select the
logical `tick` frame, then **E**, `round`, **Return**. Select `record` and enter
`items` to see its eight-element list. **Space** advances to the next store;
select `tick` again to read the new round. `E:` labels the expression result;
the matching named row says **expression result above**.

The lower pane lists fast locals, arguments, cells and captured free variables
for the selected activation. Empty cells and deleted/uninitialized names keep
an explicit reason. Recursion, active generators, resumed generators and
coroutines use that frame's slots. Module/class mapping locals report
`PythonMappingLocalsUnavailable`; globals and arbitrary expressions are not
looked up. A bare name is matched exactly, including UTF-8 names, without
normalization. Bounded builtin container subscripts are also supported (see
[Container paths](#container-paths)); attributes, calls, operators and execution
in the target remain unsupported.

Shared observers use the same reader without a controller lease:

```json
{"name":"get_language_locals","arguments":{"generation":7,"tid":1234,"language":"python","segment":0,"frame":1,"start":0,"limit":16}}
{"name":"evaluate_language_expression","arguments":{"generation":7,"tid":1234,"language":"python","segment":0,"frame":1,"expression":"round"}}
```

Use the generation, tid and logical segment/frame from your own stopped
session. `address` is the decoded value's PyObject address, or null for an
unbound slot or an immediate tagged integer. `slot_address` is its frame
stack-reference slot, including for a cell; for a container path it is the
current leaf slot within the container. Neither is stable after resume.
`hidden` marks a compiler local and `immediate` marks an integer without an
object. This is observation, not a hardware watchpoint or interpreter watch.

Names and kinds come from the code object's published `localsplusnames` and
`localspluskinds` offsets; the frame publishes `localsplus` and `stackpointer`.
The cell offset and normal GIL stack-reference representation are checked
against DWARF when present. Stackref-debug and free-threaded builds are refused.
Reads are bounded to 4096 names, 32 rows per page, 16,384 memory reads and 2 MiB;
value previews keep their existing limits. An incomplete name never matches a
shortened expression.

For the named-local oracle and MCP tests, use a matching interpreter with
development headers and its `python3-config`:

```sh
python3 tests/python-component.py --python /opt/debug/bin/python3 --work out/python-component
python3 tests/python-locals.py --python /opt/debug/bin/python3 --strace --work out/python-named
python3 tests/python-locals-shared.py --python /opt/debug/bin/python3 --work out/python-shared
python3 tests/python-locals-gui.py --python /opt/debug/bin/python3 --work /tmp/python-gui
```

The component and MCP tests also accept `--lua-source PATH` for a Lua 5.4
source directory. This builds an owned executable containing both runtimes and
checks Python → Lua → Python callbacks, including the suspended Python caller
and Lua locals. It needs the interpreter’s embedding library.

## Values

A pointer whose DWARF type starts with a CPython object head (`ob_type` at
offset 8, or `ob_base` leading to one) is shown by type:

| Object | Display |
| --- | --- |
| `None`, `True`, `False` | `None`, `True`, `False` |
| `int` | `int 42`, `int -1267650600228229401496703205381` (exact up to 28 30-bit digits, then `int <N bits>`) |
| `float` | shortest round-trip: `float 3.25`, `float 0.1`, `float 2.0` |
| `str` | `str 'héllo'`; ASCII, Latin-1, UCS-2, UCS-4 and non-compact (subclass) strings; at most 96 characters then `'... (N chars)` |
| `bytes` | `bytes b'raw\x00bytes'`, at most 128 bytes |
| `list`, `tuple` | `list (8 items)` and up to eight items |
| `dict` | `dict (2 items)` and up to eight `key: value` items (combined, Unicode-keyed and split tables; `{}` and cleared dicts show `dict (0 items)`) |
| `set`, `frozenset` | `set (3 items)` |
| a type | `<class 'int'>` |
| a code object | `<code Outer.inner>` |
| anything else | `<Foo object>` |

The summary is followed by `(refcnt N)` or `(immortal)`, except for freed or
invalid heads, whose refcount means nothing. Subclasses of int, str, bytes,
list, tuple and dict show their own name (`Color(int) 2`, `Text(str) 'sub'`); a
float subclass shows `<F object>`. Strings escape what `str.__repr__` escapes,
including NBSP, bidi controls, zero-width and other format characters, so
displayed text cannot be hidden or reordered. An `int` beyond the exact decimal
bound shows its exact bit length (`int <841 bits>`). Item keys and displays
that do not fit are cut on a character boundary and end in `...`. A child that
cannot be read carries its own diagnostic; the container and the other items
still display. MCP returns the details under
`value.visualization.python`: `type`, `display`, `refcount`, `immortal`,
`type_object`, the runtime version/build-id, and `items` with `key`, `type`,
`display` and a per-item `diagnostic`. Nested items are one level deep.

Values are checked, not trusted. A zero refcount is `freed object
(FreedObject)`; a non-zero `ob_overflow` (an allocator's free-list pointer over
the head) is `ObjectHeaderInvalid`; an `ob_type` that is not a type is
`ObjectTypeInvalid`. A builtin type missing its fast-subclass flag, a negative
size, an impossible dict table, a bad `str` kind or a 30-bit digit out of range
are marked `inconsistent … (reason)`. Unreadable memory gives
`MemoryUnreadable`. Every read is bounded.

## The Python stack through MCP

At a retained stop, with the TID and generation from `get_session`:

```json
{"name":"get_language_stack","arguments":{"tid":1234,"language":"python","generation":7}}
```

The tool is observer-readable (no controller lease). It returns `segments`.
Each segment has the runtime (`cpython`, version, build-id, layout basis), the
interpreter instance (an **address scoped to this process and stop**, its
interpreter id and thread state), its `frames` innermost first, and an
`anchor` naming the native frame index, PC and symbol of the interpreter loop
activation that runs those frames. Frames carry `name` (the code object's
qualified name), `file`, `line`, `code_kind` (`function`, `generator`,
`coroutine`, `async_generator`, `module`), `owner` and addresses.

### How segments are proved

Every `_PyEval_EvalFrameDefault` activation pushes an *entry frame* onto the
thread's frame chain, and that entry frame is a local variable on the
activation's own C stack. Walking the chain from the thread state, the Python
frames above each entry frame belong to the native frame whose `[sp, cfa)`
contains that entry frame. That containment is the anchor's proof, so:

- repeated activations of one interpreter split exactly: `coroutine.send()`, a
  generator's first (unspecialized) resume, `threading` bootstrap, callbacks
  from C each give their own anchored, `complete` segment;
- subinterpreters on one thread give separate instances, in native order;
- each thread is read from its own thread state (matched by native thread id);
- it works on stripped builds whose loop has no symbol: the anchor then has
  `symbol: null` and `interpreter_loop_symbol: false`.

A symbolized interpreter loop (`_PyEval_EvalFrameDefault`) that is not the
innermost one always has its entry frame on the chain; only the innermost can be
in its prologue or epilogue. When one has none, the chain skipped that
activation and its Python frames may be merged into the next outer segment, so
that segment becomes `partial` with `InterpreterLoopWithoutEntryFrame` and lists
the loop's native index in `unanchored_loop_frames`. With no outer segment (the
chain ends early, or the thread's current frame is unreadable) a trailing
unanchored `partial` segment carries the same reason. This holds for every
`frame` selection. On a stripped build such as `/usr/bin/python3` 3.14 the loop
has no symbol, so a skipped entry frame **cannot be detected** there; the
remaining anchors are still proved by containment.

Segments are ordered by anchor frame index. A segment whose entry frame is not
inside any recovered native frame is `partial` with
`EntryFrameOutsideNativeAnchors` (or `EntryFrameUnavailable`) and `anchor:
null`; it makes no ordering claim. `frame` selects the first native frame to
report (0–63); earlier activations still delimit the chain.

Line numbers come from the code object's location table at the frame's current
instruction, as CPython's own tracebacks compute them. A frame whose
executable is not a code object, whose instruction lies outside its code, or
whose name or file is unreadable keeps its place with a `reason`, and the
segment is `partial` (`PartialFrames`). A corrupt owner byte, a chain cycle or an
unreadable link ends the walk with that reason.

### Identity and versions

The reader uses CPython's published `_Py_DebugOffsets` (in `_PyRuntime`,
cookie `xdebugpy`). Before use, the loaded bytes of those offsets must equal the
image file's `.PyRuntime` initializer and the loaded GNU build-id note must
equal the file's; otherwise `PythonDebugOffsetsMismatch` or
`PythonBuildIdMismatch`. A few fields CPython does not publish (dict key table,
`co_flags`, compact `str` header size) come from a per-version table. When the
image has DWARF, every table entry and every published offset position is
checked against it (`PythonLayoutMismatch` otherwise). Development and
pre-releases must have that DWARF (`PythonLayoutUnverified`); a 3.14 final
release may be stripped, as `/usr/bin/python3` usually is: stacks and named
locals then work. Discovering Python object pointers among native C variables
still needs their DWARF types.
`PythonVersionUnsupported` and `PythonFreeThreadedUnsupported` refuse the rest.
Several different CPython images in one process are refused
(`PythonRuntimeAmbiguous`) rather than guessed.

### Bounds

Per call: at most 4,096 interpreter frames examined per segment
(`FrameExaminedLimit`); 128 frames retained per segment and 512 per call
(`FrameLimit`, innermost frames kept); 8 thread states for the thread, 64
interpreters, 4,096 thread states, 16,384 reads and 2 MiB read (the read cap is
the overall bound). Segments before `frame` are still walked, to delimit the
chain, but retain no frames, so a deep inner activation cannot starve the
segments you asked for. A whole-read failure (`SegmentLimit`, a read limit) is
reported as one trailing unanchored `partial` segment; segments proved before it
keep their own state. Names are
bounded to 255 bytes and paths to 1023; a path that does not fit is null, never
shortened. Code objects are validated once per call, so deep recursion costs
one header and one table read per frame (5,000 recursive frames: about 4,300
reads). The response reports `memory_reads`, `memory_bytes` and
`native_stack_incomplete`.

## Runtime watches

Run `scripts/demo-python`, press **Space**, choose **Python**, select **tick**,
then **Shift+E**, `round`, **Return**. **Space** reaches the next iteration.
Click a named binding and press **W** to watch its exact declaration instead.
The runtime WATCH pane shares its list with MCP; **Delete** removes a selected
watch and **[ ]** scrolls. C/C++ keeps its hardware watchpoint behavior.

The C reader resolves the interpreter, thread state, frame/code pair and binding
at each stop. Fast locals, parameters, cells and free variables use the same
validated storage rules as named-local reads, including immediate stackref
integers. A deleted or uninitialized variable stays unavailable and can recover.
No Python expression, descriptor, property or target function runs.

Comparisons use complete scalar samples, independently of truncated previews:
exact builtin `None`, bool, int, float, str and bytes. Integers compare canonical
sign/digits, so boxing alone does not change a value. Floats compare exact bits,
including signed zero and NaN payloads; this is not Python `==`. Strings compare
Unicode code points, including lone surrogates. The 4096-byte sample cap allows
1024 Unicode code points, 4096 bytes, or 1023 base-2^30 integer digits plus sign.
Subclasses, nonscalar results and oversized values have an explicit reason
and retain the last complete baseline; a preview is never treated as equality.

Matching a frame location and code object does **not** prove continuous activation
between stops: the demo's successive calls to `tick` are an example. The C result
and MCP `comparison` describe `same_slot_equal` or `same_slot_different`; the GUI
labels differences **DIFF (activation unproved)**. A frame proved absent from a
complete retained chain is permanently retired. Suspended generators and
coroutines are deliberately absent from that chain, so their watches remain
unavailable until observed again; remembered frame addresses are never followed.
Their close and reuse entirely between observations also cannot be proved.

At most 16 watches share the process's C comparison state, allocated as needed.
`add_language_watch` accepts `language: "python"`, generation, tid, segment and
frame, plus either a bounded `expression` or an absolute named-local `row` index.
Add/remove require the controller lease. `get_language_watches` returns cached
results to observers without a lease or target reads. Watches compare only when
execution stops and do not interrupt it automatically.

## Container paths

With a supported debug-built interpreter:

```sh
xodb --break builtin_print -- python3 examples/python-path-demo.py
```

Press **Space**, choose **Python**, select **main**, then **Shift+E**,
`state["player"]["score"]`, **Return**. **Space** reaches the next print and
**V** shows the changed score, even though its containing dictionary was
replaced. **E** reads the path once; **Delete** removes a selected watch.

C resolves the current fast-local/cell/free-variable root and each container
at every stop. A path is at most 128 UTF-8 bytes and four subscripts. Subscripts
are signed 32-bit integer literals or quoted printable ASCII strings, with no
escapes. Exact builtin dict, list and tuple storage is supported. Negative
sequence indices count from the current end. There is no attribute, descriptor,
property, method, slice, arithmetic or target-code execution.

Dictionary lookup scans every occupied entry within a 128-entry table cap;
scans over the cap refuse before accepting an early match. Deleted entry slots
also count toward this cap. String keys compare complete code points; integer
queries respect builtin int/bool/float equality. Unknown live key types, including
subclasses, refuse with `PythonPathKeyUnsupported`, even if another key matched:
an exact dict can otherwise invoke a custom key's equality method. An oversized
numeric key may also refuse under the scalar sample cap. Combined and split
storage use the verified runtime layout; counts and duplicate matches are checked.

A missing dictionary key is `PythonPathKeyNotFound`, never a fabricated `None`.
Out-of-range sequence access is `PythonPathIndexOutOfRange`. Subclasses or a
non-container intermediate value produce `PythonPathContainerUnsupported`.
Unsupported syntax returns `UnsupportedLanguageExpression` for both one-off
reads and watch creation, without occupying a watch slot. Incomplete memory
reads leave an unavailable value; an existing watch retains its last complete
baseline and can recover at a later stop. The
existing activation-continuity caveat still applies.

## Verification

```sh
scripts/build test -Doptimize=ReleaseSafe -j4
python3 tests/python-language.py --python /opt/debug/bin/python3 --python /usr/bin/python3 --work out/python-test
python3 tests/python-gui.py --python /opt/debug/bin/python3 --work /tmp/pg
```

Use new output directories; keep the GUI work path short for Unix sockets.
The build test runs `tests/python-reader.c` on a synthetic address space
(values, line tables, corrupted chains, cycles, deep chains and every single
failed read). The integration test cross-checks the reader's offset tables
with each interpreter's installed headers; runs nested calls, all value kinds,
generators, coroutines, 300- and 5,000-deep recursion, two threads and a
subinterpreter; corrupts heads and frames in the owned stopped child and
restores them; alters the published offsets and build-id to prove refusal; and
traces xodb with `strace` to show the reads issue no writes, resumes or
register changes. Stack tests stop in libc `getpid` (the fixture calls
`os.getpid()` after each store), which fires on any build; on a 3.14 built
with LTO `_PyDict_SetItem_Take2` is inlined and never stops.
