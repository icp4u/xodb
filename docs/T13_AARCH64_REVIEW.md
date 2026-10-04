# T13 AArch64 handoff review

Reviewed by Codex, 2026-10-01, against production commit `f81e16a`.
Handoff: [Grok's report](research/aarch64.md), based on `213b5004`;
prototype: `tests/repros/aarch64/`. This review supplements that unchanged record.

## Assessment

The native register, breakpoint, stepping and signal results are a useful basis
for an ARM64 backend. A standalone harness was the right first slice: it isolates
kernel behavior from the workstation's graphical and debug-library dependencies.
The report preserves failed attempts and distinguishes cross compilation from
native execution. Its architecture constants can inform the production boundary.

The weakest part is the acceptance harness. Its sampling path cannot consume perf
sample records as written, the remote runner masks failed modes, and cleanup is
not fully bounded. The watch result also conflates an unreadable value with zero.
These do not erase the successful breakpoint observations, but they prevent
accepting the harness wholesale. Production architecture selection, register
ownership and capability reporting still need implementation and regression tests.

Status: **delivered and reviewed; prototype evidence accepted with the limits
below. No production ARM64 backend or archive migration has been integrated.**

## Evidence and provenance

| Check | Result | Provenance |
| --- | --- | --- |
| Architecture and register-buffer tests, ReleaseSafe | 5/5 passed | Coordinator rerun on workstation |
| `aarch64-linux-gnu.2.27` harness build | 3/3 steps passed; static AArch64 ELF | Coordinator cross build; not native execution |
| Register/memory reads, BRK restoration, single step, signal forwarding | Successful native transcript | Grok's Jetson run, not rerun by coordinator |
| One aligned eight-byte store watch | Trap and final stored value reported | Grok's rerun; read-at-stop caveat below |
| CPU sample | Permission denied | Native sampling remains unverified; reader also needs correction |
| ARM64 CFI, full xodb, graphics | Pending | Neither local tests nor the standalone harness prove these |

Coordinator logs and input hashes:
`.work/t13-review-20261001T114510181112/{tests.log,cross.log,elf.log,inputs.sha256}`.
Source files were copied into that fresh directory before building, with private
local/global Zig caches and TMPDIR. No delivered files, installed binary, user
process, display, remote host or host policy was changed by this review.

Commands in that copy:

```sh
zig build test -Doptimize=ReleaseSafe --summary all
zig build -Dtarget=aarch64-linux-gnu.2.27 -Doptimize=ReleaseSafe harness --summary all
file zig-out/bin/harness
```

The report records Jetson kernel `4.9.337-tegra`, Ubuntu 18.04.6, L4T R32.7.6,
glibc 2.27 and GDB 8.1.1. Its recorded collection date is 2026-10-01; this is an
agent-reported host snapshot, not a coordinator recheck. Installed graphics
libraries do not establish that xodb's GUI works. Missing pkg-config entries do
not by themselves establish that runtime libraries are absent.

## Required corrections before reuse

1. **Sampling reader: `live.zig:326`.** `readOneIp` polls then calls `read(fd)`
   and treats the result as a `PERF_RECORD_SAMPLE`. There is no perf ring mmap.
   Regular sample records must be consumed from the mapped ring with correct
   head/tail ordering and record validation. See the
   [Linux perf ring documentation](https://docs.kernel.org/userspace-api/perf_ring_buffer.html).
   The current production collector already supplies that mechanism. Permission
   denial prevented this path from being exercised on the Jetson; changing host
   policy alone would not make the probe valid. T18 should use a corrected ring
   path and distinguish denied, unsupported, empty, lost and successfully decoded
   evidence. Empty is not a successful sampling acceptance result.
2. **Runner exit status: `native.sh:11`.** Each mode is followed by `echo`, so
   the final successful echo masks harness failure. The supplied transcript
   contains `EXIT watch 1` followed later by `NATIVE_EXIT:0`. Aggregate failures
   explicitly while preserving per-mode diagnostics. Test a deliberately failing
   mode locally. Capability skips need a separate summary from executed passes.
   Remote staging also overwrites an existing harness without a backup; future
   authorized deployments should use a new run directory or back up first.
3. **Cleanup: `live.zig:421`.** `killAndReap` uses blocking `waitpid(..., 0)`,
   does not retry EINTR, ignores kill failure and clears ownership after a wait
   error. Ordinary waits have deadlines, but this cleanup does not. Keep the
   child identity until a terminal status or explicit ECHILD; bound waits,
   report cleanup failure and handle interrupted calls. Exercise partial setup
   failure and tracer failure on an owned child. `runCaps` also lacks EXITKILL.
4. **Watchpoint evidence: `live.zig:161`.** A failed or short read becomes
   `value_at_stop=0`. Require a complete read or label the value unavailable.
   Recheck the before/after-store observation with the corrected probe before
   depending on it in the UI. Trap detection and the final shared-memory value
   remain separate observations. The aligned eight-byte fixture does not prove
   arbitrary byte offsets, lengths or watchpoints spanning aligned regions.
5. **Remote addresses: `live.zig:355`.** Constructing a non-null Zig pointer
   from target address zero can panic in ReleaseSafe. Changing the negative
   fixture to 0x1000 avoided the input but did not fix the helper. Return a typed
   unsupported/unreadable result for zero or use an appropriate raw syscall
   representation; never dereference a target address locally. Keep zero in the
   adverse-input tests. Also reject impossible returned regset lengths rather
   than clamping them into an apparently complete buffer.

These are prototype corrections, not requests for package installation or perf
policy changes. Preserve the original native transcript; any corrected binary
needs its own native evidence and must not inherit the old run's pass label.

## Production boundary and next work

- Keep the target ISA/ABI distinct from the frontend host. Validate ELF machine,
  byte order and register ABI together; this will also matter for remote targets.
- Encoding knowledge is distinct from an implemented backend and detected OS/CPU
  capability. `Arch.supports(.software_breakpoint) == yes` must not advertise an
  ARM64 feature in current xodb merely because BRK bytes are known.
- The published Arm mapping confirms X0–X30, SP=31 and PC=32; caller recovery
  must use the CIE return column (normally LR=30), not assume it equals PC=32.
  See [AADWARF64 register definitions](https://github.com/ARM-software/abi-aa/blob/main/aadwarf64/aadwarf64.rst#dwarf-register-names).
  The current `[17]?u64` x86 register model and return-column check need a real
  adapter. Preserve numeric register identity even when formatting names.
- Treat breakpoint-PC normalization, call-site display and CFI/mapping lookup as
  separate operations. Do not globally replace x86 PC-1 with ARM64 PC-4 without
  tests at mapping/function boundaries, exact leaf PCs and signal frames.
- Keep the production ELF/archive rejection until the respective consumers
  handle ARM64. The descriptor patch alone does not supply those consumers.
- A production target slice needs launch/exec, owned attach/detach, register
  writes, breakpoint lifecycle and multithread cleanup coverage. The successful
  fork-without-exec fixture does not exercise those paths.

[Grok's next packet, T18](tasks/T18-aarch64-sampled-state.md), now carries these
review corrections into its isolated sampling/unwind prototype. Local synthetic
work can proceed while native perf access is unavailable. The coordinator owns
shared backend/model/ELF integration. T12 remains the independent remote-protocol
lane; T13 does not imply a remote daemon is ready.

External LLM opportunity: compare architecture-specific stop transcripts and
propose focused follow-up experiments, preserving raw PC, siginfo, read status
and before/after bytes. A model must not infer a memory value from a failed read
or convert a permission skip into evidence that sampling works.
