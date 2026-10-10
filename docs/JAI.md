# Jai runtime type information

The C layout detector and static type reader recover metadata without debug
symbols from bounded, immutable read-only image ranges. A C value reader consumes
that graph and an exact-read callback for a retained stop. Generic runtime-type MCP tools expose the graph and typed values. Native expressions and watches accept a trailing `as TypeName` preview. A
language tab, object search and writes remain future work. Check
the C components with
`scripts/build test-jai-layout test-jai-reader test-jai-value test-jai-job`.
The fixture reports its own C `sizeof` and `offsetof` values; the reader must
recover those values from synthetic runtime metadata.

## Evidence and supported profile

Profile **jai-rtti-le64-v1** is a little-endian, 64-bit bootstrap family. It was
corroborated against runtime self-description in one private image, then encoded
in an independent synthetic fixture. No compiler version has been established,
and this is not a promise that all Jai releases share the layout. Other byte
orders, pointer widths, missing type tables and incomplete self-description
produce a typed refusal. No captured image bytes or application names belong in
fixtures or this document.

Some seed information is unavoidable: finding a self-description requires
reading its initial name and member records. The detector makes those assumptions
explicit, checks the runtime's own enum values, then requires the self-description
to agree with the seed. It searches for the members-array offset and member
stride instead of assigning the observed 64-byte values to every image.

| Seed record | Bytes / offsets | Corroboration |
| --- | --- | --- |
| Common header | tag u32 at 0; runtime size s64 at 8; extent 16 | Type_Info's named members and their type widths/signedness |
| Struct/enum name | string at 16 | Struct's own `name` member; enum is a seed encoding |
| string / view | count s64 at 0; pointer at 8 | string's stored runtime size 16; member-list bounds and self-description |
| Member prefix | name string at 0; type pointer at 16; instance offset s64 at 24 | Type_Info_Struct_Member's named members |
| Array type | element type pointer at 16; kind at 24 (low 16 bootstrap bits) | members' array points to Type_Info_Struct_Member with the recovered stride; kind 1 is the view seed; the graph reader checks Array_Type and uses its stored width |
| Enum type | underlying type pointer at 32; names view at 40; values view at 56 | unsigned u32 underlying type, equal counts, all expected stored tag/flag values |
| Enum entries | names are 16-byte strings; values are 64-bit slots | two independent enum tables: tags and member flags |
| Integer type | signed bool at 16 | metadata instance offsets and runtime sizes require signed 64; enum bases require unsigned 32 |

The four bytes at header offset 4 are **uninterpreted**. They are not a proved
identifier, version or hash. They are deliberately varied in the fixture.

The required stored Type_Info_Tag mapping is:
`INTEGER=0 FLOAT=1 BOOL=2 STRING=3 POINTER=4 PROCEDURE=5 VOID=6 STRUCT=7
ARRAY=8 OVERLOAD_SET=9 ANY=10 ENUM=11 POLYMORPHIC_VARIABLE=12 TYPE=13 CODE=14
UNTYPED_LITERAL=15 UNTYPED_ENUM=16 VARIANT=18`.
A missing, duplicate or changed value refuses the profile. This check uses the
actual enum value table, not just a nearby string pool.

## Recovered layouts

These are the observed offsets, not unconditional parser constants. The detector
returns the offsets and record sizes recovered from that image. A synthetic
variant moves `members` to 72 and increases the member stride to 72; it must still
work and have a different schema fingerprint.

| Type_Info_Struct member | Observed byte offset | Stored type |
| --- | --- | --- |
| info | 0 | Type_Info, size 16 |
| name | 16 | string, size 16 |
| parameters | 32 | array view, size 16 |
| specified_parameters | 48 | array view, size 16 |
| members | 64 | array view of Type_Info_Struct_Member |
| tagged_union_bindings | 80 | array view, size 16 |
| status_flags | 96 | enum, size 4 |
| nontextual_flags | 100 | enum, size 4 |
| textual_flags | 104 | enum, size 4 |
| alignment | 108 | integer, size 4 |
| polymorph_source_struct | 112 | pointer, size 8 |
| initializer | 120 | procedure, size 8 |
| constant_storage | 128 | array view, size 16 |
| notes | 144 | array view, size 16 |

Observed struct runtime size:160. Every required field must have its stated
category and width, fit the record and not overlap another required field.
The layout detector alone does not prove other array element types or procedure
signatures. The graph reader validates each referenced type separately.

| Type_Info_Struct_Member member | Observed byte offset | Stored type |
| --- | --- | --- |
| name | 0 | string, size 16 |
| type | 16 | pointer to Type_Info, size 8 |
| offset_in_bytes | 24 | signed integer, size 8 |
| flags | 32 | enum, size 4 |
| notes | 40 | array view, size 16 |
| offset_into_constant_storage | 56 | signed integer, size 8 |

Observed member runtime size:64. The member schema also contains a **constant**
named Flags. Its instance offset is -1; it is not an instance field and must not
be rejected merely because that offset lies outside the record. The old
prototype's blanket `offset <= runtime_size` check incorrectly discarded it.
The flag enum supplies CONSTANT, IMPORTED, USING,
PROCEDURE_WITH_VOID_POINTER_TYPE_INFO, AS and OVERLAY. The detector reads their
values, requires distinct single bits, and uses the stored CONSTANT value when
checking bounds. Nonconstant fields must fit; required fields cannot be constants.
The type reader expands USING/AS struct fields and retains a bounded constant
storage address for each proved constant.

## Detection and identity

1. Validate sorted, nonoverlapping read-only ranges: at most 128 ranges and 64 MiB
   total. Addresses and lengths must not wrap. The caller supplies relocated
   virtual addresses and immutable bytes; the detector does no file or target IO.
2. Scan aligned candidate headers for exact Type_Info_Struct and Type_Info_Tag
   names. Exactly one of each is required. Pool strings alone are insufficient.
3. Check the tag enum's actual name/value pairs and underlying integer type.
4. Search members-array offsets 32..496 and member strides 32..256, in steps of 8.
   Lists are capped at 64 members during bootstrap. Require a unique solution
   consistent with the self-descriptions of the struct, member and common header.
5. Check member flags against their own enum, constant-vs-instance placement,
   pointer backreferences, data-field bounds and the required scalar widths.
6. Return the layout and a diagnostic schema fingerprint. Failure clears output.

The version key is **profile + schema fingerprint**, paired with the exact image
identity by the caller. The fingerprint is FNV-1a over little-endian 64-bit words:
profile, struct size, member stride, struct offsets in enum order, member offsets
in enum order, member flag values in enum order, and the checked tag values above.
It excludes addresses, so relocation cannot change it. It is not a cryptographic
image identity. Never reuse it as an address-space or lifetime key.

No stored layout hash is identified in this profile. Therefore there is no
hash comparison to claim. The proof is agreement with the stored member offsets,
widths, references and enum values. If a future profile identifies a stored hash,
it must corroborate that value before interpreting data; a mismatch must be an
explicit refusal, never a missing value.

Reasons include JaiInvalidImage, JaiImageLimit, JaiLayoutUnavailable,
JaiLayoutAmbiguous, JaiTagTableUnproved, JaiTagValueMismatch and
JaiSelfDescriptionUnproved. A later graph reader may preserve independently
validated types alongside per-record reasons. The bootstrap itself is all-or-none.

## Static type graph

`xjai_graph_build` first validates the layout, then scans for struct and enum
roots and follows references with an append-only queue. Recursive pointers are
represented by indices, not recursive C calls. Strings and rows are copied into
owned, demand-grown storage; the input bytes are not retained.

The reader covers integers with signedness, floats, bool, string, void, Type,
Any, pointers, structs, enums and fixed/view/resizable array metadata. Names are
bounded UTF-8 without control characters. Structs retain their original name,
polymorph-source reference and specified parameters, including constant storage
locations. It does not invent a unique expanded name when several instantiations
share a name. Resolve by type-record address until a later interface explicitly
checks name ambiguity.

Array_Type's stored enum values must prove FIXED=0, VIEW=1 and RESIZABLE=2. Its
underlying integer can be unsigned 16 or unsigned 32; the reader uses that width
at the array record's offset 24 and ignores adjacent padding. Fixed counts are
checked against element size and total runtime size. Views require size 16;
resizable arrays require size 40 in this profile. The latter proves metadata
shape only, not the live allocator/header interpretation for container walking.
The struct `alignment` field may be -1 (unspecified); otherwise this reader
requires a power of two up to 4096, consistent with the runtime size. It never
turns the unspecified sentinel into an inferred alignment.

A tag/name match alone is not a root. Root recognition requires bounded metadata
arrays, plausible alignment and corroborating names/flags in the first eight
member rows. Enum roots need a compatible integer base and matching name/value
counts. Rejected named candidates are counted as `rejected_candidates` and make
the result partial; they may be ordinary data resembling metadata, so they are
not advertised as types. A damaged unreferenced record may be among them.
Referenced damaged records have their own typed reasons. Later member damage
also remains explicit, preserving the other members of the struct.

`xjai_fields_flatten` expands USING struct members, including AS bases, by adding
stored offsets. It skips constants and compiler-imported duplicates. Every row
retains its member path: two equal leaf names are not collapsed. Recursive using
cycles, depth 16, output capacity and a 65536-member work limit return typed
reasons along with any already validated prefix. Procedure/variant metadata and
other unimplemented categories remain explicit `JaiTypeCategoryUnsupported`
records; a pointer to an unsupported target still preserves its own pointer shape.

Hard caps are 16384 types, 65536 members, 65536 enum values and 8 MiB copied text,
with smaller caller limits supported. Individual struct tables allow 4096 members,
parameter tables 256 and names 1024 bytes. Beyond the initial 64 MiB image scan, the
graph reader allows at most 1048576 bounded reads/128 MiB cumulative read bytes.
Budget exhaustion is `JaiReadBudget`, never a complete result. All collections
grow as needed. Fatal argument/bootstrap/allocation failures return no graph;
capacity limits or damaged records return a partial graph with reasons.

The fast reader fixture checks C sizeof/offsetof, recursive pointers, negative
enum values, three array kinds, polymorph parameters, constant offsets, nested
base fields, same-name distinct types, 300-type storage growth, string-pool decoys,
corrupt references/offsets and smaller caps. Its wrong-value oracle must abort
with NDEBUG. `tests/jai-reader-fuzz.c` mutates only synthetic metadata and belongs
to the periodic lane.

## Typed value component

`xjai_value_read` reads an explicit type-record index and address through the
caller's exact-read callback. The caller must hold a stopped target generation
and use the same image identity as the type graph. The C component has no session
or transport of its own. It executes no target code and performs no writes.

Scalar rows carry exact integer/float/pointer bits and an explicit `has_bits`;
unreadable rows never present an invented zero. Narrow signed values are extended
to 64 bits. Enums retain numeric bits plus a matching enumerator name when present.
A Type field reports the referenced type-record index. String previews retain
byte length, including embedded NUL or invalid UTF-8, for the presentation layer
to escape correctly; the bytes are not assumed to be C strings.

Struct fields and fixed/view arrays expand into parent-indexed rows. Constants
and compiler-imported duplicate members are omitted from instance previews.
Root aggregates page with start/limit; nested aggregates start at 0. The depth
limit, paging and 128-byte string preview mark truncation. A damaged member gets
its own reason and no invented field address. Recursive pointer traversal is
opt-in and detects repeated type/address pairs. Resizable headers use the
profile documented below. Any payloads remain unsupported; their static types
are still available.

`xjai_self_type` follows an explicitly selected member whose type is Type. It is
not a heuristic based on names such as entity_type. The referenced type must be
a validated struct equal to the declared type, or contain it at offset 0 through
USING fields. Unknown pointers, incompatible types and bounded traversal failures
are distinct refusals. The call shares the caller's read budget.

Per read: at most 512 exact callbacks, 64 KiB cumulative bytes, 256 rows, depth 8 and
64 children per aggregate page. Address/count/size arithmetic is checked before
calling the backend. Rows grow from 16 as needed. Fatal argument/allocation errors
return no result; unreadable/unsupported/cyclic values return partial rows and
reasons. The session adapter checks the captured session, image epoch and stopped
generation before live reads and checks the stop again afterward.

The fast value fixture checks native C fields in its own memory and in its owned,
ptrace-stopped child, then verifies that reads after child exit are unavailable.
It covers exact bits/addresses, float bits, nested fields, pages, cycles, raw string
bytes, explicit self-typing, incompatible/unknown Type pointers, row/read budgets
and address overflow. Its wrong signed-value oracle fails before creating the
child. `tests/jai-value-fuzz.c` mutates value bytes/pointers within explicitly
owned spans and belongs to the periodic lane.

## Next integration

The C reader owns interpretation; Zig presents results through a generic
runtime-type-info provider with Jai as its first provider. UI, typed watches,
instance search and container walkers follow these components. A later typed-write path requires mutate scope and the controller lease,
with value validation, readback, audit and undo. No writes exist in these components.

The layout fast tests cover the synthetic offsetof/sizeof oracle, relocation,
changed layout, constants, wrong tag values, corrupt offsets/counts/pointers,
duplicate roots and split/overlapping ranges. `--wrong-oracle` deliberately expects
the wrong struct size and must fail even with NDEBUG. The periodic libFuzzer
layout target is `tests/jai-layout-fuzz.c`; it mutates only synthetic data. A Jai
compiler fixture and an ELF/PE file importer remain future work. The live adapter
currently consumes relocated bytes captured from the stopped process.


## Runtime-type MCP workflow

Start a stopped session with `xodb --headless --mcp --agent-scope control -- ./app`.
Choose complete read-only ranges containing its RTTI and pooled strings from
`list_modules`. Capture them at the current `get_session` generation using
`capture_memory`. The type loader accepts up to 16 snapshot IDs, 32 MiB total,
all from the same session, image epoch and stopped generation. Overlapping,
incomplete or writable captures are refused. No target code is executed.

The following are MCP tool argument examples; replace the example generation,
snapshot ID, context ID and address with those returned by your session:

```json
{"provider":"jai","generation":42,"snapshot_ids":[1, 2]}
```

Pass that to `load_runtime_types`, then poll `list_runtime_types` with
`{"id":1,"start":0,"limit":64}` until its state is `ready` or `failed`. A ready
graph can be partial; inspect the reasons and rejected-candidate count. Discovery
runs on a bounded C worker. There are four retained contexts per session and at
most two active workers, 64 MiB copied input and 64 MiB retained graphs per xodb
process. Limits are caps; storage grows with the result. Releasing a pending
context returns immediately; its worker finishes and frees its own resources.

`get_runtime_type` accepts either an exact `type_address` hex string or a unique
`type_name`, for example `{"id":1,"type_name":"FixtureObject"}`. Duplicate names
are refused. Members and enumerators use `start`/`limit`; specified parameters
have a separate `parameter_start` cursor. Results preserve constant storage
addresses, `using` flags, polymorph source records and metadata refusal reasons.

Read a live value with `read_runtime_value`:

```json
{"id":1,"generation":42,"type_name":"FixtureObject","address":"0x12340000","depth":3,"start":0,"limit":32,"follow_pointers":false}
```

Rows form a tree through their `parent` index. Addresses, offsets and integer,
float and pointer bits are exact hex strings. `preview_hex` preserves raw string
bytes, including NUL and invalid UTF-8. Missing values have a reason and null bits;
they are never represented as zero. Pointer traversal is opt-in. An optional
`self_type_field`, such as `entity_type`, must name a direct Type member. The
referenced struct must pass the C reader's equal/base-prefix compatibility check.
Other threads can change mutable values during these external reads.

After execution or image replacement, static list/get results remain available
with `stale:true`; live value reads refuse the old context. Capture and load again
at the new stop. `release_runtime_types` accepts `{"id":1}`. Observers may load,
read and release their own derived contexts from existing captures. Only the
controller may evict or release another client's context. Capturing target memory
still follows the existing controller requirement.

For a reproducible owned fixture, run
`python3 tests/jai-runtime.py --work .work/jai-live` after building xodb. Add
`--agent zig-out/bin/xodb-agent` for the runtime-agent path, or `--shared` to test
two observers and a controller. Its `oracle.json` records native `sizeof` and
`offsetof` truth. `--wrong-oracle` plants an incorrect signed value and must fail.
These are fast-lane tests; all target processes and metadata are synthetic.


## Native expressions and watches

After loading a runtime-type context at the current stop, use a trailing
`as TypeName` in the native expression editor, watches, `evaluate_expression` or
`get_value_children`. For example, `0x12340000 as FixtureObject` presents that
address using Jai RTTI. An existing native pointer uses its pointer value; an
addressable struct/array uses its storage address. A negative integer address or
an unavailable operand is refused. This is a preview suffix: nested casts,
arithmetic on the result and field syntax after the type name are not supported.
Expand or page the resulting children to inspect fields and array elements.

Names must be unique among current captured types. If several types share a name,
use the exact type-record address instead: `0x12340000 as 0x56780000`. Captures of
the same type-record address at one stop are coalesced, with the newest context
selected. A pending current discovery defers selection until uniqueness can be
checked. An unsupported layout or unreadable scalar shows a reason, never a
fabricated zero. Strings preserve embedded NUL and invalid UTF-8 through escaped
text or a hex preview.

In the GUI, press **E** to pin a watch to the selected native frame, or **Shift+E**
for a display that follows the selected frame. Enter the expression and press
Return. Press Return on a selected aggregate watch to expand it. A type context
that becomes ready at the same stop refreshes waiting watches. After continue,
the watch says that runtime types are stale. Capture/load the RTTI again at the
new stop; it then refreshes without re-entering the expression. Automatic metadata
recapture is not implemented. Existing frame/thread lifetime rules still apply.

An owned example after `python3 tests/jai-runtime.py --work .work/jai-live`:

```sh
xodb --break runtime_ready -- .work/jai-live/fixture .work/jai-live/manual.json
```

Continue to `runtime_ready` if needed. The fixture writes its object address and
read-only type range to `manual.json`. Load that range with the MCP workflow above,
then use E and the recorded object address followed by `as FixtureObject`.
`python3 tests/jai-runtime-gui.py` automates the watch workflow in a private display.


## Container storage and candidate checks

The C container reader pages fixed, view and resizable arrays, and occupied
`Bucket` slots. A bucket must have unique `occupied`, `data` and `count` fields:
RTTI supplies their offsets, element types and fixed lengths. Occupancy is a
fixed array of one-byte booleans. Every flag must be 0 or 1, and their sum must
match the stored signed 64-bit count before any page is returned. Physical slot
indices survive paging; inactive slots are omitted. The reader refuses packed
bitmaps, overlapping fields, inconsistent lengths and more than 16384 slots.

Resizable arrays use the documented little-endian 64-bit profile: a 40-byte
header, with count, data pointer and allocated element capacity in its first
three words. This is a profile assumption, not a discovered compiler-version
hash. It follows the Preload declaration reproduced in the
[Jai community array documentation](https://github.com/Jai-Community/Jai-Community-Library/wiki/Getting-Started#dynamic-arrays).
The validated RTTI array kind and size must agree, and the header must satisfy
nonnegative count/capacity, count <= capacity and checked address arithmetic.
Allocator words are never followed. Native previews and container enumeration
share this C decoder; an invalid header cannot become an empty array.

Each call returns at most 256 storage addresses, with shared live-read limits of
512 reads and 64 KiB. It allocates no heap storage. Values are read separately
with the existing typed-value API. Addresses and occupied flags describe sampled
storage; they do not prove allocation lifetime or rule out concurrent mutation.
`Table` occupancy and the outer `Bucket_Array` layout remain unproved, with
explicit refusal rather than guessing hash sentinels or bucket links.

A type-pointer search hit is also only a candidate. The C corroboration helper
requires an explicit direct `Type` field, subtracts its recorded offset, re-reads
the field and applies the compatible self-type check. Matching bytes may still
be unrelated storage. The MCP tools below retain the stopped generation and keep the candidate
distinction visible. The runtime browser below exposes the same readers in the GUI.

Run `scripts/build test-jai-container -Doptimize=ReleaseSafe` for the fast
synthetic `sizeof`/`offsetof` and value oracle. Its deliberately wrong value mode
is `--wrong-oracle`; it must fail rather than accepting 23 for the fixture's 22.


## Container and instance MCP tools

`read_runtime_container` accepts the same `id`, `generation`, type selector and
`address` as `read_runtime_value`, with `start`/`limit` paging (limit <= 64).
It returns occupied storage addresses, physical slot indices, element type
addresses and exact total/capacity hex strings. Read any returned element with
`read_runtime_value`, or enter its address followed by `as TypeName` in a native
watch. An unavailable container has null counts and a reason, never a false zero.

Start a search with `search_runtime_instances`. The range is explicit and capped
at 1 GiB, or given as `ranges` or a `regions` selector (optionally clipped by
`address`/`length`) exactly as for `search_memory` (see
[MEMORY_REGISTERS.md](MEMORY_REGISTERS.md)); `get_memory_search` pages its
per-range coverage. It uses the same incremental search job as `search_memory`, so normal
ownership, replacement and `cancel_memory_search` apply. This job requires the
controller. Choose the declared struct with `type_name` or `type_address`, and
name a direct `self_type_field` of type `Type`. Optionally provide an exact
`dynamic_type_address` to search for a derived type through a declared base:

```json
{"id":1,"generation":42,"type_name":"FixtureTypedBase","self_type_field":"entity_type","dynamic_type_address":"0x56780000","address":"0x12340000","length":4096}
```

The returned `id` is the memory-search job ID; `context_id` identifies the retained
RTTI. Poll or page `get_runtime_instances` with the job ID, generation, start and
limit. Observer clients may read these results and container pages. Starting a
search directly from observe scope or without the controller lease is refused,
even when bypassing the tools list.

`candidate_hit_count` counts raw matching words in the scanned range. Each row
re-reads and corroborates the explicit self-type field with the C reader; failed
checks retain the hit address with a reason and null candidate address. The compatibility traversal bounds both type visits and member inspections. Matching
words can be unrelated data, so `lifetime_proved` is always false. Results retain
running/cancelled/match-limit state, scanned bytes and unreadable bytes. A complete
search over a range containing holes is not complete coverage of that range.

Continuing or changing images makes live candidate/container reads stale.
Releasing the metadata context expires its search interpretation; replacing the
ordinary memory search expires the bound runtime search. Failed start arguments
do not replace a valid job. No metadata is recaptured automatically.

An owned example:

```sh
python3 tests/jai-discovery.py --work .work/jai-discovery
xodb --break discovery_ready -- .work/jai-discovery/fixture .work/jai-discovery/manual.json
```

At `discovery_ready`, use the metadata range in `manual.json` with the capture/load
workflow above. `bucket` is a `Bucket` with two occupied slots; `area`/`area_size`
contain two typed objects and one unrelated matching word. All three are labelled
candidates. Select `FixtureTypedBase` plus the `FixtureTypedChild` record address
for that search. Press E and enter a returned address followed by
`as FixtureTypedChild`, then Return to expand it. Only the two fixture objects
have ground-truth object identity; the tool deliberately makes no such claim.

The fast test also checks malformed counts, resizable previews, an unmapped hole,
nonzero self-field offsets, actual cancellation of a running search, observers,
replacement and stale stops. Add `--agent zig-out/bin/xodb-agent` or `--shared` for
those paths. It reserves a read-only anonymous 1 GiB virtual range to keep the
cancellation case active; it does not write 1 GiB or create a large file.


## Runtime browser

Press **Y** in the native debugger view. **L** opens a field for the read-only
metadata `ADDRESS LENGTH` (decimal or hex); Return captures that range and starts
background type discovery. The range must fit one memory capture (16 MiB).
For disjoint sections, capture/load them through MCP, then press **T** to select
the retained context. Names remain browsable after a stop changes; live values
and candidates clear with a stale reason. Use L again at the new stop.

**/** filters type names; an exact `0x` type-record address selects unnamed or
ambiguous types. Arrows select a type. **G**, an address, then Return reads it as
that type. The right pane shows an indented typed tree, with explicit unavailable
reasons. **Tab** cycles focus between types, candidates and values; arrows scroll,
and **[ / ]** page candidates by 64 or root fields/array elements by 16. A `...`
marks truncated children. Pointers are not followed. **Esc** closes the panel
(or cancels the input field first).

**S** accepts `ADDRESS LENGTH DIRECT_TYPE_FIELD [DERIVED_NAME_OR_ADDRESS]`.
The optional selector is a unique, case-sensitive type name or exact type-record
address in this context. It searches for that Type pointer through the selected
declared type. **X** cancels; Return opens the selected candidate. Counts are raw
candidate hits, not proved live instances. The panel shows scan state, unreadable
bytes and the lifetime caveat. Unsearched types have no measured count.

Select a Bucket or array type and use **O**, its address, Return to enumerate
occupied storage. Return opens a slot as a typed value. Invalid containers show
the reason, never a false zero count. These actions share the C decoder and the
existing search job; GUI jobs belong to the human, including after F8 yields
control. The browser does not modify or resume the target.

Try the owned fixture above:

```sh
xodb --break discovery_ready --break discovery_changed -- .work/jai-discovery/fixture .work/jai-discovery/manual.json
```

At the breakpoint, read `manual.json` in another terminal. Press Y, L, enter its
`base size`, Return. Press /, enter `FixtureTypedBase`, Return. Press S and enter
its `area area_size` followed by `entity_type FixtureTypedChild`, Return. The
three candidate rows include an unrelated matching word. Return on the first
candidate shows `health: 22`. To see occupied slots instead, / `Bucket` Return,
O with the recorded `bucket` address, Return. To read the changed value, continue
to `discovery_changed`, recapture the metadata with L, filter `FixtureTypedChild`,
and use G with the first `candidates` address: its health is now 23.

`python3 tests/jai-browser-gui.py` automates this flow on a private display.
`--pagination` separately tests 70 candidates and 70 array elements; both tests
use the fast GUI lane. Add `--agent zig-out/bin/xodb-agent` for the agent path.
`--wrong-oracle` deliberately expects the wrong health value and must fail.


## Stripped ELF and Windows PE fixture

The owned C demo builds the same self-describing metadata and native
`sizeof`/`offsetof` oracle as a stripped ELF or PE executable. This is a synthetic
Jai-layout fixture, not evidence from a Jai compiler. The Windows path runs under
Wine in its own prefix with the desktop environment removed. It attaches only
to the fixture spawned by the test, reads metadata protected read-only by
`VirtualProtect`, and removes only its own helper processes at exit.

```sh
python3 tests/jai-demo.py --work .work/jai-demo-elf
python3 tests/jai-demo.py --kind pe --wine wine --work .work/jai-demo-pe
python3 tests/jai-demo.py --kind pe --wine wine --work .work/jai-demo-pe-agent --agent zig-out/bin/xodb-agent
```

Each run builds a fixture, checks metadata offsets and enum names, reads health 77,
pages a resizable array, walks occupied Bucket slots and finds three Type-pointer
candidates (including an unrelated word). A breakpoint uses the fixture's emitted
code address, without symbols. Continue changes health to 78; the old metadata
context refuses live reads, and a new capture recovers the new value. Registers
and generation must remain unchanged during the inspection phase.
`--wrong-oracle` expects 78 before execution and must fail at the actual 77.

ELF checks are in the fast host/all lane. PE checks require Zig's Windows C
target support plus Wine and use the periodic lane because prefix initialization
and helper cleanup add startup cost:

```sh
scripts/release-check periodic --wine wine
```

The test retains its binary, oracle, transcript and result under `--work` for
review. A private Wine prefix can occupy hundreds of MiB; choose a work directory
with room. It installs no packages, changes no tracing policy and needs no
privileged helper. Normal permission to debug the owned child is still required.
This validates the same C reader against both executable formats; a native
Windows debugger transport and a real Jai-compiler fixture remain separate work.


## Typed write planning in C

`xjai_write_plan` resolves an explicit field path and encodes replacement bytes;
it does not write target memory. Paths use direct names such as `base.score`,
`items[2]` or `buckets[1].health`. Inherited fields need their explicit base path.
Array indices use the same checked fixed/view/resizable span decoder as previews.
Pointers are never implicitly followed.

Normal values support 8/16/32/64-bit integers, one-byte booleans, finite IEEE
32/64-bit floats and declared enum names or values. Integer overflow, signedness,
float overflow/underflow and unrepresentable enum constants are refused. Decimal
and `0x` integer forms are accepted; floats use decimal syntax. Enum values must
match a declared representable constant. Constants, ambiguous field names and
unresolved metadata are never writable through this planner.

Pointers, Type fields, strings and array headers require explicit raw mode:
exactly two hex characters per byte in target byte order. This also permits a
raw representation of another resolved leaf. A leaf is limited to 64 bytes;
paths to 256 bytes and 16 components; all field/enum visits share a 4096-work bound.
Name comparisons inspect only the requested token length. Invalid inputs clear
the complete output plan. The planner makes no explicit heap allocation and
uses the existing live-read budget for array headers.

The planner does not grant write authority. The C journal below performs writes
through guarded IO callbacks; the session adapter must bind those callbacks to
the current stopped target and mutation authority. The live bindings below use the same C implementation for MCP and the browser. `scripts/build test-jai-write
-Doptimize=ReleaseSafe` checks native offsets, values, boundaries, raw headers and
that planning leaves all owned target bytes unchanged. Its wrong-value control
expects 78 for a planned 77 and must fail even with NDEBUG.


## Guarded writes and undo in C

`xjai_write_destination` checks every mapping crossed by a plan (at most 64 bytes).
Every byte must be readable and writable, no mapping may be executable or shared (a write must not reach a file, /dev/shm or a device buffer), and no
byte may overlap any retained runtime-metadata capture. Invalid mappings or
metadata spans fail closed. Explicit raw writes and raw undo use these same
checks.

`xjai_write_apply` needs a stopped-target guard, exact read, write and generation
callback. The adapter enforces mutate scope/controller ownership, target identity
and the C destination check. Every IO callback must refuse a resumed or replaced
target. A complete old-byte read and journal storage reservation precede the
write. A second guard and generation check run immediately before it. The write
is followed by exact readback; a mismatch, unavailable readback or changed
generation remains an explicit failure. A backend error is retained even if the
requested bytes are independently verified by readback.

The journal stores original before/requested bytes and the latest observed
result, including partial or unverified effects. Each operation also returns a
change record for the session audit: per-operation before/requested/observed
bytes, validity flags, generations and write outcome. The caller stamp supplies
actor/client identity.
Those audit bytes must be copied, not retained as a pointer into the journal.
The journal starts at 32 bytes on this host, grows lazily from 4 entries and caps
at 1024 entries (about 632 KiB here). It retains every record for the current
target/image: at capacity, new writes refuse and existing undo remains available.
After restart or exec, the first write that passes preflight releases the old
incarnation's recovery records and starts again with four slots. Record IDs never
repeat; an evicted ID reports `JaiWriteUnknown`, never a different operation.
Before eviction, an old incarnation's ID reports `JaiWriteTargetChanged`.
Failed preflight preserves the existing history. The copied audit ring is separate.

`xjai_write_undo` requires the same session, target incarnation and executable
image. A restart must change the incarnation even if a PID or image number is
reused. At a later stop, checked undo compares current bytes with the last
observed result, or with the originally requested bytes if readback was
unavailable. If bytes already equal the original value, it records successful
undo without another write. Otherwise a conflict refuses. Partial undo preserves
its original recovery bytes and may be retried. Explicit raw undo bypasses only
the byte-conflict comparison; it still requires identity, authority, a complete
current-byte read, a permitted destination and readback. Comparisons are sampled,
not atomic, and do not prove that an allocation still has the same lifetime.

`scripts/build test-jai-journal -Doptimize=ReleaseSafe` is a fast component test
using owned synthetic storage. It checks overlapping writes, partial effects,
readback failures, scope/destination/identity refusals, changed bytes, raw
recovery, and undo at full capacity. `--wrong-oracle` expects 78 after writing 77
and must fail with NDEBUG too. `tests/jai-journal-fuzz.c` belongs to the periodic
lane; it varies failure modes and overlapping ranges and requires reverse-order
recovery to restore every owned byte, while protected bytes never change.


## Live field editing and recovery

In the runtime browser (`Y`), open a typed value with `G ADDRESS` or Return on a
candidate/container row. `W` opens an editor: enter `health 123` (or an explicit
path such as `base.score 42`) and press Return. The result is read back before
"Write verified" appears. `Shift+U` undoes the latest remaining write for this
target/image. Plain `U` does nothing. All text-entry fields capture typing even
without a loaded context or after continue/exit. A verified data write refreshes
the displayed tree and keeps protected metadata usable at the new generation.
Continue, restart and other changes still require an explicit metadata recapture.

The owned example above supports edits to `health`. For a short demo, run:

```sh
python3 tests/jai-writes-live.py --work .work/jai-write-demo
xodb --break discovery_ready --break discovery_changed -- .work/jai-write-demo/fixture .work/jai-write-demo/manual.json
```

Continue to the first breakpoint. In `manual.json`, use `base` and `size` for
`Y`, `L ADDRESS LENGTH`; filter `/ FixtureTypedChild`, then `G` the first
`candidates` address. `W health 123` changes 22 to 123; `Shift+U` restores 22. This
fixture is synthetic C emitting the documented RTTI, not a real Jai compiler.

MCP names are provider-neutral:

- `write_runtime_field(id, generation, type_name|type_address, address, path, value,
  raw=false)` uses the retained context and an explicit string value. Addresses
  are hex strings. A raw value is exactly two hex digits per target byte.
- `list_runtime_writes(start=0, limit=32)` pages at most 128 journal entries. It
  includes original before/requested bytes, latest observed bytes/outcome,
  original/latest actor and client, undone state and current-target applicability.
- `undo_runtime_write(write_id, generation, raw=false)` restores original bytes.
  Use the current generation, including after a later stop. Conflicting bytes
  refuse unless raw is explicitly requested. A different target/image always
  refuses, including after restart; raw never overrides that identity check.

Write and undo require `--agent-scope mutate` and the shared controller lease.
Direct calls from observe/control stdio or a shared observer refuse, even when
the tools are absent from the advertised list. Human GUI edits and undo use
human authority; after `F8` returns control, `Shift+U` can undo an agent's write.
No calls into the target are injected.

Mutation replies contain the current `generation` and a `change`: `state`,
`verified`, `write_attempted`, before/requested/observed hex bytes and reasons.
Check the change, not merely JSON-RPC success: `refused` means no write was
attempted; `failed` retains a journal ID if effects may have occurred. A backend
error remains visible even if `verified` proves that the requested bytes are now
present. `generation_after` in the change is the readback generation, before the
session's audit event; use the reply's outer generation for the next request.
`get_audit` includes the same copied change on each accepted write/undo attempt.
The 256-entry audit ring may rotate; the 1024-entry write journal retains
original recovery bytes for its current target/image, until the first valid write
against a new incarnation releases the old records.

Fast owned tests: `tests/jai-writes-live.py` covers local/agent and stdio/shared
paths; `tests/jai-writes-gui.py` runs on a private display. `tests/jai-demo.py
--writes` checks the stripped native oracle; add `--kind pe --wine wine` for the
periodic Wine lane. The fixture itself checks that undo restored its original
health before continuing.


## Periodic checks and shared presentation

`python3 -B tests/jai-fuzz.py --work .work/jai-fuzz --cases 2000` compiles the
six synthetic harnesses (layout, graph reader, values, containers, write plans
and journal) with Clang/libFuzzer, ASan and UBSan. Each has a fixed case count,
512-byte input cap, per-input timeout and process deadline. This is registered
only in `scripts/release-check periodic`; failures remain failures and their
logs/corpus/reproduction inputs stay in the work directory. No private image
is used as a seed.

The shared watch pane uses compact rows below 960 pixels of content width,
with selected type/context information on separate lines. This applies to all
languages because the expression, frame provenance, value and failure reason
compete for the same limited space. Reserving up to 220 pixels for the frame tag
and 320 for the expression leaves the remaining width for the value; selecting
a row gives its diagnostic a separate detail line. The runtime type work
uses this existing shared layout rather than introducing a Jai-only watch style.

Typed write paths currently name direct members: use `base.health` for a field
inside a `using base` member, even when reads display the flattened `health`.
An MCP value retained before a write becomes stale; cast it again at the reply's
current generation. GUI watches re-evaluate automatically.
