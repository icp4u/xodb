# Release reliability gate

Run from an x86-64 Linux checkout with Zig 0.16 or newer and the dependencies in
[SETUP.md](../SETUP.md). Each command returns nonzero on failure or missing
capabilities. It never changes tracing policy or contacts a device.

## Build targets

`scripts/build` wraps `zig build` with repository-local temporary files and
caches. The same targets and `-D` options work with either command. Builds
default to Debug unless `-Doptimize` is supplied.

| Command | Purpose |
| --- | --- |
| `./scripts/build -Doptimize=ReleaseSafe` | Default install: GUI app, allocation helper and native test/demo fixtures in `zig-out/bin` |
| `./scripts/build app -Doptimize=ReleaseSafe` | Install the app and applicable helper without building fixtures |
| `./scripts/build test -Doptimize=ReleaseSafe --summary all` | Build/install fixtures and run Zig unit plus live target tests |
| `./scripts/build run -- --help` | Exercise the run target and CLI; replace `--help` with normal app arguments for an interactive launch |
| `./scripts/build app -Dgui=false -Doptimize=ReleaseSafe --prefix .work/headless-release` | Build the headless MCP service separately from the GUI executable |
| `./scripts/build --help` | List targets and build options |

Repeat with `-Doptimize=Debug` when checking safety diagnostics. An ordinary
`test` run needs live ptrace/perf permissions; use the portable release tier
below when those capabilities are intentionally unavailable.

## Release commands

```sh
./scripts/release-check portable             # GUI build and tests, no display/ptrace/perf
./scripts/release-check portable --headless  # No GUI development dependencies
./scripts/release-check host                 # Live debugger/profiler regressions
./scripts/release-check gui                  # Private Sway/Vulkan regressions
./scripts/release-check gui --perl /path/to/debug/perl # Also the Perl live-row demo (5.44 + DWARF)
./scripts/release-check all                  # Host plus focused GUI, one build
./scripts/release-check periodic-gui         # Full graphics and delayed-discovery matrices
./scripts/release-check all --uprobes        # Also native/C-agent function investigations; explicit sudo helper opt-in
./scripts/release-check all --list           # Exact commands; no execution
./scripts/release-check gui --keep-going     # Run every step, then list all failures
./scripts/release-check gui --only gui-files,gui-themes # Rerun chosen steps (always rebuilds first)
./scripts/release-check gui --from gui-files # Resume at a step
./scripts/release-check periodic --headless  # Portable checks plus readelf source-path differential
./scripts/release-check perf --headless      # Owned observer RPC measurements; no speed thresholds
```

GUI steps that fail are retried once by default in `gui`, `all` and
`periodic-gui` (`--retry-flaky N`; `0` turns it off). A step that passes only on
retry is recorded as `flaky` in the summary line and `results.json`, never as
passed. `scripts/build` uses an existing `ZIG_GLOBAL_CACHE_DIR`, so gate
snapshots can share one warm cache; `packaging/build` always uses the in-tree
cache.

The explicit `periodic` tier starts the periodic correctness lane. It includes
portable checks and 1,500 deterministic malformed/valid DWARF 2–4 file tables,
compared with GNU readelf: every authorized path must appear in readelf's table.
Stricter refusals are counted separately. It is excluded from `all`; run it in a
scheduled job or when changing the source-path parser. This tier performs no
live target or GUI checks and rejects live-runtime options. Reports record the
host load and available CPU count; correctness still fails on a counterexample
under load. This is not a performance benchmark or a replacement for `all`.
Other slow matrices remain in their existing tiers until focused replacements
preserve their lifecycle and fault assertions.

The separate `perf` tier is excluded from `all`. Its first benchmark measures
cached `get_session` RPCs on an owned stopped fixture, locally and through the
C agent. It warms the transport before recording CPU and resident memory at
the same boundaries, and saves each RPC duration plus host load samples. The
fixed request count defines the workload, not a throughput requirement.
These measurements include RPC and harness overhead; they do not measure GUI
latency, tracing overhead or language-reader performance.

If any sampled load average exceeds the allowed CPU count, the measurement
and top-level report say **not-measurable** and return zero. The raw observations
remain available but are not performance evidence. Crashes, failed requests,
target state/register changes and missing capabilities still fail or block
normally, including under load. No existing correctness check is removed by
this initial lane. It rejects runtime SDK options; use the ordinary host/GUI
tiers to validate language adapters.

Use `--optimize Debug` for a second build mode; the default is ReleaseSafe.
For a release candidate, require portable CI plus `all` on the configured
workstation, plus `periodic-gui` for the full graphics and delayed-discovery matrices. An `all` pass deliberately excludes those matrices; its result records that exclusion. A portable pass alone does not certify tracing, graphics or ARM64.

The newer source-block, comparison, process-tree and allocation suites are
separate from `all`. After building the default target, also run:

```sh
python3 tests/source-blocks.py
python3 tests/comparison.py --gui
python3 tests/allocations-gui.py
python3 tests/process-tree.py
python3 tests/process-capacity.py
XODB_BUILD_PREFIX=zig-out python3 tests/process-gui.py
sudo -v
python3 tests/allocations-live.py --helper "$PWD/zig-out/bin/xodb-allocation-helper"
python3 tests/allocations-live-gui.py --prefix zig-out --helper "$PWD/zig-out/bin/xodb-allocation-helper"
```

The two allocation commands explicitly opt into the scoped helper described in
[ALLOCATIONS.md](ALLOCATIONS.md). They do not belong in unprivileged portable CI.
The `--uprobes` release option likewise opts into that helper for owned function
fixtures. It covers invocation evidence, recipes, archive reopening and temporal
associations locally and through the C agent. Stopped-context inspection jobs
are covered by the ordinary host tier without that helper.

## Test source layout

`tests/repros` was retired before release. Maintained C/Zig inputs live in
`tests/fixtures`; shared private-display/input code lives in `tests/helpers`.
APK, Android-native/app and standalone ARM64/sample-state checks have dedicated
directories directly under `tests`. Their device opt-ins are unchanged.
The private GUI `tests/helpers/input.py` Display accepts `binary=PATH` and
`output_size=(width, height)`; defaults use the checkout binary at 1280×800.
Set its `WORK` to an owned short path containing `/.work/input-` (for example,
`WORK_DIR/.work/input-demo`). The virtual-input helper checks that path together
with `XODB_TEST_PRIVATE_DISPLAY=1` before injecting; this is a guard against
accidentally using an interactive desktop. Display creates its own Sway session.

Display also enables `XODB_LANGUAGE_LAYOUT=1`: the language pane records clipped
text boxes and reports overlapping labels. Shared language-selection checks
require a nonempty report; diagnostic-row tests require the diagnostic to have
been drawn. Selected frame diagnostics occupy the existing detail line, so they
cannot spill into the next frame name.

Old prototype patch runners and generated research outputs were removed;
historical task/research notes may still mention their archived paths.

## Coverage

| Gate | Evidence |
| --- | --- |
| Portable | Build/install, ELF/DWARF fixtures, parser/decoder bounds, archive allocation/cancellation, recorded views, scope/generation guards; GUI model/input tests when building the GUI |
| Host | All Zig live tests; source/instruction stepping, locals/eval, breakpoint/watch restoration, thread creation and exec/exit, attach/detach and target ownership |
| Host profiles | Mapping changes, dynamic threads and fixed subsets, bounded rings and descriptors, explicit forced stops, sampled stacks, snapshot workers, 65,536-sample limit, save/reopen without original binaries |
| Remote | Loopback TCP, fragmented messages, stale requests, EOF and SIGHUP cleanup, preservation and restored code in attached targets, agent scope |
| GUI | Local debugging/profiling, neutral flame refresh progress and visible worker failures, remote panes while running, hidden workspace responsiveness, injected Vulkan acquisition/fence delays, SIGINT/window close/MCP EOF, competing Wayland readers |

Existing tests are called directly; assertion failures are never turned into
skips. `XODB_TEST_NO_LIVE=1` explicitly excludes live Zig cases for the portable
and GUI-only build step. The host/all gate explicitly clears that exclusion.
The normal `./scripts/build test` still runs live tests by default. ARM-only
tests report their existing architecture skips on x86-64.

## Isolation, prerequisites and results

- Each run copies **tracked working-tree** build/source/test/script files into
  a fresh, short `.work/rXXXX/` directory. Local edits are included; untracked
  prototypes and ignored build outputs are excluded. Stage new test inputs
  before running. This is an isolated test run, not proof of a clean checkout
  or a reproducible distribution build.
- Original `zig-out`, fixture outputs, caches and the interactive desktop are
  untouched. GUI scripts create private headless Sway displays; the runner
  strips inherited display/session variables before starting any test.
- Every tier probes local Unix-socket communication. Host/gui/all/perf also probe
  loopback binding, ptrace on an owned child and a user-only perf event.
  Missing tools or denied probes return **2 (blocked)** with diagnostics. A
  successful probe is necessary, not proof that every requested perf feature
  works. Later assertion failures remain failures. Re-run with the intended
  host permissions after a sandbox denial; see [setup](../SETUP.md).
- Live tests additionally use G++, Clang++, GDB and strace. GUI tests need
  Sway/swaymsg, grim, Python Pillow, DejaVu Sans Mono, a working Vulkan driver, and
  `/usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml`.
- Tests run sequentially with per-command deadlines. The runner creates a
  process group for each command and acts as a child subreaper. Timeout,
  nonzero exit and leftover processes fail the gate; only that command's
  process group and adopted descendants are terminated and reaped, including
  descendants that change sessions. It stops at the first failure.
- Every step starts with `TERM=dumb`, `LANG=LC_ALL=C.UTF-8` and `TZ=UTC`.
  Inherited colour overrides, terminal descriptions/geometry and other locale
  categories are removed. Tests that exercise colour, terminal size or a
  particular locale set those capabilities explicitly in their child environment.
  Build, SDK and test configuration variables remain available.
- `results.json` records status, commands, timings, exit codes, logs, kernel,
  policy values, dependency versions, commit, tracked modifications and a
  SHA-256 manifest of the copied sources. Detailed test artifacts remain in
  that run's nested `.work/`. No reports are uploaded by the local runner.

`tests/release-runner.py` runs in every tier and checks environment isolation,
explicit test overrides, nonzero exits, deadline enforcement and cleanup
of deliberately orphaned or signal-resistant owned children, including a child
that escapes its original process group/session.

## Automation and hardware sign-off

This checkout has no checked-in GitHub Actions workflow. The local
`scripts/release-check` runner is the available automation; its reports are
local evidence, not a claim of hosted CI coverage. Dependency versions are
recorded in each report. #TODO: set up CI

Before tagging, record these additional results for the candidate build:

- Real GPU: leave a stopped debugger with expression watches hidden on another
  workspace for at least 20 minutes; return, step/continue, resize and quit.
  Repeat with an attached expendable fixture and confirm it survives untraced.
  Automated eight-second pacing/fault tests cannot establish long idle/driver
  reliability. Record GPU, driver, compositor and elapsed time.
- ARM64 Linux: run the native/watchpoint suites described in [ARM64.md](ARM64.md)
  on the intended host; record kernel and binary identity. The x86 gate does
  not convert its ARM skips into ARM coverage.
- Android: run the bounded, reviewed tests in [ANDROID_NATIVE_PLAN.md](ANDROID_NATIVE_PLAN.md)
  and [ANDROID_APK_TEST_PLAN.md](ANDROID_APK_TEST_PLAN.md), including confirmed
  probe restoration/detach and exact-file cleanup. Test device-loss behavior
  on an expendable target/device before claiming it; these tests require a
  separate device authorization and are never part of `all`.

Keep pass/blocked/fail and untested configurations explicit in release notes.

For language-pane coverage, pass explicit debug runtimes to `scripts/release-check
all --python ./python --perl ./perl --node ./node --lua ./lua ./lua-src
./liblua.a` (as one command). These flags also exercise tab discovery with the
real runtimes, locally and through the C agent. `--python` includes a syscall
audit: repeated selections at one retained stop do not reread target memory;
stepping invalidates that cache. Timing numbers are evidence, not pass criteria.

Node's positive context/watch checks require a build with proved V8 frame
configuration. A matching version string alone is insufficient. Keep that
runtime in `--node`; for a separate build whose frame configuration is unproved,
add `--node-refusal ./debug-node` to the gui/all gate. The separate case requires
metadata to complete, then checks the exact `JavaScriptContextFrameUnproved`
refusal from both locals and watch creation, with unchanged registers/generation
and no watch added. It never substitutes for the positive watch checks. Cold
metadata setup has the same bounded 900-second ceiling as the other Node GUI
checks; the actual elapsed time is recorded as evidence.

With a debug Perl and a separately built test-only PadWalker tree, add
`--perl /path/to/perl --padwalker /path/to/PadWalker` to the host/all gate for
named-local sanitizer/oracle, local and C-agent MCP, and shared-observer checks.
The gui/all gate also exercises Perl named locals, sigil-name entry and the
collapsible native-object section on a private display. Nothing is installed.

## Focused checks and periodic matrices

Run `scripts/release-check all` for ordinary changes and
`scripts/release-check periodic-gui` periodically and before release. Scheduling
changes do not change a test failure into a skip. The full existing commands
and their assertions remain in the periodic lane; this runner does not install
a scheduler. Use `--list` to see the exact commands.

| Area | Ordinary host/gui/all | Explicit periodic coverage |
| --- | --- | --- |
| Vulkan faults | Baseline, partial and poisoned creation, present loss/recovery, ten-lifetime late-init failure with host/Vulkan accounting, actual resize; existing hidden/acquire/fence/Wayland tests also remain | Complete startup/create/poison/frame/resize matrix |
| Overview | Redacted identity, unavailable-state reasons, all-panel layout at 1280×720 redacted, animation/shutdown; live overview test remains | Complete panel/theme/sort/search/action/redaction and resolution matrix |
| Clipboard | Control/format filtering, truncation, UTF-8 edits, stalled transfer and stale-editor checks | All cursor/selection, middle-click, editor, profile and archive threshold cases |
| Symbol discovery | Normal discovery and install cases, including completion, interruption and unavailable symbols | Same completion/interruption assertions at 25/50/100 ms per reply |

`periodic --headless` includes the source-path differential and delayed-discovery
matrix without graphics. `periodic-gui` includes those plus the three full GUI
matrices. Runtime SDK flags are rejected in both because these lanes do not
schedule runtime-specific checks; run the ordinary lane with those flags too.
Neither periodic lane is the performance lane: its correctness failures remain
failures under load. `perf` reports measurements separately.

The focused GUI checks retain the existing synchronization and timeout rules.
They do not claim a new presentation acknowledgement or a timing-flake fix.
Other expensive suites, including memdefrag and runtime-specific GUIs, still run
in their original lanes pending separately reviewed coverage changes.

The performance lane also records syscall-capture status-query latency against
the historical 250 ms reference, with CPU, RSS and host load at the capture
boundaries. This reference never fails a correctness gate; overloaded runs are
labelled not measurable. The ordinary syscall check still requires exact
records, observable overflow/loss, closed perf descriptors and lossless archive
roundtrips. Run `python3 tests/syscall-timing.py --perf --work .work/syscall-perf`
for just these measurements on a host with syscall tracing configured.
