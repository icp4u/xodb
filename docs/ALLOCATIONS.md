# Allocation tracing

Native Linux x86-64 allocator entry/return tracing, with a local inspector and
MCP controls. The workflow was adopted on 2026-10-03. Live glibc, boundary, cleanup and private GUI checks pass; see [the implementation journal](research/allocation-tracing.md).

## Quick demo

Build with `./scripts/build -Doptimize=ReleaseSafe`. On this workstation perf
uprobes require elevated creation permission. Authorize sudo in your terminal,
then explicitly opt in to the short-lived helper:

```sh
sudo -v
sh scripts/demo-allocations \
  --allocation-helper "$PWD/zig-out/bin/xodb-allocation-helper"
```

The script builds a small owned workload inside `.work/`; xodb cleans up its
owned process on exit. It does not change host policy. Without the helper option,
xodb attempts ordinary-user perf access and reports the real permission error.

1. **Space** runs past the loader to `allocation_marker` with phase=0.
2. **A** opens allocations. **P** or **Start capture** selects the currently
   highlighted stopped thread and prepares malloc/calloc/realloc/free probes.
3. Wait for **Tracing selected threads**, then **Space** runs the workload.
4. At the second `allocation_marker` stop (phase=1), press **P** to stop/drain.
5. **L** shows lifetimes; **O** shows one outstanding block requesting **29 bytes**.
   The fixture also includes a failed realloc that preserves its old allocation.
6. **Esc** returns to source. **Q** closes xodb.

The record count can exceed twice the user-visible allocator calls: glibc may
tail-reenter free during initialization. Both entry/return pairs remain in the
Calls/Events pages; complete matching nested operations are counted once.

## Inspector

| Key | Action |
| --- | --- |
| A | Open allocations in the local debugger |
| P / Start / Stop / Cancel | Start on the selected stopped thread, stop collection, or cancel preparation |
| Space / F5 / F6 | Continue or interrupt the target while the inspector is open |
| C / L / O / E / F | Calls / Lifetimes / Outstanding / Events / Flames |
| M (Flames) | Allocated bytes / outstanding bytes / allocation count |
| S | Enter a new archive path and save the finalized capture |
| Tab | Next inspection view |
| T | Cycle the retained capture's thread filter |
| J/K, arrows, wheel | Select rows; reaching an edge can page |
| Page Up / Page Down | Previous / next bounded page |
| R | Explicitly retry failed lifetime analysis |
| Esc | Close the inspector |

Calls link their entry/return evidence, including incomplete reasons. Lifetimes
link allocation/release call ordinals. The thread filter selects the allocation
origin for lifetime rows; a free on another thread is still part of that lifetime.
Summary totals describe the whole capture, not just the filtered page.

One allocation capture is retained per debugger process. Successful replacement
discards the old allocation capture; failed preparation preserves it. Collection,
analysis and CPU profiling have separate state. Allocation captures have their own save/reopen format and byte/count-weighted
flame graphs; CPU archives keep their existing format. Remote clients can use the MCP
tools on an x86 server; the remote GUI has no allocation panel yet.

## Scope and limits

- Default hooks: malloc, calloc, realloc and free in the unique executable
  `libc.so.6` mapping. Stop after libc is loaded. Stripped dynamic symbols work;
  IFUNC, missing, ambiguous or mismatched runtime images fail explicitly.
- GUI start chooses one thread. MCP can choose 1–32 stopped TIDs from the same
  process. The selection stays fixed. Thread/process creation, image replacement,
  selected-thread loss and target end can terminate capture.
- Preparation runs on a worker. Keep the target stopped until ready; continuing,
  changing stops or cancelling prevents a stale result from enabling probes.
- Default bounds are **60 seconds**, **32,768 records**, **32 MiB** retained
  evidence/metadata/analysis. Each entry and return is one record.
- One 64 KiB perf data ring plus a metadata page per selected thread, and two
  descriptors per hook per thread. These kernel resources are separate from the
  retained-memory budget. Preparation uses a bounded 64 MiB runtime ELF snapshot.
- Lost/throttled records, unmatched entries/returns, identity failures and
  retention exhaustion remain explicit. Incomplete evidence suppresses lifetime
  totals. Stop reasons and collector failures are printed to stderr.
- Outstanding means allocated in this capture with no observed release in its
  covered threads/hooks. It does not mean leaked. Counts omit allocations from
  before capture and unobserved/custom allocators; bytes are requested sizes,
  not resident memory or allocator overhead.
- Per-call instrumentation can significantly slow allocation-heavy workloads.
  Start with a short interval and a small explicit thread set.

## Preferences

Pass `--config FILE`; no implicit configuration files are loaded or written.

```json
{
  "allocations": {
    "duration_ms": 60000,
    "record_limit": 32768,
    "memory_limit": 33554432,
    "callstacks": true
  }
}
```

Duration is 0–4,294,967,295 ms; zero removes only the time deadline. Record limits
are 2–131,072; retained memory is 1–128 MiB. Duration counts paused time. Prefs
set future defaults; MCP arguments override one capture. Helper permission is
a separate explicit launch option, not a preferences field.

## MCP

| Tool | Required arguments / behavior |
| --- | --- |
| start_allocations | Current generation and nonempty tids; optional duration_ms, record_limit, memory_limit, mapping_address, hooks |
| stop_allocations | Current generation, session_id, capture_id; also cancels the matching pending preparation |
| get_allocation_capture | Preparation ID/state, error/failure, stop reason, defaults, scope and retained capture key/summary |
| get_allocation_events | session_id, capture_id, revision; exact retained events |
| get_allocation_calls | Same key; paired/incomplete call evidence |
| get_allocation_stack | session_id, capture_id, revision and allocation_span; exact entry PCs and recorded labels |
| get_allocation_flamegraph | session_id, capture_id, revision; metric allocated_bytes, outstanding_bytes or allocations; poll pending with unchanged filters |
| save_allocation_archive | generation, capture_id, revision and a new path; poll get_archive_status |
| get_allocation_lifetimes | Same key; may return pending during analysis; outstanding_only and explicit retry supported |

All accept optional `process_id`; omitted means the root process, independent of
GUI selection. Start/stop require control or mutate scope. Read pages permit
observe scope. Poll `get_allocation_capture` until preparing is false and
collecting is true before continuing the target. Its preparation_id identifies
a pending start; finalized capture identity is in key.identity.

Pages accept start (ordinal cursor), limit (1–256), thread_id (debugger thread
identity), from_ns and to_ns (monotonic timestamps). Follow next; an empty
filtered page can still have a next cursor. Capture revisions change while
collecting. Use a finalized key for stable multi-page inspection.

Custom hooks require an explicit executable mapping address (hex string) and
objects such as `{"name":"my_malloc","kind":"malloc"}`. Supported kinds are
malloc/calloc/realloc/free with the native x86-64 C ABI and corresponding
arguments/results. A name alone does not establish custom allocator semantics.

## Helper permissions

`--allocation-helper PATH` explicitly permits `sudo -n -- PATH --stdio`.
The helper validates the calling user, ptrace ownership, stopped threads and
mapped executable ELF offsets; opens only disabled task-specific events;
transfers their descriptors over an inherited local socket; and exits.
The GUI, collection and analysis run as the normal user. There is no persistent
service, network listener, policy change or file-capability installation.

The helper has a 30-second lifetime bound and the client checks cancellation
during startup. A missing sudo authorization fails noninteractively. Host sudo
policy may use terminal-specific credentials; consult the terminal diagnostic
if a cached authorization does not apply.

**Security:** This is privileged executable code. Do not install unrestricted
sudoers permission for a helper writable by an untrusted account. Captures can
contain sensitive process addresses and allocation behavior. Keep the helper,
its launch option and MCP control scope restricted to trusted debugging work.


## Caller stacks and heap flames

Allocation entry probes now capture bounded user frame-pointer chains and the
single return-address word at the function-entry stack pointer. Return probes
retain the smaller pairing payload. Set `allocations.callstacks: false`, or pass
`callstacks: false` to `start_allocations`, to measure the cost of stack collection
separately. This setting defaults to true. Rebuild the optional helper alongside
xodb: the private descriptor protocol version changed.

Stacks retain at most 32 PCs, with at most 16,384 distinct stack records. Shared
stacks are interned. Missing entry callers, depth limits and omitted stacks remain
explicit; successful allocator pairing and lifetime totals do not imply complete
caller coverage. Frame pointers are required for reliable deeper callers. This
version does not reconstruct allocation stacks using DWARF. Symbols come from
immutable ELF snapshots taken while the selected target is stopped, with the
existing 256 MiB per-image / 512 MiB total asset bounds. Unavailable images leave
raw addresses. Executable mapping events end collection; unobserved unmaps,
remaps and JIT changes remain attribution limits.

**F** in the allocation panel opens flames. **M** changes the weight:

- **Allocated bytes:** requested sizes of successful allocation generations.
  A successful realloc contributes its full new requested size, not its size
  difference. This measures allocation volume, not resident memory.
- **Outstanding bytes:** requested sizes still outstanding at capture end.
- **Allocation count:** successful allocation generations, including zero-size
  successes. Byte-weighted views report zero-weight entries separately.

Click a frame to zoom, use Back/PgUp to reset, and scroll to deeper frames.
Thread/time filters select allocation entries, including for outstanding bytes;
they do not compute a historical heap snapshot at the filter endpoint. Unknown
stacks still contribute their weight under an unavailable marker. Node-limit
exclusions report their weight explicitly. GUI and MCP builds have independent
cancellable workers, each bounded to 64 MiB, separate from retained evidence.

## Save and reopen

After stopping capture, press **S**, enter a new path, and press Enter. The status
bar reports asynchronous publication. Existing files are never overwritten.
MCP offers `save_allocation_archive` and the existing archive status/cancel tools.
Reopen with:

```sh
xodb --open-capture allocation.xoa
```

The allocation panel opens automatically. The archive retains raw entry/return
records, caller PCs, copied symbol annotations, scope and gap diagnostics.
Reopening validates the checksum and reconstructs lifetimes from the records.
It never inspects an old PID or implicitly loads host binaries. Outstanding
still means outstanding within recorded scope. Incomplete traces remain
inspectable without gaining lifetime totals.

Allocation archives use an independent version-1 format, limited to 64 MiB;
JSON decode scratch is bounded to 256 MiB, in addition to the capture's evidence
budget. CPU archive readers/formats are unchanged. Opening allocation archives
with symbol-reanalysis options is rejected because they retain annotations,
not ELF assets. `--capture-out` saves an allocation capture when no CPU capture
is present; with both present, use the explicit allocation save operation.
Publication requests no durability syncs.
