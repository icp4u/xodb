"""Alter only an owned synthetic image after mapping it, then wait to attach."""
import ctypes
import json
import os
from pathlib import Path
import sys

path, mode = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                      ctypes.c_int, ctypes.c_int, ctypes.c_long]
if mode == 'many':
    # Every file in the directory, executable: distinct inodes, one mapping each.
    address = 0
    for name in sorted(os.listdir(path)):
        fd = os.open(os.path.join(path, name), os.O_RDONLY)
        address = libc.mmap(None, os.fstat(fd).st_size, 5, 2, fd, 0)
        assert address != ctypes.c_void_p(-1).value, ctypes.get_errno()
        os.close(fd)
elif mode in ('data', 'unknown', 'pe', 'unreadable'):
    fd = os.open(path, os.O_RDONLY)
    address = libc.mmap(None, os.fstat(fd).st_size, 1 if mode in ('data', 'unreadable') else 5, 2, fd, 0)
    assert address != ctypes.c_void_p(-1).value, ctypes.get_errno()
    os.close(fd)
    if mode == 'unreadable':
        # A data mapping whose file can no longer be opened by anyone unprivileged.
        os.chmod(path, 0)
        assert not os.access(path, os.R_OK), 'run this case unprivileged'
else:
    image = ctypes.CDLL(path)
    address = ctypes.cast(image.definer_fixture, ctypes.c_void_p).value
    if mode == 'deleted':
        os.unlink(path)
    elif mode != 'elf':
        magic = {'mz': b'MZ', 'other': b'XXXX', 'macho': bytes.fromhex('cffaedfe')}[mode]
        with open(path, 'r+b') as f:
            f.write(magic)
        assert Path(path).read_bytes()[:len(magic)] == magic
print(json.dumps(dict(address=address, mode=mode)), flush=True)

def definer_checkpoint():
    held = 42
    input()
    return held

definer_checkpoint()
