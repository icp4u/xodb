#!/usr/bin/env python3
"""Run the production sampled-state collector on owned children only."""
from datetime import datetime
from pathlib import Path
import os
import subprocess

root = Path(__file__).resolve().parents[2]
work = root / ".work" / ("sampled-state-" + datetime.now().strftime("%Y%m%dT%H%M%S%f"))
work.mkdir()
(work / "tmp").mkdir()
env = dict(os.environ, TMPDIR=str(work / "tmp"),
           ZIG_LOCAL_CACHE_DIR=str(work / "cache"),
           ZIG_GLOBAL_CACHE_DIR=str(work / "global"))
command = ["zig", "test", "-O", "ReleaseSafe", "--dep", "perf",
           "-Mroot=tests/sampled-state/live.zig",
           "-Mperf=src/profile/linux_perf.zig", "-lc"]
with (work / "live.log").open("x") as log:
    result = subprocess.run(command, cwd=root, env=env, stdout=log,
                            stderr=subprocess.STDOUT, timeout=180)
print(work)
print((work / "live.log").read_text())
raise SystemExit(result.returncode)
