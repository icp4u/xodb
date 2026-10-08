#!/usr/bin/env python3
"""Check bounded persistent cache ownership and crash recovery."""
import argparse
import fcntl
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--sanitize', action='store_true')
a = p.parse_args()
os.umask(0o022)
root = Path(__file__).resolve().parents[1]
os.chdir(root)
w = a.work.resolve()
w.mkdir(parents=True, mode=0o755)
cache = w / 'cache'
cache.mkdir(mode=0o700)
(cache / 'victim').write_text('v')
(cache / 'victim').chmod(0o600)
flags = ['-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
exe = w / 'pool'
subprocess.run(['clang' if a.sanitize else 'cc', '-std=c11', '-g', *flags,
    '-Wall', '-Wextra', '-Werror', 'tests/cache-pool.c', 'src/binary/cache_pool.c',
    'src/binary/object_cache.c', '-o', str(exe)], check=True, timeout=60)
r = subprocess.run([str(exe), str(cache)], capture_output=True, text=True, timeout=30)
(w / 'results.log').write_text(r.stdout + r.stderr)
assert r.returncode == 0, (r.returncode, r.stdout, r.stderr)
print(r.stdout, end='')
home = w / 'home'
home.mkdir()
base = w / 'xdg'
base.mkdir()
env = dict(os.environ, HOME=str(home), XDG_CACHE_HOME=str(base))


def directory(expected):
    r = subprocess.run([str(exe), '--directory'], env=env, capture_output=True, text=True, timeout=5)
    assert r.returncode == expected, (r.returncode, r.stderr)


# Use the production writers to create real, sparse version-one headers.
# No source data is read and only header blocks occupy disk space.
legacy = base / 'xodb-debug-v1'
legacy.mkdir(mode=0o700)
subprocess.run([str(exe), '--legacy', str(legacy)], check=True, timeout=30)
extent = 3400000000 + 512 + ((3400000000 + 16383) // 16384) * 16
headers = {}
for slot in range(2):
    headers[slot] = ((legacy / f'{slot}.lease').read_bytes(),
                     (legacy / f'{slot}.ranges').open('rb').read(512))
    assert (legacy / f'{slot}.ranges').stat().st_size == extent
    (legacy / f'{slot}.names').write_bytes(b'owned')


def range_file(path):
    with path.open('wb') as file:
        file.write(headers[0][1]); file.truncate(extent)
    path.chmod(0o600)


def fingerprint(path):
    with path.open('rb') as file:
        return path.stat().st_size, file.read(512)


def rechecksum(data):
    data = bytearray(data)
    crc = 0xffffffff
    for byte in data[:-4]:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0x82f63b78 if crc & 1 else 0)
    data[-4:] = (crc ^ 0xffffffff).to_bytes(4, 'little')
    return bytes(data)


lease = (legacy / '0.lease').open('r+b')
fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
directory(0)
assert (legacy / '0.ranges').stat().st_size == extent
assert (legacy / '1.ranges').stat().st_size == 0
assert (legacy / '0.names').read_bytes() == b'owned'
lease.close()
held_range = (legacy / '0.ranges').open('r+b')
fcntl.flock(held_range, fcntl.LOCK_EX | fcntl.LOCK_NB)
directory(0)
assert (legacy / '0.ranges').stat().st_size == extent
held_range.close()
directory(0)
assert (legacy / '0.ranges').stat().st_size == 0

# Valid owner/perms/names are insufficient: unknown and malformed headers must
# not authorize truncation. Rechecksum field mutations to isolate each guard.
cases = []
for suffix, valid in zip(('lease', 'ranges'), headers[0]):
    cases.extend([(suffix, b'', 'empty'), (suffix, b'owned', 'unrecognized'),
                  (suffix, valid[:80], 'truncated'),
                  (suffix, valid[:-1] + bytes([valid[-1] ^ 1]), 'checksum')])
    for offset, value, name in [(0, b'NOTCACHE', 'magic'), (8, (2).to_bytes(4, 'little'), 'version'),
                                 (72, (65).to_bytes(4, 'little'), 'build-id-length')]:
        changed = bytearray(valid); changed[offset:offset+len(value)] = value
        cases.append((suffix, rechecksum(changed), name))
for offset, name in [(16, 'identity'), (80, 'build-id'), (12, 'block-size'),
                     (144, 'data-offset'), (152, 'extent')]:
    changed = bytearray(headers[0][1]); changed[offset] ^= 1
    cases.append(('ranges', rechecksum(changed), name))
for suffix, content, name in cases:
    (legacy / '0.lease').write_bytes(headers[0][0])
    range_file(legacy / '0.ranges')
    changed = legacy / f'0.{suffix}'
    with changed.open('wb') as file:
        file.write(content)
        if suffix == 'ranges' and len(content) == 512: file.truncate(extent)
    before = [fingerprint(legacy / f'0.{kind}') for kind in ('lease', 'ranges')]
    directory(0)
    assert [fingerprint(legacy / f'0.{kind}') for kind in ('lease', 'ranges')] == before, (suffix, name)

(legacy / '0.lease').write_bytes(headers[0][0])
victim = w / 'old-range-victim'
range_file(victim)
expected = fingerprint(victim)
path = legacy / '0.ranges'
path.unlink(); path.symlink_to(victim)
directory(0); assert fingerprint(victim) == expected
path.unlink(); os.link(victim, path)
directory(0); assert fingerprint(victim) == expected
path.unlink(); os.mkfifo(path, 0o600)
directory(0); assert path.is_fifo()
path.unlink(); range_file(path); path.chmod(0o644)
directory(0); assert fingerprint(path) == expected
path.chmod(0o600); legacy.chmod(0o755)
directory(0); assert fingerprint(path) == expected
legacy.chmod(0o700)
old_lease = legacy / '0.lease'
old_lease.unlink(); old_lease.symlink_to(victim)
directory(0); assert fingerprint(path) == expected and fingerprint(victim) == expected
old_lease.unlink()
directory(0); assert fingerprint(path) == expected and not old_lease.exists()
old_lease.write_bytes(headers[0][0]); old_lease.chmod(0o600)
directory(0); assert path.stat().st_size == 0
legacy.rename(base / 'old-owned')
legacy.symlink_to(base / 'old-owned', target_is_directory=True)
range_file(base / 'old-owned/0.ranges')
directory(0); assert fingerprint(base / 'old-owned/0.ranges') == expected
print('legacy ranges: real headers, malformed-header refusal, lease-safe reclamation and unsafe entries passed')
directory(0)
assert (base / 'xodb-debug-v2').stat().st_mode & 0o777 == 0o700
(base / 'xodb-debug-v2').chmod(0o755)
directory(2)
(base / 'xodb-debug-v2').chmod(0o700)
base.chmod(0o775)
directory(0)
base.chmod(0o777)
directory(0)
base.chmod(0o755)
env['XDG_CACHE_HOME'] = 'relative-cache'
directory(2)
env.pop('XDG_CACHE_HOME')
directory(0)
assert (home / '.cache/xodb-debug-v2').stat().st_mode & 0o777 == 0o700
alias = w / 'alias'
alias.symlink_to(base, target_is_directory=True)
env['XDG_CACHE_HOME'] = str(alias)
directory(2)
print('cache directories: XDG/HOME, private permissions and path refusals passed')
