# xodb.logical-frames v1, draft C05-1

Status: prototype envelope, stable for adapter work (C06 Kotlin/JVM, C07 JIT).
Reader boundary: contract **C05-R4-1** (sections "Reader boundary (C05-R2)" and the C05-R3/R4 corrections below):
exact aggregates, accounted budgets, synchronized cancellation. Candidate only; not an
installed xodb feature.
It is **not** a frozen production xodb ABI; the host integration chooses
production naming and archive integration. Reference reader:
`src/profile/logical_frames.[ch]` (C11, no dependencies) and the CLI
`src/profile/logical_frames_main.c` (`xodb-lframes`).

## Encoding

- UTF-8 JSON Lines. One JSON object per line, LF terminated. Strict UTF-8
  (no overlongs, no encoded surrogates, nothing above U+10FFFF); `\u0000` and
  lone surrogate escapes are rejected; raw control characters are rejected.
- Duplicate keys in an object are rejected. Objects have at most 64 members.
- Unknown members are rejected **except** members whose name starts with `x_`
  (producer extensions; ignored by the reader, nested values allowed within
  the depth limit). Adapters put producer-specific evidence in `x_*`.
- JSON numbers are integers only (no fraction/exponent, at most 18 digits)
  and are used for small values (line numbers, pid/tid, counts, seq).
- Exact unsigned 64-bit values (times, weights, counts of loss, start ticks)
  are canonical **decimal strings** (`"0"`, no leading zeros, no sign).
- Addresses (native PC, code ranges) are canonical lowercase hex strings
  `"0x0"`..`"0xffffffffffffffff"`; no leading zeros.
- Digests are 64 lowercase hex chars. GNU build-ids are even-length lowercase hex.
- `null` means "unknown". Wherever an identity can be null, a companion
  reason member is required (`unavailable`, `os_tid_reason`, `clock_unavailable`,
  frame `reason`). A *missing* required member is a schema error; it is
  distinct from an explicit `null`.

## Ordering rules

1. Line 1 is the `header`. Exactly one header.
2. Dictionary records (`code`, `function`, `thread`) must appear **before**
   any record that references them (streamable, single pass).
3. `acquisition.seq` is strictly increasing in file order. A `stack` cites an
   earlier acquisition; the number of stacks citing it must equal its
   declared `stacks` (checked at `end`).
4. The final record is `end`. Records after `end` are rejected.
   Missing `end` => document decodes but is marked incomplete (`no_end_record`);
   a final line without LF is treated as an interrupted write: cited
   (line/offset/length) and ignored (`truncated_tail`). `--strict` turns both
   into exit status 4.

## Records

### header
```
{"type":"header","format":"xodb.logical-frames","version":1,"draft":"C05-1",
 "producer":{"name":str,"version":str,"kind":K,"sha256":digest|null},
 "source_kind":S,
 "runtime":{"language":str,"implementation":str,"version":str,"build":str|null,
            "executable":IMAGE,"library":IMAGE|null},
 "process":{"pid":int|null,"start_ticks":dec|null,"boot_id":uuid|null,"unavailable"?:str},
 "clock":{"domain":str,"unit":"ns"} | null,  "clock_unavailable"?:str (required if clock null),
 "command":[str...]|null,
 "collection":{"method":str,"trigger":str,"interval_ns":dec|null,"atomicity":A,"notes"?:str|null},
 "frame_order":"innermost_first",
 "weight_unit":str,"weight_semantics":str}
IMAGE = {"path":str|null,"sha256":digest|null,"gnu_build_id":hex|null,"unavailable"?:str}
```
- K (producer kind): `cooperating_in_process` (the observed program runs the
  exporter), `external_reader` (another process reads the target),
  `report_converter` (converts an existing runtime/profiler report).
- S (source kind): `cooperative_sample`, `cooperative_emit`,
  `stopped_snapshot`, `external_sample`, `imported_report`.
- A (atomicity): `all_threads_one_call`, `per_thread_sequential`,
  `process_stopped`, `single_thread`, `not_applicable`.
- Process instance = pid + `start_ticks` (field 22 of /proc/PID/stat) +
  `boot_id`. pid alone is not an instance. If pid or start_ticks is null,
  `unavailable` is required.
- Clock: the domain names the clock (e.g. `CLOCK_MONOTONIC` of the host
  whose `boot_id` is given). Host and guest clocks are different domains.
  A null clock forbids every time value in the document.
- `weight_unit`/`weight_semantics` are mandatory: an observation count is
  not CPU time. Never convert counts to nanoseconds.

### code (module / source / code-object identity)
```
{"type":"code","id":str,"kind":"source_file"|"builtin"|"native_library"|"jit"|"generated"|"unknown",
 "path":str|null,"sha256":digest|null,"bytes":int|null,"unavailable"?:str,
 "range"?:{"start":hex,"end":hex,"load_ns":dec|null,"unload_ns":dec|null}}
```
- sha256 null requires `unavailable`. A path alone is not code identity; the
  reader warns `code_path_reused` when one path appears with two digests.
- `range` (JIT/native code interval, end exclusive, end > start). Two ranges
  that overlap while both are live (all four lifetime bounds known and the
  lifetimes overlap) are rejected (`address`). Overlap where a lifetime bound
  is unknown is accepted with warning `address_reuse_ambiguous`. Address reuse
  after unload must use a **new code id**. Untimestamped perf-map input has
  unknown lifetimes and therefore always stays ambiguous.

### function
```
{"type":"function","id":str,"name":str,"qualified":str|null,"code":code-id|null,
 "first_line":int|null,"frame_kind":"interpreter"|"native"|"jit"|"logical"|"unclassified",
 "runtime_id":str|null}
```
`runtime_id` is an opaque, namespaced runtime handle (e.g.
`cpython:code@0x7f..`); it is not an address of code to execute and may be
reused after the runtime frees the object.

### thread
```
{"type":"thread","id":str,"language_id":str|null,"name":str|null,
 "os_tid":int|null,"os_tid_source":str (required when os_tid set),
 "os_tid_reason":str (required when os_tid null),"pid"?:int}
```
- A language thread and an OS thread are distinct identities. A new
  (language thread, OS TID) pair gets a new record. If two records name the
  same OS TID the reader marks both `os_tid_shared` (TID reuse or M:N
  scheduling) and never merges them.
- `pid`, when present, must equal the header pid (`bad_identity` otherwise).

### acquisition
```
{"type":"acquisition","seq":int,"start_ns":dec|null,"end_ns":dec|null,"stacks":int}
```
One collection moment/interval. Its interval bounds all of its stacks.

### stack
```
{"type":"stack","id":str,"acquisition":seq,"thread":thread-id,
 "start_ns":dec|null,"end_ns":dec|null,"trigger":str,"weight":dec(>0),
 "state":"complete"|"truncated"|"partial","omitted":dec|null,"reason":str|null,
 "exception"?:{"type":str,"message":str|null}|null,
 "frames":[FRAME...]}            (innermost first)
FRAME = {"function":function-id|null,"kind":KIND,"line":int|null,
         "provenance":"runtime"|"cooperative_annotation"|"external_read",
         "label"?:str,"reason"?:str,"pc"?:hex}
KIND = interpreter | native | native_transition | jit | logical | unknown | unclassified
```
- Times: both known or both null; `start <= end`; inside the acquisition.
- `truncated`/`partial` require `reason`; `complete` cannot omit frames and
  needs >= 1 frame. `omitted` null means "unknown how many".
- A frame with a function must have the function's `frame_kind`.
- Marker frames (`function:null`) are only `native_transition` or `unknown`
  and need `label` + `reason`. They mark a boundary/gap; they are not
  functions and are never assigned addresses.
- `pc` is allowed **only** on `native`/`jit` frames whose provenance is not
  `cooperative_annotation`. Interpreter/logical frames with a PC are rejected
  (`invented_pc`).
- Interpreter frames with `line:null` need `reason`.

### loss
```
{"type":"loss","reason":str,"count":dec,"acquisition":seq|null}
```
Explicit lost/skipped acquisitions (e.g. `timer_overrun`). Summed in `lost`.

### end
```
{"type":"end","records":int,"acquisitions":int,"stacks":int,"status":"complete"|"interrupted"}
```
`records` = number of records before `end`. Counts must match exactly.

## Native/logical joins

There is no join record in v1. Logical stacks are a separate view. A
native<->logical merge requires an actual bridge observation (for example an
interpreter entry frame whose native PC and logical frame were captured in the
same stopped context). A shared timestamp or thread does not establish order.
A future draft may add a `bridge` record citing both sources; v1 readers
reject unknown record types, so it cannot be smuggled in.

## Reader limits (defaults; all configurable)

input 256 MiB, record 4 MiB, records 4 Mi, string 16 KiB, frames per stack
4096, frames total 16 Mi, entities (codes/functions/threads/losses) 1 Mi each,
stacks/acquisitions 4 Mi, memory 512 MiB (peak live bytes of one decode, every
allocation accounted), JSON depth 8, 64 members per object, JSON values per record
`16*frames_per_stack+4096`. Query budget: 256 MiB incremental, 768 MiB combined with
the retained document. Limits are validated (counts below 2^32-2).
Exceeding any limit is an error (`input_limit` / `memory_limit`), never silent
truncation.

## Error statuses (CLI `error` field, exit 2)

`memory_limit input_limit invalid_utf8 invalid_json schema version_unsupported
duplicate_id bad_reference bad_identity clock order invented_pc address
count_mismatch empty cancelled overflow invalid_argument io_error`. Each error
carries the 1-based line and byte offset, the failing phase (`decode`/`query`) and
the operation's peak charged bytes.

## Warnings

`no_end_record truncated_tail producer_interrupted os_tid_shared
acquisition_incomplete loss_records partial_stacks code_path_reused
address_reuse_ambiguous no_clock`.

## Derived queries (reference CLI)

`xodb-lframes validate|threads|stacks|aggregate|folded|frames FILE [--thread ID|NAME]
[--limit N] [--top N] [--function NAME] [--strict] [--max-* N]`.
Every output names `input_sha256`; rows cite source `line/offset/length`.
All weights are exact unsigned integers printed as decimal strings (no wrap, no
saturation). Aggregate rule (`xlf-aggregate-v1`): self = innermost function frame;
inclusive counts a function once per stack (recursion-safe); partial stacks
are included and also totalled in `partial_weight`; marker frames are
totalled in `marker_weight`; stacks whose innermost frame is a marker count in
`unknown_leaf_weight`. Listings report `matched`/`shown`/`incomplete_listing`.

## Adapter guidance (C06 JVM, C07 JIT)

- JFR execution samples: `source_kind:"external_sample"` or
  `"imported_report"`, `producer.kind:"report_converter"`,
  `collection.method:"jdk.ExecutionSample"`, weight unit `"sample"`; JFR
  ticks/clock go in `clock.domain` with a converted ns value only if the
  conversion is documented in `x_*`; otherwise `clock:null` + reason.
  Java frames: `frame_kind:"interpreter"` or `"jit"` per JFR frame type
  (`Interpreted`, `JIT compiled`, `Inlined` -> `jit` with `x_inlined:true`),
  `native` for `Native`. Bytecode index goes in `x_bci`; never in `pc`.
- async-profiler collapsed/JFR output: counts are `weight` with
  `weight_unit:"sample"`; no per-sample time unless the report has it.
- Thread dumps (jstack/`Thread.getAllStackTraces`): `source_kind:
  "stopped_snapshot"` only if the VM was at a safepoint for all threads;
  otherwise `per_thread_sequential`.
- Kotlin coroutines: continuation frames are `logical` with provenance
  `runtime` only if read from runtime debug probes; never reconstructed.
- JIT maps (C07): one `code` record per (range, lifetime) with `kind:"jit"`;
  perf-map files lack timestamps => `load_ns/unload_ns:null` and the reader
  keeps `address_reuse_ambiguous`. A JIT frame may carry `pc` only when it came
  from a native sample (`provenance:"runtime"` or `"external_read"`).
- Kotlin/JVM, Kotlin/Native and ART are distinct `runtime.implementation`
  values; do not reuse one producer name across them.

## Reader boundary (C05-R2, contract C05-R2-1)

- **Exact counters.** `struct xlf_count` is an exact unsigned 128-bit value. Every
  derived value (total, partial, marker, unknown-leaf, per-function self/inclusive,
  document `lost` and `total_weight`) is a sum of fewer than 2^32 terms below 2^64, so it
  is below 2^96 and always exact. `xlf_count_to_u64` returns false when a value does not
  fit u64: that is the explicit overflow outcome for consumers that narrow. The
  regression `tests/logical-frames/regress/c05-weight-overflow.jsonl` totals
  `18446744073709551690`.
- **Budgets.** One accountant per operation charges every allocation and uncharges
  frees; limits bound the peak. Decode: document (struct, entity arrays, text arena) +
  transient parse storage (JSON values, record scratch, id maps) + the input copy for
  `xlf_decode_file`. Query: result (self/inclusive) + scratch, against an incremental and
  a combined (document retained + query) limit. Results report `retained_bytes`,
  `decode_peak_bytes`, `result_bytes`, `query_peak_bytes`, `combined_peak_bytes`. A limit
  equal to the measured peak succeeds; one byte less fails with `memory_limit`.
- **Ownership.** Documents are immutable after decode and may be queried concurrently.
  Every failure returns no object, releases everything it allocated, leaves inputs
  unchanged and fills `xlf_error`. Partiality inside successful results is explicit
  (`XLF_W_INCOMPLETE`, `input_incomplete`, `partial_weight`, listing flags).
- **Cancellation.** `struct xlf_cancel` wraps a C11 `atomic_bool` (release store,
  acquire load; safe from a signal handler). Polled per record, per MiB hashed/read and
  per aggregated stack. Cancelled operations return `cancelled` with the failure
  guarantees above.
- **Tests.** `make -C tests/logical-frames BUILD=DIR check`: decoder cases, R2
  regressions with allocation-failure and cancellation hooks (`-DXLF_TESTING`, test builds
  only), ASan/UBSan, ThreadSanitizer cross-thread cancellation and concurrent queries, and
  an independent Python exact-integer oracle (`exact_oracle.py`).

## C05-R3 corrections (contract C05-R3-1)

- **Admission.** `xlf_aggregate` refuses (`memory_limit`, zeroed result, nothing
  allocated) when the document's retained bytes alone exceed `max_combined_bytes`,
  including documents with no functions. A limit equal to the retained bytes succeeds.
- **File input.** `xlf_decode_file` observes an already requested cancellation before
  touching the path, pins it with `O_PATH`, refuses anything but a regular file without
  opening it (a FIFO never blocks and a blocked FIFO writer is not released),
  reopens the pinned inode through `/proc/self/fd`, and
  refuses a file whose size, inode or times change while it is read.
- **JVM evidence bundle** (`src/import/jvm_evidence.h`). One owned object holds the
  immutable source bytes, the typed import, the exact C05-1 bytes decoded and the
  `xlf_doc`; typed accessors keep what C05 kinds cannot (JIT inlining, Java methods
  declared native without native authority, heuristic text parsing, loader identity,
  virtual threads, coroutine creation stacks and parents, raw times with a status).
  Citations resolve from the retained bytes, never by reopening the path. Read,
  import, JSON scratch, adapter maps, emission, decode and the retained result are
  charged to one whole-operation budget (`max_total_bytes`) with phase-labelled
  usage; cancellation is polled before any work and throughout.
- **JVM identity and time.** Function identity includes the exported class loader
  (name and loader type), module and module version; a frame without loader
  information is `x_identity_basis:"loader_not_exported"` and never shares a function
  with one that has it. Timestamps are validated against the calendar (leap years),
  time of day, a +-18:00 zone offset range and refuse leap seconds; conversion to
  signed epoch ns is checked at both int64 endpoints. An invalid or unrepresentable
  time keeps its raw text and an explicit `x_time_status`, never a wrapped value.

## C05-R4 corrections (contract C05-R4-1)

- **Stable file reads.** Comparing size, inode and times before and after a read does
  not detect a concurrent same-size rewrite on common filesystems (XFS included), so
  it no longer stands alone. `xlf_read_stable` (used by `xlf_decode_file` and the JVM
  importer) takes a kernel read lease (`F_SETLEASE`, `F_RDLCK`) on the pinned, reopened
  regular file. The lease is granted only while no process has the file open for
  writing (otherwise the read is refused with `io_error`); while it is held, every open
  for writing and every truncate waits until the read is over. A lease still intact
  after the last byte proves the bytes are one version: `input_stability` /
  `source.stability` is `leased`. The lease-break signal goes to a helper thread that
  blocks all signals, never to the host process. When no lease is possible (a file
  owned by another user without `CAP_LEASE`, a filesystem without leases, leases
  disabled) the read is labelled `unverified`: only the size/inode/time check ran and
  the bytes may mix versions. Caller bytes are `caller_bytes`. Producers should write
  to a temporary name and rename. A file with bytes beyond its size (a `/proc` or
  `/sys` pseudo-file, a growing file) is refused instead of read short.
- **JVM import under a budget.** An allocation that fails anywhere in the importer is
  sticky; a failed string is never dereferenced, and the import fails with the
  budget's reason (`whole-operation budget exhausted`), never "failed". JSON arena
  blocks start at 4 KiB and double up to 1 MiB, so a small source charges what it
  uses and every phase boundary is reachable by a budget sweep.
- **JVM text and identity.** Thread.print accepts CRLF line endings; its timestamp line
  is repaired like every other line (invalid UTF-8 becomes U+FFFD) and validated
  (`unzoned` when valid, else `malformed` or the calendar/clock reason). Function
  identity also includes the raw exported class name (`p/C` and `p.C` differ;
  `x_raw_class`). A string with an embedded NUL is never shortened: it is stored with
  NUL as `\0` and backslash as `\\` and marked `x_nul_escaped`, which is part of the
  identity. A time with more than nine fraction digits is `precision_finer_than_ns`
  only when the rest of the text is well formed.
- **Evidence API.** Hosts use `jvm_evidence_info` (source, label, hash, stability,
  completeness, counts, pid, runtime identity, diagnostics) and the typed accessors;
  the import state and the cancellation test hook moved to
  `jvm_evidence_internal.h` (in-tree CLI and tests only). Concurrent
  `jvm_evidence_aggregate` calls share what the budget leaves after the bundle: each
  reserves its query budget atomically from that remainder, so concurrent queries
  never together exceed it.

## C05-R5 notes (reader unchanged, contract C05-R4-1)

- **Producers: a rename during a read is a refusal, retry it.** Write the document to
  a temporary name and `rename(2)` it over the final path. If that rename lands while
  a reader is reading the old file, the old inode's link count and ctime change and
  the read is refused with `io_error` ("changed"); the bytes were never mixed. Retry
  the read (it then opens the new file). The same holds for the JVM importer
  (`read:` io_error). A file still open for writing is refused the same way: close
  it before handing it over.
- **Hosts: serialize or retry limited aggregates.** On a bundle with a whole-operation
  byte limit, a running `jvm_evidence_aggregate` usually reserves the whole remaining
  budget, so a concurrent call is refused with `memory_limit` ("reserved by
  concurrent queries") even when the limit is far above one query's need. Call
  aggregates on one limited bundle one at a time, or retry the refused call after
  the running one returns. Without a limit no reservation applies.
- **Typed frame identity.** `struct jvm_evidence_frame` also carries `raw_class`
  (the class name as exported: `p/C`, or an already dotted `p.C`; `class_name` is
  the binary name of both) and `nul_escaped`, a bit per identity field
  (`enum jvm_nul_field`: class, method, descriptor, loader, loader type, module,
  module version) whose string held NUL and is shown with NUL as `\0` and backslash
  as `\\`. With these a host can tell apart every pair of functions the document
  keeps distinct. The escape mark is now per field (one flag per frame merged a NUL
  in the class plus a literal `\0` in the method with the reverse); the document
  adds `x_nul_escaped_fields` next to `x_nul_escaped`.
- **Undeclared JFR export depth by default.** `jvm_limits_default` now sets
  `jfr_export_depth = 0` (undeclared); it was left uninitialized, so a CLI built with
  `-O2` could treat a JFR stack as `complete` without `--jfr-stack-depth`.
- **Not a stable ABI.** `jvm_evidence.h` is a source-level API for code built with
  this tree: its structs grow, `jvm_evidence_info` embeds `struct jvm_diagnostics` by
  value, and it includes `jvm_import.h` (whose `struct jvm_import` is internal).
  Recompile the host with the importer it links.

## Perl

[Perl values and logical stacks](PERL.md) describes the core-module-only
cooperating exporter, stopped-memory MCP reader, and GUI scalar summaries.
The exporter uses this version-1 format without extensions to its contract.

## CPython

[CPython values and stacks](PYTHON.md) describes the stopped-memory MCP reader
(`get_language_stack` with language `python`) and GUI object summaries. Its
frames use the logical-frame vocabulary but its response is not an importable
version-1 document.


## Session and GUI integration

`xodb --open-frames FILE` opens logical-frame JSONL or a saved `.xof` bundle.
Add `--headless --mcp --agent-scope control` to use the same importer without a
GUI. It works offline and with a native session. Imported frames remain a
separate segment: matching names or timestamps do not create a native/logical
bridge, and a producer-declared PC grants no native debugger authority.

For a quick owned Python recording:

```sh
python3 tests/logical-frames/python_workload.py frames.jsonl frames-meta.json .5 10
xodb --open-frames frames.jsonl
```

The list orders functions by exact inclusive weight; self weight is shown beside
it. The header reports method, units, partial/unknown/marker weights, incomplete
input and read stability. **J/K** select, **Enter** explicitly reads the selected
source file, **T** cycles logical threads, **[ / ]** cycle imported sources,
**L** switches to/from the native workspace, and **Esc** cancels pending work.
Source previews are limited to regular UTF-8 files of at most 1 MiB. A recorded
SHA-256 is compared with the opened file; changed or unverified identity is
shown. Merely opening an archive never follows recorded source paths. Preview
strings are shortened for display; the original bytes and full MCP rows remain
available.

### Agent workflow

These are tool argument objects, passed through ordinary MCP `tools/call`:

1. `import_logical_frames` with `{"path":"frames.jsonl","kind":"logical"}`.
   JVM sources use `jfr` (JFR JSON export), `thread_dump` (Thread.dump_to_file
   JSON), `thread_print` (Thread.print text), or `coroutines` (DebugProbes export).
   Optional `jvm_kind` selects the documented C importer event-kind ordinal;
   the original source and its selected kind are retained together.
2. Poll `get_frame_status` until `status` is `ready` or `failed`. Inspect
   `error_name`, read stability, provenance, limits, completeness and warnings.
3. Take `source_id` and `index` from the returned source. Pass `source` and
   `source_id` to `get_frame_threads`, `get_frame_stacks`,
   `get_frame_functions`, or `get_frame_aggregate`. Pages use `start`/`limit`,
   at most 64 rows, and return `next`. Counts are exact decimal strings.
4. `get_frame_stack` adds `stack` (the stack ordinal) and pages its frames.
   JVM rows preserve inline/native-method distinctions, virtual-thread state,
   coroutine parents and heuristic text provenance. A JVM native method is not
   a machine stack frame.
5. `get_frame_citation` with the source identity, `basis:"source"` (original
   bytes) or `basis:"logical"` (the adapted logical document), `offset` and
   `length` returns at most 4,096 cited bytes in hex. Offsets are byte offsets.
6. `select_frame_aggregate` with the identity and optional `thread` explicitly
   recomputes a selection. `save_frames` with `{"path":"frames.xof"}` saves
   the sources; poll status and check `publication.state == "published"`.
   `open_frame_bundle` reopens it. `cancel_frame_job` requests cancellation.

Accessors are observer tools. Import, selection, preparation, cancellation and
save require the controller lease in shared sessions and control scope. One
worker runs at a time per session; conflicting requests return `FrameBusy`.
Failures leave the last successfully published evidence intact.

### JIT labels in native samples

Import a **completed** owned Node `--perf-prof` jitdump or CPython `-Xperf_jit`
export with `import_jit_map`. A perf-map uses `kind:"perfmap"`; jitdump uses
`kind:"jitdump"`. The `declaration` object records facts measured during the
capture, not guesses from the filename. It includes:

- `pid`, plus `start_ticks` and `boot_id` together when the process incarnation
  is known. These must match the native capture's recorded incarnation.
- `clock:{kind,scope}`: the producer's timestamp domain and an optional 32-hex
  scope identifier. An unknown clock stays unknown. A clock conversion can be
  declared using `mapping:"offset"` or `"perf_tsc"`, `target_clock` and the
  associated offset/conversion fields, uncertainty and `measured_by` provenance.
- `capture_clock` and nonempty `capture_clock_evidence` may identify a native
  CLOCK_MONOTONIC capture's scope. Measure the collector and target time
  namespaces while they are alive; a shared boot ID alone does not prove this.
  Remote producer clocks are conservatively left unverified here.
- Optional `coverage_end`, `slack`, `header_time_in_clock`, `debug_address_bias`
  and `label` retain producer-specific evidence. `header_time_in_clock` defaults
  false: Node versions may encode the header timestamp differently from record
  timestamps. Do not declare them identical without checking the producer.

For example, after measuring the facts, the agent calls:

```json
{"path":"jit.dump","kind":"jitdump","declaration":{
  "pid":4242,"start_ticks":123,
  "boot_id":"aaaaaaaa-0000-4000-8000-000000000001",
  "clock":{"kind":"monotonic","scope":"11111111111111111111111111111111"},
  "capture_clock":{"kind":"monotonic","scope":"11111111111111111111111111111111"},
  "capture_clock_evidence":"collector and owned target time namespaces were measured equal before collection",
  "header_time_in_clock":false
}}
```

Those identity and scope values are synthetic placeholders, not defaults.
Omitting evidence is supported; it produces unverified labels rather than
invented confidence. The import owns the source bytes and declarations.

CPython `-X perf_jit` does not emit a jitdump close record. For attribution,
also declare `coverage_end`, measured in the declared clock after the final
sample and before the owned process exits (for example `"coverage_end":900000000`
when that measured boundary was 900,000,000 ticks). Without this explicit
boundary the retained code can be inspected, but its lifetime coverage is
unverified and cannot produce a resolved label. Do not infer coverage from file
mtime or the last code-load record.

After polling frame status, call `prepare_jit_profile` with `capture_id`,
`revision`, `start` and `limit` (1–64 samples). The worker resolves the sampled
leaf at its exact PC and recorded user callers at return PC minus one. Poll
frame status again, then use `get_jit_profile` for sample summaries,
`get_jit_stack` with `ordinal` for paged caller summaries, and
`get_jit_candidates` with `ordinal` and optional `frame` for candidates (omitting
`frame` selects the sampled leaf). Names have 256-byte previews, explicit
truncation/encoding, and original source offsets and lengths for full citations.
Views are keyed by capture/revision and evidence revision; stale views are refused.
`get_profile_samples` also includes a prepared leaf summary.

In the GUI open the native profile, press **I** for the sample inspector and use
**[ / ]** for samples. Completed labels are prepared asynchronously. The view
keeps raw PCs visible and shows `resolved`, `ambiguous` with candidate count, or
`unverified`. Perf-map input cannot become resolved. An unverified file read
also cannot become a resolved host label, even when the lifetime resolver alone
finds a unique object. Its separate `resolver_outcome` remains available.

### Persistence and limits

`.xof` is the standalone evidence bundle: magic `XODBFRAM`, payload version 1,
SHA-256 body and per-source checksums, typed source records, original source
bytes and selection/declaration metadata. It retains up to eight sources with
64 MiB of aggregate original input. The host's import/aggregate budget is
256 MiB, including raw bytes, owned C evidence, decoder scratch and copied host
aggregates. Limit failures are typed (`FrameInputLimit`, `FrameMemoryLimit`,
`JitMemoryLimit`, `FrameResponseLimit`); no partial replacement is published.
MCP responses are bounded to 512 KiB; reduce the page size when necessary.
Standalone frame saves poll cancellation during hashing and copying. Native
capture saves currently finish encoding the frame attachment before observing
archive-job cancellation. This phase is bounded to 64 MiB of source input,
eight metadata records of at most 32 KiB each, and bundle headers; it has no
wall-clock deadline. Shutdown waits for that phase to drain. Cancellation is
checked again before publishing the native archive.

Saving a native capture with imported evidence adds the optional `FRAM` section
in XOC 2.7, inside the existing 256 MiB file limit. Native evidence bytes stay
unchanged, the unmodified XOC 2.6 reader skips this section, and captures with
no attachment retain the previous writer output. A corrupt or future frame
payload leaves native evidence inspectable: `get_archive_status` reports a
bounded `recorded_origin.frame_attachments` summary (retained bytes and SHA-256),
never the raw bundle. Only the frame worker validates that optional payload.
`frame_attachments` reports restoration state, a typed reason and, on successful
restoration, counts, source IDs and input digests; `get_frame_status.archive_attachment` and the GUI
show the same persistent failure. XOC envelope and section CRC checks still apply.
Re-saving an older minor-6 capture that already carries FRAM upgrades its header
to minor 7 and recomputes the header CRC. Its retained sections stay unchanged,
but the whole file is therefore not byte-identical.

Opening an attached capture alongside `--open-frames` never replaces either
input silently. If the separate import was active or already loaded, restoration
is `not_loaded`. Reopen the capture by itself to load its retained attachments,
then import additional sources. Saving refuses `ArchiveFrameAttachmentConflict`
if any original source is missing, including after replacing the workspace with
another bundle. Once the frame worker has finished, `get_frame_status` also
reports `status: "conflict"` and `error_name: "ArchiveFrameAttachmentConflict"`
at the top level; the separately imported sources remain inspectable. An active
job still reports `pending`, and a failed frame job retains its own diagnostic.
This version has no archive attachment removal command. A
successful save reports retained, added and removed counts (removed is zero);
an opaque attachment copied without importing anything reports
`opaque_preserved:true` and an unknown count when its envelope cannot be read.
Plain resaves preserve the original metadata, including unknown optional fields.

The saved algorithm identifier records how to recompute analysis. An unknown
identifier leaves original evidence readable and marks aggregates stale;
explicit selection/preparation recomputes them with the current implementation.
An out-of-range saved thread selection similarly reports `selection_stale`
without discarding the source. Import failures include the C reader's bounded
line, byte offset and diagnostic message when available.
JIT query views are recomputed, not saved as authoritative native symbols.
Reopen does not need the original runtime, source files, jitdump or perf-map.
