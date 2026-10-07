# Repeated observation experiments

Run an explicit recipe against baseline, changed and unchanged control builds.
This Linux runner calls the existing headless xodb recipe/archive commands. It
adds scheduling, input identity, retained outcomes and descriptive statistics.
It does not edit or build your program.

For a small controlled latency demo, from the repository root:

```sh
cc -g -O0 -fno-omit-frame-pointer -DDELAY_NS=8000000 \
  tests/fixtures/observation-experiment.c -o experiment-before
cc -g -O0 -fno-omit-frame-pointer -DDELAY_NS=2000000 \
  tests/fixtures/observation-experiment.c -o experiment-after
python3 tools/experiments/run.py run examples/observation-experiment.json \
  --out experiment-01
python3 tools/experiments/run.py summarize experiment-01 --xodb zig-out/bin/xodb
xodb --open-observation experiment-01/run-003/capture.xoi
```

There are no keys to press. Each variant has one labelled warmup and five measured
runs in a seeded, interleaved order. The target calls `observed_work` 16 times.
The changed build deliberately sleeps less; the unchanged control uses the
baseline executable. The recipe's threshold remains 4 ms. Look at all run
outcomes and the distribution of per-run means, including the control's spread.
Actual measurements depend on the machine; no fixed ratio is promised.

Use a fresh destination for each experiment. Exit 0 means every run completed
without reported coverage gaps, exit 1 reports failed/incomplete/limited work,
and exit 130 reports handled cancellation. A failed run is never retried. The
manifest includes every scheduled run, including warmups and runs never started.
`result.json`, log files, capture hashes and immutable checkpoints retain the
attempted work. A crash before the final manifest leaves the plan and completed
checkpoints; this slice has no resume command. Publication is atomic and refuses
overwrite; it does not promise survival of a power failure.

`run.py summarize` verifies retained artifact hashes and reopens successful
captures through the supplied xodb to check the recorded comparison. It needs
neither original targets nor input files, and never opens executable/input/helper
paths from the recorded plan. It prints planned and eligible counts, failures,
incomplete runs, per-run complete-call denominators, min/median/max, sample
standard deviation and exact duration numerators/denominators. Warmups are
excluded from measurement summaries. A descriptive baseline/variant median ratio
requires at least two eligible runs in each group and matching selections. It is
not a significance test. Inclusive invocation duration is not CPU cost; nested
or parallel calls can overlap. There is no cross-process timestamp alignment.

Copy and edit `examples/observation-experiment.json` for your program. Paths are
resolved from the invoking working directory. Arguments are a JSON list, not a
shell command. Add explicit data/script inputs as follows:

```json
"inputs": [{"name": "data", "path": "demo-input.txt"}],
"variants": [
  {"name": "baseline", "exe": "program-before", "args": ["{input:data}"]},
  {"name": "changed", "exe": "program-after", "args": ["{input:data}"]}
]
```

Each placeholder must occupy a whole argument. An interpreted program declares
its ELF interpreter as `exe` and its script as an input. ELF executables, xodb,
the recipe, explicit inputs and an optional local C agent are copied to sealed
Linux memfds before any launch. Their hashes describe the exact sealed bytes.
Changing the original files after pinning cannot change those bytes. The capture
may record temporary descriptor labels; those are historical labels after exit.
Shared libraries, undeclared modules/files, environment, kernel and an explicitly
selected privilege helper are outside this identity claim. This is bounded
profiling, not a hermetic build or deterministic replay system.

To use the same-host C agent, add `"runtime_agent": "zig-out/bin/xodb-agent"`.
An optional `"allocation_helper": "path/to/approved-helper"` passes that exact
option to xodb; the runner does not configure privileges. SSH is outside this
slice. The existing recipe collector permissions still apply. A collector setup
failure remains a failed run with its stderr, not an empty successful profile.

Limits: 2–4 variants, 1–20 measured runs and 0–4 warmups per variant, 50 ms–300 s
per attempt, 256 MiB of aggregate pinned inputs, 64 MiB per capture, 2 MiB per
output channel, 32 KiB retained comparison per run, and up to 2 GiB of selected
output artifacts. A reserved metadata/log allowance can stop the schedule before
the requested byte ceiling. The limits cover runner-owned evidence/logs; they are
not a filesystem sandbox for target writes. Runs are serial. Linux subreaping and
pidfds clean up the owned process family on timeout, failure or handled signals,
including detached descendants. An uninterruptible task or SIGKILL of the runner
is not a graceful cancellation; incomplete cleanup stops subsequent runs and is
reported explicitly.

Component checks use synthetic collection with real xodb archive replay:

```sh
python3 tests/observation-experiments.py --work-root ./test-output
```

Create `test-output` first. These checks exercise sealing, changing inputs,
failures, timeouts, cancellation, detached-child cleanup, no-overwrite publication,
byte limits, malformed manifests and known distributions. They do not establish
live collector support. Run the demo once in native mode and once with the local
C agent to validate collection on the current host.

Destination and resource details: `--out` names a new literal directory. An
existing final component, including a dangling symlink, is refused. Input names
and placeholders are checked and all declared inputs pinned before that directory
is claimed. The pinned bytes are rehashed after the memfd is sealed.

The child xodb and its target inherit `RLIMIT_FSIZE` (the remaining per-file
allowance) and `RLIMIT_CORE=0`. The aggregate run directory is checked after each
run, before publishing a completed result. Exceeding it stops later runs and
records `output_budget` in the row's optional `additional_reasons`. An earlier
timeout, failure or cancellation remains the primary `status` and `error`;
cancellation still exits 130. A run that otherwise succeeded is marked
`output_budget`, with no successful result. Summaries count the additional
budget reason separately from primary outcomes. Older manifests without this
optional field remain readable; reading the new field needs the current runner. Retained files can already exceed the allowance because
per-file limits do not constrain the sum. This is a bounded experiment runner,
not a filesystem quota or a sandbox for arbitrary target output elsewhere.

Pinned executables see a memfd through `argv[0]` and `/proc/self/exe`. Programs
that locate resources relative to their executable path may need explicit input
arguments or a different launch setup. Libraries and environment remain outside
the pinned-input identity contract. Local manifests contain the supplied spec
paths; review or redact them before publishing results.
