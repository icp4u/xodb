# Go value reader

The C value component reads interface dynamic types, channel state and map
entries from a stopped Go **1.27.1, Linux/amd64** image. Native locals,
expression watches and MCP previews use the same reader. Named locals inside
the Go tab, CGO and further inline-frame work remain separate follow-ups.

Try `scripts/demo-go`: **Space** reaches `main.marker`, **F10** passes its
prologue, then select **C/C++**. Press **E**, type `counts`, **Return**, then
**Return** again to expand the map's entries. Add `err` for its concrete
interface type, or `results` for channel len/cap/closed and queue counts.

For an explicit launch after building `examples/go-demo.go`:

```sh
mkdir -p .work
/opt/debug/bin/go build -o .work/go-demo examples/go-demo.go
xodb --break main.marker -- .work/go-demo
```

MCP uses the existing observer tools: `evaluate_expression` previews a native
expression; `get_value_children` returns up to 64 map entries or a concrete
interface's fields/elements. Use `start`/`limit` and retain `generation` for
every page; restart at zero after a resume. `raw: true` selects the native
DWARF fields. Expressions retain the native evaluator's syntax, including
`p->Field` for a pointer to a Go struct. Map lookup syntax and target method
calls are not added.

An interface holding a scalar or pointer has one child, `value`; an aggregate
expands directly to its fields/elements. Nil interfaces have no children.
A typed nil pointer displays its concrete type with `0x0`. Incomplete or
unsupported previews retain an explicit reason. A refused map/interface
expansion reports `GoMapPageUnavailable`/`GoInterfaceValueUnavailable`; query
the preview for its more specific reader reason.

`go_value_layout.c` builds an independent profile through the same bounded
DWARF walker as the goroutine reader. Required sizes, member offsets, scalar
encodings and interpreted constants come from the inspected image. Missing
value metadata does not disable the goroutine profile. The caller must verify
the version, architecture, loaded-image identity and stopped generation before
using the layout. The supplied build identity is retained with the profile.
There is no offset fallback for stripped or incompatible images.

The runtime definitions used are the Go 1.27.1 source files:

- `src/internal/abi/type.go`: `Type`, `Name`, `TFlagDirectIface`, `TFlagExtraStar`.
- `src/internal/abi/iface.go` and `src/runtime/iface.go`: `ITab`, interface words,
  and runtime-created itabs.
- `src/runtime/chan.go`: `hchan`, ring indices, wait queues and timer semantics.
- `src/runtime/runtime2.go`: `sudog`, `maybeTraceableChan` and mutex state.
- `src/runtime/symtab.go`: each loaded module's `[types, etypes)` section.

The installed toolchain's source is authoritative for this version. In this
version, direct interface storage is a **TFlag**, not the old kind bit. The
reader checks it against `Size_ == PtrBytes == 8`. A direct result points to
the interface's data word; an indirect result points to the value storage.
A captured register/composite interface supplies its header bytes directly;
a direct value preserves those bytes without inventing a target address.
A typed nil pointer is therefore distinct from a nil interface.

Non-empty interfaces corroborate `ITab.Hash` with `Type.Hash`, check that the
interface type has interface kind and require a nonzero first method entry.
Runtime-created itabs can deliberately store a zero hash; when that cannot
corroborate the type, the result is `GoInterfaceHashUnproved`. Types created
by reflection outside module type sections return `GoRuntimeTypeUnmapped`.
Type names longer than 159 bytes return `GoTypeNameLimit`. These are explicit
limitations, not nil values. No method or reflection operation is called in
the target.

Channel results report len/cap/closed, element type, ring indices and the
number of linked send/receive queue entries. Entries participating in select
are counted separately. These are **physical queue entries**, not a claim
about the number of unique goroutines or which select branch will win.
Checks include len/cap/index agreement, element size, queue backlinks,
channel membership, repeated nodes and a final header re-read. A held channel
lock returns `GoChannelBusy`; a timer channel returns
`GoChannelTimerUnproved` because its logical len/cap can differ from its
physical buffer.

Each call is capped at 8,192 reads and 1 MiB. Module traversal is capped at 64
records. Each direction of a channel queue is capped at 256 entries; reaching
that cap preserves a verified header and bounded lower counts with
`GoChannelWaitLimit` and `waits_complete == false`. Other channel failures do
not publish valid header/count flags. Callers must honor reasons and validity
flags, and use a fresh reader budget for each value.

Tests use an optimized owned Go fixture with `reflect.TypeOf`, `len`, `cap`
and `runtime.Stack` oracles. A GDB-hosted bridge calls the C reader through a
read-only memory callback with target calls disabled. The test compares all
DWARF offsets with GDB's independent type reader, tests missing/stripped
metadata, and can audit the observer interval with strace. The C synthetic
suite tests malformed headers, stale reads, bounds and a deliberately wrong
result under NDEBUG and sanitizers.

```sh
python3 tests/go-values-component.py --work .work/go-values-component
python3 tests/go-values.py --go /opt/debug/bin/go --strace --work .work/go-values
```

The component test is in release-check; the live oracle runs in the host/all
lanes when `--go` is supplied. The goroutine and value C unit checks also run
with `scripts/build test-go` and the regular build test step.

## Map enumeration

`go_map.c` enumerates stored slots in Go 1.27.1 Swiss maps. Its independent
map profile requires the image's own MapType/Map/table DWARF definitions and
constants. It uses MapType's stored KeysOff/KeyStride and ElemsOff/ElemStride,
so both `mapsplitgroup` and `nomapsplitgroup` layouts work. GroupSize must
match Group.Size_; indirect flags must agree with key/element size; all slot
spans must stay inside the group without overlapping.

Small maps use one group. Larger maps use a bounded directory of tables;
local depth, first index and contiguous duplicate directory entries must
agree. Each table's occupied/deleted controls are corroborated with its used,
capacity and growthLeft counts, then the total with Map.used. The eight control
bytes at the start of each group are a versioned ABI fact from
`src/internal/runtime/maps/group.go`; the live oracle also checks this prefix
in every concrete typed group DIE. The other algorithm sources are
`src/internal/abi/map.go` and `src/internal/runtime/maps/{map,table}.go`.

The result is a page of key/value storage addresses with runtime type metadata,
not a target evaluation. No hash is computed or checked, no equality method is
called, and NaN entries remain separate. A write-in-progress marker, malformed
metadata, changed group/table/directory/header, count mismatch or exhausted
budget refuses the page rather than reporting missing entries. Indirect
pointers are validated for null/overflow; the later value preview must still
check that the actual key/value bytes are readable.

Pages hold at most 64 entries in physical order. Start/next cursors apply only
to one stopped generation and must be reset after a resume. Every page scans
the bounded map to corroborate counts; this is intentionally uncached and can
cost many read callbacks on an agent transport. No transport performance claim
is made yet. The limits are 2,048 directory entries, 2,048 groups and the shared
8,192-read/1MiB value budget. Only the actual directory is allocated (two copies
for a final re-read, at most 32KiB), not the whole cap for each map.

```sh
python3 tests/go-maps-component.py --work .work/go-maps-component
python3 tests/go-maps.py --go /opt/debug/bin/go --strace --work .work/go-maps
python3 tests/go-maps.py --go /opt/debug/bin/go --experiment nomapsplitgroup --strace --work .work/go-maps-interleaved
```

The synthetic checks are always registered. Split-layout live tests are in the
host/all lanes with --go; interleaved-layout tests are in periodic with --go.
Both are required when changing the map reader. Tests prove that they observed
the intended group layout, deleted controls and multiple tables, compare every
paged pair with Go's MapRange oracle, and reject a planted wrong value.


## Runtime type identity

The C type index resolves `DW_AT_go_runtime_type` offsets to actual DIEs from
the same image. Go encodes this extension as DW_FORM_addr, but its linker
value is **section-relative**, not a loaded address. The adapter corroborates
`runtime.types`/`runtime.etypes` with the C reader's module range, then checks
size and kind. Names alone never choose a type. Conflicting DIE identities
for one offset report `GoRuntimeTypeMetadataAmbiguous`; missing offsets report
`GoRuntimeTypeMetadataUnavailable`. Typedef aliases of the same DIE agree.
External Go modules/plugins are not matched to the main image's metadata.

The index is lazy and owned by its debug image, with at most 65,536 entries,
16,384 compilation units and eight million visited top-level DIEs. Storage
grows with actual entries. Value/map layout profiles are allocated only when
used and released with their module.

```sh
python3 tests/go-type-index.py --work .work/go-type-index
python3 tests/go-native-values.py --go /opt/debug/bin/go --strace --work .work/gnv-local
python3 tests/go-native-values.py --go /opt/debug/bin/go --agent zig-out/bin/xodb-agent --shared --strace --work .work/gnv-agent
python3 tests/go-native-values-gui.py --go /opt/debug/bin/go --work .work/input-gnv
```

These tests are registered in the component, live local/agent/shared, and GUI
lanes. The optimized fixture records Go's values before two stops; tests
compare every map pair, interface scalar/field, nil distinction, channel state
and register-composite interface. A second stop changes values and invalidates
the old generation. Read-only intervals preserve registers and are audited
for target writes/resumes/signals. The independent small DWARF images exercise
aliases, conflicting type offsets and malformed metadata under NDEBUG and
sanitizers, with a planted wrong result that must fail.
