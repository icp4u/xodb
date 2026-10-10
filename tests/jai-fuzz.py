#!/usr/bin/env python3
"""Periodic lane: build and run every owned Jai fuzz harness with fixed caps."""
import argparse
import json
import os
from pathlib import Path
import resource
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--clang', default='clang')
p.add_argument('--cases', type=int, default=2000)
a = p.parse_args()
if not 1 <= a.cases <= 100000:
    p.error('--cases must be between 1 and 100000')
os.umask(0o022)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
root = Path(__file__).resolve().parents[1]
w = a.work.resolve()
w.mkdir(mode=0o755, parents=True, exist_ok=False)
names = ('layout', 'reader', 'value', 'container', 'write', 'journal')
assert {p.name for p in (root/'tests').glob('jai-*-fuzz.c')} == {
    'jai-'+name+'-fuzz.c' for name in names}, 'update the periodic harness inventory'
sources = ['src/language/jai_'+name+'.c' for name in names]
results = []
try:
    for name in names:
        work = w/name
        corpus = work/'corpus'
        corpus.mkdir(parents=True, mode=0o755)
        for label, data in [('zero', bytes(512)), ('ones', b'\xff'*512),
                            ('ramp', bytes(range(256))*2), ('field', b'\x06\0health77')]:
            (corpus/label).write_bytes(data)
        binary = work/'fuzz'
        started = time.monotonic()
        with (work/'build.log').open('w') as log:
            subprocess.run([a.clang, '-std=c11', '-O1', '-g', '-DNDEBUG', '-D_GNU_SOURCE',
                            '-Wall', '-Wextra', '-Werror', '-fno-omit-frame-pointer',
                            '-fsanitize=fuzzer,address,undefined', 'tests/jai-'+name+'-fuzz.c',
                            *sources, '-o', str(binary)], cwd=root, stdout=log,
                           stderr=subprocess.STDOUT, timeout=90, check=True)
        compiled = time.monotonic()-started
        with (work/'run.log').open('w') as log:
            subprocess.run([str(binary), str(corpus), '-runs='+str(a.cases), '-max_len=512',
                            '-seed=1', '-timeout=10', '-rss_limit_mb=1024',
                            '-artifact_prefix='+str(work)+'/repro-'], cwd=root, stdout=log,
                           stderr=subprocess.STDOUT, timeout=180, check=True,
                           env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1:abort_on_error=1',
                                    UBSAN_OPTIONS='halt_on_error=1'))
        text = (work/'run.log').read_text()
        assert 'DONE' in text and 'Done ' in text, text[-1000:]
        results.append(dict(name=name, status='pass', cases=a.cases, compile_seconds=compiled,
                            run_seconds=time.monotonic()-started-compiled))
        print(name+': bounded ASan/UBSan fuzz PASS', flush=True)
finally:
    (w/'results.json').write_text(json.dumps(dict(status='pass' if len(results)==len(names) else 'failed',
                                                harnesses=results), indent=2)+'\n')
