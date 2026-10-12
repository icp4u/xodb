# Process-tree debugging

Adopted with a default of 32 retained sessions and a configurable ceiling of
1,024; see [design and review](M2_PROCESS_TREE_PROPOSAL.md).
Following is opt-in and currently supported on Linux x86-64.

## Following off (the default)

A program that forks, vforks or spawns a helper (`popen`, `system`,
`posix_spawn`, a crash dialog, a shader compiler) just keeps running. Each new
child process is made safe and released, and the parent resumes on its own:

| The child is a | What xodb does |
| --- | --- |
| fork (own copy of memory) | Puts the original instructions back in the child's copy, wherever the parent has a breakpoint or a step trap, then detaches it. The parent's breakpoints are untouched. |
| vfork or `posix_spawn` (borrows the parent's memory) | Takes the breakpoints out of the shared memory, lets the child run, and puts them back when the child execs or exits. Only then is the child detached and the parent resumed. |

- Each release adds a `process_released` row to the event log (thread = the
  child's PID, detail = the forking thread). The process panel row counts them
  as `released N`. The first one per process also prints one line on stderr:
  `xodb: process #1 child pid=N released (not following; --follow-forks or F to follow)`.
- A released child is not debugged: its breakpoints do not stop it, and it is
  not killed when xodb closes.
- While a vfork child borrows the parent's memory, the parent's breakpoints are
  out for every thread of the parent. A thread that runs through one in that
  window (normally a few milliseconds, until the child's exec) is not stopped.
- The parent is not stopped for the child's `SIGCHLD` either: it is delivered
  and the program runs on (with following on or off). A thread that is in the
  middle of a step still stops on it. That includes the hidden step a Continue
  takes to leave a breakpoint, so a Continue right after a child exited can
  stop once more with `SIGCHLD`; Continue again.
- A step across the creating call releases the child the same way.
- Threads may spawn at the same time: up to eight children can borrow the
  parent's memory at once, and the breakpoints go back when the last of them
  has exec'd or exited.
- If the process exits or execs while a vfork child is still out, that child
  is detached and runs on.
- Still held, as before: a clone that shares memory without being a vfork, a
  ninth vfork child while eight are still out, a child whose memory sharing
  cannot be determined, and a child that does not report its first stop within
  two seconds. Those report `ProcessFollowingDisabled`; enable
  **Follow (F)** in the process panel or choose **Detach family**.

To debug the children, turn following on before the program creates them:
`--follow-forks`, or **F** in the process panel while the process is stopped.
The rest of this page describes following on.

## Launch and select

```sh
./zig-out/bin/xodb --follow-forks --break tree_ready -- \
  ./zig-out/bin/xodb-process-fixture fork
```

- Continue to `tree_ready`, then continue again to the fork.
- **O / Processes** opens the process list. With following on, both parent
  and child are held.
- Click a row or use arrows and Enter to switch the GUI. The header names
  the selected debugger process ID and PID.
- Continue, pause, stepping, registers, stack, expressions, hardware watches,
  memory inspection and capture controls use that selected process.
- Each process keeps its own source/frame selection and expression list.
- **F** in the process panel toggles following for the highlighted stopped
  process. Newly admitted children inherit it; existing children keep their
  own setting.
- **R** retries held admissions after their cause has been corrected.
- **Shift+D in the process panel** detaches the highlighted process, its shared-vfork
  family and pending children. **Shift+D outside the panel** remains ordinary detach
  and refuses unresolved shared/pending relationships.
- Closing xodb kills its owned launches/children and attempts to detach
  externally attached processes and their children.

## Limits and sharing

Default: 32 retained sessions, including exited/detached ones. Set
`--process-limit N` (1–1024) at launch, or raise it through
`set_process_following` with the current enabled value. A full table reports
`ProcessLimit` and holds the child. Slots are not recycled in this version.

For a larger prefork server, launch it through xodb with `--follow-forks
--process-limit 1024` before the `--` separating its executable and arguments.
The root/master uses one slot, leaving up to 1,023 retained child sessions.
Following observes newly created children; attaching to an already populated
master does not automatically attach its existing workers. Each new child
stops for inspection and requires its own Continue.

The default 32 limits admitted sessions, which limits their debugger storage.
It is not a whole-application memory budget. On exhaustion, the pending child
and its parent remain held; raise the limit and retry, or explicitly detach
the family. Exited/detached sessions still count, so repeated worker replacement
can eventually fill even the larger limit. The 1,024 ceiling does not eagerly
allocate 1,024 Sessions: child state is allocated when admitted.

The process ceiling is independent of the existing 1,024-thread-per-process
backend limit, 1,024-distinct-thread CPU capture limit and 32-target shared-vfork
family cleanup bound. Ordinary prefork children have separate address spaces.
MCP process-list replies remain paged at up to 128 rows.

Ordinary fork gives separate breakpoint state. Vfork shares actual memory
until exec/exit; its parent is intentionally blocked. Continue/instruction
step the child, or use explicit family detach. Software breakpoint edits,
memory writes and operations requiring temporary traps can report
`SharedAddressSpace` before separation. Independent hardware-watch registers
remain per task.

The kernel's `KCMP_VM` comparison determines whether memory is shared.
Comparison failure is explicit. A non-vfork shared-VM clone is held with
`SharedCloneRequiresCoordination`; family detach restores its inherited
traps before release. This version does not independently debug that case.

New children inherit probe definitions, but start fresh hit/log histories.
A filter for the forking parent thread is rebound to the child's first thread;
other inherited thread filters cannot match and report
`InheritedThreadFilterNotPresent` until the user reconfigures them.
Investigation annotations and expression lists are not copied.

Root restart remains an owned-launch operation; it refuses pending/shared
relationships. Private children already admitted remain separate sessions.
Children do not have a captured launch command and cannot be restarted here.

## MCP

Ordinary tools accept optional `process_id`. Omission always addresses root
process **1**, even while the GUI is looking at a child. Read current process
IDs, PIDs, state and generations using `get_processes`. That paged response
also reports pending births, sharing, admission errors and the GUI selection.
Pending-child previews are capped at eight per entry and label truncation.

```json
{"name":"get_processes","arguments":{}}
{"name":"get_session","arguments":{"process_id":2}}
{"name":"get_stack","arguments":{"process_id":2,"tid":12345}}
{"name":"continue","arguments":{"process_id":2,"generation":7}}
```

Use actual IDs, TID and generation from your session; these numbers are examples.
A mutation needs the selected process's current generation and the required
agent scope. Process IDs namespace generations, breakpoint IDs, captures and
archive jobs. Replies carry `process_id` and `process_session_id`.
Human scope changes affect every process; selecting a different process does
not grant more agent access.

Management tools:

- `set_process_following`: `generation`, `enabled`, optional global
  `process_limit`; requires a stopped process.
- `retry_process_admission`: `generation`; retries all pending admissions.
- `detach_process_family`: `generation`; explicit coordinated release, with
  independent adopted fork sessions left attached.
- `get_processes`: optional `start` / `limit` (up to 128), read-only.

Following does not attach unrelated existing children. The remote MCP service
can expose this interface on supported hosts; the remote GUI still selects the
original process.

## Profiles and cleanup

Captures, flames and archives belong to one process. Use the GUI's selected
workspace, or pass `process_id` to MCP profile/archive tools. There is no
combined process-tree flame graph. Existing captures can still stop on
child-process events according to their collector's scope rules.

CLI `--profile-out`, `--capture-out` and `--record` refer to process 1.
Save a child's capture explicitly through MCP before quitting.

Explicit family-detach errors retain targets and block unsafe resume so the
operation can be retried. Final shutdown still uses best-effort backend cleanup;
read stderr if detach fails. Session storage stays alive while shared-target
links remain, avoiding a dangling pointer during the final cleanup attempt.
