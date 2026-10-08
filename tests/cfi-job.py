#!/usr/bin/env python3
"""Owned CFI workers, live mapping proof, cancellation and foreground fairness."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--library', type=Path, required=True)
p.add_argument('--agent', type=Path, required=True)
p.add_argument('--fixtures', type=Path, required=True)
p.add_argument('--sanitize', action='store_true')
p.add_argument('--node', type=Path)
a = p.parse_args()
os.umask(0o022)
r = Path(__file__).resolve().parents[1]
w = a.work.resolve()
w.mkdir(parents=True, exist_ok=True, mode=0o755)
exe = w / 'check'
flags = ['-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
subprocess.run(['clang' if a.sanitize else 'cc', '-g', '-std=c11', '-Wall', '-Wextra', '-Werror',
    *flags, 'tests/cfi-job.c', 'src/debug/metadata_job.c', 'src/debug/cfi_image.c',
    'src/language/javascript_image.c', 'src/language/javascript.c', 'src/language/javascript_ranged.c',
    'src/binary/symbol_query.c', 'src/binary/placement.c', 'src/binary/object_cache.c', 'src/binary/cache_pool.c', 'src/debug/dwarf_index.c', 'src/debug/dwarf_names.c',
    str(a.library.resolve()), '-ldw', '-lelf', '-latomic', '-pthread', '-lm', '-o', str(exe)], cwd=r, check=True, timeout=60)
rows = []


def run(name, image, remote=False, mode='plain', delay=0):
    if mode == 'mutation':
        copy = w / name
        shutil.copy2(image, copy)
        image = copy
    env = dict(os.environ, XODB_METADATA_AGENT=str(a.agent.resolve()), XODB_METADATA_DELAY=str(delay))
    proxy = str(r / 'tests/fixtures/metadata-agent-proxy.py') if remote else '-'
    p = subprocess.run([str(exe), str(image), proxy, mode], env=env, capture_output=True, text=True, timeout=150)
    (w / (name + '.log')).write_text(p.stdout + p.stderr)
    rows.append({'name': name, 'exit': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr})
    (w / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
    assert p.returncode == 0, rows[-1]


for variant in ('exec', 'pie'):
    for remote in (False, True):
        for mode in ('plain', 'cancel', 'mutation'):
            run(variant + ('-agent-' if remote else '-local-') + mode,
                a.fixtures.resolve() / variant, remote, mode)
for delay in (.05, .1):
    run('slow-' + str(delay), a.fixtures.resolve() / 'pie', True, delay=delay)
if a.node:
    if a.node.exists():
        run('real-node', a.node.resolve())
    else:
        rows.append({'name': 'real-node', 'status': 'skip', 'reason': 'requested image absent'})
        (w / 'results.json').write_text(json.dumps(rows, indent=2) + '\n')
print('CFI job checks:', len(rows))
