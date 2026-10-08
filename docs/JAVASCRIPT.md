# JavaScript at a native stop

Run `scripts/demo-node`, press **Space**, then **E**, enter `value`, and press
**Return**. Each **Space** reaches another native probe with a number, string,
array, object, class instance or function. In another terminal,
`scripts/demo-node stack` prints the physical JavaScript frames and readable
value elements.

The demo needs Node, its matching development headers, a C++ compiler, and a
built GUI xodb. Set `NODE`, `NODE_INCLUDE`, `CXX` or `XODB` to override them.
Like the Lua, Python and Perl demos, it chooses `XODB`, then this checkout's
`zig-out/bin/xodb`, then `xodb` on `PATH`. It prints the resolved executable and checks that its MCP
schema advertises the JavaScript reader before starting Node. An old checkout
binary can otherwise show `UnsupportedType` for `Local<v8::Value>` even when
a newer installed binary works. Rebuild or set `XODB` to the current executable.
It compiles `examples/node-probe.cc` with DWARF into a private temporary
session directory, runs only `examples/node-demo.js`, and removes its probe
on exit. It does not install anything or modify Node.

## Verified layouts

The initial reader supports Linux x86-64, uncompressed pointers, sandbox off,
and V8 **14.6.202.34-node.28** (Node **26.8.2**). It compares the loaded build-id,
version string and published `v8dbg_*` constants with the identified ELF image.
It selects the main executable using the kernel's program-header address;
the supported Node build embeds V8 there. An unrelated addon that exceeds
the full-image limit does not disable previews. Split-library V8 runtimes
and targets without that main-image evidence remain unsupported.
Missing, inconsistent, ambiguous or unsupported metadata produces a diagnostic.
It never chooses the closest version.

Some offsets are absent from the published metadata. Their exact-version table
in `src/language/javascript_v8_14_6.h` cites the upstream Node tag and V8 source.
Same-image DWARF constants, when available, are checked before using that table;
any disagreement refuses the layout. Outputs identify `postmortem-metadata`,
`version-table`, or `version-table+partial-dwarf-crosscheck` as their layout source.
The `dwarf_fields` mask reports which supplemental table fields were observed;
fields without a DWARF fact still use the exact-version table. A partial
cross-check does not certify every offset used by a value or frame.
An incomplete DWARF check also refuses, preserving its work, unit, depth or
malformed-data reason; it is not reported as a layout mismatch.

Frame code identity also needs configuration-dependent builtin and dispatch
facts. These are currently established by either the required same-image DWARF
constants or the tested stock build-id
`93f82af1eac24ff5123595e6669572c93421c436`. Another build can show independently
verified names and scripts but gets `JavaScriptFrameConfigUnavailable` and null
positions until its configuration is proved. The Node executable does not need
DWARF for the tested stock profile; the native variable's owning addon does
need DWARF to prove its V8 handle layout.

## Context storage in the JavaScript pane

Run `scripts/demo-node`, press **Space**, choose the **JS** tab, and select an
interpreted frame `inspect` to see its retained `value` and `round` parameters.
Native V8 objects appear above **CONTEXT
STORAGE**; click the native-section header to collapse or expand it. Scroll over
the context rows to browse captured parameters and variables; each row includes
its context depth. Contexts are ordered nearest first; slots keep their runtime
order within each context. Even a one-row viewport advances without skipping
bindings. "No mapped native image" means the selected native anchor has no
usable mapped image for native variable inspection; the separately proved JS
context rows remain available. The pane retains at least three stack rows at normal window
sizes.

This is **context storage — lexical visibility unproved**. Retained ScopeInfo
names describe storage, but a block-scoped variable can shadow a same-named outer
context slot. For example, a context may hold `captured = 41` while the active
block's `captured` is 99. The displayed context row does not resolve that source
expression. Stack-only locals and parameters are **not shown**: V8 does not
retain their complete name/register map here. **E**, `captured`, **Return** in
the JS pane gives `JavaScriptLexicalUnproved`; it never guesses an outer value.
Native **C/C++** expressions such as the demo's `value` remain available in the
native pane.

`get_language_locals` with `language: "javascript"`, a current generation, thread,
segment and logical-frame index returns `view_kind: "context_storage"`, the
lexical limitation and per-row depth, context address, slot address and storage
provenance. It is an observer read. `start` and `limit` page at most 32 rows per
call, through at most 64 contexts and 4096 bindings, under the shared read/byte
budget. Memory reads batch into a bounded cache (8 KiB of data plus address tags)
created for each stopped inspection and discarded afterward. Counters include speculative reads and
failed attempts; a failed batch falls back to the exact requested bytes.
Addresses belong only to the retained stop: moving GC requires resolving
the frame and storage again after resume.

The initial implementation reads proved interpreted frames, function/block/catch
and class contexts, captured parameters, and supported context-cell values.
Optimized or unproved frames, dynamic/eval/module scopes, detached cells,
unsupported name tables (75 or more bindings in one scope), malformed bounds
and read failures report explicit reasons. Script/native contexts end the chain.
An unproved frame configuration also prevents context inspection even when its
name and script can be displayed: `get_language_locals` returns
`JavaScriptContextFrameUnproved`. The physical stack explains the underlying
missing proof with `JavaScriptFrameConfigUnavailable`. No target code is executed to recover names or
values.

## Values

Locals and expression watches recognize V8 `Local<T>` and internal `Tagged<T>`
only when their namespace, size and single-word handle representation are
proved by DWARF. Previews include smis, heap numbers, booleans, null, undefined,
strings, fast arrays, fast in-object data properties, function names and
proved constructor names. A base constructor's name is not substituted for a
subclass: its initial map must match the receiver's root map and the receiver's
prototype must still match that initial map. Otherwise the preview uses `Object`
with `JavaScriptConstructorNameUnproved`. When a field also has a reason, the
name advisory remains separately available as `name_diagnostic`; the field
reason remains visible in the summary and on its item. Ordinary object literals retain the
generic `Object` name when their copied map's constructor and prototype agree;
that alone adds no diagnostic. Strings handle
sequential, cons, sliced, thin and cached
external one- or two-byte representations. Uncached external strings refuse
because recovering their data would require calling a virtual method.

Each preview keeps at most eight elements, three aggregate levels and 128
UTF-16 string units. Control characters and invisible formatting characters are
escaped. Dictionary properties, out-of-object and boxed double fields, and
unsupported object kinds carry diagnostics. A child failure stays on its item
so independently decoded siblings remain visible; exhausting the shared read
budget still stops the preview. Double arrays distinguish the verified hole
encoding from `NaN`. Boxed holes remain item-local unsupported objects when
their type is not available in the published metadata. Accessors are identified and
never invoked. There is no `toString`, coercion, getter or inferior call.
The optional undefined-double encoding is refused because its build option
is not proved by the exported metadata.

Malformed maps, failed reads and inconsistent bounds are explicit failures.
A readable, consistent heap header is not proof that an object is still live;
this interface makes no garbage-collector liveness guarantee, and the MCP
basis states that explicitly. Sequential-string value previews also check that
the claimed aligned end reaches another readable object header. A failure adds
the advisory `JavaScriptStringExtentUnproved` while preserving the bounded
preview: valid large strings and fresh allocations need not have a following
object. Payload reads use at most the claimed length and the 128-unit preview
limit, and truncation is marked. Items retain an independent `truncated` flag
and a visible ellipsis even when another diagnostic is present. A
plausible following header is only a consistency check, not an independent
proof of the allocation extent; stale or consistently corrupted heap data
can still pass it.

The GUI dims and labels a preview whose extent check raised an advisory,
including a container with an affected child. No exact safe byte boundary is
known, so it conservatively marks the whole preview rather than inventing a
proved prefix. MCP exposes `extent_advisory`; false does not certify an extent.
A corrupt length whose claimed end lands exactly on a later valid header can
still show neighbouring bytes without this advisory. Property-key, function-name
and script-name strings are bounded but do not perform this extent check.

## Physical JavaScript stack

An observer can call:

```json
{"name":"get_language_stack","arguments":{"tid":1234,"language":"javascript"}}
```

Use a thread ID from `list_threads`. The result has a generation and segments,
each anchored to a retained native-unwind V8 API-exit frame. Frames carry name,
script, line, column, kind, raw frame pointer and PC, plus a partial reason when
needed. Positions come from bytecode or verified active Code source tables.
They are never replaced by a function's declaration line.
The optional `frame` argument is the first native frame to search for an
anchor, not a logical JavaScript frame index. Nameless eval scripts may retain
proved line/column values with `file: null` and an explicit name diagnostic.

The reader follows at most 256 frame links and retains at most 64 JavaScript
frames. It stops at a V8 entry boundary, so the segment remains `partial` with
`JavaScriptEntryBoundary`. Optimized code that has changed, baseline position
encodings not yet supported, and unresolved inline positions retain null
line/column values with reasons. Async causal frames are not reconstructed;
only the physical stopped stack is reported.

Every operation has an 8192-read and 2 MiB memory budget. Source-position tables
are capped at 16 KiB, and source scanning is bounded. Deep stacks and large
sources may therefore return partial results. Reading does not resume the
target or change registers.

## Checks

`scripts/build test -Doptimize=ReleaseSafe -Dgui=true -j1` includes the synthetic
memory and DWARF tests. Run the owned live fixtures explicitly:

```sh
python3 tests/javascript-language.py --node /usr/bin/node
python3 tests/javascript-gui.py --node /usr/bin/node --work .work/node-gui
```

The GUI check creates a private headless compositor. Pass `--include DIR` for
matching headers when testing a different Node build. A selected unsupported
runtime is a failed check, not an automatically skipped success.
The live fixture compares each proved position, including frame zero, with
V8's own stack captured at the native call site. It covers a proved TurboFan
position and a genuinely inlined call whose physical frame must keep a null
position. It also loads an owned sparse 300 MiB library to check that unrelated
large files do not disable the reader.
