# Syscall durations and scheduling context

Adopted workflow; see [critical review](M2_SYSCALL_TIMING_PROPOSAL.md).
Linux x86-64 live collection; saved captures can be inspected offline.

## GUI

- Pause the target, open flames (`F`), then Setup (`S`).
- Enable **Syscalls** (`Y` inside Setup). Enable **Scheduling** for observed
  running/off-CPU overlap.
- Choose an explicit subset of **1–32 threads**, then start (`P`) and continue
  the target (`Space`). The default all/new-thread selection is not accepted
  for syscall tracing. Selecting all current threads explicitly is allowed.
- `P` stops collection; it does not pause the target.
- Amber timeline overlays mark syscall spans. Hover for labels; `X` opens
  syscall detail. Wheel/PgUp/PgDown page, click a row for return/overlap details,
  `X`/Esc closes. The flame timeline's thread/time filter applies to the list.
- A crowded timeline bounds its drawing. Use range zoom or the paged detail
  for evidence omitted from the overlay display.

## MCP

With the target stopped, use the current generation and explicit TIDs:

```json
{"name":"start_profile","arguments":{"generation":7,"tids":[1234],"syscall_timing":true,"context_switch":true,"syscall_limit":16384,"duration_ms":10000}}
```

Read `get_profile`, then use its capture ID and revision:

```json
{"name":"get_profile_syscalls","arguments":{"capture_id":1,"revision":20,"start":0,"limit":64}}
```

These are `tools/call` parameters. Pages support `tid`/`tids`, relative
`from_ns`/`to_ns`, and at most 128 rows. A live revision can change; refresh
`get_profile` after `StaleProfile`. Stop collection for stable pagination.
Row ordinals are capture-local citations, and entry/exit timestamps are absolute
CLOCK_MONOTONIC values. Time filtering selects overlap and keeps full original
endpoints; durations and scheduling overlap are for the original call.

Prefs, explicitly loaded with `--config prefs.json`:

```json
{"profile":{"syscall_timing":false,"syscall_limit":16384}}
```

Turning recording on still requires choosing threads in the GUI or MCP.
The limit accepts 1–65,536. A full store stops the entire capture and prints
`syscall_limit` on stderr. Existing sample, scheduling, duration and scope limits
can also stop it. Stopping keeps retained evidence. `discarded` counts decoded
spans rejected by storage; `unread_possible` separately reports an uncounted
ring suffix after a limit or error.

## Meaning and limits

- Each complete duration is monotonic exit minus entry, including time off CPU
  and stopped in the debugger. It is neither CPU time nor device service time.
- Scheduling overlap reports observed running/off-CPU/unknown intervals. It
  does not prove why a call waited or attribute that time to a resource.
- Unknown entry/exit boundaries, loss, mismatches and interrupted collection
  never produce a fabricated duration. A terminal `exit_group` commonly has
  an entry and no return. Kernel restart codes are labeled separately from errno.
- Names assume the x86-64 syscall ABI. Raw tracepoints do not identify every
  compatibility call (for example `int 0x80` from a 64-bit image); confirm that
  ABI separately before interpreting those names. Unknown numbers stay numeric.
- The kernel writes argument words into its raw ring; xodb discards them during
  decoding. Retained spans/MCP/archive contain no argument words, paths or buffers.
- This traces every observed call. Short CPU fixtures and responsive status
  requests do not establish acceptable overhead for every workload.
- One ordered ring per task receives both entry and exit events; no system-wide
  event is opened and `inherit` is off. New tasks require a new explicit capture.
- Two syscall descriptors and 16 data pages per chosen thread. On a 4 KiB-page
  host that is 64 KiB data plus one 4 KiB metadata page. Data counts against the
  configured ring budget together with CPU rings.
- Setup verifies tracepoint ID, field widths, offsets and signedness before
  opening. Failure reports the stage, errno, TID and cleanup count; a requested
  combined capture never silently becomes CPU-only. Earlier completed capture
  evidence survives a failed start. See [SETUP.md](../SETUP.md) for host policy.
- Save/reopen carries spans and diagnostics in archive 2.5. An older reader
  rejects this feature explicitly. Ordinary captures keep their prior format.
