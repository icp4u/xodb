# Optimized native code

Initial x86 implementation, 2026-10-02. Build with debug information (`-g`);
optimization is supported where the compiler describes the current value.
[Matching separate symbols and source paths](SYMBOL_DISCOVERY.md) are supported.

## Inline calls

- `get_stack` retains physical frame numbers and adds `inline_frames`, ordered
  innermost first, with names, call sites and declaration locations.
- `inline_diagnostic` explains missing/unsupported debug information separately
  from a physical unwind failure. One failure does not erase the machine stack.
- `list_locals`, `evaluate_expression` and `get_value_children` accept
  `inline_depth`: zero is the innermost scope; `inline_frames.length` selects
  the outer physical function. Out-of-range selection is an error.
- Native GUI: select a physical stack frame, press **I**, then click a scope or
  use **Up/Down**. **E** evaluates an expression in that scope.
  **Wheel/PgUp/PgDn** scroll locals; **I/Esc** closes. In profile view, I retains
  its sample-inspector function.
- Inline scopes share a physical frame's registers and stack. Selecting one
  does not fabricate a separate CFA or saved register set. F12 still finishes
  the physical frame. Ordinary watch-list expressions use the innermost scope.
- The separate remote GUI does not yet have this panel; remote MCP exposes the
  same scope fields and evaluation arguments.

Example MCP arguments at a stopped inline call:

```json
{"name":"evaluate_expression","arguments":{"tid":1234,"frame":0,"inline_depth":1,"expression":"input"}}
```

## Values divided into pieces

DWARF `DW_OP_piece`, `DW_OP_bit_piece` and bounded implicit values can combine
register and memory data. x86 XMM and x87 state can supply current-frame DWARF
register locations; callers' unsaved vector state is unavailable.

Field expressions and child pages work for materialized structs/arrays. These
values have no invented memory address: `&value` and hardware-watch creation
require an actual address. Summaries expose `composite` for materialized byte
storage and `partial` when bits are missing. An aggregate can expose available
children while another field reports `PartialValue`. Missing data is never
presented as a valid zero. The initial assembly bound is 4 KiB per value.

Entry-value reconstruction, arbitrary DWARF operations, general C++ evaluation,
bit-field type layout and scalar values larger than eight bytes remain limited
or explicitly unsupported. FP/SIMD register inspection itself has the separate
[typed register panel](MEMORY_REGISTERS.md).

## Split DWARF

Live modules resolve DWARF 4 GNU and DWARF 5 skeletons to matching `.dwo` units
through libdw's DWO ID checks. Keep the `.dwo` at its recorded absolute path, or
under its recorded absolute compilation directory. Names and offsets alone do
not establish identity. Different split files retain separate type identities.

- Up to 64 opened DWO candidates, 64 MiB per file and 256 MiB of candidate file
  bytes per debug image; missing/mismatched files produce explicit diagnostics.
- Requires libdw with `dwarf_cu_info`; older builds report unsupported support.
- No `.dwp` packaging, relocated DWO search roots or source-map substitution for
  DWO paths yet. `--source-map` remaps source paths, not split-debug filenames.
- Immutable/archive analysis does not implicitly open host DWO files.
- libdw maps these local files after a regular-file/size preflight. Keep them
  stable for the session. The limits bound input files, not every libdw
  allocation; this path is not an immutable snapshot of concurrently rebuilt
  DWO files. Loading remains synchronous at first inspection.

## Reproduce

```sh
scripts/build -Doptimize=ReleaseSafe
python tests/optimized-info.py
python tests/composite-values.py
python tests/optimized-gui.py zig-out
```

The last command uses a private headless compositor. Tests exercise nested
inline scopes, caller expressions, DWARF 4/5 split files, missing/foreign files,
multiple split compilation units and GP/SIMD aggregate arguments.
[Implementation findings and evidence](research/optimized-debugging.md).
