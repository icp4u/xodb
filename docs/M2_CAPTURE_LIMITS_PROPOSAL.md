# T15 follow-up: configurable sample ceilings

Status: adopted by the user and integrated, 2026-10-02.

## Short critical review

This makes a longer capture possible with one preference or MCP argument while
keeping the initial 16,384-sample default. The candidate crossed that old boundary
in a real two-thread capture, reached 65,536, served a live flame snapshot, and
saved/reopened all samples. Keeping the compact store's 32 MiB budget prevents
the count knob from becoming unbounded retention. Diverse stacks can still fill
memory first; 65,536 is a ceiling, not a promised count or duration.

The cost is larger archive and worker budgets and an explicit file-format
extension. Nondefault limits use archive 2.4 and require a newer reader; default
captures keep the 2.3 encoding. Synthetic maximum-path/stack tests cover difficult
size combinations, but do not establish game/server overhead. Snapshot copying
still runs briefly on the event loop (about 10–24 ms in these synthetic tests),
so this is a bounded fourfold increase, not a claim that indefinite captures are
ready. Spooling, retention rotation and larger defaults remain separate choices.

## Candidate behavior

- `profile.sample_limit` in JSON preferences: **1–65,536**, default **16,384**.
- MCP `start_profile.sample_limit` overrides the next-capture preference for that
  capture; omitted values use the preference. `get_profile` reports defaults and
  the capture's actual limit.
- The GUI summary/setup and exceptional-stop stderr show the capture's own limit.
  This first slice changes the knob through preferences or MCP, with no new GUI
  input control. Existing setup changes preserve the count preference.
- The sample store remains at **32 MiB**; saved stacks retain their independently
  configured budget. Saved register/state entry capacity follows sample_limit.
  A full stack budget keeps CPU sampling and register records, with explicit gaps.
- Archive **2.4** adds required feature bit 4 (`16`) and a `LIMT` section containing
  the chosen `u32` ceiling. Decode validates it before sample allocation.
  Legacy archives imply 16,384. Nondefault ceilings, including smaller ones,
  carry the extension; an older reader rejects its required feature explicitly.
- Archive file cap **128 → 256 MiB**; archive allocation budget **256 → 512 MiB**;
  recorded snapshot/graph worker allocation budget **64 → 96 MiB**. These are
  ceilings, not eager allocations or whole-process RSS limits. Original captures,
  ELF snapshots, graphics and an output byte copy have separate lifetimes/budgets.
- Existing archive copies retain their original bytes. No durability/fsync change.

Example opt-in configuration:

```json
{"profile":{"duration_ms":0,"sample_limit":65536}}
```

```sh
./zig-out/bin/xodb --config my-prefs.json --attach PID
```

## Evidence

Candidate: `.work/t15-limits`, based on commit `742b674`. The approved candidate is now integrated in the main working tree. [Detailed journal](research/capture-limits.md).

- ReleaseSafe suite: **200 passed, 4 ARM-only skipped**.
- Config validation: default, one-sample minimum, maximum, zero/overflow/type errors.
- Collector admission: continues through 16,384 and stops at the configured count;
  later records are discarded without orphaned saved stack records.
- Archive: default/legacy ceiling, custom low/high ceiling, required feature,
  invalid limits and count-over-limit rejection; lossless reopened bytes.
- Synthetic archive: 65,536 deep samples, large mapping paths, scheduling and a
  full 64 MiB stack budget saved/reopened in **143,175,163 bytes**; encoding allocation peak **300,162,453 bytes**
  (including output copying), decoded allocation peak **265,702,561 bytes**.
- Worker: 65,536 repeated deep samples, ~10.5 ms snapshot/~117.6 ms build;
  diverse deep chains stop at 27,776 within the sample byte budget, ~23.8 ms
  snapshot/~66.8 ms build, ~64.5 MiB worker peak. The latter exceeds the previous
  64 MiB worker budget, which is why that bound must move too.
- Real perf/MCP: **65,536 samples and saved state records**, 32.9-second capture,
  explicit stack-budget gaps, stable live flame snapshot, capacity stderr,
  save/reopen; largest status request **6.98 ms** in 313 polls.
  [Machine-readable result](research/capture-limits/live-results.json).
- Private headless Sway: reopened capture and setup show **65,536 of 65,536**.
  [Flame view](research/capture-limits/01-large-capture.png) ·
  [Setup](research/capture-limits/02-large-capture-setup.png).

## Adoption decision

Adopt this opt-in ceiling, its required archive extension and the three larger
resource bounds together. Keep all default capture settings as they are.
