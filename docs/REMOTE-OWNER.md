# Remote session ownership

The remote owner module defines a command and presentation boundary for
runtime-agent and GDB-backed sessions. Remote headless and GUI sessions use
one owner worker. The GUI exchanges bounded commands and immutable workspace
publications without reading Session or entering the remote transport. Native
ptrace, offline capture and core sessions keep their existing ownership.

## Commands

`model/remote_owner.zig` provides owned typed GUI requests and owned MCP tool
name/argument ingress. MCP ingress is not an authorization result: the owner
must parse it, resolve the existing catalog's access annotation, and perform
ordinary tool argument, scope and controller checks. GUI actor identity must
also reach the dispatch adapter; existing handlers that hard-code agent actions
cannot simply be called for human commands unchanged.

Both frontends submit to the same connection-family queue. Successful submission
transfers ownership and returns a monotonically increasing sequence. Errors
retain ownership with the caller. The queue holds at most 64 regular commands, including an active regular
operation, and 8 MiB of their headers and nested argument payload. Polls use a
reserved slot: at most one pending poll and one active poll add two fixed command
headers, without argument payload.
These are admission caps, not up-front payload allocations. Existing tighter
per-tool limits still apply. The GUI separately retains at most 64 commands and
8 MiB while waiting for admission or a completion. Each payload is copied before
submission; borrowed editor text never crosses the boundary. Busy admission
retries in original FIFO order without waiting on the frame thread.

`take` transfers a const borrow to the owner. The owner validates the connection
incarnation, session/process identity and start time when both stamps know it.
Typed GUI inspections and controls also require their displayed image epoch
and stop generation immediately before dispatch. Polls may observe a new stop.
MCP ingress preserves each tool's existing freshness contract: `get_session`
reads the execution-time snapshot, while mutation handlers require and validate
the caller's generation. Lease and retained-job operations keep their ordinary
argument semantics. All commands still match process identity. Learning a previously
unknown start time does not replace connection/session/process/PID identity.
Two known, different start times always reject the command. An explicit authorizer consults the live
service using queued client/lease IDs; no borrowed service or Session pointer
crosses the boundary. Deferred execution must recheck its lease again when it
actually resumes the target, as the current session code does.

The owner routes a success or explicit refusal to the request's frontend before
calling `finish`. Sequence-to-request correlation and bounded response delivery
belong to that adapter, not to the coalescible presentation slot. Never report a
queued action as completed and never replace one mutation's result with another
snapshot. Repeated pending polls for the same process and actor coalesce into
one request, returning its first sequence and consuming the duplicate input.
Different identities or actors receive `PollPending`; they are never silently
retargeted. A poll requested during an active poll becomes one pending follow-up.
The owner takes the earlier of the reserved poll and regular FIFO head, retaining
submission order for every distinct command. Polls cannot consume user-command
capacity, including while an owner operation is blocked. Regular command
saturation remains an explicit refusal.

`trySubmit` and `take` return `Busy` on lock contention. The lock is never held
during allocation, dispatch or remote I/O. `close` only stops admission; it does
not cancel transport waits or confirm detach. Queued commands require explicit
failed/cancelled results during lifecycle teardown. `deinit` requires producers
and the owner to have stopped.

The concrete dispatcher preserves human versus agent authority. Queued MCP
control uses the original lease ID as well as the current service policy;
releasing and reacquiring a lease does not revive an old queued command. The
protocol server retains the request line, including its ID and pipelined bytes,
until its own response is encoded. Full queues or lock contention leave that
line pending for retry. Responses use the existing bounded per-client output
buffer, never the presentation mailbox. A failed shared client does not stop
another client's session work.

The worker owns the remote Tree, its poll/follow-up work and protocol dispatch.
Frontend completions are fixed-size values: up to 64 normal completions, plus
64 slots reserved for cancellation of the remaining input queue. Backpressure
prevents another frontend operation from executing when normal completion
capacity is full. Closing admission drains queued requests with cancellation,
without executing their mutations. A full completion mailbox has reserved space
for these cancellations, even after a burst followed by silence. A disconnected
shared client instead has one explicit disposal; its lease is revoked before
the next command can execute, including while its request is pending.

## Publications

A publication owns all nested arrays and strings in a versioned remote `View`,
plus a connection/process stamp, revision, timestamp and ready/pending/error
state. The contained view keeps its last confirmed generation when a newer
request is pending. A failed connection does not fabricate a stopped, resumed
or detached target. Core and full workspace panels have separate owned
presentation fields. No Session, Target, module pointer or borrowed C target
view may replace them.

`Publications` uses one exchange slot. The owner publishes a new view; the GUI
exchanges its current view for it and returns its old view in the same slot.
The owner frees the replaced/retired view outside the lock before building the
next. `collect` can retire it when no new view is ready. GUI `take` performs no
allocation, free, model work or network operation. On null or `Busy`, the caller
still owns its current view. With one GUI view, one slot and one new view being
built, at most three publication payloads coexist under this ownership rule.

Each publication caps headers plus recursively counted payload at 16 MiB. Arena
capacity and allocator bookkeeping add overhead; these payload limits are not
RSS limits. Measure retained RSS and CPU as well as input bytes during live
integration. Revisions must increase. A connection reset rejects late results
from the old incarnation; the GUI must retire its old connection's view before
displaying the replacement. `Inspection.request_id`, `Presentation.inspection_id`
and `matchesInspection` correlate typed inspections and publications. Pane
adapters also check their own request/selection keys: changing tabs or expressions
need not change the process generation.

## Indirect reads which block

Flame preparation reads `Capture.summary().mapping_history` on the owner.
Constructing that summary also calls `Collector.allocatedRingBytes` → `profile/runtime.info` →
`xrt_perf_info` → `xrt_remote_perf_refresh` → `XRT_RPC_PERF_INFO`. The C function
accepts a const pointer but performs an RPC and updates remote perf state. The
same path is used by MCP profile summaries; `Collector.acceptance` and
`pendingFailure` also refresh perf info. These summaries belong in owner-built
publications, including when a renderer uses only one apparently local field.

`Target.expectGeneration` can wait on the remote health mutex. `invalidate` and
`event` send `XRT_RPC_INVALIDATE` and `XRT_RPC_EVENT`. These are owner operations,
not frame-safe generation checks or local counters. The runtime guard already
covers their dispatch/lock boundaries.

## Runtime guard and migration

`xrt_remote_io_guard(true)` marks the calling thread as forbidden from entering
remote transport or connection-lock operations. It is thread-local and defaults
to false. The remote GUI arms it in every optimization mode after the owner
takes the family. Production calls refuse with `RemoteIoForbidden` before
locking or I/O, increment a saturating thread-local counter, and print at most
one diagnostic per thread. `xrt_remote_io_guard_strict(true)` additionally
aborts in Debug and explicit assertion tests, independently of `NDEBUG`.
Native empty-target work and native file-budget no-ops remain allowed.

File-budget updates, GDB capability reads, invalidation and event recording
return status rather than silently discarding a refusal. Fallible callers
propagate it; local policy/audit operations retain the failure in the session's
visible diagnostic. A refused call does not change remote generation or data.

The guard checks both backend opens, foreground/background dispatch, health and
failure checks, file/symbol retrieval, remote file-budget updates and GDB info
reads. In particular, a cached GDB capability read still takes the connection
mutex and can wait behind a remote call. A transport guard cannot detect every
borrowed-data race; owner-only Session access must also be audited.

The frame loop passes only the owner exchange, window, renderer and local
workspace state. All target input/inspection paths execute on the owner.
Existing file and perf workers keep their documented wire serialization.

The core debugger panes now share owner-side preparation in
`model/debugger_view.zig`: registers, target-architecture assembly, physical and
inline frames, native value summaries, source text, breakpoint lines and a
prepared control-flow graph. Threads and events accompany that presentation.
Source permissions and fallback rules remain those of the native workspace;
this GUI capture is distinct from the narrower MCP source-sharing contract.
Frame and preview arrays are deeply const. The ordinary GUI prepares these
values synchronously on its existing owner, while typed remote debugger
inspections prepare them on the worker and deep-copy them into publications.
Source/assembly/flow, native values/registers and bottom-pane painters consume
prepared values without a Session. Binding the same stop/selection again keeps
local source scrolling; status text retained across publications is copied into
GUI storage.

The owner preparation cache is separate from publication payload accounting:
it retains source storage and arena capacity for native locals and control-flow
graphs. The 16 MiB publication cap is not a bound on that cache or process RSS.
No additional maximum-size row arrays are preallocated. The existing bounded
source reader still reserves up to 1 MiB. Register storage contains a C union;
publication copying permits an untagged union only when every alternative is
pointer-free. The richer presentation has a compile-time deep-const check.

Language pane preparation now uses `model/language_view.zig` for Python, Perl,
Lua, JavaScript and Ruby. The projected header contains detection text and
selection values, without caches or symbol cursors. Stack rows, named bindings,
context storage and expression results are deeply const publication data.
Scrolling, expansion, editor text and hit testing remain frontend state. Native
callers retain synchronous wrappers; the same header/body painters and editor
helpers can consume a publication without accessing Session.

Typed language selections execute on the owner. Logical row actions validate
the session, stop, metadata and language context that supplied the row. Language
inspections retain at most 128 expression bytes in fixed worker storage; neither
a retired command nor an old presentation backs an automatic refresh. Paging
and expressions reset when the selected session or logical frame changes.
Language revisions trigger refresh even when the target generation is unchanged.
If preparation itself starts metadata discovery, its publication remains pending
and the worker retains the observed revision for another capture. It must not
mark old data current merely by attaching the latest session stamp.

Runtime comparison watches use `model/runtime_watch_view.zig`. The owner copies
cached comparison entries into a deeply const publication; canonical comparison
bytes and runtime/frame revalidation remain in the existing watch model. Native
wrappers cache the display projection by session, generation, comparison revision
and selected language. Drawing, selection navigation and scrolling consume only
that projection. Add/remove actions execute on the owner with the displayed stop
and logical metadata checks; human authority is retained independently of agent
scope. Comparison revisions request a fresh publication even without a new stop.
The comparison state and frame-identity uncertainty text remain in each copied
entry; a different sample at the same slot does not prove activation continuity.

Native expression watches use `model/native_watches.zig` for evaluation and
frame matching. Their publication contains const entries and expanded children;
the editor, selection, scroll position and row hit geometry stay in the frontend.
The remote owner allocates its watch list only on demand. Mutation commands carry
the displayed list revision, so removing one entry cannot redirect a queued row
action after compaction. New and rebound watches also validate selected-frame
metadata. Pinned-frame retirement, live selected-frame displays and stale values
while running retain their existing behavior. The native GUI uses the same
model and action functions synchronously.

Stop details use `model/stop_view.zig` to gather the signal, source location and
fault mapping on the owner. The painter receives copied evidence. Memory and
vector inspection use `model/inspection_view.zig`: publications carry copied
bytes, validity, comparison markers, search hits and register values. Historical
vector data retains the thread and stop where it was read. Search progress and
expired retained snapshots trigger a refresh without requiring a new stop.
The remote owner creates the inspection capture on demand; hidden panes release
projection storage. Existing bounded memory snapshot retention is unchanged.
Address expressions, pinning, search and cancellation execute as typed owner
commands. Expression evaluation validates selected-frame metadata, and cancel
uses the displayed search ID so a replacement job cannot receive an old action.
Local formatting, scrolling and editing use only the prepared view.

Inline scopes use `model/inline_view.zig` for stack and summarized locals. The
owner validates metadata before and after read-only expression evaluation and
returns a fixed-size completion. The frontend must match the command sequence
and its scope context before applying that result. Process rows use
`model/process_view.zig`; each carries its connection/process incarnation and
generation for controls. Tree revisions refresh child changes independently of
the displayed process. Navigation and drawing only read copied rows, and hidden
inline/process panes release their projection storage. Native wrappers execute
the same model operations synchronously.

The production remote GUI uses these preparations, including profiling setup,
analysis, runtime types, logical frames, invocations and allocation control.
The native GUI shares the same painters through synchronous preparation wrappers.
Offline capture comparisons/imports keep their original local ownership.

Cancellation, close/reconnect and final joins need a separate lifecycle change.
The existing operation deadlines remain defense in depth. A live acceptance
test `tests/remote-owner-gui.py` holds a real SYNC reply behind a proxy barrier,
checks that the hold occurred, and compares editor pixels with a calibrated open
state before releasing the reply. The previous synchronous GUI fails this oracle.
It records CPU, RSS and load separately from the correctness assertion.

Buffered MCP requests retain the normal finite pump budget across deferred owner replies (eight stdio requests, one per shared peer). A start/cancel pair already in the same batch executes before a newly admitted poll. Crossing the batch boundary admits a poll even under continuous input; output backpressure also permits polling. Previously admitted polls keep their FIFO order. `tests/remote-owner-batches.py` checks cancellation within a batch, progress across its boundary, and reset after draining, against both native and remote runtimes.

Breakpoint policy rows use `model/probe_view.zig`. The owner copies breakpoint
state, condition/log options, thread labels, pending-symbol diagnostics and the
latest log message. Persistent-resolution diagnostics carry a display revision,
so a yielded lookup refreshes the pane without fabricating a target stop. Rows
retain stable breakpoint IDs after compaction. An edit retains the session,
image and generation from when its editor opened; a later publication cannot
silently rebind that text to a new stop. Owner actions resolve thread TIDs and
check internal loader breakpoint protection before mutation. Human/agent
authority is preserved. Drawing, scrolling, hit testing and editor navigation
read only the const view; hidden captures release their arena storage.


Profiling flame preparation uses `model/profile_view.zig` for recorded and
reconstructed graphs, capture status and selected-frame source/assembly.
The painter and local selection/zoom use deeply const graph data. Navigation
stores frame identities by value so exchanging and retiring a publication cannot
leave paths pointing into the old graph. Stale filter/basis responses are refused;
a pending graph does not erase an otherwise valid selection. Capture, mapping
and trust changes reset incompatible paths.

The owner keeps the existing quarter-second graph cadence, detects worker
completion and next-setting changes, and frees projection storage while hidden.
The last displayed-view metadata remains readable with visibility false.
Graph storage scales with actual nodes, capped at 8192. Display names are bounded
to 384 UTF-8 bytes, with colors computed from the original names; full retained
symbols and selected source/assembly remain available through their existing
models. The maximum graph projection fits below 6 MiB of publication payload.
Capture setup/control also executes on the owner. The GUI receives selected
thread identities, active settings, next defaults and archive-job progress.

Queued protocol calls enter the common `Server.tool()` dispatcher, which derives
the requester and controller status for that individual call and restores prior
session context afterward. Retained-job operations use that requester; neither
an old queued lease nor a previous caller's context grants authority. Typed memory
search/cancel and allocation retry also preserve human versus agent ownership.


Timeline preparation uses `model/profile_timeline.zig`. Full sample, scheduling
and overlay history remains on the owner; publications contain actual bounded
pixel runs, overview buckets, edge markers and lane metadata. The selected
wide off-CPU labels keep their exact source intervals. Overlay projection
preserves the existing painter's capped order for the overview and each visible
lane. Exact pointer readouts are computed from full history and shown only for
that pointer request, so a changed pointer cannot reuse old counts or labels.
The maximum retained-history fixture publishes less than 256 KiB while keeping
all overview sample counts and the original lane/overlay totals.

Range, thread, viewport, drag and scroll choices remain frontend values. A
prepared response must match the current session, capture, selection and
viewport. Changing the pointer alone does not withhold a matching graph.
Hidden owner caches release their arenas; reopening the same session/capture
restores the frontend's selection. A replacement session cannot inherit it.
Typed presentation inspections are human frontend requests; agent protocol
inspection goes through the common tool dispatcher. This prevents an agent
from turning a GUI publication request into a human-owned retained job.

The sample inspector publishes formatted recorded/derived stack columns, exact
sample metadata and actual matching ordinal identities. Frontend bracket and
scroll navigation does not read capture storage. Navigation can advance while
an earlier detail result is pending; the stale result cannot reset its ordinal.
The owner prepares stack/JIT jobs and checks their completion independently of
capture revision. A pending flag closes the race where completion happens
between preparing pending text and recording a cache signature. Hidden sample
projection arenas are freed. The full matching-ordinal set is bounded by the
existing 65536-sample limit; lines retain the existing 512-byte display bound.
Bulk matching uses a sorted thread index so preparation does not perform a
linear scan of all 1024 threads for every sample. The maximum navigation,
recorded/JIT and derived-column fixture publishes less than 384 KiB.

Syscall detail publishes at most 64 actual rows with original elapsed time,
return class, missing-endpoint reason and scheduling overlap. Request identity
includes session, capture, filter and page; old pages cannot relabel newly
selected navigation. Full syscall history remains in the owner/MCP model.
Hidden page storage is freed. Native wrappers and the remote owner use the same
preparation functions; sample and syscall painters receive only const values.


Static analysis retains at most 256 questions and 512 answer rows. Questions
bind the artifact and operation/input identity. Old navigation replies cannot
replace a newer panel mode, choice or question; Return during preparation is
retained until its questions arrive. Logical frame pages and source previews
contain at most 64 rows. Runtime type pages contain at most 64 rows per category;
write/undo/search actions retain the displayed context and requester. Invocation
pages retain exact call/record citations and comparison identity, with 64 rows.

The workspace header copies metadata, scope, shared-controller and FD collector
facts. Its signature hashes strings immediately and retains only a scalar hash.
The owner publishes native and logical language views together. MCP and GUI
selection use the canonical session frame, with native watch lists separated
by process. Frontend editor completions require the same editor epoch and text;
a delayed completion cannot close a newly opened or edited field.

`gui-owner-*` periodic steps run the existing pane/navigation oracles with a
runtime agent; archive-only subcases remain local. `gui-remote-owner` is the fast
responsiveness regression. Native/agent live tests cover buffered MCP ordering,
direct hidden-tool denial, shared observers and retained-job ownership. Fast
transport cancellation and bounded close/reconnect latency remain a separate
lifecycle milestone: joining may still wait for the active transport deadline.

Publication admission uses one aggregate payload budget and checks each pane
before copying it. A pane that does not fit is omitted; other panes still fit
against the remaining budget. The native debugger's source, locals, stack and
other sections are checked independently. A persistent GUI banner names every
omitted section. Workspace process identity and scope survive an oversized
metadata string, so degradation cannot change process routing or authority.

A refresh error does not leave the owner loop. The prior immutable publication
remains owned and the GUI reports that it is the last confirmed view. A fixed
atomic error notice requires no allocation, so allocation failure is visible
even when a replacement publication cannot be created. Normal shutdown and
loss of the primary stdio protocol client retain their existing lifecycle.
Background metadata scanning still yields to foreground RPCs. Once its worker
has joined, validating a ready result uses foreground ordering; transport
contention is not reported as unfinished metadata. File identity is still
revalidated before lending that result, and changed bytes remain refused.

## Close and reconnect

Every connection has a separate reference-counted cancellation capability.
An ordinary quit, primary stdio EOF, or reconnect closes admission immediately
and gives the owner two seconds to finish its active operation and shutdown
exports on the live connection. Queued commands are cancelled without dispatch.
The deadline starts with the first stop request; repeated requests cannot extend
it. The joining thread requests transport cancellation if the owner is still
working when the grace expires. Internal owner failures may cancel immediately.
The grace bounds when cancellation is requested, not local disk writes or the
final wait for an owned transport child to be reaped.

Cancellation sets a terminal atomic flag with a nonblocking wake. It never takes
the connection mutex or closes its transport from the frame thread.
Agent framing and GDB packet reads/writes check that flag
around polls and transfers; a reader waiting for the serialization mutex checks
again after acquisition. Cancellation cannot make a partially used stream reusable.

A sent mutation whose reply is lost returns `RemoteOutcomeUnknown`. It is not
safe to repeat it automatically. Queued commands that were never dispatched
finish cancelled. Local teardown cannot prove that the remote target detached,
stopped, or cleaned up breakpoints.

`--profile-out`, `--capture-out`, and investigation export run before connection
cancellation on a normal close. A stalled or already-broken connection still
reports an incomplete collector drain. Optional breakpoint discovery and
source-step fallbacks must propagate `RemoteOutcomeUnknown`, including an
uncertain internal loader-hook installation, rather than reporting a pending
breakpoint or attempting another target operation.

The window keeps pumping while the owner drains commands, metadata/file/profile
readers and its owned transport child. It joins only after the owner reports done.
An unresponsive owned child is terminated and reaped by the owner; a missing
child exit status is not treated as confirmed remote cleanup. Startup for a
remote GUI runs on the owner with the cancellation capability already available.
GDB name resolution uses at most four independent jobs process-wide, including
abandoned libc calls. Those jobs own only copied names, results and notification
pipes. Cancellation releases the connection immediately; it does not claim to
cancel libc's resolver or let it retain Session/Target/token storage.

**Ctrl+Shift+R** retires the current owner and opens a fresh connection. It resets
publications, pending GUI commands, inspection keys and shared clients/leases;
unaccepted old sockets also disconnect. Stdio clients must restart their channel.
The new session begins in observe scope. No launch, attach, breakpoint or control
is replayed. A fresh runtime agent therefore starts without a target; starting
another target requires a new explicit launch/attach invocation. A GDB peer
reports its current target after the handshake, but matching PID values alone
do not establish continuity. Remote stamps retain an unknown start time when
the protocol supplies none; they never substitute the host's `/proc` identity.

**Ctrl+R** retries the current inspection. Automatic retry uses the selection,
connection, stop and metadata identity plus the failure class. Temporary pending,
busy and allocation failures back off from 250 ms to 4 s. Permanent refusals
wait for a new identity/selection or explicit retry. The owner applies the same
pacing before repeating a full failed capture, and the GUI retains a visible
error with its last confirmed view. Local input and painting remain available.
