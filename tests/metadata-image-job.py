#!/usr/bin/env python3
"""Live stopped-image verification with bounded worker and owner-thread slices."""
import argparse
import json
import fcntl
import re
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--library', type=Path, required=True)
p.add_argument('--agent', type=Path, required=True)
p.add_argument('--fixtures', type=Path, required=True, help='javascript-image.py output directory')
p.add_argument('--sanitize', action='store_true')
p.add_argument('--image', type=Path, help='Optional debug Node image')
a = p.parse_args()
os.umask(0o022)
root = Path(__file__).resolve().parents[1]
os.chdir(root)
w = a.work.resolve()
w.mkdir(parents=True, mode=0o755, exist_ok=True)
exe = w / 'job'
flags = ['-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
subprocess.run(['clang' if a.sanitize else 'cc', '-std=c11', '-g', *flags,
    '-Wall', '-Wextra', '-Werror', 'tests/metadata-image-job.c', 'src/debug/metadata_job.c', 'src/debug/cfi_image.c',
    'src/language/javascript_image.c', 'src/language/javascript.c', 'src/language/javascript_ranged.c',
    'src/binary/symbol_query.c', 'src/binary/placement.c', 'src/binary/object_cache.c', 'src/binary/cache_pool.c', 'src/debug/dwarf_index.c', 'src/debug/dwarf_names.c',
    str(a.library.resolve()), '-latomic', '-pthread', '-lm', '-lelf', '-o', str(exe)], check=True, timeout=60)
rows = []
cache_home = w / 'cache-home'
cache_home.mkdir(mode=0o700)


def run(name, path, remote=False, cache='-', delay=0, mask='0', mode='plain', cache_root=None, no_home=False):
    env = dict(os.environ, XODB_METADATA_AGENT=str(a.agent.resolve()), XODB_METADATA_DELAY=str(delay), XDG_CACHE_HOME=str(cache_home))
    if cache_root is not None:
        env['XDG_CACHE_HOME'] = str(cache_root)
    if no_home:
        env.pop('HOME', None)
        env.pop('XDG_CACHE_HOME', None)
    proxy = root / 'tests/fixtures/metadata-agent-proxy.py'
    command = [str(exe), str(path), str(proxy) if remote else '-', str(cache), mask, mode]
    r = subprocess.run(command, env=env, capture_output=True, text=True, timeout=930)
    (w / (name + '.log')).write_text(r.stdout + r.stderr)
    assert r.returncode == 0, (name, r.returncode, r.stdout, r.stderr)
    rows.append({'name': name, 'status': 'pass', 'stdout': r.stdout, 'stderr': r.stderr})
    return r.stdout


for image in ('exec', 'pie'):
    fixture = a.fixtures.resolve() / image
    for remote in (False, True):
        name = image + ('-agent' if remote else '-local')
        run(name, fixture, remote)
        run(name + '-restart', fixture, remote, mode='restart')
        cache = w / (name + '.cache')
        run(name + '-cold', fixture, remote, cache)
        run(name + '-warm', fixture, remote, cache)
        run(name + '-managed-cold', fixture, remote, '@')
        run(name + '-managed-warm', fixture, remote, '@')
run('slow-50ms', a.fixtures.resolve() / 'pie', True, w / 'slow.cache', .05)
run('slow-100ms', a.fixtures.resolve() / 'pie', True, w / 'slow2.cache', .1)
run('warm-100ms', a.fixtures.resolve() / 'pie', True, w / 'slow2.cache', .1)
sparse_source = a.fixtures.resolve() / 'sparse-large'
if sparse_source.exists():
    sparse = w / 'sparse-large'
    subprocess.run(['cp', '--reflink=auto', '--sparse=always', str(sparse_source), str(sparse)], check=True, timeout=30)
    sparse.chmod(0o755)
    run('sparse-managed-local', sparse, cache='@')
    run('sparse-managed-agent', sparse, True, cache='@')
fixture = a.fixtures.resolve() / 'pie'
run('managed-no-home', fixture, cache='@', no_home=True)
cache_home.chmod(0o775)
run('managed-group-cache', fixture, cache='@')
cache_home.chmod(0o700)
busy = w / 'busy'
private = busy / 'xodb-debug-v1'
private.mkdir(mode=0o700, parents=True)
leases = []
try:
    for slot in range(2):
        fd = os.open(private / (str(slot) + '.lease'), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        leases.append(fd)
    run('managed-busy-fallback', fixture, cache='@', cache_root=busy)
finally:
    for fd in leases:
        os.close(fd)
recovery = w / 'recovery'
recovery.mkdir(mode=0o700)
run('index-recovery-cold', fixture, cache='@', cache_root=recovery)
indexes = [p for p in (recovery / 'xodb-debug-v1').glob('*.names') if p.stat().st_size]
assert len(indexes) == 1, indexes
index = indexes[0]
hash_ = 5381
for char in b'kRootRegisterBias':
    hash_ = (hash_ * 33 + char) & 0xffffffff
# Preserve the header so this reaches query-time checksum validation.
with index.open('r+b') as out:
    out.seek(4096 + (hash_ % 65536) * 16)
    byte = out.read(1)
    out.seek(-1, 1)
    out.write(bytes([byte[0] ^ 1]))
result = run('index-recovery-query', fixture, cache='@', cache_root=recovery)
assert int(re.search(r'index_units=(\d+)', result)[1]) > 0, result
# Wide corruption reproduces the persistent-cache failure, and must recover too.
with index.open('r+b') as out:
    for offset in range(4096, index.stat().st_size, 4096):
        out.seek(offset)
        byte = out.read(1)
        out.seek(offset)
        out.write(bytes([byte[0] ^ 1]))
run('index-recovery-sweep', fixture, cache='@', cache_root=recovery)
if a.image:
    run('real-image', a.image.resolve(), mask='fc1cfe')
    run('real-managed-cold', a.image.resolve(), cache='@', mask='fc1cfe')
    run('real-managed-warm', a.image.resolve(), cache='@', mask='fc1cfe')
(w / 'results.json').write_text(json.dumps({'status': 'pass', 'checks': rows}, indent=2) + '\n')
print('Live image metadata job checks passed:', len(rows))
