# T10: sampled-stack unwinding prototype

Status: delivered by Grok; the corrected collector, capture-owned retention,
MCP worker reconstruction and raw-state archive extension are integrated by Codex.
See [workflow and validation](../M2_SAMPLED_UNWIND.md). Native derived-stack views
are the follow-up T16 packet; this prototype packet remains the delivery record.

## Goal and ownership

Improve evidence for native programs built without frame pointers. Produce a
measured, bounded offline DWARF unwinding prototype using perf-captured user
registers and stack bytes. Keep the current working profiler untouched.

Own only:

- `tests/repros/sampled-unwind/`
- `docs/research/sampled-unwind.md`
- `docs/research/sampled-unwind/`

Read `docs/PROFILING.md`, `docs/M2_MAPPING_PROPOSAL.md`, `src/profile/records.zig`,
`linux_perf.zig`, `capture.zig`, `src/debug/info.zig` and T04 workload research.
Proposed production changes belong in a patch under your research directory,
tested in a fresh repo-local scratch copy. Do not edit shared production/build,
other tasks, milestones or this assignment packet.

## Requirements

- Evaluate opt-in PERF_SAMPLE_REGS_USER / PERF_SAMPLE_STACK_USER on owned targets
  using installed Linux headers. Preserve current default collection and scope.
  No inherited/system-wide collection or system permission changes.
- Decode register ABI/mask, captured stack length and dynamic size, absent data,
  wrapping, truncation, bad bounds, output backpressure and loss. Keep explicitly
  bounded bytes per sample and total retained bytes, not only a sample count cap.
- Offline unwinding may read only captured registers/stack and retained matching
  ELF metadata. Never read a running target later and call that historical state.
- Account for sample timestamp/mapping identity, return-address adjustment,
  architecture, signal frames, missing CFI, stack holes, invalid pointers,
  recursive frames and maximum depth. Return a partial stack with a reason.
- Build on the approved installed libdw dependency where practical. Capture
  memory adapters must remain separate from live debugger memory reads.
- Treat offline reconstructed callers separately from kernel-provided callchain
  evidence. Supply a typed contract and provenance; do not silently substitute.

## Evidence and handoff

1. GCC/Clang optimized recursion fixtures with and without frame pointers.
   Compare known call structure and available GDB/perf evidence; identify oracle
   limitations instead of assuming an exact instruction match between runs.
2. Failure fixtures: undersized stack capture, absent CFI, malformed records,
   invalid return address and truncated mapping metadata. Confirm bounded work.
3. CPU-only versus additional stack-data collection on T04 frame/server fixtures:
   bytes/sample, ring pressure, loss, capture duration, drain/unwind CPU, memory
   and elapsed-time variation. Avoid broad machine saturation.
4. Reproducible runner, exact compiler/kernel versions, primary source references,
   API proposal, patch, budget recommendation and limitations. No package install
   or dependency selection without coordinator review.

Use only owned processes and private graphics if needed. A sandbox permission
error is not a workstation capability result.

Record external LLM opportunities: partial-stack confidence, workload comparison,
recognizing when more evidence is needed. No model is embedded in the collector.
