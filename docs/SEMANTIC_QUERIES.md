# xsg v1 — bounded semantic query input (provisional)

Status: C02 candidate proposal, implements the semantics of
`contracts/EVIDENCE.md` (draft 2026-10-04) for static findings. Not a
production wire format. Names may change at integration.

One file holds one image's functions in high-p-code SSA form. It is plain
ASCII, line oriented, whitespace separated, `#` starts a comment. Every
native address/offset is a `0x` hexadecimal u64 (no floating point, no
sign); ids are decimal u32 below 4294967295. The loader is strict: any
unknown directive, attribute, reference, width mismatch or limit failure
rejects the whole file, and a file without the final `end` line (or with a
last line lacking `\n`) is rejected as truncated.

```
xsg 1
image sha256=<hex|unknown> [build_id=<hex|unknown>] [name=<token>]
spec language=<ghidra language id> [compiler=<cspec id>] addr_bytes=<1..8>
producer <name> <version>
source kind=<synthetic|c01-function-graph-0.1.x|...> [sha256=<hex of original input|none>]
qualification level=<complete|qualified|unreliable|unknown> [reasons=<code,...>] [artifact=<id>]
space <id> <name> <constant|ram|register|unique|stack|join|other>
readonly 0x<low> 0x<high>                 # [low, high) immutable image bytes
function <id> <name> entry=0x<addr>
block <id> 0x<start>
edge <from-block> <to-block> <fall|true|false|jump|switch>
vn <id> <space-id> 0x<offset> <size-bytes> [input] [param=<n>] [spacebase]
   [spacebase_heuristic] [annotation] [addrtied] [persist] [name=<t>] [origin=<t>]
op <id> <block> 0x<addr> <seq> <OPCODE> <out-vn|-> <in>... [origin=<t>]
call <op-id> target=<0x..|unknown> [name=<t>]
end
```

Header lines (`image`, `spec`, `producer`, `source`, `space`, `readonly`)
precede the first `function`. Each `block`, `edge`, `vn`, `op` and `call`
belongs to the most recent `function`; a reference into another function is
rejected (`cross-function reference`). Ids are unique per kind across the file.

## Semantics carried by the format

- **Blocks/edges.** The block whose start equals `entry` is the entry. A block
  ending in CBRANCH has exactly one `true` and one `false` edge; `true` is
  taken when the CBRANCH condition varnode (input 1) is nonzero. BRANCH has one
  `jump`/`fall` edge, RETURN none, BRANCHIND only `switch` edges (none means an
  unresolved indirect branch and marks the CFG incomplete). Any other final op
  has at most one `fall`/`jump` edge; zero edges is treated as a function exit
  (for example a call that does not return). Control-transfer ops may only end
  a block. Ops in a block are ordered by `seq` (strictly increasing).
- **Predecessor order.** For each block, the file order of `edge` lines that
  target it is its predecessor order; MULTIEQUAL input *i* comes from
  predecessor *i*, and arity must equal the predecessor count.
- **Varnodes.** Every non-constant varnode has exactly one defining op, or is
  an `input` (function entry state), or an `annotation` (code address operand
  of BRANCH/CBRANCH/CALL; never a value). `param=n` marks an input the
  prototype names as parameter *n*. `spacebase` marks the entry stack pointer;
  `spacebase_heuristic` means an adapter inferred it (C01 0.1.0 does not export
  Ghidra's spacebase flag). Constants must fit their size.
- **Ops.** Opcode names are Ghidra p-code names. The loader checks widths per
  opcode (equal operand/output sizes for arithmetic, 1-byte comparison/boolean
  results, widening extensions, in-range SUBPIECE truncation, PIECE size sum,
  constant LOAD/STORE space ids naming a declared non-constant space, 1-byte
  CBRANCH conditions). Unknown opcode names are accepted and stay barriers.
  INDIRECT input 1 is `@<op-id>`: the op that may change the value.
- **SSA.** A data-flow cycle that does not pass through MULTIEQUAL/INDIRECT is
  rejected (not SSA). Checked iteratively, so deep inputs cannot exhaust the stack.

## Loader limits (XSQ_LIMIT)

64 MiB file, 64 KiB line, 4112 tokens/line, 4096 inputs/op, 4096 functions,
2^18 blocks, 2^19 edges, 2^21 varnodes, 2^20 ops, 2^22 input references,
64 spaces, 4096 read-only ranges, 4096-byte varnodes, 8 MiB strings.

## Identity

`xsq` records the SHA-256 of the xsg bytes it loaded; results also carry the
`image`, `spec`, `producer` and `source` lines verbatim. The adapter writes the
SHA-256 of the original C01 JSON into `source sha256=`, so a derivation is
reproducible from the saved input alone. A Ghidra/loader function name is not
proof of a native runtime symbol, and an address here is a link-time address of
the identified image only.
# C01 function_graph 0.1.x -> xsg v1 adapter

`adapter/c01_to_xsg.py INPUT.json OUTPUT.xsg [--elf IMAGE]` (stdlib Python).
The C01 JSON is read only. Its SHA-256 goes into `source sha256=`; the C01
`artifact_id`, producer and Ghidra commit go into header comments.

Inputs accepted: `schema == xodb.ghidra.function_graph`, `schema_version`
0.4.x only (the versions `tools/ghx/ghx_validate.py` admits; run it with
`--image` on saved exports first), `status == ok`,
`high_pcode.kind == decompiler_final_ssa`. Anything else exits 1. 0.1.x and
0.2.x exports predate instruction admission and 0.3.x counted any accepted
function-map record as function-start evidence, so they are refused (see
"C01 worker export contract" below). The mapping table below still documents
the 0.1.0 field names it was written against.

## Mapping decisions (not pure renaming)

| C01 0.1.0 | xsg | why |
|---|---|---|
| native opcode names `BUILD`, `DELAY_SLOT`, `LABEL`, `CROSSBUILD` | `MULTIEQUAL`, `INDIRECT`, `PTRADD`, `PTRSUB` | Ghidra's native `get_opname()` returns SLEIGH placeholder spellings for these (opcodes.cc lines 20-28). Unmapped they would become barriers. |
| `INT2FLOAT`, `FLOAT2FLOAT`, `TRUNC`, `CEIL`, `FLOOR`, `ROUND` | `FLOAT_*` | native short names |
| other unknown opcode names | passed through | the engine keeps them as barriers |
| `succ.kind` `true_out` / `false_out` | `true` / `false` | Ghidra `getTrueOut()` is out-edge 1. `BlockBasic::negateCondition` toggles `boolean_flip` *and* swaps the edges, so `true_out` is always taken when the raw condition varnode is nonzero. Flipped CBRANCHes are counted in a header note. |
| `unconditional` | `jump` if the block ends in BRANCH, else `fall` | |
| `flow` / `switch` | `fall` / `switch` | |
| edge order | emitted in each target's `pred[]` order | MULTIEQUAL input *i* corresponds to `pred[i]` |
| block `ops[]` position | `seq` | execution order within the block |
| `op:N`, `vn:N`, `bb:N` | ids N, `origin=op:N` / `origin=vn:N` | ids are per artifact; origin keeps the C01 identity for selection (`--origin`) and citations |
| iop varnode with `ref_op` | `@N` on the INDIRECT | the op that may change the value |
| fspec varnode | `annotation` | call-spec reference, not a value |
| input varnode whose (space, offset) equals a prototype parameter's storage | `param=index` | parameters are the decompiler's inferred prototype (`decompiler_inferred` unless locked) |
| input register named RSP/ESP/SP (x86), sp (AArch64), SP/A7 (68000) | `spacebase_heuristic` | C01 0.1.0 does not export Ghidra's `isSpacebase()`; results mark frame-base facts as adapter-inferred |
| `--elf IMAGE` | `readonly` ranges | SHF_ALLOC sections without SHF_WRITE (NOBITS excluded), only after the ELF's SHA-256 equals `image.sha256` |
| `instructions_outside_declared_bounds` non-empty | header note | advisory bounds: the graph may contain tail-called or fallen-through code of other functions |

## Rejections (exit 1, message names the cause)

- no block starts at `function.entry` (observed: stripped `fx_calls` at -O2,
  where Ghidra reported "Possible PIC construction ... Changing call to branch";
  the graph then describes `fx_add`, not the requested function)
- block lists an unknown op, op listed in two blocks or in no block
- `pred[]`/`succ[]` disagreement, unknown edge kind, unknown space or space type
- free non-constant varnode without `input`/`annotation`
- id not of the form `op:N`/`vn:N`/`bb:N`, non-string or >64-bit hex values
- `--elf` image hash mismatch

## Requests to C01 (schema 0.1.x additive)

1. Export canonical p-code names (or add `opcode_canonical`) so consumers need no alias table.
2. Export `Varnode::isSpacebase()` as a varnode flag so frame-base facts are not heuristic.
3. Export read-only/writable image ranges (or section table) with the image identity.
4. Calls to PLT stubs: `target_name` is null and the CALL often has no inputs because the
   callee prototype is unknown. Exporting the decompiler's trial parameters (or a flag
   saying the input list is not ABI-complete) would let consumers cite missing arguments.


# C02-R2 changes (bounded operation, qualification passthrough)

## Qualification passthrough

The optional `qualification` header line (at most once, before the first
function) carries the producer's graph qualification (see "C01 worker export
contract" below) and artifact identity. The adapter writes it for every C01 export (0.1.x
exports get `level=unknown`). Every xsq JSON result repeats it as
`input_qualification`, adds `result_trust: graph_<level>` and
`verified_semantics: false`. xsq never upgrades a qualification: it computes
static possibilities over the graph it was given and does not verify that the
graph is a correct decompilation. Schema-valid `status: ok` is not semantic
verification.

## Cancellation

`struct xsq_cancel` holds one lock-free atomic flag. `xsq_cancel_request`
(release store) may be called from any thread or a signal handler; loading and
queries poll it with acquire loads before doing any work and at least every
256 work units (queries) or 256 lines / 4096 records (loading). A set flag stays
set: a later query or load with the same object is cancelled immediately. The
previous `const volatile int *` flag was a C11 data race and is gone.

## Budgets: per phase and operation total

| phase | bound | outcome when exceeded |
|---|---|---|
| graph load (`xsq_load_*_budget`) | `max_bytes`: cumulative bytes requested from the allocator (file buffer, tables, indices, validation scratch; frees do not refund); fixed format limits as before | `XSQ_LIMIT` (budget) / `XSQ_NO_MEMORY` (allocator) / `XSQ_CANCELLED`; nothing of the graph is kept |
| query (`xsq_slice`, `xsq_controls`) | `max_bytes` cumulative (scratch, per-query load scratch, frontier, result arrays and their growth), `max_work`, `max_nodes`, `max_edges`, optional `max_ns` | `XSQ_PARTIAL` with `limit` = `memory`, `work`, `nodes`, `edges`, `time`, or `allocation_failed` (the allocator itself failed), or `XSQ_CANCELLED`; records produced so far are kept and are a prefix of the unbounded run |
| report | one array of `node_count + 1` citations (bounded by the charged node array), outside the query budget | `instructions_complete: false`, never a silently empty list |

The CLI's `--max-bytes N` is the operation total: the load phase is charged
first and the query receives `N - load_bytes` (JSON `budget.load_phase.bytes`
plus `stats.bytes` never exceeds N). A process `RLIMIT_AS` bounds the process,
not a query.

The frontier array (one slot per function varnode, or per block for
`controls`) is allocated first so recording the frontier never fails; if even
that allocation exceeds the budget the result says `frontier.complete: false`
with an empty list, meaning the whole query from its root is unexpanded.
Identical inputs and budgets give identical partial results (node order,
frontier, work and byte counts).

## Test support

`xsq_test_alloc_fail_at(k)` fails the k-th allocation (counted across loader,
query and report) so every allocation-failure path can be exercised;
`tests/semq/test_xsq.c` sweeps all of them. `tests/semq/compose.py` runs the
complete ELF -> ghx worker -> adapter -> xsq path with source-grounded
expectations (see its docstring).


# C02-R3 changes (memory model, limits, cancellation, presentation)

`XSQ_ANALYSIS_VERSION` is `xsq-0.3`.

## Address spaces and widths

A memory location is (LOAD/STORE space id, address width, base, offset). The
offset is accumulated modulo 2^(8 x width), where the width is the size of the
address varnode; p-code operand widths are already validated on load, so every
step of an address computation is arithmetic at that width (32-bit pointers
wrap at 2^32). Two accesses are only proven the same location, or disjoint,
when their space ids and widths are equal. Accesses in different spaces, of
different widths, or through an address varnode whose size differs from
`addr_bytes`, are may-alias: the store becomes a `possible` dependency and the
result is not exhaustive, so no irrelevance is claimed. `readonly` ranges name
no space; they are applied only when the graph declares exactly one `ram`
space and the access is in it.

## Limits

`max_edges` is checked before another relation is taken (slice) or published
(controls): `stats.edges` and the control list never exceed it. When a query
stops inside an expansion, the interrupted value (slice) or block (controls)
is part of the frontier together with everything still queued, so a partial
frontier is complete in the sense that every missing relation is reachable
from it.

Byte budgets charge the allocator request itself: a growth `realloc` is
charged its full new size (R2 charged only the growth), in the loader and in
queries. `make check` runs `tests/semq/alloc_probe.c`, linked with
`-Wl,--wrap=malloc,--wrap=calloc,--wrap=realloc`, which counts the requests
outside the library and requires charged == requested for loads and for
every query kind at every op (counts of requested bytes, not RSS). The report
phase's citation array stays outside the query budget, as before.

`xsq bench` runs every sampled query as its own operation on the one loaded
graph: each query gets `--max-bytes - load_bytes` (reported as
`query_max_bytes` next to `load_bytes`), so load + that query never exceeds
`--max-bytes`. With the whole budget used by loading, every query stops at once
with `limit: memory`.

## Cancellation

Loading polls cancellation before any size-dependent work: a pre-cancelled
load, or one whose buffer exceeds the file limit, hashes nothing. The input
hash then runs in 1 MiB chunks with a poll before each chunk, and the
validation passes poll every 4096 records. A pre-cancelled query allocates
nothing: it returns `cancelled` with `frontier.complete: false`, an empty
frontier and a message (R2 allocated its frontier and scratch first). After
any stop no further query allocation is made. The regression oracle is
counted work (`xsq_test_hashed_bytes`, the allocation counter of
`xsq_test_alloc_fail_at`), not elapsed time.

## Presentation

Text output always prints the producer qualification line
(`input qualification=<level> reasons=<codes> artifact=<id>
result_trust=graph_<level> verified_semantics=no`), outside the `--lines`
budget, and a frontier line for partial or cancelled results. JSON is
unchanged. Copying producer fields is not admission: saved C01 exports go
through `tools/ghx/ghx_validate.py` first.


# C01 worker export contract (consumer view, v5)

What a consumer of `tools/ghx` output may rely on. Schema
`xodb.ghidra.function_graph` **0.4.1**; every ok export carries
`"contract": "C01-R5 CONTRACT.v5"`. Not a production xodb interface. The
complete producer contract (input snapshots, identity basis, supervisor
deadlines) is kept with the candidate delivery; this section is the part a
consumer needs. Changes from v3 (0.3.0) are marked **[v4]**, changes from v4
(0.4.0; additive: two reasons, a narrower `.cold` rule, `--map`) **[v5]**.

## Instruction admission

An instruction is evidence (`admission: "admitted"`, with `bytes`, mnemonic,
operands and raw p-code) only if every byte of `[addr, addr+length)` is a file
byte of one PF_X PT_LOAD and, with `bounds=strict`, inside
`[entry, entry+size)`. The decoder's 16-byte prefetch may be zero-padded past a
segment end; padding is never exported.

- `refused`: no bytes or p-code; listed in `instruction_admission.refused[]`
  and qualified `instruction_refused_<reason>` (unreliable); the path is cut
  there. Reasons: `not_file_backed_executable` (suffix past the segment, gap,
  non-executable, unmapped or `memsz`-only bytes), `outside_strict_bounds`,
  **[v4]** `undecodable_at_segment_end` (the bytes do not decode and the
  decoder window runs past the file-backed executable bytes, so the failure may
  come from padding: a truncated instruction). An invalid opcode within 16
  bytes of a segment end is therefore refused too (conservative).
- `undecoded`: file-backed executable bytes whose 16-byte window is entirely
  real and that do not decode. **[v4]** Always qualified `instruction_undecoded`
  (qualified) at its address: the path ends where the CPU would fault.
- A refused entry instruction refuses the request:
  `error.code=instruction_refused`.
- **[v4]** Strict bounds whose flow leaves the range (e.g. one byte short of
  the last instruction) fail with `error.code=bounds_exceeded` instead of the
  generic `flow`.

## Function maps

`function_map=` names a file of `name 0xentry 0xsize` records (one per line;
blank and `#` lines ignored). Hex is canonical: lowercase, `0x` prefix, no
leading zeros (`0x0` for zero). **[v4]** `0X401000`, `0x0401000` or `0xA` are
rejected as non-canonical. Any malformed, non-canonical, truncated,
duplicate or out-of-range record refuses the request (`error.code=function_map`,
message with per-kind counts `malformed`, `noncanonical`, `truncated`,
`duplicate`, `range` and the first bad line).

**[v4]** A map is evidence for the requested function only if an accepted
record starts at the requested entry: `function.function_map.used` and
`qualification.function_starts.function_map == "used"` mean exactly that, and
`function.function_map.entry_size` gives that record's size (else null and
`supplied_unused`). Without such a record (and without a symbol table)
`stripped_without_function_starts` stays. Other records still name callee
starts (tail calls, call targets). In v3 any accepted record counted, so one
unrelated record could turn an absorbed tail call into `complete`.

**[v5]** gcc's hot/cold split: a record or symbol named exactly
`<owner>.cold` or `<owner>.cold.<n>` is a fragment of the requested function
(flowed as its code, not a tail call or another function's start), where
`<owner>` is the entry record's name, else the function's own name. Any other
name containing `.cold` (`B.cold` for entry `A`, `foo.coldstart`) is another
function.

**[v5]** Declared extents (the requested `size=` and the entry record's size)
are trusted input. Two cheap checks report a wrong one:
`declared_extent_conflict` when both are given and differ, and
`declared_extent_unreached` when no exported instruction reaches the last
byte of the extent in effect (the requested size, else the entry record).
Known limit: an extent that is too large but ends exactly at code the flow
reaches (for example one that covers an absorbed tail callee for which the map
has no record) is not detectable; the absorbed code is then exported as the
requested function's own.

## Qualification

`qualification.level` is the maximum over `reasons[]`; `complete` requires
none. `status=ok` is not semantic verification.

| code | level | meaning |
|---|---|---|
| `stripped_without_function_starts` | qualified | no symbol table (or `symbols=0`) and no map record at the requested entry **[v4]** |
| `instruction_refused_<reason>` | unreliable | a flowed path reaches a refused instruction; path cut |
| **[v4]** `instruction_undecoded` | qualified | a flowed path reaches undecodable file-backed executable bytes |
| `flow_outside_declared_bounds` | qualified | instructions start outside the requested `[entry, entry+size)` |
| `instruction_crosses_declared_bounds` | qualified | advisory bounds: an instruction starts inside and ends past the requested end |
| **[v4]** `flow_outside_function_map_bounds` | qualified | no requested size: instructions leave the entry's map record `[entry, entry+entry_size)` |
| **[v4]** `flow_reaches_other_function_start` | qualified | flow reaches the start of another map record (not the owner's own `<owner>.cold[.<n>]` **[v5]**): that function's body is absorbed. The code is reached by real control flow (an inlined tail call or fall-through); its ownership is what is wrong |
| **[v5]** `declared_extent_conflict` | qualified | the requested size differs from the entry record's size |
| **[v5]** `declared_extent_unreached` | qualified | no exported instruction reaches the last byte (`addr`) of the declared extent: dead code, or an extent wider than the function |
| `flow_past_unknown_noreturn_candidate` | unreliable | flow continues after a call out of the declared range |
| `pic_call_to_branch_heuristic` | unreliable | the decompiler rewrote a call as a branch |
| `conditional_tail_call_unmodelled` | unreliable | `jcc` to another known function start |
| `tail_call_inferred` | qualified | `jmp` to another known function start treated as call+return |
| `unresolved_indirect_branch`, `jump_table_hypothesis`, `decompiler_warning`, `unknown_call_semantics`, `call_arguments_inferred`, `callee_abi_assumed` | qualified | as named |

## Saved-export admission (`ghx_validate.py`)

`tools/ghx/ghx_validate.py [--image ELF] [--map FILE] FILE...` (options
anywhere on the line) admits 0.4.x with the v5 contract string only and recomputes what it can: `artifact_id`, the
qualification maximum, the contract string, admitted spans against the
export's PT_LOAD table, strict containment, outside/crossing lists, refusal
and **[v4]** undecoded reasons, **[v4]** that every admitted or undecoded
instruction starts in file-backed executable bytes (so a refusal relabelled
`undecoded` is rejected), map `used`/`entry_size` consistency, the map-extent
reason, **[v5]** the two declared-extent reasons, and the stripped reason. With `--image` it hashes the ELF, re-parses
its PT_LOAD table and flags, re-checks every admitted/undecoded start against
the image's own PF_X file bytes and compares every exported byte.

Limit **[v4, stated]**: the validator checks byte provenance, not decode
correctness. Instruction length, mnemonic, operands and raw p-code are not
re-derived (that needs a decoder): a shortened length whose bytes are a true
prefix of the file bytes, or rewritten semantics, pass.

Limit **[v5, stated]**: the map itself is not in the export, so without
`--map` the claims `function_map.supplied`/`sha256`/`records`/`used`/
`entry_size` and `flow_reaches_other_function_start` are producer-asserted,
the same class of limit as the decode fields above: an export rewritten to
claim a map entry record (and to drop `stripped_without_function_starts`)
passes. **[v5]** `--map FILE` checks them against the map the caller trusts:
the file's SHA-256 must equal `function_map.sha256`, and `records`, `used`,
`entry_size` and the set of `flow_reaches_other_function_start` addresses are
re-derived from its records. Whether each record range is file-backed
executable bytes is not re-checked (the worker refuses such maps).

## Supervisor

`ghx_supervise` writes `results.jsonl` and `worker-stderr.log` only as
regular files: an existing FIFO, device, symlink or directory under either
name exits 2 before any worker starts.
