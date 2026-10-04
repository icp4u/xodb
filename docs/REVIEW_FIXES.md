# Public review follow-up

Reviewed baseline: `0f38e64`. Local verification: 2026-10-03, Linux x86-64,
Zig 0.16.0, ReleaseSafe. Original reviewer scripts and logs are kept outside
the checkout; this document contains only the implementation and test summary.

## Repairs

| Finding | Change | Regression |
| --- | --- | --- |
| Investigation metadata after exec | Retention copies all nested strings, including enums, previews, frame names and source paths, into the evidence arena. | Poison borrowed strings; investigate an enum, exec, query and export the retained record. |
| Btrfs file identity | Shared validation normalizes the candidate's device through a temporary, unread mapping. It retains inode checks and compares kernel-rendered paths when an exact mapped-file descriptor is unavailable. Privileged allocation validation requires the exact descriptor on Btrfs. | Real proc mappings plus simulated Btrfs stat numbers; unrelated files, wrong devices/inodes and a different path with the same inode are rejected. Actual Btrfs remains unverified here. |
| Partial memory writes | `PartialMemoryWrite` reports a successful prefix followed by failure. The memory event records its address/count; generation advances and MCP records `write_memory_partial`. Unpatched breakpoint bytes change only after the physical write succeeds. | Cross into an unmapped page; inspect bytes, generation, event and audit; reject the stale generation. Also fail a write beneath a disabled breakpoint after its mapping disappears. |
| MCP bursts | Flush replies before consuming more requests; retain buffered input under backpressure; bound each pump's request count. A single oversized reply becomes a protocol error. | 64 pipelined tool-list requests with an active reader; repeat with EOF after the burst; check oversized replies separately. |
| Truncated live ELF | Ordinary live modules now use owned snapshots rather than retained file mappings. | Cache two library instances, truncate the backing file, then query symbols and source again. |
| Recursive typedefs | Finalize aliases after constructing the complete recursive type graph. Discard unfinished cache entries on construction failure. | Explicit struct and typedef/qualified paths through a linked list, in both lookup orders. |
| Repeated ELF loads | Apply the existing per-placement mapping checks to standalone ELF as well as APK entries. | Two `dlmopen` instances resolve source at both real function addresses. |
| Inferior signals | Save the inherited dispositions before installing debugger handlers; restore them in launch children, including restarts. | Native and debugged SIGPIPE fixtures both terminate with signal 13 after delivery. |
| Portable test partition | Guard the real syscall collector test with `requireLive`; retain a separate unprivileged descriptor-cleanup test. | Portable test suite passes without executing the privileged test. |
| Vulkan result 5 during initialization | Query and allocate enumeration storage, retry `VK_INCOMPLETE`, and allocate swapchain resources for the returned image count. | Private GUI with 96 formats, a count change during enumeration, and 24 image entries; normal hidden-workspace/resize/cleanup test. |

Module loading failures are now retained in `list_modules.load_failures` and
reported on stderr. Symbol search returns a loading failure when incomplete
inspection prevents it from establishing that a symbol is absent. Non-ELF
file mappings are still skipped.

The stale hosted-CI claim was removed. `README.CODEX.md` and `DAY1.md` are
labeled as historical, and the main README's process/debug-info/tracing limits
were corrected. Larger schema/dispatch refactoring is deferred.

## Verification

- Headless portable Zig suite: **210 passed, 35 skipped, 0 failed**.
- Native GUI-enabled Zig suite: **298 passed, 4 ARM skips, 0 failed**.
- Host integration steps: **25 passed**.
- Focused boundary suite: **8 passed**, including retained evidence export.
- Vulkan enumeration and hidden-workspace/resize tests passed on NVIDIA.
- Formatting and patch whitespace checks passed.
- Original reviewer repros were rerun with temporary paths redirected outside
  the checkout. The burst returned all 64 responses; partial writes advanced
  generation and audit; both library instances resolved and survived truncation;
  recursive fields resolved; SIGPIPE terminated the inferior with status -13.
- The reviewer's exact enum crash did **not** reproduce on this host's original
  build. The borrowed-string defect was confirmed by inspection; the repair is
  covered by deterministic string poisoning and the exec/query/export sequence.

`tests/review-boundaries.py` is part of the host gate.
`tests/mapping-identity.py` runs in the portable gate too, and accepts
`XODB_IDENTITY_TEST_DIR` pointing to an existing writable Btrfs directory.
`tests/vulkan-enumeration.py` is part of the GUI gate. As with the other release
tests, run them in an external source snapshot to keep artifacts out of the
working checkout; stage new inputs before using `scripts/release-check`.

## Tradeoffs and remaining platform checks

- Owned live ELF snapshots use the existing **256 MiB per image / 512 MiB total
  per module collection** limits. Initial loads now read the complete selected
  ELF into owned memory; this costs memory and synchronous I/O, and larger
  images report `BinarySnapshotLimit`. Retained metadata describes that snapshot,
  not subsequent in-place edits to the file.
- Btrfs unprivileged validation uses device, inode and the kernel's mapped path;
  it is conservative about aliases and inaccessible paths. It does not supply
  a mount-change transaction. The privileged helper requires the pinned mapped
  object and never authorizes probes using only this pathname fallback.
- Actual Btrfs subvolume runs still need confirmation on the review host.
  Simulated device-number differences do not establish filesystem sign-off.
  The reviewer's separate surface-format fix now passes on Radeon RX 7900 XTX;
  our exact combined patch still needs that hardware check.
- This pass did not exercise Android, ARM64, GPU reset recovery, or privileged
  allocation capture. Existing architecture skips remain explicit.

## Second reviewer addendum

The follow-up labeled 2026-10-04 adds real Radeon startup evidence and an MCP
session against a 31-thread editor. The original review payloads are unchanged;
all 13 added text artifacts match their supplied SHA-256 manifest.

- On Radeon RX 7900 XTX, the driver returned 99 surface formats. The old
  64-entry buffer returned `VK_INCOMPLETE` and repeatedly prevented startup.
  The reviewer's independent count-query/allocation/retry fix rendered three
  frames and exited cleanly. Their 96-format and 96-to-97 growth tests passed.
  This confirms the cause addressed by our enumeration fix; it is not a run
  of our exact combined candidate.
- The live MCP session completed a 15-second capture, scheduling queries,
  instruction inspection, speedscope export and archive publication. It
  recorded three CPU samples, 828 scheduler events and no reported loss.
  Procfs recorded about 30 ms of target CPU time: sparse samples are consistent
  with this mostly idle observation and cannot establish performance hotspots.
- The session still reported `BinaryIdentityUnavailable`, retained no ELF
  images and could not resolve names or unwind beyond frame zero. These are
  consistent with the already reproduced Btrfs defect; this session does not
  demonstrate whether our identity repair works on the reviewer's filesystem.
- `NotStopped` and `StaleSnapshot` responses match concurrent GUI control.
  Unknown scheduling intervals remain explicit. The renderer log reports
  deferred compositor callbacks with an active event loop, without a crash.

No additional defect is established by this transcript. The next useful
external check is to rebuild the combined repair, rerun the Btrfs identity
reproduction on its original subvolume, and then check live editor symbols,
stacks and a fresh capture. An active-workload capture is useful after symbols
load; these three idle samples are not a performance baseline.
