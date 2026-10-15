# xodbfetch

A fastfetch-style card of the machine xodb runs on, in two forms:

| Form | How | What |
|---|---|---|
| Terminal | `xodb --fetch` | Logo left, `user@host`, a rule, `Key: value` lines, colour blocks; then exits. No window, no Vulkan, about 35 ms. |
| JSON | `xodb --fetch --json` | The same lines as `{"schema":1,"title":...,"redacted":...,"lines":[{"key":...,"value":...}],"bench":...}`. |
| Live panel | `xodb --overview`, then **N** (or `--panel fetch`) | The same card drawn by xodb: the real distro logo, sparklines beside the values that move, uptime and clocks ticking. |

The terminal gets colour only when stdout is a terminal, `NO_COLOR` is
unset and `TERM` is not `dumb`; piped output is plain text. Colours are
24-bit when `COLORTERM` is `truecolor` or `24bit`, the 256-colour cube when
`TERM` says 256 colours, else the 16 basic ones; the half-block logo needs a
UTF-8 locale and is left out otherwise. The logo is the
distribution's own PNG (`LOGO=` in `/etc/os-release`, looked up in
`/usr/share/pixmaps` and `/usr/share/icons/hicolor/*/apps`), read at run
time and drawn as half-block characters or, in the panel, as cells. xodb
ships no logo. Without a PNG the panel draws the distribution's name on its
`ANSI_COLOR`. The key column, title and rule take the logo's dominant colour
(the most-covered saturated colour of the PNG), else `ANSI_COLOR`, so each
distribution's card looks like its own.

## Lines and sources

Lines follow fastfetch's names and order. A line with nothing honest to show
is left out. Nothing runs a subprocess; every source is a bounded file read
or the overview's collector (`src/runtime/sysstat.c`).

| Line | Source | Notes |
|---|---|---|
| OS | `/etc/os-release` `PRETTY_NAME`, collector architecture | |
| Host | `/sys/class/dmi/id/product_name` (+ version), else board vendor and name | placeholders such as "To Be Filled By O.E.M." are skipped |
| Kernel | collector (`uname`) | |
| Uptime | collector (`/proc/uptime`) | the panel adds seconds |
| Packages | entries of `/var/lib/pacman/local`; `Status: install ok installed` in `/var/lib/dpkg/status`; `P:` in `/lib/apk/db/installed`; flatpak app directories (system and user) | per manager |
| Shell | `$SHELL` | name only |
| Display | each connected `/sys/class/drm/card*-*`: EDID preferred timing (size, refresh) and monitor name; else the first `modes` line | marked "preferred": sysfs does not say which mode is current |
| DE | `$XDG_CURRENT_DESKTOP`, `$XDG_SESSION_DESKTOP` | only a desktop environment (GNOME, KDE, XFCE, ...); compositor names are the WM line's |
| WM | the panel: the peer of xodb's own Wayland connection (`SO_PEERCRED`, then `/proc/PID/comm`); `--fetch`: the same for the server of `$WAYLAND_DISPLAY` | the compositor actually drawing, never a guess from `/proc` |
| Theme, Icons, Font | `gtk-3.0/settings.ini` in `$XDG_CONFIG_HOME` or `~/.config` | |
| Terminal | first known terminal among this process's ancestors, else `$TERM_PROGRAM` or `$TERM` | terminal form only |
| CPU | collector: model, logical CPUs, highest `cpuinfo_max_freq` | |
| GPU | collector (DRM, NVML), PCI ids resolved through `pci.ids` | one line per GPU |
| Memory, Swap | collector (`/proc/meminfo`) | |
| Disk (/) | collector (`statvfs` of `/`) | |
| Battery | collector (`power_supply`) | |
| Locale | `$LC_ALL`, else `$LANG` | |

Lines fetch tools do not show (moving ones have a sparkline in the panel):

| Line | Source | Form |
|---|---|---|
| CPU load | collector `/proc/stat`, load average | panel |
| Boost | fastest core's `scaling_cur_freq` now / highest max | both; sparkline |
| Activity | context switches/s and forks/s from `/proc/stat`, task count | panel |
| Pressure | `/proc/pressure/{cpu,memory,io}` some avg10 | both |
| Temps | CPU package (k10temp/coretemp), GPUs, NVMe, first fan; a CPU or GPU at 69 °C gets " (nice)" | both ("nice": terminal only) |
| Power | RAPL package power (often needs privilege), GPU power | both |
| NVMe | `/sys/class/nvme/nvme*/model` and the PCIe link (`current_link_speed`, `current_link_width`) | both |
| Disk IO | collector rates | panel |
| Governor | cpufreq governor and driver | both |
| Network | physical links only (bridges, veth and tunnels repeat their traffic): in and out: live MB/s and packets/s in the panel; `--fetch` shows bytes and packets since boot from `/proc/net/dev` (one read, no waiting: it is a show-off card, not a monitor) | both; sparkline in the panel |
| Scheduler | `/sys/kernel/sched_ext/root/ops` when sched_ext is enabled | both |
| Open files | `/proc/sys/fs/file-nr` | both |
| xodb | the Vulkan device xodb draws on; draw time; first frame after start | panel |
| Benchmark | the last saved result and its date | terminal |

Not shown: boot-to-desktop time (no portable unprivileged source without
systemd), deleted-but-open files and syscalls/s (they need the descriptor
scan or tracepoints, which cost more than a card should), VRR/HDR (the
compositor does not report them to xodb), CPU vulnerability mitigations
(security sensitive; deliberately left out).

## Redaction

`--fetch --redact`, `--overview --redact` and **x** hide what the overview
hides: the title becomes `user@host`; Host and Font are left out; GPU names,
the Vulkan device (also in the benchmark result) and monitor names are
hidden. Serial numbers (DMI, EDID, NVMe) and network addresses are never
read.

Rather than blanks, the card's identity lines become mad-libs: obviously
fake values no one could take for this machine's, picked once per run so
one card is self-consistent.

| Line | Redacted |
|---|---|
| Logo | a retro system's small original ASCII logo (OS/2 Warp, BeOS, CP/M, MUMPS, AmigaOS, NeXTSTEP, OpenVMS, Plan 9), in its colour |
| OS, Kernel | that system's name and a matching silly kernel string |
| Uptime | random, under ten years (ticking in the panel) |
| Packages | a random count "(floppies)" |
| Shell | `3rdseashell` |
| Theme | an IKEA-style name with the toolkit suffix, e.g. `SKRUVBY [GTK3]` |
| Icons | a pop icon, e.g. `Michael Jackson [GTK3]` |
| Network | random plausible totals (`--fetch`) or rates (panel) |

The rest (Display, CPU, Memory, Temps, ...) are real values under their
usual rules. Mad-libs live only in this card: `src/redact.zig`'s
placeholders (`user`, `host`, `~`, ...), MCP replies, archives and logs are
unchanged, so redacted evidence never carries plausible fakes. The tables
are in `src/ui/overview/fetch.zig`. `tests/fetch.py` reads the machine's
host, user, kernel, model names and DMI serials at test time and checks
that none appears in redacted text or JSON, and that each mad-lib comes
from those tables; `tests/fetch-gui.py` does the same with OCR of the
panel.

## Benchmarks

On demand only: `xodb --fetch --bench`, or **B** on the panel (**Esc**
cancels). Nothing starts them on its own; they heat the machine for a few
seconds.

| Measure | How |
|---|---|
| SHA-256, one core | a 1 MiB buffer hashed in a loop for 0.4 s; MB/s = 10^6 bytes/s |
| SHA-256, all cores | the same on every logical CPU at once; the panel shows both, so the scaling is visible |
| memcpy | two buffers (256 MiB, `--bench-mb N` for 1..4096) copied for 0.4 s; GB/s = 10^9 bytes copied/s |
| Memory latency | a random cycle of 64-byte lines in one buffer, dependent loads for 0.4 s; ns per load |
| GPU (panel only) | 65536 scene3d instanced boxes in the logo square for 60 frames; boxes per second of GPU timestamp time on the device the panel draws on, which the result names (its kind only when redacted; "software renderer" for llvmpipe/lavapipe). A private headless compositor often renders on the integrated GPU, so expect a lower figure there than on the discrete one (`--vk-device`) |

The last result is kept in `$XDG_STATE_HOME/xodb/fetch-bench.json`
(else `~/.local/state/xodb/`) and shown with its date by later cards.
