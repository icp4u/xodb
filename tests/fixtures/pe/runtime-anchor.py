"""Map an owned PE anchor before or after the actual native Python runtime."""
import ctypes
import json
import os
from pathlib import Path
import sys

path, order, evidence = sys.argv[1:]
native = ctypes.addressof(ctypes.c_char.in_dll(ctypes.pythonapi, '_PyRuntime'))
libc = ctypes.CDLL(None, use_errno=True)
libc.mmap.restype = ctypes.c_void_p
libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                      ctypes.c_int, ctypes.c_int, ctypes.c_long]
fd = os.open(path, os.O_RDONLY)
size = os.fstat(fd).st_size
base = 0x100000 if order == 'before' else ((native + (1 << 30)) & ~4095)
address = None
for i in range(64):
    want = base + i * (1 << 20)
    p = libc.mmap(want, size, 5, 2 | 0x100000, fd, 0)
    if p != ctypes.c_void_p(-1).value:
        assert p == want
        address = p
        break
assert address is not None, ctypes.get_errno()
assert (address < native) == (order == 'before')
os.close(fd)
Path(evidence).write_text(json.dumps(dict(native=native, pe=address, order=order)))

def pe_anchor_checkpoint():
    os.getppid()

pe_anchor_checkpoint()
