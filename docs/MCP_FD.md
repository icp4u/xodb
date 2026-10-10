# File-descriptor observers

Four observer MCP tools share one background collector in each xodb
process. They work over stdio MCP and local session sockets without a control
lease. Two separate control tools start/renew and stop optional event capture.
Polling reads permitted `/proc` metadata. Events use syscall tracepoints for
one explicitly selected process, with host-wide cost while active. Neither mode attaches with
ptrace, stops a target or changes privilege.

| Tool | Result |
| --- | --- |
| `get_fd_activity` | Process rates and sampled fd churn; with `pid`, its descriptor table; with `mode: "events"`, syscall-return counts |
| `who_has_open` | Cached holders matching exact path text or the pair of device and inode |
| `get_fd_leaks` | Sustained fd-growth candidates with up to 32 history samples; growth alone does not establish a leak |
| `get_deleted_open` | Descriptors holding unlinked files, with file size and allocated disk bytes |

Every FD reply also includes passive `system_flow` status for the overview's
graph/galaxy capture: running/requested state, generation, sampled and
unattributed bytes, CPU coverage, loss and failure. `active_cpus` becomes zero
when tracing stops; `enrolled_cpus` retains the last capture's coverage. The
`host_cost` field repeats **LIVE SYSCALL TRACING · ~11% host syscall overhead · E
to stop**. These observer reads never start, restart or renew graph tracing.

## Polling and lookup

Start a server with `xodb --headless --session-socket session.sock
--agent-scope observe`, then use these tool arguments:

```json
{"name":"get_fd_activity","arguments":{"limit":20,"sort":"churn","redact":true}}
{"name":"get_fd_activity","arguments":{"pid":123,"interval_ms":250}}
{"name":"who_has_open","arguments":{"path":"/fixture/output.data"}}
{"name":"who_has_open","arguments":{"device":"2049","inode":"12345"}}
{"name":"get_fd_leaks","arguments":{"limit":10}}
{"name":"get_deleted_open","arguments":{"pid":123}}
```

The example identity is synthetic; use a PID from the current process list.
Lookup searches cached text or numbers. It does not resolve or stat the query
path. Device/inode numbers are unsigned decimal strings, preserving all 64
bits. Non-UTF-8 or truncated paths have a null `path` and an explicit
`path_state`; use device/inode lookup when available. An empty result cannot
establish absence when the cache is partial or permission was denied.

Every polling result reports its sequence, age, coverage, interval and owner
CPU time. Per-PID scope distinguishes sampled, stale, unavailable and missing
coverage. Missing stat or fdinfo fields are null. A descriptor's offset advance
is seekable-file progress; pread, pwrite, seeks, shared offsets and mmap prevent
it from being an exact per-file IO count. Process logical read/write rates come
from `/proc/PID/io`. Sampled opens/closes miss changes between polls. Deleted
file sizes are per inode and must not be added across multiple holders; there
is no claim about immediately reclaimable filesystem space.

Descriptor freshness is field-specific: `path_state`, `stat_state` and
`fdinfo_state` report `stale` for retained values; `stale: true` means at least
one part of the row is cached. `offset_age_ms` and `offset_interval_ns` describe
the last offset measurement. A cached rate remains readable, but
`offset_advance` is null until a new comparable offset sample exists.
Process `quiet_hint` identifies an unchanged-count/IO hint, not proof that its
fd table is unchanged. `offset_progress_state` qualifies partial aggregates
that exclude cached offsets. Query results may therefore contain an old path
or inode, explicitly stale, after a same-count close/reopen or rename.

A query with `pid` requests fresh paths and seekable offsets for that process;
a query without `pid` requests them across the cache. Requests return the
current snapshot immediately, so inspect its freshness and sequence on a later
read. Concurrent clients' demands are merged for three seconds. The GUI also
requests its visible processes. At most 128 individual PIDs retain demand;
when full, the oldest request yields its slot. Background paths and seekable
offsets refresh at least every eight scan sequences once reached by the
budget. Nonseekable fdinfo may remain cached because it has no offset progress.

`limit` defaults to 50 and is capped at 500. To continue, use `next_offset`
with the returned `sequence`; a changed snapshot gives `FdSnapshotChanged`.
Restart pagination from zero when that happens. `FdCacheBusy` is a short
publication-lock conflict and can be retried. Tool calls only request work and
copy cached results; they do not scan `/proc` or sleep.

## Explicit event capture

**exact mode slows all syscalls on this machine by roughly 10 % while active**.
The syscall-bound target can slow much more (about 2.2x in a synthetic write
loop). These measurements describe one host/workload, not a fixed upper bound.
Registering `raw_syscalls` tracepoints puts every task on the syscall slow path,
even unrelated tasks. Poll mode does not enable these tracepoints.

Starting capture requires control scope and, on a shared socket, the current
control lease. An observer's `get_fd_activity` call never starts or renews
capture, even with `mode: "events"`. Merely opening a view must not start it.
Overview-only MCP remains observer-only. In a control-enabled server, claim the
lease, obtain the target's current `pid` and `start_ticks`, then explicitly opt in:

```json
{"name":"start_fd_events","arguments":{"pid":123,"start_ticks":456,"acknowledge_host_cost":true}}
{"name":"get_fd_activity","arguments":{"mode":"events","pid":123,"start_ticks":456,"limit":50}}
{"name":"stop_fd_events","arguments":{}}
```

`start_fd_events` starts or renews a three-second window. Renewals need current
control and the same cost acknowledgement. Stop, lease release, lease expiry,
controller disconnect or demand expiry close the capture; observer reads do
not extend it. Lease cancellation is checked on the owner pump and capture
cleanup runs asynchronously after any in-flight worker operation. Retained
counts remain readable after capture stops. Every fd reply reports `host_cost`,
`exact_mode_active` and `exact_mode_requested`; active describes the last
published capture state, which may briefly lag a stop request. A future UI
start action must display the same host-cost warning before confirmation and
show active capture status.

Enrollment is asynchronous. One native Linux x86-64 process with at most 32
initially selected threads is supported. The collector checks process and
thread start identities around enrollment and pins its proc directory. Another
active PID/start pair gets `FdEventScopeBusy`; a peer cannot silently replace
an active capture. All peers see the same cached counts. Explicit restart after
expiry advances the capture generation. Task exit or exec stops the selected
lane; counts remain readable. Children and new threads are outside the original
scope. Event pagination uses a content sequence: idle drains preserve it;
changed records, coverage, state or capture generation invalidate old pages.

Event rows aggregate by **fd number across its reuse during the capture**.
They contain no current-path attribution. A close and reopen of fd 3 must not
assign its earlier bytes to the newly opened file. Counts are successful
syscall return values from complete entry/exit pairs, including short returns
and zero-byte EOF; failed calls add no bytes. They measure logical transfers,
not storage traffic. A capture starting inside a call reports an unpaired exit.

| Family | Coverage |
| --- | --- |
| read/write, pread/pwrite, vectored variants, send/recv and message variants | Successful returned bytes per fd; recvmmsg/sendmmsg are excluded because their return is a message count |
| sendfile, splice, tee, copy_file_range | Successful returned bytes on the source and destination descriptors; tee duplicates pipe data without consuming it |
| open/openat/openat2, socket/accept, descriptor-producing helpers | Successful returned descriptor counts |
| close, dup/dup2/dup3, fcntl duplication | Successful explicit close/dup counts; dup2 replacement's implicit close is not inferred |
| pipe/pipe2/socketpair | Global creation count; returned fd arrays are not read from target memory, so per-fd attribution is marked incomplete |
| close_range, recvmmsg/sendmmsg, io_uring operations | Unsupported evidence is flagged when the relevant successful syscall is observed |
| mmap IO, ABI-switching assembly, unlisted descriptor-producing syscalls | Outside the documented coverage; native executable identity cannot rule out hand-written compatibility calls. Raw records carry no ABI, so a compat close/dup2 of a sampled fd is not treated as a mutation, and a later native IO on that fd can be joined to the old inode |

Loss is checked on every drain through `PERF_FORMAT_LOST`, so a burst followed
by an idle target cannot hide overflow until the next syscall. Per-thread loss
uses the greater of the cumulative FD reads and cumulative loss records;
delayed records do not count the same loss twice. A near-full ring sets
`possible_loss`. Older kernels or failed counter reads set
`loss_accounting_available:false`; `loss_state` says completeness is unproved.
Known loss always qualifies the IO totals as incomplete. These flags are sticky
for the capture, even after stop.

The debugger GUI displays requested/active exact FD capture in its status bar,
including its host-wide syscall cost. Reading this indicator does not start or
renew capture; it clears after kernel capture resources close.

The reply includes `flags`, `lost`, `unpaired`, `invalid`, `dropped_rows`,
`drain_pending`, selected thread count, ring size, capture generation and times.
Flags are: 1 loss, 2 malformed evidence, 4 unpaired calls, 8 row cap, 16 scope
change, 32 unsupported attribution, 64 kernel throttling, 128 counter saturation,
256 possible loss near ring capacity, 512 unavailable loss accounting.
Any such limitation qualifies the counts; absence of flags does not expand the
documented syscall coverage. Malformed ring data stops capture. Pending drain
means the bounded drain has not consumed all available records yet.

## Cost, bounds and access

Polling demand expires after three seconds. The default interval is one second
with a 10 ms scan budget; a 250 ms request uses a 5 ms budget. Faster requests
win while their demand remains active. Permission denials, stale retained rows
and omitted work remain explicit. Budgets are soft: one backing-file query can
exceed them, so sampling runs on the worker rather than the GUI/MCP thread.
Worker shutdown signals it to free resources after the in-flight operation
returns; one blocked filesystem operation can retain that worker until process
exit. There is no growing pool of replacement workers.

The owner caps polling at 16,384 visible and 16,384 unavailable processes,
65,536 descriptors, and 4 MiB of path strings. PID enumeration stores at most
32,768 entries. Event capture uses at most 64 perf descriptors, 2 MiB of data
rings on 4 KiB-page systems, and 4,096 numeric fd rows. It drains at most 8,192
records per pass, normally every 10 ms. Loss and cap exhaustion are reported.
`owner_cpu_ns` is cumulative worker CPU time, including sampling and publication;
polling also supplies scan wall and CPU time. Host-wide kernel syscall slow-path
cost and additional target tracing cost are separate from worker CPU. A low
collector CPU percentage does not bound application slowdown.

Tracepoint files and `perf_event_open` must be accessible under the host's
existing policy. Tracefs group membership alone does not establish permission
to capture every task. Permission errors return `needs privilege`, the errno
and a reason. A failed capture also returns `failure` (operation, errno text and
detail, such as the tracefs path) and, when access was denied, a `remedy`. The tools do not enable global tracefs events, alter kernel policy
or retry as root. Unsupported hosts remain usable through polling.

`redact: true` hides names and paths. Server-level overview redaction also forces
redaction for these observers. `who_has_open` refuses `path` lookups under either
request or server redaction (`FdPathLookupRedacted`), preventing guessed-path
confirmation. Device/inode queries remain available. Numeric PIDs and device/inode identities remain
visible to authorized local peers. Private paths and process data should stay in
private evidence; shipped tests use owned synthetic workloads.

Background polling may retain a pathname until its next full refresh. If a
background file is unlinked, the stat identity can remain the same while the
cached link has not yet acquired its `(deleted)` suffix. Deleted-open reporting
therefore catches up on a foreground or periodic full refresh; it is not an
immediate unlink-event stream. A stale `offset_progress_per_second` is null,
including a process total with stale offsets. Per-field state and age describe
retained offsets and paths.

A polling MCP call with a `pid` requests fresh detail for that process. Omitting
`pid` requests a full refresh of the shared cache, so whole-system polling calls
do not benefit from the background adaptive-scan speedup. Both respect the scan
budget and publish asynchronously; repeated calls do not sample synchronously.

### Parent/child descriptor comparison

`get_fd_inheritance` returns sampled same-number, kind, device/inode matches
between a child and its sampled parent. It is an observer tool; it requests fresh
fdinfo flags within the existing polling budget and never starts tracing.
`pid` filters the child. Use `limit`, `offset` and `sequence` as with the other fd
tools; nonzero offsets require the preceding snapshot sequence. At most 500 rows
are returned per page, up to the 262144-row collector bound.

Each row carries parent/child PID and start ticks, fd, kind, device/inode strings,
`child_cloexec` and `parent_cloexec` (null when flags are unavailable or stale),
and `stale`. No paths or names are returned. `comparison_coverage` describes the
whole cache, including unknown identities, missing parents, different objects
and caps. Missing parents carry a reason: `parent_denied` (the parent's fd table
needs privilege), `parent_absent` (not listed: exited, or hidden by `hidepid`) and
`parent_reused` (the pid now names a process born after the child). Rows for fds
0-2 are listed after all others, so shared standard streams fill the row cap last. `matches_in_cache` and pagination apply to the child filter.

The evidence is explicitly **unproved inheritance**. Independently reopening the
same file can produce a match; no shared open file description or fork/exec
history is inferred. A descriptor moved to another number is outside this view.

```json
{"name":"get_fd_inheritance","arguments":{"limit":50,"redact":true}}
```
