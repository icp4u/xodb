# T01 ELF and symbol reader

Goal: give M1 a small, deterministic reader for executable images and symbol
lookup. This packet is independent of the GUI and target-control implementation.

## Ownership and scope

Own `src/binary/elf.zig`, `tests/fixtures/elf/`, and `docs/research/elf.md`.
Read the shared agent-task index before starting. Do not edit `build.zig` or
session/target code; provide the small integration patch as a proposal.

Implement in Zig 0.16 over an immutable byte slice with explicit ownership.
Support the current ELF64 little-endian x86-64 executable/shared-object targets.
Report unsupported encodings/formats clearly, keeping those assumptions at the
format boundary so later architectures can be added.

Expose a compact typed view of the ELF header, program headers, named sections,
`.symtab` and `.dynsym` entries, and symbol name/address lookup. Preserve the
meaning of link-time addresses. Document how a caller supplies load bias for
PIE/shared objects; never silently treat file offsets as runtime addresses.
Avoid inventing the future session database or parsing DWARF in this task.

## Acceptance

- Validate every input range, entry stride, string offset, and arithmetic
  operation before indexing. Truncated/malformed bytes return errors, not traps.
- Cover a GCC or Clang executable, PIE, shared object, and stripped object.
  Keep fixture sources and a reproducible build script.
- Compare selected section/symbol results with `readelf` or `llvm-readelf` by
  semantic values, not formatted output equality.
- Include inline Zig tests for malformed inputs and lookups. Document a direct
  `zig test` command with all caches inside the workdir so tests can run without
  shared build changes.
- Document support for, or explicit rejection of, extended section numbering,
  missing section tables, duplicate names, and undefined symbols.
- Record any borrowed code's origin, version/commit, license, and modifications.

## Handoff

Deliver the implementation, fixture sources, test results, API usage example,
load-bias contract, and known gaps. Identify exactly how M1 can bind a parsed
image to a live module without requiring T02 to be finished.
