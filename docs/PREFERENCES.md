# Preferences: first working sketch

This is a starting point, not a frozen schema or a statement that these defaults
are settled. JSON keeps the first loader small and uses the existing parser.

Start with [config/preferences.example.json](../config/preferences.example.json):

~~~json
{
  "profile": {
    "duration_ms": 60000,
    "frequency_hz": 99,
    "sample_limit": 16384,
    "context_switch": false,
    "user_stack_bytes": 0,
    "user_stack_budget_bytes": 33554432
  }
}
~~~

Load it explicitly:

~~~sh
./zig-out/bin/xodb --config config/preferences.example.json --attach PID
~~~

There is currently no implicit config search, automatic save or preferences-file reload.
The selected [theme file](THEMES.md) is loaded at startup; restart to apply edits.
xodb does not create a file in your home directory. Edit a file where you want it
and pass its path. This keeps location, merging and persistence choices open.

## Implemented settings

| Setting | Initial default | Meaning |
| --- | --- | --- |
| appearance.theme | builtin:dark | GUI theme preset or file relative to these preferences; CLI --theme wins |
| profile.duration_ms | 60000 | Wall-clock deadline in milliseconds; 0 means until stopped |
| profile.frequency_hz | 99 | Requested user CPU sample rate per selected thread, 1–1000 Hz |
| profile.sample_limit | 16384 | Maximum retained samples, 1–65536; the independent 32 MiB sample store may fill earlier |
| profile.syscall_timing | false | Record syscall durations; requires 1–32 explicitly chosen threads |
| profile.syscall_limit | 16384 | Retained syscall spans, 1–65536; reaching the limit stops the capture |
| profile.context_switch | false | Include per-thread scheduling transitions |
| profile.follow_threads | true | Enroll new same-process threads for all-thread captures; explicit TID selections remain fixed |
| profile.ring_budget_bytes | 67108864 | Total live perf data rings, 4096–268435456 bytes; one extra metadata page per event |
| profile.user_stack_bytes | 0 | Disable stack capture, or request 64–8192 bytes/sample, multiple of 8 |
| allocations.duration_ms | 60000 | Allocation wall-clock deadline; 0 removes the time limit |
| allocations.record_limit | 32768 | Entry/return evidence ceiling, 2–131072 records |
| allocations.memory_limit | 33554432 | Retained allocation evidence/metadata/analysis, 1–128 MiB |
| allocations.callstacks | true | Capture bounded frame-pointer caller prefixes at allocator entry |
| profile.user_stack_budget_bytes | 33554432 | Total retained stack bytes, 0–67108864; registers/CPU samples continue after exhaustion |

Duration accepts an unsigned 32-bit value (up to 4,294,967,295 ms, about 49 days).
There is no separate one-minute ceiling. A deadline includes time paused in the
debugger. Zero removes only the time deadline: sample/mapping/scheduling limits,
lost metadata, thread-scope changes, target exit and collection errors can still
end a capture and report why on stderr.

Exited thread rings release their budget after final draining. Opening ring sizes
are adaptive; the budget must fit the opening set. Child processes, TID reuse,
1,024 retained thread identities or failed enrollment can still stop a capture.
These two settings are currently changed through preferences or MCP.

Set `profile.sample_limit` to 65536 for the larger opt-in ceiling. Change it
through preferences or MCP; the current GUI setup preserves it and shows the
active capture's value. A nondefault ceiling uses archive 2.4 and requires a
reader supporting that extension. [Bounds and evidence](M2_CAPTURE_LIMITS_PROPOSAL.md).

All settings are optional. Omitted fields use built-in defaults. Unknown fields,
duplicate keys, invalid values and malformed JSON fail startup with the path and
error on stderr. Files must be regular files, at most 64 KiB; FIFO paths fail
without waiting for a writer. JSON comments are not supported.

## Defaults and active captures

The precedence is:

1. Built-in defaults.
2. The explicitly loaded preferences file.
3. Human changes to the session's next-capture controls.
4. Explicit arguments to a particular MCP start_profile request.

The profile toolbar's **Next** duration button or **T** cycles through
10 seconds, 30 seconds, 60 seconds, 5 minutes, and until stopped. A custom value
from a file advances to the next larger preset. T works in the profile view
even when the window is too narrow to show the button.

**S** opens the capture setup panel: duration/rate presets and custom numeric
values, scheduling, an explicit thread subset, off/1/4/8 KiB stacks and
8/32/64 MiB total stack budgets. Prefs and MCP also accept other validated stack
values. See [sampled stacks](M2_SAMPLED_UNWIND.md).

Duration, rate, scheduling and stack controls update session defaults for subsequent
GUI captures and omitted MCP arguments. The current capture keeps its opening
settings; the capture summary shows its own limit. GUI changes do not write back
to the preferences file. Explicit MCP arguments affect only that capture.

MCP get_profile exposes defaults separately from capture. Agents should read
those defaults rather than assume every omitted argument means the original
built-in value. Preference loading does not change agent scope; command-line
--agent-scope and the existing human control remain authoritative.

Allocation prefs affect future captures. Helper use remains an explicit CLI option;
see [allocation tracing](ALLOCATIONS.md).

## Possible next sections — not implemented

These are areas to consider, not accepted keys or committed behavior:

- **appearance**: font, text size, colors, pane sizing and compact layouts.
  See the [skins and look and feel sketch](SKINS_PROPOSAL.md) for proposed keys
  and examples; these are not accepted by the current parser.
- **input**: shortcuts and navigation repeat behavior; keep the user's existing
  active-layout-only policy until reviewed.
- **profile**: presets, event choice, sampling/unwind options and separate
  resource budgets once those paths exist and have measurements.
- **debugger**: presentation, source search/remapping and stepping preferences.
- **archives**: symbol asset locations and output naming; explicit resolution
  and provenance remain necessary.
- **workspace/target overrides**: useful later, with explicit precedence and a
  clear distinction between trusted user preferences and project-supplied data.

We can revisit JSON versus another syntax, XDG discovery, multiple files,
write-back, live reload and the division between preferences and per-capture
options as real workflows emerge.

Syscall timing, timeline/detail controls, ABI assumptions and archive support:
[SYSCALL_TIMING.md](SYSCALL_TIMING.md).
