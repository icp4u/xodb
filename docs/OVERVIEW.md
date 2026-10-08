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
sampled once per second (or the slower chosen interval). Off Processes, the
collector skips per-process IO and fd counts; those fields say "not collected".
An MCP process request enables full details on the next scheduled tick. Other per-panel groups are sampled only while their
panel is shown (they read "sampled when shown" until then); connections (an fd
scan) only while the Connections panel is open. Each group's rates span its own
previous collection. `--interval-ms N` (250..10000) changes the fast interval;
disks, network and power refresh at most twice per second. Process rows update
on samples; the other panels ease transitions at one-second intervals.

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
confirmation explains cost and access. Files opens a terminal with lsof-top;
profile starts a 99 Hz, ten-second capture in a debugger window. Attach stops
the process until continued or detached. All handoffs validate the selected
pid and start ticks at launch and in the consumer. Replay cannot launch them.
These separate windows remain open when the overview closes.

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
