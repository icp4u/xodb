# Process-tree debugging

Adopted with a default of 32 retained sessions and a configurable ceiling of
1,024; see [design and review](M2_PROCESS_TREE_PROPOSAL.md).
Following is opt-in and currently supported on Linux x86-64. Process creation
is held even with following off: inherited software traps must not execute in
an untraced child. `ProcessFollowingDisabled` means enable **Follow (F)** in
the process panel or choose **Detach family**. It does not mean a kernel failure.

## Launch and select

```sh
./zig-out/bin/xodb --follow-forks --break tree_ready -- \
  ./zig-out/bin/xodb-process-fixture fork
```

- Continue to `tree_ready`, then continue again to the fork.
- **O / Processes** opens the process list. Both parent and child are held.
- Click a row or use arrows and Enter to switch the GUI. The header names
  the selected debugger process ID and PID.
- Continue, pause, stepping, registers, stack, expressions, hardware watches,
  memory inspection and capture controls use that selected process.
- Each process keeps its own source/frame selection and expression list.
- **F** in the process panel toggles following for the highlighted stopped
  process. Newly admitted children inherit it; existing children keep their
  own setting.
- **R** retries held admissions after their cause has been corrected.
- **D in the process panel** detaches the highlighted process, its shared-vfork
  family and pending children. **D outside the panel** remains ordinary detach
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
