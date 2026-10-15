# Three game launchers, idle, on Linux: Epic vs Steam vs Battle.net

*Measured 2026-10-14 by an AI agent using only xodb's MCP interface, in read-only (observe) scope.*

## Setup

One desktop: Ryzen 7 7800X3D (8 cores / 16 threads), 128 GB RAM, RTX 4090, Linux with a Wayland compositor. All three launchers were open and signed in, with no downloads and no games running:

| Launcher | How it runs here | Up for |
|---|---|---|
| **Epic Games Launcher** (new Linux build) | native AppImage | 12 minutes |
| **Steam** | native, inside the Steam Linux Runtime container | 4 days |
| **Battle.net** | the Windows build under Proton (GE-Proton), started from Steam | 3.8 days |

xodb ran as root with a shared session socket, and the agent connected as an observer. Everything below comes from MCP calls (`list_processes`, `get_process`, `get_connections`, `get_memory_map`, `get_thp_state`, `get_sensors`): no `ps`, `top`, `strace` or `perf`. The agent had no way to pause, attach to or change any launcher; observe scope does not allow it.

There were two measurement windows:
- **Hidden:** 150 s, launchers on another workspace.
- **Visible:** 200 s, all three on screen with nobody touching them.

CPU figures are each process's CPU-time growth over the window, divided by the window length: an exact average, not a sample. 100% means one full core.

## Results

| | Epic | Steam | Battle.net |
|---|---|---|---|
| Processes | 6 | 22 | 24 |
| Threads | 128 | 163 | 299 |
| Open descriptors | 4,260 | 1,431 | 7,563 |
| **Idle CPU, hidden** | **1.3%** | **2.1%** | **35.1%** |
| **Idle CPU, on screen** | **0.8%** | **2.0%** | **36.5%** |
| Resident memory (sum over processes)¹ | 1.9 GB | 3.9 GB | 4.2 GB |
| External connections | 12 (HTTPS) | 1 | 4 |

¹ Summed resident memory counts shared pages once per process, so it overstates the real footprint. See the memory notes for private memory.

**Headline:** Epic's new launcher and Steam both idle at 1–2% of one core. Battle.net under Proton burns about a third of a core continuously, and it makes no difference whether its window is visible.

## How each one is built

**Epic.** One native main process (`EpicGamesLauncher`, 53–55 threads) driving WebKitGTK 4.1: a network process and three web-content processes, one per web view. It ships as an AppImage, and the runtime process read 76 MB from the image to start. This is a native-toolkit webview design rather than a bundled Chromium.

**Steam.** The 32-bit `steam` client process (40 threads) plus `steamwebhelper`, Valve's bundled Chromium (CEF), as 11 processes covering the browser, GPU, network service and renderers. It all runs inside the Steam Linux Runtime container (pressure-vessel, `srt-bwrap`). Four `gameoverlayui` processes were also present.

**Battle.net.** The Windows client and its CEF UI processes (`CrBrowserMain`, `CrGpuMain`, two renderers, three utility processes) plus Blizzard's `Agent.exe` updater. About half the 24 processes are the Windows environment Wine provides: `wineserver`, `services.exe`, `explorer.exe`, `winedevice.exe` ×2, `rpcss.exe`, `plugplay.exe`, `svchost.exe`, `tabtip.exe`, `conhost.exe`. Proton-GE adds `xalia.exe`, an accessibility bridge.

## Where the time goes

**Battle.net (36.5% on screen):**

| Process | CPU |
|---|---|
| CEF renderer | 12.6% |
| CEF GPU process | 11.4% |
| `wineserver` | 5.9% |
| CEF browser main | 3.9% |
| `xalia.exe` (Proton-GE accessibility bridge) | 1.0% |
| second renderer | 0.8% |
| `winedevice.exe` | 0.5% |
| `Agent.exe` | 0.3% |

One renderer and the GPU process together take about a quarter of a core with nothing happening on screen. That pattern looks like a page animating every frame, and it doesn't stop when the window is hidden. Chromium normally throttles hidden pages, but it has to be told the window is occluded. Under Wine that signal may never arrive, so the cost is plausibly part Blizzard's page and part the compatibility layer. `wineserver` at about 6% is Wine servicing the CEF processes' Windows calls, and it scales with how busy they are.

**Steam (2.0%):** `steam` 1.3%, one `gameoverlayui` 0.4%, `steamwebhelper` 0.2%. Steam's web UI is effectively asleep. The steady cost is the client process itself, which looks like timers or polling.

**Epic (0.8% on screen, 1.3% hidden):** the main process 0.5%, web processes 0.05–0.4% each.

The GPU sat at 4% busy during the visible window. xodb can't split GPU time per process from observe scope.

## Memory notes

Private (anonymous) memory of the main processes, which is closer to their real cost than RSS:

| Process | RSS | Private anonymous |
|---|---|---|
| Epic main | 439 MB | 101 MB |
| Epic web content (one of three) | 445 MB | 134 MB |
| Steam client | 261 MB | 86 MB |
| Steam web helper (browser) | 1,812 MB | 161 MB |
| Battle.net CEF browser main | 502 MB | 398 MB |
| Battle.net Agent | 182 MB | 91 MB |

- **Steam's web helper looks huge but isn't:** only about 160 MB of its 1.8 GB resident is private. The rest is shared and file-backed mappings, such as GPU driver and shared memory.
- **Epic's processes each reserve about 71 GB of virtual address space.** That's WebKit's usual up-front reservation, not real memory use.
- **Battle.net's browser process holds the most private memory of any single process here,** at about 400 MB.

## Things worth a look

1. **Battle.net never idles.** A third of a core, around the clock, whether visible or not. Over a day that's roughly eight core-hours of a CPU doing nothing useful.
2. **Epic's main process holds about 4,000 open file descriptors after 12 minutes.**
   - Only about 40 are sockets, and the count held steady over a minute (4,026 → 4,014), so it isn't climbing fast.
   - 4,000 is still unusually high for one GTK process. The likely candidates are event and pipe descriptors per web view or worker, but observe scope couldn't list them.
   - Separately, **6 of its 12 HTTPS connections were in `CLOSE_WAIT`.** The server had closed them and the launcher hadn't, which usually means a connection pool that doesn't reap closed sockets.
3. **Steam's web helper has written 19.4 GB to disk over its 96-hour life,** about 56 KB/s on average, while the client read 2.3 GB and wrote 2.4 GB. Most of that was probably sitting idle. It's worth knowing which files those writes go to, because it's steady SSD wear.
4. **Steam listens on all interfaces** (`0.0.0.0:27036`), which is Remote Play and LAN discovery, plus three loopback ports. Epic and Battle.net listen on loopback only.

## Advice for each team, with xodb or AI

**Blizzard (Battle.net):**
- **Find the idle frame loop.** Profile the CEF renderer and GPU process while idle, with xodb's CPU sampling and flame graphs under Proton. The page animating every frame should show up immediately.
- **Stop drawing when nobody's looking.** When the window is minimized, unfocused or occluded, stop the animation, and don't rely on Chromium's occlusion detection to work under Wine.
- **Test it the way Linux players run it.** An agent driving xodb over MCP can run "idle for 5 minutes, CPU must stay under 1%" as a regression gate on every build, including the Proton configuration.
- **Measure the Wine calls.** xodb's syscall timing on `wineserver` shows which Windows calls the UI is making, and fewer, cheaper calls lower the Wine overhead.

**Epic (new Linux launcher):**
- **The idle behaviour is already good;** keep it as a gate.
- **Open xodb's Files view on the main process.** It shows the descriptor count by kind and leak-watch growth, and fd tracing shows who opens them. Then fix the `CLOSE_WAIT` sockets in the HTTP client (close or reuse connections the server has ended).
- **Put a ceiling in CI.** An agent can assert "descriptors and connections stay under N after 30 minutes of browsing" with the same MCP calls used here.

**Valve (Steam):**
- **The client's 1.3% is the one cost left.** Sample it in place with xodb to see whether the wakeups are polling that could be event-driven.
- **Account for the web helper's disk writes.** xodb's fd-flow tracing attributes bytes written per file, which would show whether 56 KB/s of idle writes is cache churn, logging or the shader cache, and whether it's needed.
- **Reconsider the LAN listener.** Remote Play discovery on all interfaces is a reasonable default, but some users would prefer it off until Remote Play is used.

## How to reproduce

```sh
sudo xodb --overview --session-socket /tmp/xodb.s &
# give your user access to the socket (e.g. chgrp + chmod g+rw), then point any MCP client at it via:
scripts/session-client /tmp/xodb.s
```

The agent's calls were `list_processes` (sorted by cpu, memory and pid), `get_process` per process, `get_connections` by pid, `get_memory_map` and `get_thp_state` for the main processes, and `get_sensors`.

## Limits of this run

- **Observe scope only.** No CPU sampling, syscall tracing or GPU attribution, so the "why" above is inferred from which processes were busy, not from stack samples. Agent-requested profiling for observers is on xodb's roadmap.
- **One machine, one evening, launchers idle.** Battle.net was measured under Proton, not on Windows.
- **Memory:** summed RSS overstates; private memory was read for the main processes only.

## Follow-up: why does Epic's launcher hold 4,000 file descriptors?

After a restart, xodb's per-process descriptor table (`get_fd_activity` with `pid`) showed the new main process holding **4,248 descriptors**, and **4,137 of them are open files under `/proc`**:

| Path pattern | Open |
|---|---|
| `/proc/<pid>/task/<tid>/stat` | 3,335 |
| `/proc/<pid>/stat` | 798 |
| `/proc/meminfo`, `/proc/zoneinfo`, its own `statm` and `cgroup` | 4 |

At that moment the machine had 794 processes and about 4,200 threads. So the launcher keeps one open `stat` file **for every process on the system and for most of their threads**, not just its own: 4,026 of them belong to other programs (browsers, other launchers, terminals, everything). Every one had been read (non-zero file offset), opened read-only with close-on-exec, and then left open for re-reading. Only about 110 descriptors are what you would expect from a WebKitGTK app (eventfds, sockets, GPU device nodes, shared memory).

**What this pattern is:**
- It is the signature of a whole-system process/CPU sampler that caches open `/proc` files between refreshes. The Rust `sysinfo` crate is the best-known example: it keeps `/proc/<pid>/stat` and per-thread `task/<tid>/stat` open to make the next refresh cheap, reads `meminfo` and the process's own cgroup limits, and bounds itself to a fraction of the open-file limit.
- That fits a launcher built as a native Rust webview app (WebKitGTK 4.1). We could not read the binary from this account, so the library is an inference from behaviour, not a confirmed dependency.

**Why a launcher would do it** (from the outside the intent can't be proven; these are the usual reasons):
- **Detecting running games:** to show "running", block double launches, attribute playtime, or hand off to anti-cheat. That only needs process names, though, not per-thread CPU for the whole machine.
- **Resource telemetry:** CPU and memory usage of the system or of a running game.
- **A generic "refresh everything" call** used at startup when only a narrow lookup was needed. Refreshing all processes *with threads* is what produces thousands of `task/*/stat` handles.

**What it means for users:**
- `/proc/<pid>/stat` contains each process's name, state, CPU times and memory size. Reading it is unprivileged and normal on Linux, but it does mean the launcher can see every program you run.
- Nothing here shows the data leaving the machine. We only measured what it reads.
- **Cost:** about 4,000 kernel file handles and a periodic sweep of the whole process table. The main process uses about 0.5% of a core at idle, some of which is plausibly this sweep.

**Advice for Epic:** if the goal is "is game X running", look up the launched game's own process tree (you started it, so you have its pid), or match on `comm` without per-thread refresh. If you do need system sampling, refresh only the processes you care about, without threads, and close or limit the cached handles. xodb's descriptor view (`get_fd_activity` by pid) makes this visible in one call, and an agent can gate "descriptors < 200 at idle" in CI.

## Part 2: inside the Epic launcher binary (static analysis, never executed)

The AppImage was taken apart without running it: its embedded squashfs was cut out at the ELF section-table end and unpacked. The main binary, `usr/bin/EpicGamesLauncher` (version string `0.95.2+gfa9ad49`), is a 182 MB Rust executable that ships **not stripped**: full symbol tables plus line tables. About 97 MB of the 182 MB are symbols and debug sections, 48 MB is code.

### What it's built from

The Cargo registry paths left in the binary name every dependency and version. The relevant ones:

| Area | Crates |
|---|---|
| App shell | `tauri` 2 (runtime-wry 2.11), `wry` 0.55, `tao` 0.35, `webkit2gtk` (WebKitGTK 4.1 webviews) |
| Tauri plugins | `autostart`, `single-instance`, `updater`, `store`, `fs`, `dialog`, `opener`, `os`, `process`, `sentry` |
| System info | **`sysinfo` 0.35.2**, `os_info`, `gethostname`, `sys-locale` |
| Network | `reqwest`, `hyper`, `rustls` and `openssl` (both), `tokio-tungstenite` (websockets) |
| Storage and secrets | `rusqlite`, `keyring` (Secret Service over `zbus`) |
| Telemetry | `sentry` 0.42, a LaunchDarkly SDK, and Epic's own sinks |
| Epic | `libEOSSDK-Linux-Shipping.so` (Epic Online Services), crates `eglv2-*`, `fab-*`, `dpop` |

### Where the `/proc` sweep comes from

`sysinfo`'s Linux process code is linked in, including the parts that read and cache `/proc` files: `refresh_procs`, `_get_stat_data_and_file`, `FileCounter`, and `remaining_files` with its `getrlimit`-based budget. The kept-open `stat` handles we measured are what `sysinfo` does by design.

The launcher's own modules show two consumers:

1. **`running_apps`** (`scanner`, `table`, `classify`, `lineage`, `rules`, `registry`): a process-table scanner that matches running programs against Epic install paths to detect **Epic games started outside the launcher** and attribute their playtime.
   - **Its log events:** `Launch.ProcessTableRefreshed`, `Launch.ExternalSessionDetected`, `Launch.ExternalSessionMatched`, `Launch.ExternalSessionEnded`, `Launch.ExternalScanCompleted`, `Launch.ExternalScanTitle`.
   - **Its skip reasons:** `no-install-path`, `untracked-category`, `already-tracked`, `addon-without-own-processes`.
   - **`lineage`:** parent/child chains, so a game's launcher process and the game itself become one session.
   - **The playtime path:** `playtime::tracker`, then `playtime::publisher` and `add_playtime_bulk`, then Epic's library service. It needs a machine id (`Playtime.NoMachineId`).
2. **`perf_monitor`** (`sampler::run_loop`, `aggregate_bands`): samples CPU and memory of the launcher's **own** webview processes, labelled per webview (store, social, fab, oauth, toasts), and reports web-performance timings. Finding its own children with `sysinfo` still means enumerating the whole process table.

A static read can't show which of the two holds the 4,000 handles, or with which refresh options. `sysinfo` reads each thread's `stat` unless the caller opts out of thread refresh, which matches the 3,335 `task/*/stat` handles. Tracing the live process would settle it.

### Other data it gathers

- **A device profile at startup** (`device_profile::gather_and_log`): RAM total and available, CPU vendor, GPU vendor and device IDs, VRAM, driver version, displays and refresh rate. It's logged as `App.DeviceProfileCaptured`.
- **Telemetry sinks named in the binary:**
  - Epic's Data Router (`telemetry/sinks/datarouter.rs`, `eos_datarouter.rs`)
  - **Mixpanel** (`telemetry/sinks/mixpanel.rs`, `api.mixpanel.com`, with `distinct_id` and `$device_id` fields)
  - Sentry crash and error reporting
  - LaunchDarkly feature flags and events
- **A log router** (`telemetry/logrouter/*`, with sampling and a per-second budget) forwards structured log events, the `egl_event_name` family above, into telemetry.
- **A PII scrub list:** the strings include `email`, `display_name`, `real_name`, `phone`, `address`, `ip`, `ip_address` next to the telemetry code, which reads like a deny-list of fields scrubbed before sending. That's a good sign, but it's an inference from strings, not verified traffic.

### What this means

- **Why it walks `/proc`:** almost certainly to detect Epic games you launch outside the launcher (for playtime) and to monitor its own webviews. It isn't inherently sinister, and Steam and others detect running games too. The cost is in how it's done: a full `sysinfo` process refresh, threads included, with every handle kept open. That's 4,000 descriptors and visibility into every process on the machine, where matching only processes under Epic install directories would do.
- **What we can't tell from static analysis:** what exactly leaves the machine. Event names suggest that matched external sessions (Epic titles) are reported. There's no evidence the full process list is sent, but proving that needs traffic inspection (with TLS keys) or a trace of the telemetry dispatcher.

### Advice, part 2

- **Narrow the scan.** Refresh processes with only the fields you need (`exe`, start time) and **turn off thread refresh**. Better still, watch for new processes under your install directories instead of polling everything.
- **Ship stripped binaries** with a separate debug-symbol bundle for crash symbolication. That's about 97 MB off a 182 MB binary, and it stops publishing your CI's source paths.
- **Document it.** One line in the privacy notice ("the launcher reads the list of running programs to detect Epic games started outside it") would turn a scary `ls -l /proc/<pid>/fd` into a non-event.
