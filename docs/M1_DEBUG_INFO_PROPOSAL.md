# M1 debug information decoder proposal

Use the installed elfutils `libdw` (0.196) as the DWARF and CFI decoding
primitive, with a narrow Zig adapter producing xodb-owned source locations,
frames, types, variables, and availability states. Keep expression evaluation,
breakpoint/stepping semantics, process control, and agent policy in Zig.

Approved by the user on 2026-09-30 after reviewing the completed T01/T02
handoffs. Grok recommended adapting Zig parsers; the user selected libdw for
M1 development speed. Fable/Claude's T01 ELF reader remains the route for binary images,
symbols, and explicit load-bias handling.

The installed headers expose line tables, DIE attributes/references, scopes,
location-expression decoding, CFI lookup, CFA expressions, and saved-register
rules. The adapter would decode these into typed records and evaluate locations
against xodb's own stopped target, without changing who controls the inferior.

The immediate benefit is getting source mappings, locals, and stack unwinding
into the M1 experiment without first implementing the entire DWARF byte parser.
The cost is a new system-library dependency and its lifetime/error conventions;
keep those within one adapter. Compiler coverage and unsupported expressions
still need explicit fixtures and availability errors.

Acceptance remains deterministic: compare GCC/Clang DWARF 4/5 fixtures with
independent tools; verify source, locals, stack frames, and watchpoint evidence
against known values. The implementation decision can be revised after T02's
source and license review. Preserve library provenance in DEPENDENCIES.md if
adopted.
