#!/usr/bin/env python3
"""Local symbol discovery and startup breakpoints in a runnable sparse 5 GiB ELF."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import time

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('shared', root / 'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', required=True, type=Path, help='Fresh short socket and log directory')
p.add_argument('--storage', type=Path, help='Optional separate directory for large sparse fixture')
a = p.parse_args()
os.umask(0o022)
os.chdir(root)
w = a.work.resolve()
w.mkdir(mode=0o755, parents=True)
storage = a.storage.resolve() if a.storage else w / 'fixture'
storage.mkdir(mode=0o755, parents=True)
source = storage / 'fixture.c'
source.write_text('''#include <unistd.h>
volatile unsigned reached;
__attribute__((noinline)) void large_symbol_hit(void) { ++reached; }
int main(void) { for (;;) { large_symbol_hit(); usleep(10000); } }
''')
assembly = storage / 'aliases.s'
with assembly.open('w') as out:
    out.write('.text\n.globl alias_target\nalias_target: ret\n')
    for i in range(50000):
        out.write(f'.globl owned_symbol_{i:05d}_padding\n.set owned_symbol_{i:05d}_padding, alias_target\n')
    out.write('.section .note.GNU-stack,"",@progbits\n')
small = storage / 'small'
subprocess.run(['cc', '-g', '-O0', '-fno-pie', '-no-pie', '-Wl,--build-id=sha1', str(source), str(assembly),
                '-o', str(small)], check=True, timeout=60)
known = {}
for line in subprocess.check_output(['nm', '-P', '--defined-only', str(small)], text=True).splitlines():
    parts = line.split()
    if parts[0] in ('large_symbol_hit', 'reached', 'owned_symbol_49999_padding'):
        known[parts[0]] = '0x' + parts[2]
assert len(known) == 3
image = storage / 'large'
data = small.read_bytes()
assert data[:6] == b'\x7fELF\x02\x01'
shoff, = struct.unpack_from('<Q', data, 40)
entsize, count = struct.unpack_from('<HH', data, 58)
headers = bytearray(data[shoff:shoff + count * entsize])
at = 5 * 1024 ** 3
with image.open('wb') as out:
    out.write(data)
    for i in range(1, count):
        start = i * entsize
        kind, flags = struct.unpack_from('<IQ', headers, start + 4)
        offset, size = struct.unpack_from('<QQ', headers, start + 24)
        if flags & 2 or kind == 8 or not size:
            continue
        at = (at + 15) & ~15
        out.seek(at)
        out.write(data[offset:offset + size])
        struct.pack_into('<Q', headers, start + 24, at)
        at += size
    at = (at + 7) & ~7
    out.seek(at)
    out.write(headers)
    out.seek(40)
    out.write(struct.pack('<Q', at))
image.chmod(0o755)
binary = Path(os.environ.get('XODB_BIN', 'zig-out/bin/xodb')).resolve()
rows = []


def action(client, name):
    for _ in range(30):
        reply = client.raw(name, generation=client.session()['generation'])
        if reply.get('result', {}).get('isError') and reply['result']['content'][0]['text'] == 'StaleSnapshot':
            continue
        assert 'error' not in reply and not reply['result']['isError'], reply
        return reply['result']['structuredContent']
    raise AssertionError('generation never settled')


for name in ('lookup', 'startup', 'interrupt'):
    part = w / name
    part.mkdir(mode=0o755)
    server = shared.Server(root, part, binary, image, 'control',
        options=('--break', 'large_symbol_hit') if name != 'lookup' else (), fixture_args=())
    report = {'name': name, 'status': 'running', 'calls_ms': []}
    try:
        owner = shared.Client(server, 'owner')
        observer = shared.Client(server, 'observer')
        initial = shared.eventually(owner.session, lambda s: s['state'] == 'stopped', 'initial')
        server.remember_target(initial)
        owner.claim(ttl_ms=60000)
        if name == 'lookup':
            regs = observer.tool('get_registers', tid=initial['pid'])
            deadline = time.monotonic() + 30
            while True:
                start = time.monotonic()
                reply = observer.call('tools/call', {'name': 'find_symbol', 'arguments': {'name': 'owned_symbol_49999_padding'}})
                report['calls_ms'].append((time.monotonic() - start) * 1000)
                if not reply['result']['isError']:
                    symbol = reply['result']['structuredContent']
                    break
                assert reply['result']['content'][0]['text'] == 'SymbolDiscoveryPending', reply
                assert time.monotonic() < deadline
                assert owner.session()['generation'] == initial['generation']
                time.sleep(.002)
            assert int(symbol['address'], 16) == int(known['owned_symbol_49999_padding'], 16), symbol
            assert observer.tool('get_registers', tid=initial['pid']) == regs
        else:
            def settled(s):
                return s['state'] == 'stopped' and not s['continue_pending'] and not s['symbol_discovery_pending']
            action(owner, 'continue')
            if name == 'interrupt':
                action(owner, 'interrupt')
                stopped = shared.eventually(owner.session, settled, 'interrupt cancels queued run', timeout=30)
                if not any(t['reason'] == 'breakpoint' for t in stopped['threads']):
                    action(owner, 'continue')
            stopped = shared.eventually(owner.session, lambda s: settled(s) and
                any(t['reason'] == 'breakpoint' for t in s['threads']), 'first invocation', timeout=30)
            regs = observer.tool('get_registers', tid=stopped['pid'])
            assert int(regs['registers']['rip'], 16) == int(known['large_symbol_hit'], 16)
            assert observer.tool('read_memory', address=known['reached'], length=4)['hex'] == '00000000'
            before = observer.tool('get_breakpoints')['breakpoints']
            action(owner, 'restart')
            server.remember_target(owner.session())
            action(owner, 'continue')
            stopped = shared.eventually(owner.session, lambda s: settled(s) and
                any(t['reason'] == 'breakpoint' for t in s['threads']), 'restart first invocation', timeout=30)
            after = observer.tool('get_breakpoints')['breakpoints']
            assert [p['id'] for p in before if not p['internal']] == [p['id'] for p in after if not p['internal']]
            assert observer.tool('read_memory', address=known['reached'], length=4)['hex'] == '00000000'
        assert max(report['calls_ms'], default=0) < 500, report
        report['status'] = 'pass'
        server.stop_and_check()
    finally:
        server.close()
        rows.append(report)
        (w / 'results.json').write_text(json.dumps({'file_bytes': image.stat().st_size, 'checks': rows}, indent=2) + '\n')
    print(name, 'pass', flush=True)
print('Local large-symbol cases passed:', len(rows))
