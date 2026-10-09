# System overview (`xodb --overview`)

A task-manager window with no debug target. It opens its own Wayland window,
samples the whole system with the bounded, unprivileged collector
(`src/runtime/xrt_sysstat.h`) and keeps history in the view.

```sh
./zig-out/bin/xodb --overview
./zig-out/bin/xodb --overview --redact --theme green     # for recordings
./zig-out/bin/xodb --overview --replay samples.jsonl --pause
```

| Panel | Shows |
| --- | --- |
| Summary | CPU, memory, GPU and temperature gauges; CPU, disk and network history; top processes; everything not measured right now, with reasons |
| Performance | total CPU with user/system history; one tile per logical CPU grouped by package and L3 domain, with SMT siblings marked, busy meter, clock and history |
| Processes | tree or flat list sorted by CPU, memory, disk, network, FDs, threads, pid or name; `/` search; pid + start time identity; L opens files, F profiles, Enter attaches; each action shows cost and access before confirmation |
| Memory | composition bar, swap, zswap ratio, faults, memory history and PSI (CPU, memory, I/O) |
| Disk | per device read/write throughput, IOPS, busy, queue, latency, temperature |
| Disk Space | per mount usage, as `df` computes it, with inode use |
| Network | per interface receive/send history (adaptive scale), packets, errors, addresses |
| Connections | TCP/UDP/unix sockets with owner process where visible |
| Power & Thermals | CPU package temperature and power, GPUs, and every hwmon sensor with history |
| System Info | host, kernel, CPU, memory, GPUs, per-group collector state and cost |
| Users, Services, Installed Apps | utmp sessions, observed daemon processes, package database |
| Files & IO | Descriptor tables, seekable offset progress, process churn heatmap, fd-growth sparklines, deleted holders and explicit syscall-event counts |
| FD Graph | Processes and cgroups linked through shared files, pipes and proved UNIX socket peers |
| FD Galaxy | Descriptor counts orbiting their processes or cgroups, colored by kind, with deleted holders highlighted |

Keys: `1`–`9`, `0`, Tab/Shift+Tab switch panels; arrows, Page Up/Down, Home/End
move; Left/Right fold the tree; `/` search; `s` next sort, `r` reverse; `v`
tree/flat; `t` next theme; `p` or Space pause; `x` turns redaction on (it cannot
be turned off without a restart); `q` quits. Mouse clicks and the wheel work too.

## Honesty rules

- A value that was not measured is never drawn as zero. Missing samples are
  hatched in graphs, missing values show their reason (`needs privilege`,
  `not supported`, `not present`, `first sample`, `redacted`, ...), and
  hovering shows it in the footer. Stale values (slow sources such as NVMe and
  DIMM sensors) are dimmed and marked stale.
- Processes are identified by pid and start time; the debugger hand-off sends
  both. The launcher and consumer recheck them and reject changed identities.
- The bottom-right corner always shows the overhead: CPU time this window spent
  drawing and sampling over the last second, as a share of one core.

## Sampling

Live, the cheap whole-system groups refresh every 500 ms. Process lists are
sampled once per second (or the slower chosen interval). Outside Processes, the
general collector skips its per-process IO and fd counts. Files and the two
descriptor views request their own IO and fd comparisons from the shared
descriptor worker, including quiet processes; they do not require a visit to
Processes first.
An MCP process request enables full details on the next scheduled tick. Other per-panel groups are sampled only while their
panel is shown (they read "sampled when shown" until then); connections (an fd
scan) only while the Connections panel is open. Each group's rates span its own
previous collection. `--interval-ms N` (250..10000) changes the fast interval;
disks, network and power refresh at most twice per second. Process rows update
on samples; the other panels ease transitions at one-second intervals.

Files uses a separate descriptor worker shared with the FD MCP tools: default
one-second polling with a 10 ms soft budget. `--interval-ms 250` selects 250 ms
and a 5 ms budget for this pane; other interval values keep its one-second
default. A faster MCP peer may temporarily select 250 ms, and the pane reports
the actual shared cadence. The system cards and heatmap remain system-wide
when the table is filtered to a process. Scope, cache age, denied/stale/unscanned
work and cap counts remain visible. Initial process rows may wait for their
turn in the bounded whole-system scan. Positive seekable progress animates at
up to 15 frames per second while visible; stale, paused or unknown rows do not.

Files requests comparisons for its whole-cache rate cards. Its rotating scan
budget still limits which processes are refreshed on each tick. Offscreen
paths and offsets may be retained; **[stale]** marks those rows, and hovering
shows which fields are cached and the offset's age. An unchanged descriptor
count is only a hint: a same-count close/reopen can leave a cached old path
until refresh. Scroll to a process or select it to request fresh metadata;
the scan budget still applies. Background metadata receives periodic refresh.

## Descriptor graph and galaxy

These views currently show **polling topology and descriptor counts**. Particle
size is descriptor count, not measured byte throughput; syscall tracing and
flow pulses are not connected to these views yet. The Files pane retains its
separate, explicit event capture.

```sh
xodb --overview --panel galaxy
sudo -E xodb --overview --panel graph
```

The second command uses the access already granted to root and preserves the
Wayland environment, including `XDG_RUNTIME_DIR`. It opens an ordinary window
on that display. xodb's overview does not save preferences or history into
`$HOME`; graphics drivers may write their usual shader caches. An explicit
`--session-socket` creates the socket requested by the caller.

Press `G` for the graph, `Y` for the galaxy, `C` to fold or expand proved cgroups,
and `+`/`-` to change detail. Click a process or cgroup to focus; `Esc` returns
to the whole graph. `L` opens a focused process in Files, and clicking a shared
resource opens its holders there. For an owned demo process, repeat
`--graph-pid PID` to restrict the actual descriptor collector; that restriction
also remains in effect when drilling into Files.

The C collector joins device/inode identities and validated UNIX_DIAG peers,
not path names. Anonymous or stale identities stay distinct. Denied processes,
cache age, scan omissions, unproved cgroups and peer-query failures are shown
explicitly. A peer query covers the collector's network namespace. Cgroup v2
paths are grouped only when freshly observed; unsupported or stale membership
does not silently join unrelated processes.

Storage grows with observed demand, up to 16,384 processes and 262,144
descriptors. The view aggregates these into at most 128 stars and 1,024 particle
groups; the graph draws at most 128 shared resources and 2,048 links and shows
omission counts. These are display and collection bounds, not a claim that
every cached row was refreshed at the same instant.

The collector reuses at most 2,048 read-only process-stat handles, further
limited to one eighth of the process descriptor limit. Handles are close-on-exec,
released when their tasks disappear or the collector closes, and never reused
for a replacement task with the same pid.

The corner shows drawing, sampling and the whole process's CPU time (all
threads, the GPU driver's included) over the last second.

## Services

Services is an init-independent `/proc` inventory of daemon candidates. A row
must have parent PID 1 (including reparented orphans), no controlling terminal,
and its own session: SID equals PID, or a positive SID different from PID 1's
session. Kernel threads are excluded. It must also have effective UID below
1000, or **both** an explicitly unset `/proc/PID/loginuid` (4294967295) and a
non-user cgroup. When login setup assigns an audit login UID, it survives setsid
and reparenting: screen, session dbus and desktop processes remain excluded on hosts where
every process is in `0::/`, or elogind uses a numeric session cgroup. A cgroup
never admits a high-UID process on its own. Missing or unreadable loginuid for a
high UID means unknown classification and partial coverage, including on kernels
without audit support. A root, numeric or positive cgroup does not substitute
for the missing audit value. `user.slice`, `user-*.slice` and `session-*.scope`
(or a `session` component) are user cgroups; comparisons use whole components.
If PID 1's session is unreadable, only proven session leaders can qualify.
This heuristic can include orphaned background jobs if login setup leaves
audit loginuid unset, and can omit services that remain under a supervisor. It does not enumerate unit definitions, stopped
services or unit health, and makes no assumptions about the init program.

The heading `init: <comm>` comes from `/proc/1/comm` and is informational. Each
row carries its process name, PID plus start ticks, effective user as `uid:N`,
process state, time since start, CPU percent of one core, RSS and cgroup path.
Hover the row for its start identity and the second line for the full cgroup.
The JSON also includes the audit login UID and its availability.
Numeric users avoid a passwd or NSS lookup: service discovery reads only
`/proc`, opens no manager sockets and launches no helper commands. Cgroups
prefer v2, then the named systemd v1 hierarchy, then the first v1 hierarchy;
a user path in any hierarchy disqualifies the non-user-cgroup alternative.

Rows refresh on the Services group's cadence: once every two seconds while
visible or requested by an MCP peer. Each refresh makes a bounded full process
scan. A representative 1,250-process system
cost about 15 ms per refresh, with cost depending on load and permissions. The
self-overhead display reports the actual running cost. The synthetic replay
uses a representative 15,000 us Services cost. Hidden, unrequested Services
incurs no scan; MCP reads use the same owner cache and do not sample per call.
CPU uses its own previous
PID/start counter and elapsed monotonic time; the first observation, a changed
identity or a backwards counter has a reason instead of a fabricated zero.
Inventory is bounded by the process scan limit, 512 service rows and the shared
sample deadline. Inaccessible or malformed candidates and scan limits produce
an explicit partial-inventory message; zero rows with incomplete coverage is
unavailable. A missing field remains unavailable even if other evidence admits
the row. Cgroup data is bounded to 8 KiB per process and 1023 display bytes;
overlong paths are unavailable with a limit reason. Redaction hides service
names, user labels, the init label and cgroup paths in both live and replay views.
It also removes non-root numeric UIDs from Services and Processes JSON, and
non-root audit login UIDs; root UID 0 and the unset audit marker may remain.

With procfs `hidepid=invisible` (or `hidepid=ptraceable`), other users' daemons
may be absent even from directory enumeration. When `/proc/mounts` reports that
option, Services marks coverage partial with a privilege reason; the true number
of hidden processes is unknown. Namespace restrictions and unreadable or oversized
mount tables can also hide processes beyond the visible inventory.

## Redaction

`--redact` hides the hostname, user names, remote hosts, command arguments,
MAC and non-loopback addresses, Unix socket paths outside system runtime
directories, and mount points outside common system paths. Processes not owned
by root get a stable alias (`proc-xxxxx`, from pid and start time) instead of
their name, in every panel and in search.
The view redacts its copy, so a non-redacted replay is also hidden. MCP redaction
is per reply and cannot change the shared cache or another peer's reply.

Files hides all descriptor paths and process names under redaction; numeric
PIDs, fd numbers and inode identities remain available. Turning redaction on
clears an existing path search. A redacted MCP caller cannot test guessed paths;
reverse lookup by numeric device/inode remains available.

## Files and exact events

```sh
./zig-out/bin/xodb --overview --panel files
./zig-out/bin/xodb --overview --files-pid 123 --files-start-ticks 456
```

The example identity is synthetic. Omitting `--files-start-ticks` binds to the
first sampled birth identity and never follows a replacement with that PID.
From Processes, **L** opens Files for the selected PID/start pair after a cost
and access explanation. From other panels **L** switches to Files directly.
**Enter** scopes the selected descriptor/process row to its process; **H** shows
holders of that exact device/inode; **Esc** returns to the system table. **[ ]**
cycle Files, Processes, Leak watch and Deleted; **/** searches, **S** cycles sort,
**R** reverses. **A** offers attach and **F** offers a profile, retaining identity
checks and the existing confirmation. Redacted attach/profile are refused.
A clicked or keyed row stays selected by PID/start (and fd) while rows re-sort
each refresh; the list scrolls only when you scroll it or to keep that row on
screen. A selection whose identity disappears is shown as gone, is not replaced
and is not an action target. Until a row is picked, the first row is selected.

Polling progress comes from seekable offsets and is not exact IO: pread/pwrite,
seeks, shared offsets and mmap need different interpretation. Pipes and sockets
show unmeasured progress, with a reason on hover. Hover also shows open flags
and age. Leak watch reports growth candidates, not proof of a leak. Deleted
sizes describe the held inode and are not additive across holders. The FD table
shows socket kind/inode; network peer analysis belongs to Connections.

**E** opens the exact-event confirmation. **exact mode slows all syscalls on
this machine by roughly 10 % while active**; syscall-heavy targets can slow much
more. Opening Files, reading MCP data or revisiting retained event counts does
not start capture. The explicit confirmation describes access, bounds and cost.
An active warning stays visible; **E** or **Stop** ends capture. Pausing or
leaving Files also stops it, and resume/return require a new confirmation before
restarting. Counts remain available after stopping. Event rows refer to fd
numbers across reuse, with no current-path attribution; loss, invalid records,
unpaired calls and flags qualify the result. Loss or possible loss stays visible
alongside the host-cost warning; unavailable kernel accounting is explicit.
See [FD capture coverage](MCP_FD.md).
Overview MCP peers remain observers: they can read a UI-started capture but
cannot start, renew or stop one themselves. Other control-enabled sessions use
the separate leased `start_fd_events`/`stop_fd_events` tools.

The view owns its displayed copy, so pause can freeze it while an MCP peer
continues polling. Capture activity status remains live while paused. A system
JSON replay does not contain descriptor data; Files explicitly reports it
unavailable. No descriptor recording format is implied.

## Themes

`dark`, `light`, `green`, `amber`, `blue` (phosphor: glow, faint scanlines,
vignette, ghosted VFD segments) and `mono`. `--theme` accepts these names with
or without `builtin:`; `t` cycles them. The overview's palettes are its own and
do not change the debugger's startup theme.

## Replay

`--replay FILE` reads collector JSON (`xrt_sys_json` output): a single
snapshot, or one per line, cycled at the sampling interval. History is filled
from every frame at start, so `--pause` shows complete graphs at once.
`tests/fixtures/overview-synth.py` writes deterministic synthetic samples
(invented names and documentation addresses) used by `tests/overview-gui.py`.

## Shared observation and actions

`--session-socket PATH` exposes the same live cache to local MCP peers; `--mcp`
also enables stdio. These endpoints expose observation tools only. Requests
renew demand for the needed groups without sampling inside a request. The
owner updates the cache on its clock. Replies include each group's sample
time, age and pending state; poll after a pending response. Pausing the view
freezes its display while requested MCP groups can continue refreshing.

Select a live process and press L (files), F (profile), or Enter (attach). The
confirmation explains cost and access. Files opens in this overview window;
profile starts a 99 Hz, ten-second capture in a debugger window. Attach stops
the process until continued or detached. All actions validate the selected PID
and start ticks; external consumers validate again after attachment. Replay
cannot start them. Profile and attach windows remain open when overview closes.

## NVIDIA sensors

If available, the runtime loads `libnvidia-ml.so.1` without an SDK or link
dependency. It samples NVIDIA busy percentage, watts, temperature, VRAM and
clocks every five seconds, alongside AMD DRM sensors. A dedicated worker keeps
slow driver calls off the GUI/MCP thread. Pending, failed and old readings keep
their unavailable/stale reasons. After 200 ms the group reports a slow call;
one in-flight call is retained, never multiplied by retries. Shutdown does
not wait for a stuck driver call; that worker can remain until process exit.

Process action prompts ignore key repeats and require release of the opening key,
a 250 ms arm delay and a fresh Enter press (or a later Confirm click). Holding
Enter cannot attach. In redaction mode, Files remains available and redacted;
Attach and Profile are refused because debugger windows do not support redaction.

NVIDIA VRAM uses the versioned NVML memory query where available, matching the
allocated-memory figure from nvidia-smi. Older NVML falls back to v1 with an
explicit “includes reserved memory” explanation. Missing libraries, missing ABI
and initialization errors retain their explanation alongside other power-panel
reasons. The five-second sensor cache becomes stale after six seconds, or when
a new query exceeds its deadline.

Slow hwmon sources are throttled only after three consecutive successful reads
over 1 ms. A fast read or an error resets the streak. One scheduling delay
therefore does not make the next reading stale. Sustained slow sources keep
the five-second refresh and its explicit stale reason, and recover immediately
when a refresh completes quickly. Synthetic collector fixtures can disable
this wall-time classification through `sensor_timing_disabled` in the C limits.

## Memory map (defrag views)

The **Memory map** panel (**M**, or **m** on a Processes row) draws one
process's virtual memory as fixed 2 MiB address cells inside its VMAs, from the
same shared observer as the MCP tools below. **t** on the panel cycles four
looks: a Windows 9x *Disk Defragmenter* dialog, the MS-DOS 6 *DEFRAG* text
screen (the same 80x25 composer as `xodb --memdefrag`, see
[MEMDEFRAG.md](MEMDEFRAG.md)), a modern grid and the zoomable **deep map**
(below). `--look win9x|dos|modern|deep` picks one at start; `--memmap-pid N [--memmap-start-ticks N]` opens a process.

- Cells are address ranges, so gaps between VMAs stay visible (dark). Long
  gaps and large never-resident VMAs are one compressed cell marked with a
  break. Hover shows the range, VMA, permissions, mapping (hidden under
  `--redact`), state and the known category bits.
- Colours: dark blue THP (PMD-mapped), cyan 4 KiB anonymous, yellow file or
  shared, grey swapped or not present, red unmovable (VM_IO/VM_PFNMAP), dark
  unmapped. A cell no page scan observed is grey-hatched; under plain
  pagemap (no page size) present cells are hatched over their colour.
- Three changes never share a colour: a page-category flip between the last
  two snapshots is green (DOS: blinking `r`/`W`); a collapse into a PMD
  mapping keeps the THP colour with a white ring (DOS: white `█`); a split gets
  a red edge (DOS: red `▓`). Physical migration is not observable per process
  and is never drawn.
- The progress bar is THP coverage: AnonHugePages in THP-eligible private
  anonymous VMAs over their PMD-aligned span. An unknown numerator or
  denominator draws a hatched bar and "Coverage unknown", never 0 %.
- The activity text ("Collapsing huge pages", "kcompactd compacting memory",
  "Idle") comes only from vmstat counter deltas over the last interval and is
  labelled system-wide.
- Freshness is shown in every look: the map's actual refresh period, marked
  *cost-limited* when the worker slowed an expensive map below 1 Hz to hold its
  CPU target, and the data's age (replays say *recorded*). Transitions ease only
  when a new snapshot arrives. Pause (**p**, or the Pause button) stops renewing
  demand, so scans lapse after three seconds.
- Buttons: Stop returns to the system view (free memory by buddy block size,
  counts not positions), Pause, Legend, Hide Details (compact dialog). Keys:
  **[ ]** previous/next process, **o** process picker (DOS), arrows move the
  cell cursor, **+/-** zoom toward 4 KiB cells around the cursor, **g** legend,
  **d** details, **Esc** stop.
- A replay frame may carry a `memory_map` object (schema `xodb-memdefrag/1`,
  the same JSON as `xodb --memdefrag --json`); `tests/fixtures/memmap-synth.py`
  writes synthetic ones.

For repeatable collector CPU and RSS measurements, run `python3 -B
tests/memory-cost.py --scopes 1 --mib 1024` or `--scopes 4` under the shared
heavy-gate wrapper. Four scopes use four owned processes, each with the requested
base-page allocation. Private results include idle/loaded RSS, sampled peak RSS,
whole-server CPU, load, actual publications, refresh periods and scan completeness.
Numbers collected when load exceeds the available CPUs are marked not measurable.
The script reports measurements without fixed timing or CPU assertions; adaptive
refresh and per-scope costs remain visible.

### Uniform memory viewport data

The shared presentation model can publish up to 65536 cells in one explicit
virtual-address viewport: 128 GiB at 2 MiB per cell, or 256 MiB at 4 KiB per
cell. Unlike the compact overview layout, this form retains every cell in its
half-open range, including gaps and non-resident mappings. Endpoints align to
the cell size, which must be a multiple of the host page size. Invalid geometry
or a viewport beyond the requested cell limit is refused before collection.

One `memdefrag.Request` drives both `Reader.renew` and `Reader.read`. Its
optional `range` clips page-state collection; `numa` requests VMA node totals.
Smaps metadata and THP coverage still describe the whole process. Sampling
retains the observer's CPU budget and adaptive cadence. Changing the request
never retargets another reader's cache. While waiting for a suitable scope,
`Map.pending` is true, cells are empty, and the process status says `pending`.
Pending publications are not counted as completed process scans. Reprojection
also observes cell size, anchor, limit and redaction changes even when the
sample sequence has not changed.

The additive `xodb-memdefrag/1` fields include the viewport `range`, `pending`,
per-cell `mapping_known`, process `numa` availability, and each VMA's
`numa_vma_totals`, `numa_page_size` and `numa_partial`. A hole in a partial VMA
inventory stays unknown; only known holes are unmapped. NUMA values are totals
for an entire VMA and cannot identify the node of a particular cell. Redaction
still removes process names and non-pseudo paths. High-resolution renderers
consume this bounded publication directly; MCP replies retain their existing
row limit.

### Deep map

The fourth look is a dense field of up to 65,536 fixed cells, from 2 MiB per
cell (128 GiB in view) down to one 4 KiB page per cell (256 MiB in view), drawn
as one batch of instanced quads. It asks the observer for exactly the viewport
on screen (the uniform request above), so collection follows the view.

| Do | Keys and pointer |
|---|---|
| Zoom, keeping the cell under the pointer in place | mouse wheel, or **+**/**-** (at the pointer, else the centre) |
| Pan | drag, arrows (an eighth of the field), Page Up/Down |
| Fit the process's densest VMA cluster at the finest cell size that holds it | **0** (also the first view) |
| Previous / next VMA to the top-left, selected | **[** / **]** |
| Jump anywhere | click the minimap: the whole address space, gaps over 1 GiB compressed to breaks, the view boxed |
| Details of a cell | hover, or click to select (Esc clears) |

- Details give the range and cell size, VMA permissions and mapping (path
  hidden under `--redact`), the state, byte counts (mapped, present, huge,
  zero, swapped) with the known bits, and the VMA's NUMA node totals labelled
  **VMA totals**: numa_maps has no per-page node, so none is shown per cell.
- A moved view reaches the collector after it rests for 150 ms; renewal stays
  at most 1 Hz and the refresh period, cost limiting and data age are shown.
  Cells the current request has not sampled are drawn **pending** (dotted) and
  say so on hover; data of another cell size or range is never relabelled.
  Replays draw unrecorded zooms and ranges as pending too.
- Unknown cells are hatched, gaps dark. The three changes stay apart: a
  page-category flip fills green, a collapse adds a white **ring**, a split an
  orange-red top-left **edge**. The huge zero page (HUGE|ZERO) is drawn as
  zero page, never THP.
- Colours ease only when a new page scan arrives, not on the system counters'
  own 1 Hz publications, so an idle view does not redraw.
- A replay frame may add `memory_viewports`: up to 16 explicit uniform maps
  (each with a `range`). `tests/fixtures/memmap-synth.py --viewports` records
  2 MiB, 128 KiB, 64 KiB and 4 KiB ones for the GUI tests.
- `XODB_MEMMAP_PERF=1` prints frames per second and frame CPU once a second;
  `tests/memdefrag-gui.py --only perf [--perf-binary OTHER]` measures CPU and
  RSS on the owned fixture at 1920x1080, with and without continuous redraw.

## Memory page observations over MCP

The observer tools **get_memory_map**, **get_thp_state**, and
**get_fragmentation** also work without a debug target. One lazy background
worker serves the overview and its MCP peers. Requests renew a three-second
demand lease; each scope is sampled no sooner than one second after its previous
sample finishes. Expensive sources adapt their period toward 8 ms of CPU per
second per scope (0.8% of a core), up to 60 seconds. The decision uses thread CPU
time, so preemption cannot mark a cheap read as costly. Replies expose refresh_ms,
system_refresh_ms, cost_limited and cache age. Requests may continue at 1 Hz;
cadence throttling retains sampled data. Independent scan bounds report partial
coverage explicitly. Four expensive scopes can cost more than one. Replies never reset
the counter-delta baseline.

A process request requires both pid and start_ticks from the process list.
Identity is checked before and after collection. A changed identity or exited
process has an explicit state and no map rows. Four process/range scopes are
available; a full cache or briefly held publication mutex returns
MemoryCacheBusy. Closing a peer does not destroy the shared worker.

get_memory_map defaults to VMA metadata (view "vmas"). View "ranges" returns
coalesced page states. Optional range_start and range_end are 0x-prefixed hex
strings defining a page-aligned half-open address interval. VMA metadata still
covers the process; range selection limits page scanning. View "cells" requires
a range aligned to cell_bytes: 2097152 by default, or the host base page size.
Cells retain virtual addresses and gaps. An absent virtual page is **not**
evidence of free physical RAM.

Replies contain at most 256 rows. Pass next_offset and cache.sequence for later
pages. An intervening publication returns StaleMemorySnapshot; restart from
offset zero. Integers above signed 64-bit JSON range are decimal strings.
Addresses are hexadecimal strings.

Process storage grows with the observed rows and text, up to the configured caps, and
published process arrays shrink to their populated size. The x86 `[vsyscall]`
gate remains mapped but has unobserved page state; it has no user page tables
and does not make an otherwise complete scan partial. PFN-mapped areas such as
`[vvar_vclock]` can also be skipped by the kernel page-table walk; their ranges
remain mapped with unknown page state and no observed-byte credit. A demand-time existence
check, at most once per second, wakes the collector after exit even when a
cost-limited snapshot has a longer refresh period. The worker confirms the
pinned identity and publishes the exit; a missing proc mount is not an exit.

Defaults bound each sample to 65536 VMAs, 16384 state ranges, 64 MiB of text
per source and 4 MiB of paths. Page scans have a 20 ms thread-CPU budget,
checked between ioctls spanning at most 1 GiB. A syscall already in progress
can exceed that budget. Sparse spans no longer spend a budget proportional to
their virtual size. Plain-pagemap fallback additionally limits work to 1048576
base-page entries (4 GiB on a 4 KiB system). Limits, denied sources and truncation retain explicit states and a
scan-resume address; incomplete process totals are null. Snapshot start/end
times, scanned bytes, thread CPU time and cache age expose cost and freshness.
These observations span an interval and are not atomic.

The category/known masks have these bits:

| Bit | Category | Limit |
| --- | --- | --- |
| 0 | present | Resident virtual mapping |
| 1 | swapped | No swap offsets exposed |
| 2 | file | Plain pagemap also includes shared anonymous pages |
| 3 | huge | PMD mapping, including huge zero pages, or hugetlb; not every multi-size THP |
| 4 | written | Known only with observable asynchronous write-protection tracking |
| 5 | zero | Shared zero page, when the scan backend reports it |
| 6 | exclusive | Kernel pagemap exclusivity semantics |
| 7 | soft dirty | Observed flag, never cleared |
| 8 | write-protection tracking | Backend support/state, not a write event |

Zero without its known bit is unknown. The scan ioctl uses flags zero and never
write-protects memory or resets dirty tracking. Older kernels fall back to high
pagemap flags and leave huge, zero and written unknown. Physical frame numbers
and target memory contents never enter the data. NUMA is a per-VMA histogram
with its reported page size, when available, not exact cell locations. Request
`numa: true` in `get_memory_map` to collect it; ordinary views avoid that extra
walk. `smaps_rollup` is read only when smaps is partial, and otherwise reports
that it was not requested.

Cells compare successive observations of the same pinned process. The
changed_categories/change_known masks cover present/swapped/file/written.
Separate collapsed_bytes, split_bytes and pmd_change_known fields describe
backed THP mapping gains/losses, not the kernel operation that caused them.
Here THP means HUGE set and ZERO clear, with both flags known in both samples;
writing a huge zero page can therefore count as collapse without changing HUGE.
Conversely, backed THP becoming a huge zero page counts as a split because its
private backing was lost, even if HUGE stays set. First
samples and unsupported backends leave comparisons unknown. Physical migration
is always unknown here. Replaced mappings and changes between polls can be missed.

THP coverage has separately known numerator and denominator. The numerator is
AnonHugePages in THPeligible private anonymous VMAs. The denominator is the
PMD-aligned span wholly inside those VMAs, using the kernel's PMD size.
File-backed COW, shmem and hugetlb are outside it; their metrics remain separate.
Shared huge zero pages do not contribute to AnonHugePages. Unknown eligibility,
PMD size or incomplete VMA enumeration leaves coverage unknown. A known zero
denominator means no eligible span, not zero-percent completion.

System activity comes only from cumulative vmstat deltas between successive
system samples. Missing/reset counters and first samples have null deltas;
gauges have none. These values cannot be attributed to the selected process or
a particular zone. Buddy fragmentation uses the kernel extfrag formula:
-1000 means allocation of the requested order is possible; other negative
indices are valid. It is not a completion percentage. Free-page totals
distinguish an empty zone from low fragmentation.

Redaction removes process names, paths and inodes per reply without changing
the raw cache. Virtual addresses and PID/start identity remain. Unsafe or
overlong text is omitted. No tool accepts fixture roots, guessed paths, policy
changes, system compaction, or a privileged physical-memory helper.

References: Linux
[page table metadata](https://docs.kernel.org/admin-guide/mm/pagemap.html),
[proc memory fields](https://www.kernel.org/doc/html/next/filesystems/proc.html),
and [THP statistics](https://docs.kernel.org/admin-guide/mm/transhuge.html).
