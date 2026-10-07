#!/usr/bin/env python3
"""Exercise the C agent wire and owned-target cleanup on broken streams."""
import os
import select
import struct
import subprocess
import sys
import time

# Version 2 snapshots carry the seven-byte ABI tuple before pid/state.
WIRE_VERSION = 2

agent = sys.argv[1] if len(sys.argv) > 1 else './zig-out/bin/xodb-agent'

class Agent:
    def __init__(self):
        self.p = subprocess.Popen([agent, '--stdio'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.sequence = 0
    def exact(self, n):
        result = b''
        deadline = time.monotonic() + 5
        while len(result) < n:
            assert select.select([self.p.stdout], [], [], max(0, deadline-time.monotonic()))[0], 'agent timeout'
            part = os.read(self.p.stdout.fileno(), n-len(result))
            assert part, ('unexpected EOF', self.p.poll())
            result += part
        return result
    def call(self, op, target=0, generation=0, args=(0, 0, 0), data=b''):
        self.sequence += 1
        body = struct.pack('>4Q', generation, *args) + data
        self.p.stdin.write(struct.pack('>4sHHQ4I', b'XRT1', WIRE_VERSION, op, self.sequence, target, 0, len(body), 0) + body)
        self.p.stdin.flush()
        magic, version, returned, request, handle, status, size, flags = struct.unpack('>4sHHQ4I', self.exact(32))
        assert (magic, version, returned, request, handle, flags) == (b'XRT1', WIRE_VERSION, op, self.sequence, target, 1)
        assert size <= 1024*1024
        reply = self.exact(size)
        value, extra = struct.unpack_from('>QI', reply)
        at = 12 + extra
        snapshot = reply[at]
        result = dict(status=status, value=value, extra=reply[12:at])
        if snapshot:
            at += 6  # present, shared_vm, family_root
            machine, elf_class, little, bits, linux_abi, isa_mode = struct.unpack_from('>H5B', reply, at)
            assert elf_class in (1, 2) and little in (0, 1) and bits in (32, 64)
            pid, state = struct.unpack_from('>iI', reply, at+7)
            generation = struct.unpack_from('>Q', reply, at+20)[0]
            result.update(machine=machine, pid=pid, state=state, generation=generation)
        return result

for mode in ('eof', 'truncated', 'oversized', 'sequence'):
    a = Agent()
    try:
        hello = a.call(1)
        assert hello['status'] == 0 and hello['value'] in (4, 62, 183), hello
        assert len(hello['extra']) == 16
        created = a.call(2)
        handle = created['value']
        launched = a.call(5, handle, created['generation'], (2, 0, 0), b'/bin/sleep\0' + b'30\0')
        assert launched['status'] == 0 and launched['state'] == 2, launched
        pid = launched['pid']
        stale = a.call(8, handle, launched['generation']-1)
        assert stale['status'] != 0 and stale['state'] == 2, stale
        running = a.call(8, handle, launched['generation'])
        assert running['status'] == 0 and running['state'] == 1, running
        if mode == 'truncated':
            a.p.stdin.write(b'XRT1\x00')
        elif mode == 'oversized':
            a.p.stdin.write(struct.pack('>4sHHQ4I', b'XRT1', WIRE_VERSION, 4, a.sequence+1, handle, 0, 1024*1024+1, 0))
        elif mode == 'sequence':
            a.p.stdin.write(struct.pack('>4sHHQ4I', b'XRT1', WIRE_VERSION, 4, a.sequence, handle, 0, 32, 0) + bytes(32))
        a.p.stdin.close()
        assert a.p.wait(timeout=10) == (0 if mode == 'eof' else 1), mode
        assert not os.path.exists(f'/proc/{pid}'), (mode, pid)
        print('C agent:', mode, 'stream cleanup passed', flush=True)
    finally:
        if a.p.poll() is None: a.p.kill(); a.p.wait()
