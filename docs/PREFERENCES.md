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
| wine.hide_internal_threads | false | Hide advisory Wine internal thread names in the GUI; selected and faulting threads stay visible, and MCP still lists every thread |
| appearance.theme | builtin:dark | GUI theme preset or file relative to these preferences; CLI --theme wins |
| appearance.ui_scale | compositor | Device pixels per UI unit, 0.5–4; CLI `--ui-scale` wins, and omitting both follows the window system |
| appearance.density | `"auto"` | Debugger spacing and text size: `"auto"`, `"normal"`, or `"compact"`; Ctrl+Shift+D cycles for this window |
| profile.duration_ms | 60000 | Wall-clock deadline in milliseconds, starting when collection is enabled; 0 means until stopped. Time stopped after enable still counts. Setup before enable does not |
| profile.frequency_hz | 99 | Requested user CPU sample rate per selected thread, 1–1000 Hz |
| profile.sample_limit | 16384 | Maximum retained samples, 1–65536; the independent 32 MiB sample store may fill earlier |
| profile.syscall_timing | false | Record syscall durations on x86-64; requires 1–32 explicitly chosen threads |
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
| languages.enabled | true | Master switch for the language views; false turns every one off whatever the per-language keys say |
| languages.python, .perl, .lua, .javascript, .ruby, .go, .elisp, .gdscript | true | false turns that language view off: no runtime search, no file read and no target memory read on its behalf. CLI --language-off NAME or all also turns it off |
| symbols.image_bytes | 1073741824 | Largest ELF image read in full for source, types and names, 1 MiB–1 TiB; CLI --image-limit wins |
| symbols.image_total_bytes | 4294967296 | All full images held by the xodb process: every debugged process, capture, debug file and inflated debug section together; 1 MiB–1 TiB; CLI --image-total-limit wins |
| galaxy.additive | true | Descriptor galaxy clouds and thread beads add their light where they overlap; false keeps plain alpha blending. The galaxy keys are read only by `xodb --overview --config FILE` |
| galaxy.cloud_size | 1.6 | Cloud spread around each star and cluster, 0.5–3 |
| galaxy.brightness | 0.85 | Cloud brightness, 0.1–2 |
| galaxy.camera_zoom | 1.35 | Zoom when the pointer rests on a cluster, 1–2.5; 1 only centres it |
| galaxy.easing_ms | 450 | Camera and layout settling time, 50–2000 ms |
| galaxy.max_stars | 512 | Starting star budget, 8–1024; `+`/`-` change it while running |
| galaxy.unfold | true | Start with one star per process; false starts folded into groups |

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

`appearance.ui_scale` sets device pixels per UI unit: smaller values make text
and controls smaller and fit more content. Backing resolution always follows
the window system, independently of this setting; pointer hit testing is
converted to UI units. On Wayland, xodb follows fractional output scale and
updates when the window moves between outputs. Use `--ui-scale N` for a one-run
override; the same option and preference work in `--overview` and remote GUI
windows. A scale change re-rasterizes scalable fonts; the Win95 bitmap face is
kept at its native raster and enlarged cleanly.

Debugger density is independent of UI scale. Normal uses a 16-unit font;
compact uses 14 units and tighter toolbar/list spacing. Auto enters compact
below 960 UI units wide and returns to normal at 1040, so resizing near the
threshold does not oscillate. The key changes this window only, not the file.
The minimum window request is 640×400 UI units, converted to native surface
units at the current UI and backing scales.

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

The image budgets apply from startup and are not changed while running. The
defaults are 1 GiB for one image and 4 GiB in all; larger values are
yours to set, here or on the command line, and this file is trusted. An
image over budget is named with its size, the budget and the values to rerun
with in `get_stack`, `list_modules`, `find_symbol` and the status line; see
[large images](LARGE_IMAGES.md#full-image-budgets). Searches of every mapped
image (a breakpoint by source line, the start of a capture) may hold half of
the total, less when `symbols.image_bytes` is more than half of it, so keep
the total at twice the per-image value or more. The total is one figure
for the whole xodb process, not one per debugged process or capture, and a
file that several of them hold is read and counted once. A name lookup reads
at most the main executable in full; libraries whose symbol tables are too
large for the symbols-only view are searched once they are loaded. Images
that have no symbols-only view (inside an APK, or named by a core) are read
by a lookup only up to fixed bounds that these settings do not change; see
[name lookups](LARGE_IMAGES.md#name-lookups-and-the-full-image). An image
with compressed DWARF needs the image plus its inflated debug sections to fit
`symbols.image_bytes` together. The automatic debug-file
budgets (`symbols.auto_file_bytes`, `symbols.auto_total_bytes`) are separate
and unchanged.

The `languages` switches apply from startup to every process of the session
and are not changed while running. A language that is off is reported as
`LanguageDisabled` by its MCP tools and its tab is not offered. Off in the file
or on the command line is off; nothing turns a language back on. What this
does and does not protect against:
[language views and hostile targets](GUIDE.md#language-views-and-hostile-targets).

`decompiler.prestart` defaults to `true`. With a configured Ghidra sidecar,
xodb starts it during launch (the GUI waits for its first frame), primes the target architecture, and imports
mapped executable images in the background. Set it to `false`, or pass
`--no-ghidra-prestart`, to retain on-demand startup. `XODB_GHIDRA_SIDECAR=off`
disables the sidecar regardless of this preference.

Allocation prefs affect future captures. Helper use remains an explicit CLI option;
see [allocation tracing](ALLOCATIONS.md).

## Possible next sections — not implemented

These are areas to consider, not accepted keys or committed behavior:

- **appearance**: text size, pane sizing and compact layouts.
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
