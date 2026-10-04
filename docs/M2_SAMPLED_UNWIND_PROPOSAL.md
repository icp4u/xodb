# T10 sampled-state integration proposal

Status: workflow and critical-review revisions approved by the user, 2026-10-01.
The user clarified the initial total retained-stack budget as **32 MiB**,
configurable with the intent to revise defaults later. MCP-first inspection and
delayed reconstructed flames are explicitly approved. The first workflow is implemented: configurable capture-owned retention, MCP
inspection/coverage, background per-sample reconstruction and required archive
raw-state extension. See [current workflow and validation](M2_SAMPLED_UNWIND.md).
This proposal records the design review; it does not freeze future preferences.

## Review findings

The delivered T10 prototype demonstrates useful frame-pointer-free reconstruction,
but its patch needs adaptation before production adoption:

- It removes the newer collector rotation and its regression test. Preserve fair
  draining so a busy thread cannot monopolize bounded output buffers.
- An empty/short output slice in a later ring is normal backpressure. The decoder
  currently labels some such cases malformed. Leave those records queued for a
  later drain; reserve malformed for invalid input.
- User-state counts are committed before later weight/trailing-field validation.
  Make record commit atomic so rejected records never publish orphan side data.
- Its unwinder matches only capture-start address ranges and tests raw return
  PCs before lookup adjustment. Resolve each lookup PC using recorded mappings
  at that sample's timestamp, retaining ambiguity and metadata-loss cutoffs.
- Its Image.close passes dwarf_getcfi's borrowed debug-frame cache to
  dwarf_cfi_end. Installed libdw.h explicitly forbids this. Use the existing
  validated ELF/debug-info ownership rather than copying that loader/destructor.
- The private ELF reader has unchecked arithmetic and lacks machine validation.
  Reuse the production parser; stop explicitly at unsupported architectures,
  signal frames, missing CFI, unavailable registers or inaccessible stack bytes.

Delivered artifacts remain unchanged. Regression checks will cover the first
three issues and the existing default path. Native recurrence/short-stack tests
must validate the adapted unwinder before any caller is presented as derived.

## Proposed first user workflow

1. Add `profile.user_stack_bytes` to explicit preferences and `user_stack_bytes`
   to MCP start_profile: zero (default) disables capture; a nonzero multiple of
   eight from 64 through 8192 requests that many bytes plus the x86-64 general
   register set. Recommend 4096 when enabling. Existing captures keep their
   opening settings, and omitted MCP values follow next-capture defaults.
2. Retain only the kernel-reported valid stack prefix in capture-owned storage
   before the next drain. Use stable raw sample ordinals, explicit register ABI
   and mask, requested/record/valid lengths, and a reason when data is absent.
   Proposed initial total stack-byte budget: 32 MiB, separate from sample,
   metadata, image and archive budgets; T15 can revise it after measurement.
3. On stack-storage exhaustion, continue ordinary CPU sampling and explicitly
   mark later samples' stack data as not retained. Report it in stderr once and
   in capture summaries. Preserve original kernel callchains; do not silently
   call the capture's stack coverage complete. Allocation failure has its own
   reason. This policy was approved by the user.
4. First expose bounded per-sample DWARF reconstruction through MCP for completed
   captures, with work queued off the event loop. Results identify sample,
   mappings, resolver/asset context, algorithm version, raw PCs/SPs, lookup PCs
   and terminal partial reason. No late process-memory reads or automatic target
   resume. Live inspection and reconstructed flame modes are follow-up work;
   current flames continue to represent kernel-provided callchains.
5. Save raw registers/stacks with a required archive extension. Existing 2.0/2.1
   captures stay readable/copyable; older readers explicitly reject the new raw
   evidence rather than dropping it. Copying an opened artifact preserves its
   bytes. Reconstruct offline only with explicitly resolved matching ELF assets;
   raw data remains inspectable when those assets are absent. Source text and
   target memory are not fetched to fill gaps. Preserve no-overwrite/no-fsync
   publication and separate evidence from derived analysis.

## Short critical review requested by the user

The opt-in default, preserved kernel callchains and separate derived results are
sound. The weaker choices are the arbitrary 32 MiB budget and the usefulness of
the first interface:

- At a full 4096 bytes per sample, 32 MiB retains 8192 dumps before metadata.
  Busy workloads can fill it quickly. Make the retained-byte budget configurable
  within an independent hard bound, then use T15 measurements to choose defaults.
- Retaining early dumps biases stack coverage toward the beginning and potentially
  toward particular threads. Report retained/missing state per sample and coverage
  by time/thread; a single total or generic partial label is insufficient. Ring
  draining is not globally time ordered, so a first-drop timestamp cannot promise
  complete coverage before that instant.
- Continuing to request dumps after discarding their bytes still pays capture and
  ring-copy overhead. The proposed policy bounds retention, not that overhead.
  Explain this when the budget fills; disabling dumps mid-capture would require
  a separate, explicit transition contract rather than silently changing attrs.
- Per-sample MCP inspection is a useful first diagnostic, but postpones the main
  GUI benefit. Plan reconstructed flame views as the immediate follow-up, using
  the same provenance and partial reasons, rather than treating MCP as completion.

Recommendation: keep the basic design; revise budget configurability and coverage
reporting before enabling it. The user approved these revisions and accepted delaying reconstructed flames
until after MCP. They are implemented in the first MCP workflow. Current flames still use the original kernel callchains only.

## Gates before enabling

- Existing collector fairness/default-capture and archive regression tests.
- Decoder wrap, capacity/retry across rings, transactional rejection and bounds.
- Copy ownership across multiple drains, byte-budget exhaustion and allocation
  failure without corrupting sample ordinals or original kernel callchains.
- GCC/Clang recursion with omitted/frame pointers, short/absent stacks, missing
  CFI, signal boundaries, lookup at mapping edges and historical mapping changes.
- Owned live collection and MCP flow; archive round trip with/without matching
  assets, required-feature rejection by the old reader, cancellation and bounded
  work off the event loop. Report measured overhead and limits.

No new library is proposed. libdw remains the approved dependency. ARM64 uses
its own later register/ABI adapter; this step does not advertise ARM64 support.
