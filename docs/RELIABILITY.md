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
./scripts/release-check all                  # Host plus GUI, one build
./scripts/release-check all --uprobes        # Also native/C-agent function investigations; explicit sudo helper opt-in
./scripts/release-check all --list           # Exact commands; no execution
./scripts/release-check periodic --headless  # Portable checks plus readelf source-path differential
./scripts/release-check perf --headless      # Owned observer RPC measurements; no speed thresholds
```

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
workstation. A portable pass alone does not certify tracing, graphics or ARM64.

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

With a debug Perl and a separately built test-only PadWalker tree, add
`--perl /path/to/perl --padwalker /path/to/PadWalker` to the host/all gate for
named-local sanitizer/oracle, local and C-agent MCP, and shared-observer checks.
The gui/all gate also exercises Perl named locals, sigil-name entry and the
collapsible native-object section on a private display. Nothing is installed.
