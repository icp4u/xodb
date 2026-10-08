#!/usr/bin/env python3
"""Owned C metadata jobs: progress, cancellation, cache identity and RPC fairness."""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--library', type=Path, required=True)
p.add_argument('--agent', type=Path, required=True)
p.add_argument('--sanitize', action='store_true')
a = p.parse_args()
os.umask(0o022)
root = Path(__file__).resolve().parents[1]
os.chdir(root)
w = a.work.resolve()
w.mkdir(parents=True, mode=0o755, exist_ok=True)
exe = w / 'job'
flags = ['-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
subprocess.run(['clang' if a.sanitize else 'cc', '-std=c11', '-g', *flags,
                '-Wall', '-Wextra', '-Werror', 'tests/metadata-job.c',
                'src/debug/metadata_job.c', 'src/debug/cfi_image.c', 'src/language/javascript_image.c', 'src/language/javascript.c', 'src/binary/symbol_query.c', 'src/language/javascript_ranged.c',
                'src/binary/object_cache.c', 'src/binary/cache_pool.c', 'src/debug/dwarf_index.c', 'src/debug/dwarf_names.c', 'src/binary/placement.c', str(a.library.resolve()), '-latomic', '-pthread', '-lm',
                '-o', str(exe)], check=True, timeout=60)
# A real build ID permits persistent cache reuse, and many small CUs ensure
# cancellation and observer probes overlap the scanner, even on fast hosts.
abbrev = bytes([1, 0x11, 1, 0, 0, 2, 0x39, 1, 3, 8, 0, 0,
                3, 2, 1, 3, 8, 0, 0, 4, 0x0d, 0, 3, 8, 0x1c, 0x0b, 0, 0, 0])
body = b'\x01\x02v8\0\x02internal\0\x03JSArray\0\x04kLengthOffset\0\x18\0\0\0\0'
content = struct.pack('<HIB', 4, 0, 8) + body
unit = struct.pack('<I', len(content)) + content
payloads = [('.debug_info', 1, unit * 5000), ('.debug_abbrev', 1, abbrev),
            ('.note.gnu.build-id', 7, struct.pack('<III', 4, 20, 3) + b'GNU\0' + bytes([0x42]) * 20)]
names = b'\0.shstrtab\0'
indices = {}
for name, _, _ in payloads:
    indices[name] = len(names)
    names += name.encode() + b'\0'
sections = [(1, 3, names)] + [(indices[name], kind, data) for name, kind, data in payloads]
data = bytearray(64)
headers = [bytes(64)]
for name, kind, payload in sections:
    offset = len(data)
    data += payload
    headers.append(struct.pack('<IIQQQQIIQQ', name, kind, 0, 0, offset, len(payload), 0, 0, 1, 0))
table = len(data)
data += b''.join(headers)
data[:64] = struct.pack('<16sHHIQQQIHHHHHH', b'\x7fELF\x02\x01\x01' + bytes(9),
                       2, 62, 1, 0, 0, table, 0, 64, 0, 0, 64, len(headers), 1)
fixture = w / 'fixture.elf'
fixture.write_bytes(data)
proxy = root / 'tests/fixtures/metadata-agent-proxy.py'
rows = []

def run(name, remote=False, mode='plain', cache='-', delay=0, fault=''):
    env = dict(os.environ, XODB_METADATA_AGENT=str(a.agent.resolve()),
               XODB_METADATA_DELAY=str(delay), XODB_METADATA_FAULT=fault)
    source = fixture
    if mode == 'mutation':
        source = w / (name + '.elf')
        shutil.copy2(fixture, source)
    command = [str(exe), str(source), str(proxy) if remote else '-', mode, str(cache), '1']
    r = subprocess.run(command, env=env, capture_output=True, text=True, timeout=120)
    (w / (name + '.log')).write_text(r.stdout + r.stderr)
    assert r.returncode == 0, (name, r.returncode, r.stdout, r.stderr)
    rows.append({'name': name, 'status': 'pass', 'stdout': r.stdout, 'stderr': r.stderr})

for remote in (False, True):
    prefix = 'remote-' if remote else 'local-'
    run(prefix + 'plain', remote)
    run(prefix + 'cancel', remote, 'cancel')
    run(prefix + 'mutation', remote, 'mutation')
    cache = w / (prefix + 'ranges')
    run(prefix + 'cache-cold', remote, cache=cache)
    run(prefix + 'cache-warm', remote, cache=cache)
run('slow-50ms', True, delay=.05)
run('slow-100ms', True, delay=.1)
run('warm-100ms', True, cache=w / 'remote-ranges', delay=.1)
run('illegal-error-snapshot', True, mode='protocol', fault='snapshot')
(w / 'results.json').write_text(json.dumps({'status': 'pass', 'checks': rows}, indent=2) + '\n')
print('Metadata job checks passed:', len(rows))
