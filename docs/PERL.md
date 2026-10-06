# Perl values and logical stacks

A native stop in a threaded Perl 5.44.0 debug build can show Perl values through
**Locals**, **E** expression watches, and MCP `evaluate_expression`. The first
supported stopped-memory profile is Linux x86-64, LP64, little-endian. It requires
full interpreter DWARF and a GNU build-id in the loaded image. No Perl headers,
CPAN packages, or Perl installation are needed to build xodb itself.

## Try the array demo

```sh
scripts/demo-perl
```

Press **Space** to stop at `Perl_av_store`, then **E**, type `val`, **Enter**.
The new element is **undef (refcnt 1, flags 0x0)**: the assignment of 42 happens
*after* this call. Stale bits in `sv_u` are not a value. `av` displays an array
summary. A defined scalar at a later stop displays `IV 42` once its IOK flag is
set. The automated XS fixture also supplies an already initialized IV 42.

The visualizer shows IV/UV, NV, escaped PV bytes, one reference level, at most
eight AV slots or HV entries, and CV/GV names. Refcount and flags remain visible.
MCP includes bounded elements under `value.visualization.perl.items`. GUI watches
show the same summary; expanding a native pointer still exposes its DWARF fields.
PV previews read at most 128 bytes; shortened output is marked `truncated`.
Unmapped memory, freed scalars, inconsistent flags and unavailable names have
explicit diagnostics. Magic is never invoked: these are stored values, not the
result of a Perl expression or tied-variable fetch.

## Read the Perl stack through MCP

At a retained stop, use the TID and generation returned by `get_session`:

```json
{"name":"get_language_stack","arguments":{"tid":1234,"language":"perl","generation":7}}
```

This observer-readable tool needs no controller lease. It returns `segments`,
each with a runtime build-id, an interpreter instance **address scoped to this
process and stop**, logical `frames`, and an `anchor` citing a native frame index
and PC. `frame` optionally selects the first native frame to inspect (0–63).
Source locations describe the active operation in the innermost sub and the
call site in each caller. Names/file bytes that are not UTF-8 are escaped.

Native frames are available separately through `get_stack`. Multiple Perl
interpreter instances have separate segments, ordered by their native runops
anchors. Repeated anchors for the same instance produce one partial segment
with `additional_anchors` and `RepeatedInterpreterAnchorBoundaryUnavailable`;
xodb does not guess which logical frames belong to each native activation.
An unanchored observation carries `anchor: null` and supplies no cross-runtime
ordering. Other languages are not detected by this implementation.

The reader obtains `my_perl` from the selected native frame's DWARF location.
It does not treat the TLS symbol `PL_current_context` as an ordinary address or
guess from volatile registers. Optimized-away arguments therefore produce an
explicit partial result. Loaded build-id bytes and version globals must match
the image whose DWARF supplies the layout. Wrong versions, architectures or
identities are refused. Tests temporarily alter and restore only an owned
fixture's private version/build-id bytes to exercise both refusals. Scalar previews also refuse different Perl library
builds in one process because native value types do not yet retain their owning
image identity; multiple instances of the same build are supported.

Each segment is bounded by 128 logical frames, 32 linked stack-info records,
4096 contexts, 8192 reads and 512 KiB read bytes. Names are bounded to 255 bytes,
paths to 1023. The tool inspects at most 64 native frames and reports an incomplete
native walk. Read failures or corrupt contexts return partial evidence with a
reason. It never resumes the target or calls a function in it.

The frames use the logical-frame vocabulary (`kind`, `provenance`, source
location), but the MCP segment response is **not** an importable logical-frame
JSONL document. A secondary GUI Perl-stack pane is a separate follow-up; this
change adds the MCP stack and the existing GUI value-model integration.

## Export from a cooperating Perl program

```perl
require './scripts/logical-frames/xodb_lframes.pl';
sub work {
    XodbLFrames::emit('perl-stack.jsonl', max_depth => 128);
}
work();
```

Call `emit` at the point you want to observe. It captures the current thread,
excludes its own frames, and atomically publishes a new file without overwriting
one. It uses core Perl modules only. The result is a version-1
`xodb.logical-frames` document with `source_kind: cooperative_emit`, innermost
frames first, and weight **one observation**, not CPU time.

```sh
cc -std=c11 -O2 src/profile/logical_frames.c src/profile/logical_frames_main.c -o xodb-lframes
./xodb-lframes validate perl-stack.jsonl --strict
./xodb-lframes frames perl-stack.jsonl
```

Perl's `caller()` can omit XS/native frames. `complete` describes that caller
chain only. A known XSUB is classified through `B`; unresolved anonymous frames
stay unclassified. File digests describe bytes read during export, not proof of
the code loaded by the runtime. Invalid UTF-8, embedded NULs or oversized
identities are refused rather than silently renamed. Depth limits are explicit.
There is no asynchronous sampling or cross-thread snapshot claim.

## Verification

```sh
scripts/build test -Doptimize=ReleaseSafe -j3
python3 tests/perl-language.py --perl /path/to/debug/perl --work out/perl-test
python3 tests/perl-gui.py --perl /path/to/debug/perl --fixtures out/perl-test --work /tmp/perl-gui-test
```

Use new output directories. The GUI test creates its own headless compositor;
keep its work path short for Unix sockets. Integration covers recursive exact
name/file/line agreement, eval/die, a Perl thread, an XS callback, initialized
values, recursive entry and two nested interpreter instances. Synthetic C tests
inject corrupt indices, cycles and individual failed reads; they run in the
normal build test step. Real-run evidence contains process identities and stays
in the supplied output directory, outside version control.

The memory-reader callback, bounded output structs and native-anchor response
are reusable for another language. Its context layout, scalar flags, interpreter
location and frame semantics require a separate runtime-specific implementation.

At pp-function entry, an unwound interpreter anchor may lack recoverable
`my_perl`. Such anchors remain partial. Every segment outside an unresolved
inner anchor is also partial (`InnerInterpreterAnchorUnresolved`); its current
contexts are not claimed to belong to that outer activation. When all anchors
are unresolved, a readable frame argument provides an unanchored partial
observation, with no ordering claim relative to the anchors.

Deep context stacks are read from their newest end. At most 128 frames and
4,096 contexts are retained/examined; reaching either bound reports `FrameLimit`
or `ContextLimit`. Source filenames are cached within one read and a failed or
truncated filename is null. Block eval, try, G_EVAL and ithread entry may have
no eval CV; only string eval requires one.

Magical scalar previews carry `stored_value_only` and the diagnostic
`StoredValueOnlyMagicNotInvoked`; no magic is invoked. PV previews report the
UTF-8 flag separately from the escaped byte display. Class objects (`SVt_PVOBJ`)
are valid but unsupported. Exporting preserves the caller's `$@` and reads each
source file at most once per emission.
