# M2 basic Rust/Zig value views

xodb now shows named integer enums, Rust/Zig slice lengths and bounded byte/text
previews in the locals pane. Observe-scoped MCP can page through fields and
array/slice elements. These views use stopped target memory and compiler DWARF;
they do not execute target code.

## Demo

```sh
mkdir -p .work/value-demo
rustc -g -C opt-level=0 -C force-frame-pointers=yes \
  tests/fixtures/values.rs -o .work/value-demo/rust-values
./zig-out/bin/xodb --break value_checkpoint --source tests/fixtures/values.rs \
  -- .work/value-demo/rust-values
```

Use a new output path, or back up an existing fixture before rebuilding it.
Press **Space** to reach the checkpoint, then click **#1** in the stack. Its locals
include `mode = Idle (-2)`, a three-element `slice`, an escaped string, and an
invalid-UTF-8 byte slice displayed as hex. Stack selection refreshes the same
summaries exposed by MCP. The pointer and length remain inspectable as raw fields.

![Rust caller locals in the private GUI](images/m2-values.png)

## MCP

```json
{"name":"get_value_children","arguments":{"tid":1234,"frame":1,"expression":"slice","generation":37,"start":0,"limit":2}}
```

Required: `tid`, `expression`. Optional: `frame` (0–63, default 0), `generation`,
`start` (default 0), `limit` (1–64, default 16), and `raw` (default false).
The result includes the original expression/root summary, presentation kind,
`total`, `start`, `next` and children with index, name and value summary. Preserve
the stopped generation while paging. `next: null` means the end; `start == total`
returns an empty page, and a larger start is rejected.

Structs expose named fields, arrays expose elements, and recognized slices expose
elements. `raw: true` exposes a slice's recorded pointer/length fields. Scalars
and pointers have no automatic children. Use an explicit expression such as
`*pointer`, `slice.data_ptr[0]` (Rust), or `slice.ptr[0]` (Zig) when choosing to
follow a pointer. The expression evaluator remains the existing small C-like
subset; it does not parse arbitrary Rust or Zig syntax or call methods.

`list_locals`, `evaluate_expression` and child summaries include `language`, an
optional `enumerator`, and optional `visualization` evidence: data address,
count, element type, bounded text/hex preview, truncation, diagnostics and basis.
Byte previews are at most 64 bytes. Empty slices never read their data pointer.
UTF-8 is displayed as escaped text; invalid bytes (including a split codepoint
at the preview boundary) retain exact hex. A byte slice is not assumed to be a
string merely because its prefix decodes as UTF-8.

## Recognition and limits

- Integer enum names come from DWARF enumerators and underlying integer type.
  Unknown numeric values stay numeric; at most 1,024 enumerator DIEs are read.
- Rust `&[T]`, `&mut [T]`, `&str` and `&mut str` require Rust CU language metadata
  and exactly the compiler-described `data_ptr`/`length` fields.
- Zig `[]T` requires Zig CU language or `zig ` producer metadata and exactly
  `ptr`/`len` fields. The installed Zig 0.16 LLVM backend emits C99 language;
  producer evidence handles that case explicitly. Sentinel slices are pending.
- Offsets, sizes and pointed-to types come from DWARF, with field overlap and
  address overflow checks. No fixed Rust/Zig memory layout is assumed. Rust's
  [layout reference](https://doc.rust-lang.org/stable/reference/type-layout.html)
  documents the distinction between slice data and pointer representations;
  this adapter uses observed debug metadata for its supported producers.
- No automatic traversal of arbitrary pointers, Vec/String internals, smart
  pointers, tagged unions, niche layouts, trait objects or active variants.
  DWARF variant parts are explicitly unsupported. The Rust Option fixture now
  reports unsupported instead of a misleading empty struct.
- Optimized register pieces/entry-value reconstruction remain unsupported. The
  Rust O2 fixture's split `slice` location reports unsupported; its other tested
  addressable values work. No target memory is guessed for an unavailable value.
- Aggregate fields are capped at 4,096. Nonzero/multiple subranges stay unknown,
  including repeat queries through the type cache. Zero-sized elements carry
  type/count evidence without inventing memory contents.

The namespace scope fallback fixes an observed Rust crash: libdw returned zero
scopes from the CU despite finding them when queried at its namespace DIE.
A bounded namespace walk retries the library and retains outer scopes (depth 64,
65,536 inspected children). Empty results now return a diagnostic. No external
library patch or replacement was needed. Language codes follow
[the DWARF registry](https://dwarfstd.org/languages.html); libdw headers provide
the installed API constants.

## Verification

```sh
python3 tests/m2-values.py
python3 tests/m2-values-gui.py
```

The live matrix builds installed Rust Debug/O2 and Zig Debug with LLVM/native
backends. It checks enum names, arrays/structs, slices/text/bytes/empty slices,
raw fields, page boundaries, observe scope, stale generations and unchanged
registers. Optimized split locations are checked as explicitly unsupported.
The graphical test uses a private headless Sway session and selects the caller
frame; it never operates on the user's desktop. Unit tests cover changed field
order, missing producer evidence, invalid pointers, address overflow, large
lengths, preview/page caps and signed/unsigned enum matching.

This is the initial Rust/Zig value view milestone, not general language runtime
support. Rich container and variant adapters should be added only with compiler
fixtures, layout provenance and an explicit unsupported path.
