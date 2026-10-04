# T20–T26 architecture handoff review

Reviewed by Codex, 2026-10-03, against `5dbaa5a` with Zig 0.16.0.
T24 is assigned to Claude and excluded from this review. Production sources
and the installed xodb were not changed.

## Findings

Four reproducible correctness issues need follow-up. All are P2: fix before
integrating the affected feature. The SPARC issues are in standalone candidates;
the ARM/evaluator issues are in Claude's proposed production stack.

### 1. ARM EHABI can abort on malformed unwind bytes

**Location:** [T21 adapter](../tests/repros/qemu-arm32/arm.zig), lines 984–994
(`unwindExidx`); identical to `src/target/arm.zig` in the combined patch.

The `0xb2` ULEB decoder stores its shift in `u5`. Five bytes with the continuation
bit set advance that shift through 0, 7, 14, 21 and 28, then `bit += 7` overflows
before the next iteration can check `bit > 28`. A bounded `.ARM.extab` containing
`b2 80 80 80 80 80` aborts a ReleaseSafe test with integer overflow instead of
returning `MalformedUnwindOpcodes`. Corrupt unwind metadata must not terminate
the debugger while inspecting a stack.

**Fix:** bound byte count/shift before incrementing, validate the terminal
payload against the accumulator width, and return an explicit unwind error.
Keep valid large-stack adjustments working.
[Reproduction](../tests/repros/architecture-review/arm.zig) ·
[observed abort](research/architecture-review-20261003/arm-uleb.log).

### 2. SPARC address and buffer checks can panic or return an oversized PC

**Location:** both identical adapters,
[SPARC32](../tests/repros/qemu-sparc32/adapter.zig) and
[SPARC64](../tests/repros/qemu-sparc64/adapter.zig), lines 33–47, 55–59,
127–129 and 150–152.

Three independent checks fail in both copies:

- `windowAddr(maxInt(u64), 2047, 64)` aborts: `pc + add` overflows before
  `pc + add < pc` can detect it.
- `load(four_bytes, maxInt(usize), 4, .big)` aborts at `off + width` instead
  of returning `Truncated`. `write` uses the same unsafe bounds expression.
- Decoding NOP at `0xfffffffc` in 32-bit mode returns `ok` with successor
  `0x100000000`. This path bypasses the address-width check used for CALL.

**Fix:** checked arithmetic/subtraction-based slice bounds, consistent target
address validation on every successor path, and an explicit choice of
architectural wrapping versus rejection. Never return a 33-bit 32-bit PC.
These violate the packet's explicit overflow/bounded-decoder requirements;
no production SPARC crash is claimed because no backend is integrated.
[Reproductions](../tests/repros/architecture-review/sparc.zig) ·
[overflow](research/architecture-review-20261003/sparc32-overflow.log) ·
[bounds](research/architecture-review-20261003/sparc32-bounds.log) ·
[PC width](research/architecture-review-20261003/sparc32-width.log).

### 3. SPARC's unknown-condition successor set omits a valid next instruction

**Location:** both adapters, `decode`, lines 69–81.

For `be,a +16` (`0x22800004`) at `0x1000`, with `npc=0x1004`, the decoder's
known outcomes are `0x1004` when taken and `0x1008` when not taken. Asking the
same decoder with `taken_known=false` returns `{0x1004, 0x1010}`: it omits the
untaken successor and substitutes the taken destination beyond the delay slot.
The unknown result therefore contradicts the decoder's own known results.
The C harness mirrors this logic.

**Fix:** report the correct immediate successors or explicitly refuse an
unknown condition without returning a misleading set. Test the result against
both known outcomes, including annulled/non-annulled branches and supplied NPC.
The current harness refuses `ambiguous`, so this is a component defect and an
integration risk, not evidence of an already-shipped incorrect live step.
[Reproduction](../tests/repros/architecture-review/sparc.zig) ·
[observed mismatch](research/architecture-review-20261003/sparc32-branch.log).

### 4. Cross-target evaluation still synthesizes host-width pointers

**Location:** combined patch, `src/model/evaluate.zig:127–130`
([patch](research/qemu-riscv64/stack/combined-aa23e3a.patch), line 2059).

`Context` carries target byte order, but `Parser.pointer` uses
`arch.native.addressBytes()`. On the x86-64 reviewer, a 32-bit big-endian
context returns an 8-byte pointer for `&value`, while an equivalent pointer
supplied by the target type has size 4. Both point to the same address.
This leaves the host-side m68k expression path inconsistent with its target
type metadata. The existing captured-state expression example does not exercise
address-of. Native ARM32 evaluation is not shown broken by this check.

**Fix:** carry target address width/architecture through the evaluator context,
use it for synthesized pointer types, and populate it from the image for
cross-target evaluation. Check address-of and array-to-pointer conversion.
[Reproduction](../tests/repros/architecture-review/evaluate.zig) ·
[observed 4-versus-8 mismatch](research/architecture-review-20261003/evaluate-pointer-width.log).

## Readiness by packet

| Packet | Delivered evidence | Review disposition |
| --- | --- | --- |
| T20 RISC-V64 — Claude | Combined production candidate; guest ptrace, MCP and remote GUI evidence | Near integration; no additional RISC-V-specific blocker found in this review |
| T21 ARM32 — Claude | Combined production candidate; ARM/Thumb, EHABI, guest MCP and remote GUI evidence | Fix finding 1 before integration |
| T22 PPC64LE — Claude | Combined production candidate; guest ptrace, MCP and remote GUI evidence | Near integration; documented stepping/optional-feature limits still apply |
| T23 m68k — Claude | O0/O2 C harness, decoder replay, host ELF/DWARF/eval against captured state | Useful partial implementation; fix finding 4; live xodb still toolchain-blocked |
| T24 hppa — Claude | User assigned it during this review | In progress; excluded |
| T25 SPARC64 — Grok | ABI/kernel C probes, three host adapter tests, enum-only patch | Partial handoff; findings 2/3 and independent Stage B work remain |
| T26 SPARC32PLUS — Grok | Compat ABI probes; same adapter; failed full-regset write round-trip | Partial handoff; same fixes plus register-write diagnosis remain |

These are different completion levels. Only T24 lacked a completed handoff;
T23/T25/T26 do not yet provide live xodb services. The reports generally state
that limitation plainly, and permission-denied perf results are correctly
separated from absent hardware support.

### SPARC work still required independently of the Zig build

1. **Read condition codes instead of accepting the fixture's expected answer.**
   `harness.c:996–1018` feeds `taken_bet`/`taken_ben` into `step_one`; they use
   fixture PC/constants, rather than stopped ICC/XCC state. This verifies the
   selected delay-slot mechanics but does not demonstrate an autonomous
   conditional-branch stepper. Implement condition evaluation or a correct,
   conservative fallback, and compare both outcomes with actual guest stops.
2. **Run controlled O0 and O2 fixtures.** `run-guest.sh:10–15,34–40` builds the
   live harness only at O0. It compiles `frames-o2` for `readelf` inspection;
   it never debugs that executable. The contract's optimized live-control
   evidence remains missing.
3. **Diagnose the SPARC32 write discrepancy.** The supplied transcript really
   reports `gchanged=1 ctl_same=0 other_same=0` and `FAILS 1`. Preserve that
   finding, but record complete before/after bytes, returned lengths and errno,
   then verify restoration and resumption. `parent_regs` currently ignores the
   restoring SETREGSET's result. Test narrow/legacy writes separately; the
   current log does not establish the root cause or a general kernel defect.
4. **Finish build feasibility using shared work already delivered.** Reuse the
   reviewed ELF32/big-endian foundation instead of redoing it. Missing target
   libraries and a default-linker error are immediate build blockers, not proof
   that every build route is unavailable. Isolate the SPARC64 relocation issue
   and evaluate the guest toolchain/link route. Preserve the exact SPARC32 LLVM
   failure and a runnable minimal source. The two enum patches both edit
   `src/target/arch.zig`; merge them deliberately. T26's claim that they do not
   share a file is incorrect.

The SPARC adapters also expose field descriptors rather than a complete strict
regset decoder/writer. Wire exact buffer lengths and preservation checks into
that boundary before it touches a live target. A helper such as `requireLen`
being tested in isolation is not equivalent to enforcing it for every decode.

## Verification performed here

- Applied Claude's **combined** patch to an isolated copy of current `5dbaa5a`;
  it applies cleanly. Input hashes are in
  [inputs.json](research/architecture-review-20261003/inputs.json).
- Fresh native `scripts/build test -Doptimize=ReleaseSafe --summary all`:
  **351 passed, six skipped; 27/27 build steps succeeded**. Owned native
  ptrace/perf tests ran as the ordinary user outside the sandbox.
  [Log](research/architecture-review-20261003/native.log).
- Fresh headless cross-builds of that same tree: **ARM32, RISC-V64 and PPC64LE
  all compiled and linked**. Read-only cached guest sysroots were reused;
  these new binaries were not deployed/run.
  [ARM32](research/architecture-review-20261003/cross-arm32.log) ·
  [RISC-V64](research/architecture-review-20261003/cross-riscv64.log) ·
  [PPC64LE](research/architecture-review-20261003/cross-ppc64le.log).
- Both SPARC adapters' supplied tests pass **3/3**. The additional review checks
  compile, then fail as documented: one ARM abort, one evaluator mismatch and
  four SPARC failures in each adapter copy.
  [Results and source hashes](research/architecture-review-20261003/results.json) ·
  [replay instructions](../tests/repros/architecture-review/README.md).
- Reviewed Claude's supplied guest/GUI/cleanup evidence; **did not rerun SSH
  sessions, physical hardware, Android or AArch64** in this review. The supplied
  integration stack records AArch64 compilation, not a new native ARM64 run.

No candidate was applied to production. Evidence logs replace the local checkout
prefix with repository-relative paths and anonymize file ownership. The installed binary, other agents'
owned paths, guests and system configuration were left unchanged.

## Suggested follow-up handoffs

**Claude (after T24):** fix the ARM unwind bound in T21 and the target pointer
width in the shared stack; add these repros to the candidate's tests. Deliver
an updated combined patch with its base/hash, fresh native gate, cross-builds
and targeted ARM guest smoke. Preserve existing explicit refusal of unsupported
profiling/watches/process following. Coordinate shared changes through patches.

**Grok:** keep T25/T26 open. Fix the common adapter with the supplied repros,
replace fixture-supplied branch decisions, run O0/O2 live control, and diagnose
SPARC32 register-write preservation. Then pursue the smallest viable build route
on the updated shared target model. Keep measured capability outcomes separate
from untested port claims. Stay within the original T25/T26 owned paths.

**Codex integration order:** review the corrections, integrate the common model
and RISC-V/ARM32/PPC64LE service candidates, then repeat a bounded guest/MCP smoke
against the exact integrated build. Keep m68k metadata support explicitly
separate from live target support; fold SPARC in when its independent gates pass.

## Agent-assisted investigation ideas

An external local or remote model could generate malformed EHABI streams and
branch-condition combinations, then reduce failures to deterministic fixtures.
It could also compare SPARC regset byte diffs with the recorded ABI and suggest
which offsets to probe next. Treat those suggestions as hypotheses: bounded
component tests and owned guest runs must establish the result. No embedded
model runtime is proposed.
