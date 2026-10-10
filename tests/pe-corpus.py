#!/usr/bin/env python3
"""Periodic corpus check: the PE reader and unwind validator over the PE files
of the installed Wine. Only counts are printed and kept; the files are found
at run time next to the given Wine executable and are never named."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--wine', default='wine')
p.add_argument('--corpus', type=Path, action='append', help='directory of PE files; default: found beside --wine')
p.add_argument('--max-refused-ppm', type=int, default=100, help='unwind records refused, per million functions')
p.add_argument('--wrong-result', action='store_true', help='planted: demand zero refusals with no reason allowed')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
w = a.work.resolve()
w.mkdir(parents=True)
start = time.monotonic()
directories = a.corpus or []
if not directories:
    wine = shutil.which(a.wine)
    assert wine, 'Wine executable not found'
    prefix = Path(wine).resolve().parent.parent
    directories = sorted({d.resolve() for d in (prefix / lib / tail for lib in ('lib', 'lib64', 'lib/x86_64-linux-gnu')
                                                for tail in ('wine/x86_64-windows', 'wine')) if (d / 'ntdll.dll').is_file()})
assert directories, 'no PE corpus found beside the Wine executable; pass --corpus'
files = []
for directory in directories:
    for path in sorted(directory.iterdir()):
        if path.is_file():
            with path.open('rb') as f:
                if f.read(2) == b'MZ':
                    files.append(str(path))
assert len(files) >= 50, 'corpus too small to mean anything: %d PE files' % len(files)
tool = w / 'corpus'
subprocess.run(['cc', '-std=c11', '-O2', '-g', '-DNDEBUG', '-Wall', '-Wextra', '-Werror', '-Wswitch-enum',
                'tests/pe-corpus.c', 'src/binary/pe.c', 'src/debug/pe_unwind.c', '-o', str(tool)], check=True, timeout=60)
(w / 'files.rsp').write_text('\n'.join(files) + '\n')
out = subprocess.run([str(tool), '@' + str(w / 'files.rsp')], capture_output=True, text=True, timeout=300)
assert out.returncode == 0, out.stderr[-2000:]
(w / 'files.rsp').unlink()
counts = json.loads(out.stdout)
# 32-bit images are another machine, not a refusal of this reader.
refused_images = sum(n for reason, n in counts['load_refused'].items() if reason != 'unsupported')
refused = sum(counts['unwind_refused'].values())
counts.update(status='pass', refused_images=refused_images, refused_records=refused,
              refused_ppm=round(refused * 1e6 / max(counts['functions'], 1), 1), seconds=round(time.monotonic() - start, 3))
(w / 'results.json').write_text(json.dumps(counts, indent=2) + '\n')
print(json.dumps(counts))
assert counts['loaded'] >= 50 and counts['functions'] >= 10000, counts
assert refused_images * 100 <= counts['files'], counts
assert refused * 1000000 <= a.max_refused_ppm * counts['functions'], counts
# Every refusal has a reason this decoder states: a machine frame (interrupt
# and dispatcher stubs), a version or opcode it does not interpret, or a
# record that breaks the format's own ordering rules.
allowed = set() if a.wrong_result else {'machine_frame', 'malformed', 'unsupported_version', 'unsupported_opcode', 'unsupported_chain'}
assert set(counts['unwind_refused']) <= allowed, counts
