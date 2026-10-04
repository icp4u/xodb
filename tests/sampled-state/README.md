# Production sampled-state collector check

This tests the low-level production perf collector with owned child processes.
The end-to-end sampled-stack workflow is covered by `tests/m2-sampled.py`.

From the repository root, coordinate workstation resource use with bugme, then:

```sh
python3 -B tests/sampled-state/run.py
```

The runner uses a fresh `.work/sampled-state-*` directory for all logs/caches.
Four short child runs check disabled, 64-byte, 4096-byte and 8192-byte modes,
register ABI/mask and kernel header identities, side-buffer bounds, actual
samples, stop/drain and descriptor cleanup. It kills/reaps only its own children.
Run outside the sandbox when perf/fork access is restricted. No policy changes,
package installation or user target is needed. Python enforces a compiler/run
wall-clock timeout; children also have their own two-second lifetime bound.

Decoder/fairness/archive guards run in the normal `zig build test` suite.
Scheduling decoder regressions can also be run with
`python3 tests/scheduling-decode.py`.
