# Live kernel-stack census

Open **K** in the system overview, or start directly:

```
xodb --overview --panel kernel_stacks
xodb --overview --headless --mcp --kernel-pid PID
```

Linux normally requires root/access to `/proc/PID/task/TID/stack`. Start xodb
with the appropriate existing permissions; it never invokes sudo, changes
kernel policy, attaches to a task or starts tracing. An unprivileged view shows
denied stacks honestly. Default startup and other panels do not collect stacks.

The panel groups identical ordered kernel-provided symbols, including callsite
offsets and module names. D-state groups come first, then larger groups. Each
group lists its member PID/TID, state, command name and wait channel. Addresses
in procfs prefixes are discarded; this also groups stacks when addresses are
masked. **P** pauses/resumes, arrows and the wheel scroll. Sampling runs on a
worker, at most once a second while visible/unpaused. Leaving the panel stops
new demand; an in-flight census can finish.

This is not an atomic snapshot, an NMI backtrace or a KGDB stop. A running task
can change state/stack during sampling. Empty, denied, vanished, unsupported and
unreadable stacks are distinct from real stacks; counts of those groups are not
evidence of identical execution. Task start times guard against ID reuse.
`--kernel-pid PID` restricts the collector to that process's threads. Without it,
the census visits all visible process task directories.

## MCP

`get_kernel_stacks` works from overview observers and debugger sessions. It
always describes the **debugger host**, not a runtime-agent machine.

- `refresh` defaults to true: request a fresh census when the cadence allows.
  False only reads the cache, and does not start or renew work.
- `start`/`limit` page groups (at most 32); `group` selects members and
  `member_start`/`member_limit` page them (at most 128).
- Save the returned `sequence` and send it with `refresh=false` while paging.
  A changed publication returns `StaleCensus`, not mixed generations.
- `user_tid` adds user frames from that thread when the original local debugger
  process already has it stopped. It checks task identity, does not attach or
  resume, and reports a reason when unavailable. User frames and the census are
  explicitly not simultaneous. Remote, core and offline process IDs are never
  joined to live host task IDs.

The overview has no debugger target, so it explains that user stacks require a
stopped debugger thread. Use the debugger/MCP for the paired view; the overview
does not acquire ptrace access implicitly. Redaction hides task names; kernel
symbols, module names and wait channels stay visible (they are not personal),
and all text still passes through the normal output policy.

## Bounds and testing

One worker, at most 32,768 tasks and 8 MiB of retained text; each stack read is
bounded at 8 KiB. A scan has a five-second budget checked between procfs reads.
Partial results expose `truncated`/`failure` rather than pretending to cover the
whole system. A single kernel read can exceed that budget; there is no hard
deadline for a wedged kernel. Large systems can scope to a PID. These are caps,
not preallocated buffers; no collection occurs at idle.

Fast registered tests cover synthetic procfs, grouping, D-state ordering,
limits, refusal versus empty data, MCP paging/refresh, local user frames and a
private GUI. The optional periodic `kernel-census-lab` step uses
`XODB_KERNEL_LAB`: a read-only kernel-lab kit plus a private initramfs and owned
guest. Its static probe creates two pipe-waiting threads and requires their
symbolized stacks to share a group. It records CPU and current RSS alongside
the sample. No lab configured is an explicit skip; a configured broken lab
fails.
