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


# Old persistent ranges can contain gigabytes. Use sparse owned files so this
# regression proves extent reclamation without allocating gigabytes of RAM/disk.
legacy = base / 'xodb-debug-v1'
legacy.mkdir(mode=0o700)
for slot in range(2):
    for suffix in ('lease', 'ranges', 'names'):
        file = legacy / f'{slot}.{suffix}'
        file.write_bytes(b'owned')
        file.chmod(0o600)
    with (legacy / f'{slot}.ranges').open('r+b') as file: file.truncate(3400000000)
lease = (legacy / '0.lease').open('r+b')
fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
directory(0)
assert (legacy / '0.ranges').stat().st_size == 3400000000
assert (legacy / '1.ranges').stat().st_size == 0
assert (legacy / '0.names').read_bytes() == b'owned'
lease.close()
range_file = (legacy / '0.ranges').open('r+b')
fcntl.flock(range_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
directory(0)
assert (legacy / '0.ranges').stat().st_size == 3400000000
range_file.close()
directory(0)
assert (legacy / '0.ranges').stat().st_size == 0
victim = w / 'old-range-victim'
victim.write_bytes(b'keep'); victim.chmod(0o600)
path = legacy / '0.ranges'
path.unlink(); path.symlink_to(victim)
directory(0); assert victim.read_bytes() == b'keep'
path.unlink(); os.link(victim, path)
directory(0); assert victim.read_bytes() == b'keep'
path.unlink(); os.mkfifo(path, 0o600)
directory(0); assert path.is_fifo()
path.unlink(); path.write_bytes(b'keep'); path.chmod(0o644)
directory(0); assert path.read_bytes() == b'keep'
path.chmod(0o600); legacy.chmod(0o755)
directory(0); assert path.read_bytes() == b'keep'
legacy.chmod(0o700)
old_lease = legacy / '0.lease'
old_lease.unlink(); old_lease.symlink_to(victim)
directory(0); assert path.read_bytes() == b'keep' and victim.read_bytes() == b'keep'
old_lease.unlink()
directory(0); assert path.read_bytes() == b'keep' and not old_lease.exists()
old_lease.write_bytes(b'owned'); old_lease.chmod(0o600)
directory(0); assert path.stat().st_size == 0
legacy.rename(base / 'old-owned')
legacy.symlink_to(base / 'old-owned', target_is_directory=True)
(base / 'old-owned/0.ranges').write_bytes(b'keep')
directory(0); assert (base / 'old-owned/0.ranges').read_bytes() == b'keep'
print('legacy ranges: lease-safe reclamation, active clients and unsafe entries passed')
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
