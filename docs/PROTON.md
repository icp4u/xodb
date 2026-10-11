# Wine and Proton on Linux

xodb attaches to the Linux process running a Windows executable under Wine or
Proton. It uses the Linux debugger interface; no Windows machine or Windows
build of xodb is required. Use this workflow for owned programs, single-player
games and offline sessions only. Do not attach to anti-cheat-protected sessions.

## Pick a process

```sh
xodb --attach-exe
```

This opens the existing process picker with an editable `.exe` search. It
matches process names and readable command lines; it is a candidate filter,
not proof that every match is a Windows program. `/` edits the search. Select a
row and press Enter, then confirm the debugger action. The handoff retains
the sampled PID and start time and refuses an identity that changed before
attach. An attached process is preserved on debugger close.

For a known PID, use `xodb --attach PID`. Container paths are resolved through
the target's mappings and mount namespace where possible; see [PE support](PE.md).
No target, game, Steam prefix or machine configuration is modified to enable
these labels. Existing ptrace permissions still apply.

## Process and thread labels

Executable mappings of both the Windows and Unix ntdll components identify a
Wine process. The debugger header then says `Windows process under Wine`.
A mapped Proton installation can also supply its bounded `version` file.
Unavailable versions are labelled unavailable; a Steam path or `.exe` search
match alone does not establish Wine or a Proton version. Detection is advisory.

The native Linux backend reads task names for Wine processes. Wine copies
readable Windows thread descriptions into those names. Linux can truncate
them to 15 bytes; `~` marks possible truncation. Names that are unavailable
remain unavailable. xodb does not inject a call into the game or query a
different process to recover a longer description. Remote-agent, GDB-remote,
core and archive sessions report this local metadata as unavailable.

All threads are shown by default. Recognized `wine_threadpool`, `wine_rpcrt4_`
and `wine_sechost_` task-name hints are grouped below other threads and labelled
`Wine internal name`. These names are hints: a pool thread may execute game
callbacks, and an application can choose the same name.

Press **H** to hide or show those rows. Selected threads and threads stopped
on a signal, breakpoint, watchpoint or single-step remain visible. J/K follows
the displayed order. Filtering changes only the visible list: controls,
capture, retained evidence and MCP thread inventory still include every thread.

```sh
xodb --wine-threads hide --attach PID
xodb --wine-threads show --attach PID
```

The equivalent explicit preference is:

```json
{"wine":{"hide_internal_threads":true}}
```

Load it with `--config FILE`. A CLI choice overrides the file; an H-key change
is local to that process workspace and is not written back.

MCP `get_session` includes advisory `compatibility` and `thread_labels` fields.
`list_threads` also returns the labels alongside its unchanged full inventory.
Each label binds the debugger thread ID and Linux TID and reports its source,
readability, possible truncation and internal-name hint.

Implementation references: Wine's [thread naming](https://github.com/wine-mirror/wine/blob/master/dlls/ntdll/unix/thread.c)
and Proton's [installation version file](https://github.com/ValveSoftware/Proton/blob/proton_11.0/proton).

A target can influence which `version` file is selected within its Proton directory.
That bounded, sanitized line is advisory target-provided text, not a verified host installation identity.
