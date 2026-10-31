#!/usr/bin/env python3
"""Periodic GUI lane: invalid overview arguments/help with a slow finalizer.

The finalizer widens the original loader/ICD exit race. Correctness is exact
exit/error output, an observed instance call before finalization, and normal
completion of the active amplifier, never a timing threshold or crash rate.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import time

os.umask(0o022)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
root = Path(__file__).resolve().parents[1]
os.chdir(root)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary', nargs='?', default='zig-out/bin/xodb')
parser.add_argument('--runs', type=int, default=100)
args = parser.parse_args()
if not 4 <= args.runs <= 500:
    parser.error('--runs must be 4..500')
binary = str(Path(args.binary).resolve())
spec = importlib.util.spec_from_file_location('display', root/'tests/helpers/display.py')
display = importlib.util.module_from_spec(spec)
spec.loader.exec_module(display)
display.WORK = str(root/'.work'/('vkx-'+str(time.time_ns())[-9:]))
d = display.Display('soak')
rows = []
started = time.monotonic()
try:
    shim = Path(d.dir)/'slow.so'
    subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                    'tests/vulkan-slow-fini.c', '-ldl', '-o', str(shim)], check=True, timeout=30)
    env = dict(d.env, LD_PRELOAD=str(shim), XODB_TEST_SLOW_FINI='1')
    deadline = time.monotonic() + 240  # total service/deadlock ceiling
    for n in range(args.runs):
        help_exit = bool(n % 2)
        # An explicit device disables the display-driver-only loader filter;
        # early abandonment does not need to select/create this device.
        unfiltered = bool((n // 2) % 2)
        argv = ['--overview', *(['--vk-device', '0'] if unfiltered else []),
                *(['--help'] if help_exit else ['--panel', 'test-invalid-panel'])]
        remaining = deadline - time.monotonic()
        assert remaining > 0, 'exit soak exceeded service ceiling'
        before = time.monotonic()
        proc = subprocess.run([binary, *argv], env=env, capture_output=True, timeout=min(30, remaining))
        text = (proc.stdout+proc.stderr).decode(errors='replace')
        (Path(d.dir)/f'run-{n}.log').write_text(text)
        marker = re.findall(r'^vkslowfini: begin instances=(\d+) delay_us=(\d+)$', text, re.M)
        expected = 0 if help_exit else 1
        problems = []
        crash = proc.returncode < 0 or bool(re.search(r'Segmentation fault|panic|reached unreachable', text))
        if crash:
            problems.append('crash/panic')
        if proc.returncode != expected:
            problems.append(f'exit {proc.returncode}, expected {expected}')
        if not help_exit and 'error: UnknownOverviewPanel' not in text.splitlines():
            problems.append('missing exact panel error')
        if len(marker) != 1 or int(marker[0][0]) == 0:
            problems.append('instance creation not observed before finalization')
        if text.splitlines().count('vkslowfini: end') != 1:
            problems.append('amplifier did not complete')
        row = dict(run=n, help=help_exit, unfiltered=unfiltered, returncode=proc.returncode,
                   seconds=time.monotonic()-before, crash=crash, problems=problems)
        rows.append(row)
        print(json.dumps(row), flush=True)
    assert not any(row['problems'] for row in rows), [row for row in rows if row['problems']]
finally:
    (Path(d.dir)/'results.json').write_text(json.dumps(dict(seconds=time.monotonic()-started, runs=rows), indent=2)+'\n')
    d.close()
    print(d.dir, flush=True)
