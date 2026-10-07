# lsof-top: live open files

`lsof` is a snapshot. `xodb --lsof-top` is the live version: which files are
being read and written right now and by whom, which processes are churning or
leaking descriptors, and which deleted files are still pinning disk space.

It is a plain terminal program (termios and ANSI sequences, no curses). It needs
no privilege and changes nothing: it only reads `/proc`.

## Try it

```sh
./scripts/build -Doptimize=ReleaseSafe
mkdir -p ~/tmp/lt
F=./zig-out/bin/xodb-fd-fixture
$F leak 5 5000 & $F deleted ~/tmp/lt 3145851 & $F write ~/tmp/lt 1048576 & $F pair 262144 &
./zig-out/bin/xodb --lsof-top --redact --pid "$(jobs -p | paste -sd,)"
```

Press **1** for files (the writer's file advancing at 1 MiB/s), **3** for the
leaker, **4** for the deleted file, **Enter** on a row to drill in. Without
`--pid` it shows every process you may inspect. `kill %1 %2 %3 %4` cleans up.

## Views and keys

| Key | View | Shows |
| --- | --- | --- |
| **1** | Files | Files by offset advance per second, read/write direction, kind, size, holders. Idle files of one kind held by the same processes share a row (`51 pipes · both ends in app[12]`, `2 pipes · a[3] ↔ b[4]`); **Enter** expands it. **Enter** on a file: who has it open |
| **2** | Processes | fd count and change, fd-set churn, read/write bytes per second (`/proc/PID/io`), a kind bar and a trend of the sort key. With few rows, a summary of the whole system follows. **Enter**: its fd table |
| **3** | Leaks | Processes above their lowest fd count of the last 32 samples, rising ones flagged, what kinds accumulated and the commonest target |
| **4** | Deleted | Unlinked files still held open: pinned size, blocks on disk, holders |
| **Enter** | fd table | Live offsets and progress bars, access mode and flags (A append, N nonblock, C cloexec, D direct, S sync, P path) |

**Tab**/**Shift+Tab** cycle views; arrows, **j/k**, **PgUp/PgDn**, **Home/End**
select; **Esc** or **Backspace** goes back (and clears a filter). **/** filters
the current view as you type, **s** cycles the sort key and **r** reverses it,
**Space** freezes sampling (the screen stays explorable), **+**/**-** change the
period (0.25 s to 10 s; the scan budget follows), **?** is help (**j/k** scroll it) and **q** quits.

The header shows system totals with meters (read, write, churn, fds) scaled
against half again their recent peak, which is shown dim (`pk 3.1M`) from 140
columns; how many
deleted files are held and what they pin; the scan's own cost; and run time
(never the wall clock). Other users' processes appear only as `+ N hidden`:
`/proc` denies their fd tables and IO counters.

The screen is redrawn line by line inside synchronized-output brackets, so
updates do not flicker. Resizing reflows it. **q**, SIGINT, SIGTERM, SIGHUP, a
terminal hangup, **Ctrl+\\** and every other signal that would end the program
restore the terminal first; **Ctrl+Z** suspends cleanly. A dumb or unset `TERM`
gets one plain frame, as with `--once`.

Colours are mid-tone so they work on dark and light backgrounds. 256 colours are
used when `TERM` or `COLORTERM` says so, otherwise 16; `NO_COLOR` or
`--no-color` leaves only bold, dim and reverse. The selected row is a blue band
in 256 colours and reverse video otherwise (graphics included), with a `▸`
marker either way.
`--ascii` (or a non-UTF-8 locale) replaces block glyphs. The footer always keeps
`? help` and `q quit`.

## What polling can and cannot see

| Measure | Source | Limit |
| --- | --- | --- |
| Open fds and their targets | `readlink /proc/PID/fd/N` | A sample: an open and close between two samples is invisible |
| Churn | fd-set differences between samples: a new number, or a number now naming a different file. Files are told apart by device and inode, so a rename or unlink is the same open and a log reopened under its old name is a close plus an open | A lower bound on real opens/closes |
| Read/write bytes per process | `rchar`/`wchar` in `/proc/PID/io` | All IO, every fd, including pipes and sockets |
| Bytes per file | forward movement of `fdinfo` `pos` | Seekable files only; pread/pwrite and mmap IO do not move it; direction is inferred from the access mode |
| Deleted files | `st_nlink == 0` through the fd | Size and blocks of the held inode |

Exact per-fd byte counts and every open/close need syscall tracepoints; that
event source fills the same records later. The fd table, kinds and deleted
sizes match `lsof` on the test fixtures.

## Snapshots and JSON

`--once` prints one plain frame after `--samples` scans (default 2) and exits;
`--size 120x40` fixes its size. `--json` prints a snapshot instead: scan cost and
counts (visible, `hidden`, `kernel_threads`, `unscanned`, `gone`, `stale`,
dropped), system totals, each visible process with rates, windowed growth,
`lifetime_low` and its kind breakdown (`--fds` adds fd tables), and the top 200
files with holders (`files_total` says how many there were). Rates are bytes or
fd changes per second over each process's own interval. `leaking` needs at
least six samples (`--samples 6`). Neither mode needs a terminal, and neither
has a time budget unless `--budget-ms` asks for one.

`--redact` replaces user and host names (whole words), IPv4 and IPv6 addresses and
command arguments, keeps only the first word of a process title (programs such
as sshd rewrite theirs), and shortens paths outside system directories to
`…/name`. Use it for screenshots and demos.

## Cost and bounds

Each scan reads, per process, `stat`, `io` and the fd directory, and per fd one
`readlink`. Regular files and directories are also stat'ed, for sizes and to
tell a reopen from the same open; pipes, sockets and devices only when they
change. Offsets and flags (`fdinfo`) are read for seekable files and for new or
changed fds, plus every fd of the drilled-in process. Owners and denied tables
are rechecked every eighth scan.

On an x86-64 desktop with 2,077 processes (702 hidden) and 9,400 fds, a scan
took about 57 ms of CPU: 5.7 % of a core at a 1 s period and 22 % at 250 ms, in
32 MiB RSS. Almost all of it is kernel `/proc` work, so cost scales with
processes plus fds; a single process with 50,000 fds adds about 100 ms.

Memory is bounded at start (`--max-processes`, default 16384, for visible
processes and again for hidden ones and kernel threads; `--max-fds`, default
262144; a 16 MiB name arena); arrays are only touched as far as a scan fills
them. Interactive scans have a time budget (`--budget-ms`, default half the
period). A scan that reaches it keeps the remaining processes from the previous
scan, marked stale with their last measured rates, counts processes never
sampled yet as `unscanned`, and the next scan continues where it stopped, so
every process is reached in turn. Anything cut by a limit is counted in the
header as `partial`, never silently dropped.

## Building it elsewhere

The program is C over the runtime's scanner (`src/runtime/xrt_fdscan.h`), so
machines that run only the C agent can build it too:

```sh
make -C src/runtime CC=gcc BUILD="$PWD/.work/c-runtime" all
.work/c-runtime/xodb-lsof-top --help
```

## For developers

`xrt_fdscan_poll()` fills a borrowed snapshot, valid until the next poll:
visible processes in pid order, each with a contiguous fd range, deltas and
per-second rates against the previous sample of the same identity (pid plus
start time), a 32-sample history (fd count, churn, IO, kinds) and its growth
over that window; plus the unseen processes (other users', kernel threads).
Open files are identified by device and inode for paths and by link text
otherwise, and carry the scan `generation` that first saw them.
`xrt_fd_snapshot_copy()` makes an owned, immutable copy for readers on other
threads. `xrt_fdscan_files()` aggregates fds into files by device and inode
(anonymous inodes stay per fd), with a hash of the holder set, and
`xrt_fdscan_totals()` keeps 120 samples of system totals. The GUI pane and MCP
tools are meant to reuse this core; the TUI only formats it.

Tests: `tests/runtime-fdscan.c` (a synthetic `/proc` tree plus owned children
with exact activity, run by `scripts/build test`) and `tests/lsof-top.py`
(fixtures, `/proc` and `lsof` cross-checks, rotation, non-UTF-8 names, rewritten
titles, a time budget, and the TUI through a pseudo-terminal; `--overhead N`
measures cost with N idle processes).
