#!/usr/bin/env python3
"""Real proc-map identities plus simulated Btrfs stat device numbers.

Set XODB_IDENTITY_TEST_DIR to an existing writable Btrfs directory to exercise
the actual filesystem too. No mounts or privileges are required or changed.
"""
import ctypes
import mmap
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
run = Path(tempfile.mkdtemp(prefix='mapping-identity-', dir=root / '.work'))
flags = ['gcc', '-fPIC', '-O2', '-Wall', '-Wextra', '-Werror']
subprocess.run([*flags, '-shared', str(root / 'src/binary/mapped_file.c'), '-o', str(run / 'real.so')], check=True)
subprocess.run([*flags, '-Dfstat=xodb_test_stat', '-Dfstatfs=xodb_test_statfs', '-c', str(root / 'src/binary/mapped_file.c'), '-o', str(run / 'mapped.o')], check=True)
subprocess.run([*flags, '-shared', str(run / 'mapped.o'), str(root / 'tests/fixtures/identity-stat-shim.c'), '-o', str(run / 'simulated.so')], check=True)
directory = Path(os.environ.get('XODB_IDENTITY_TEST_DIR', run))
with tempfile.TemporaryDirectory(prefix='xodb-identity-', dir=directory) as fixture_dir:
    fixture = Path(fixture_dir) / 'mapped'
    fixture.write_bytes(b'x' * mmap.PAGESIZE)
    other = Path(fixture_dir) / 'other'
    other.write_bytes(fixture.read_bytes())
    alias = Path(fixture_dir) / 'alias'
    os.link(fixture, alias)
    with fixture.open('rb') as file, other.open('rb') as unrelated, alias.open('rb') as link:
        with mmap.mmap(file.fileno(), mmap.PAGESIZE, access=mmap.ACCESS_COPY) as mapped:
            address = ctypes.addressof(ctypes.c_char.from_buffer(mapped))
            for row in Path('/proc/self/maps').read_text().splitlines():
                fields = row.split()
                start, end = [int(x, 16) for x in fields[0].split('-')]
                if start <= address < end:
                    major, minor = [int(x, 16) for x in fields[3].split(':')]
                    inode = int(fields[4])
                    break
            else:
                raise AssertionError('fixture mapping missing')
            stat = os.fstat(file.fileno())
            print('maps device:', major, minor, 'stat device:', os.major(stat.st_dev), os.minor(stat.st_dev))
            for variant in ('real', 'simulated'):
                library = ctypes.CDLL(str(run / (variant + '.so')))
                match = library.xodb_mapped_file_matches
                match.argtypes = [ctypes.c_int, ctypes.c_int] + [ctypes.c_uint64] * 5 + [ctypes.c_int]
                match.restype = ctypes.c_int
                args = (os.getpid(), start, end, major, minor, inode)
                assert match(file.fileno(), *args, 0) == 1, variant
                assert match(unrelated.fileno(), *args, 0) == 0, variant
                assert match(file.fileno(), os.getpid(), start, end, major, minor + 1, inode, 0) == 0, variant
                assert match(file.fileno(), os.getpid(), start, end, major, minor, inode + 1, 0) == 0, variant
                if variant == 'simulated':
                    # Strict probe validation may never use the pathname fallback.
                    try:
                        pinned = os.open(f'/proc/self/map_files/{start:x}-{end:x}', os.O_RDONLY)
                    except PermissionError:
                        assert match(file.fileno(), *args, 1) == 0
                        # Equal inode/device alone must not admit another path.
                        assert match(link.fileno(), *args, 0) == 0
                    else:
                        os.close(pinned)
                        assert match(file.fileno(), *args, 1) == 1
                print('PASS', variant)
print('Artifacts:', run)
