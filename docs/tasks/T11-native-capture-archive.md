# T11: bounded native capture archive prototype

Status: ready, unassigned. Suggested owner: Fable/Claude.

## Goal and ownership

Design and test a small versioned archive that can reopen captured evidence
without a live target. The new Speedscope export is an aggregate and cannot
restore arbitrary time filters or scheduling history. Prepare a concrete codec
and integration proposal for native reopening; do not replace that export.

Own only:

- `tests/repros/capture-archive/`
- `docs/research/capture-archive.md`
- `docs/research/capture-archive/`

Read `src/profile/capture.zig`, `records.zig`, `mappings.zig`, `scheduling.zig`,
`intervals.zig`, `export.zig`, `docs/PROFILING.md`, `M2_TIMELINE.md` and journal.
Prototype only in owned paths. Shared production/build/UI/MCP changes belong in
an optional patch tested in a fresh scratch tree; Codex owns integration.

## Contract to establish

- Versioned, architecture/endianness/clock-explicit records; no serialized native
  pointers or unchecked host struct images. Preserve absence separately from zero.
- Retain CPU samples, opening task identities, mapping history, scheduling events,
  imported intervals/provenance, debugger markers, collection settings and loss.
- Define module identity and what is self-contained versus reloaded from external
  ELF/source files. Never trust current files at recorded paths without identity
  checks. Show raw addresses if matching symbol evidence is unavailable.
- Separate completed offline capture identity from live session/generation and
  target mutation. An opened archive must not authorize actions on a live process.
- Validate all counts, offsets, lengths, record tags and cross references before
  allocation or indexing. Establish total input/memory limits and version errors.
  Avoid compression/dependency additions for this initial proof unless measured
  need warrants a separate recommendation.
- Preserve source evidence exactly; regenerate derived flame/scheduling views
  through the shared semantics, not independently implemented approximations.
- Publish new files without overwriting existing destinations. Handle truncated
  writes and cleanup. Document crash/power-loss guarantees accurately.

## Evidence and handoff

Supply a deterministic codec runner, fixtures and exact commands. Round-trip
CPU/filter counts, recursion, reused mapping ranges, unknown/lost scheduling
spans, imported labels and whole-capture debugger markers. Exercise empty captures,
all field absence cases, max budgets, invalid/mutated/truncated inputs and trailing
bytes. Show bounded allocations and that parsing never reads target memory.

Measure representative and budget-sized file/memory/time costs, with separate
encode/decode/derived-view timings. A standalone synthetic demo is sufficient;
use owned live fixtures only if useful. Do not touch the user's running programs.

Back up existing files; keep artifacts/caches in the repo;
private headless graphics only. No system changes, paid tools or remote writes.
Return design choices needing user review as a short concrete list, with the
prototype and evidence already available. Journal potential external LLM uses
for offline comparative investigations, preserving uncertainty and provenance.
