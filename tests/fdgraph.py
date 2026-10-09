#!/usr/bin/env python3
"""Bounded descriptor graph checks; all live PIDs and UNIX sockets are owned."""
import argparse
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--cc', default='cc')
p.add_argument('--sanitize', action='store_true')
p.add_argument('--stress', action='store_true', help='synthetic 1000 process / 100000 fd evidence')
a = p.parse_args()
os.umask(0o022)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
root = Path(__file__).resolve().parent.parent
work = root / '.work'
work.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='fdgraph-', dir=work) as td:
    out = Path(td)
    out.chmod(0o755)
    flags = ['-std=c11', '-DNDEBUG', '-Wall', '-Wextra', '-Werror', '-pthread', '-g', '-O1' if a.sanitize else '-O2']
    if a.sanitize:
        flags += ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
    common = ['src/runtime/fdscan.c', 'src/runtime/fdgraph.c', 'src/runtime/fdgraph_layout.c', 'src/runtime/unix_peer.c']
    for name, source in [('graph', 'tests/runtime-fdgraph.c'), ('owner', 'tests/runtime-fdgraph-owner.c'), ('growth', 'tests/runtime-fdscan-growth.c')]:
        binary = out / name
        subprocess.run([a.cc, *flags, '-Isrc/runtime', *(common if name != 'growth' else ['src/runtime/fdgraph.c', 'src/runtime/fdgraph_layout.c']), source, '-lm', '-o', str(binary)], cwd=root, check=True, timeout=120)
        modes = [[]] + ([['--live']] if name == 'graph' else [['--fast'], ['--quiet-demand']] if name == 'owner' else [])
        if name == 'graph' and a.stress:
            modes += [['--stress']]
        if name == 'growth' and a.stress:
            modes += [['--large']]
        for mode in modes:
            before = os.getloadavg()
            result = subprocess.run([str(binary), *mode], cwd=root, text=True, capture_output=True, timeout=60)
            print(json.dumps({'test': name, 'args': mode, 'returncode': result.returncode, 'load_before': before, 'load_after': os.getloadavg(), 'cpus': os.cpu_count()}), flush=True)
            print(result.stdout, end='', flush=True)
            print(result.stderr, end='', flush=True)
            result.check_returncode()
        wrong = subprocess.run([str(binary), '--wrong-oracle'], cwd=root, text=True, capture_output=True, timeout=60)
        if wrong.returncode != -signal.SIGABRT or 'CHECK failed:' not in wrong.stderr:
            raise RuntimeError(f'{name} planted wrong oracle did not fail: {wrong.returncode}: {wrong.stderr}')
        print(f'{name}: planted wrong oracle rejected with NDEBUG', flush=True)
print('descriptor graph checks PASS')
