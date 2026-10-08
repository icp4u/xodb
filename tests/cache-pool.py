#!/usr/bin/env python3
"""Check bounded persistent cache ownership and crash recovery."""
import argparse
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


directory(0)
assert (base / 'xodb-debug-v1').stat().st_mode & 0o777 == 0o700
(base / 'xodb-debug-v1').chmod(0o755)
directory(2)
(base / 'xodb-debug-v1').chmod(0o700)
base.chmod(0o775)
directory(0)
base.chmod(0o777)
directory(0)
base.chmod(0o755)
env['XDG_CACHE_HOME'] = 'relative-cache'
directory(2)
env.pop('XDG_CACHE_HOME')
directory(0)
assert (home / '.cache/xodb-debug-v1').stat().st_mode & 0o777 == 0o700
alias = w / 'alias'
alias.symlink_to(base, target_is_directory=True)
env['XDG_CACHE_HOME'] = str(alias)
directory(2)
print('cache directories: XDG/HOME, private permissions and path refusals passed')
