# Remote session ownership

The remote owner module defines a command and presentation boundary for
runtime-agent and GDB-backed sessions. It is not yet connected to the live
session loop. The current GUI can still block on remote operations. Native
ptrace, offline and core sessions keep their existing ownership.

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
per-tool limits still apply. An input being prepared by a producer is outside
that queue budget; integration must bound producer staging too.

`take` transfers a const borrow to the owner. The owner validates the connection
incarnation, session/process identity, start time when both stamps know it, image epoch
and generation immediately before dispatch. Polls may observe a new generation
but must still match process identity. Learning a previously
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

## Publications

A publication owns all nested arrays and strings in a versioned remote `View`,
plus a connection/process stamp, revision, timestamp and ready/pending/error
state. The contained view keeps its last confirmed generation when a newer
request is pending. A failed connection does not fabricate a stopped, resumed
or detached target. The existing remote view is the initial core schema; full
workspace panels require additional owned presentation fields when migrated.
No Session, Target, module pointer or borrowed C target view may replace them.

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
displaying the replacement. Selected-pane adapters use `Inspection.request_id`, `Presentation.inspection_id`
and `matchesInspection` to check selection keys as well as identity and target
generation: changing tabs or expressions need not change the process generation.

## Indirect reads which block

The flame renderer reads `Capture.summary().mapping_history`. Constructing that
summary also calls `Collector.allocatedRingBytes` → `profile/runtime.info` →
`xrt_perf_info` → `xrt_remote_perf_refresh` → `XRT_RPC_PERF_INFO`. The C function
accepts a const pointer but performs an RPC and updates remote perf state. The
same path is used by MCP profile summaries; `Collector.acceptance` and
`pendingFailure` also refresh perf info. Migrate these summaries to owner-built
publications, including when a renderer uses only one apparently local field.

`Target.expectGeneration` can wait on the remote health mutex. `invalidate` and
`event` send `XRT_RPC_INVALIDATE` and `XRT_RPC_EVENT`. These are owner operations,
not frame-safe generation checks or local counters. The runtime guard already
covers their dispatch/lock boundaries.

## Runtime guard and migration

`xrt_remote_io_guard(true)` marks the calling thread as forbidden from entering
remote transport or connection-lock operations. It is thread-local and defaults
to false, so this API-only increment changes no live dispatch behavior. The
assertion remains enabled independently of `NDEBUG` once explicitly armed.
Native empty-target work and native file-budget no-ops remain allowed.

The guard checks both backend opens, foreground/background dispatch, health and
failure checks, file/symbol retrieval, remote file-budget updates and GDB info
reads. In particular, a cached GDB capability read still takes the connection
mutex and can wait behind a remote call. A transport guard cannot detect every
borrowed-data race; owner-only Session access must also be audited.

The next integration step moves the complete remote Session tree loop, its
callbacks and follow-up operations, target-related MCP dispatch and inspection
onto one owner. Rendering consumes publications. Existing file and perf workers
keep their documented wire serialization. Enable the frame guard only after
all those paths have migrated; spawning a polling thread alone is insufficient.

Cancellation, close/reconnect and final joins need a separate lifecycle change.
The existing operation deadlines remain defense in depth. A live acceptance
test must hold a remote reply behind a barrier and observe repaint and local GUI
input progress before releasing it. Fake-owner queue tests do not establish
that live responsiveness property.
