#!/usr/bin/env python3
"""Fast cooperative remote image range/cache/cancel and old-cap compatibility.

An ordinary owned C image with a debug payload and a large inert tail exercises
the main-runtime preparation path; it is deliberately not a GDScript engine.
The real engine's language/value oracles remain in gdscript-stack/values.
"""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import time
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--agent', type=Path, required=True)
p.add_argument('--old-agent', type=Path, help='Also verify the actual previous agent file-open refusal')
p.add_argument('--wrong-result', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root); os.umask(0o022)
w = a.work.resolve(); w.mkdir(parents=True, mode=0o755)
cache = w/'cache'; cache.mkdir(mode=0o700)
os.environ.update(XDG_CACHE_HOME=str(cache), XODB_METADATA_AGENT=str(a.agent.resolve()))
proxy = root/'tests/fixtures/metadata-agent-proxy.py'
mib = 1 << 20
image = w/'image'
(w/'main.c').write_text('''
#include <stdio.h>
#include <unistd.h>
volatile unsigned marker_value = 0x1234abcd;
int main(void) { char byte; puts("ready"); fflush(stdout); return read(0, &byte, 1) < 0; }
''')
subprocess.run(['cc', '-g', '-O0', '-Wl,--build-id', str(w/'main.c'), '-o', str(image)], check=True, timeout=30)
(w/'payload').write_bytes(bytes(2*mib))
subprocess.run(['objcopy', '--add-section', f'.debug_xodb_payload={w / "payload"}', str(image)], check=True, timeout=30)
os.truncate(image, 300*mib)
target = subprocess.Popen([str(image)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
client = None
result = {'status': 'running', 'runs': [], 'load': os.getloadavg(), 'cpus': os.cpu_count()}


def usage(c):
    fields = Path(f'/proc/{c.p.pid}/stat').read_text().rsplit(')', 1)[1].split()
    return {'cpu_seconds': (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK'),
            'rss_bytes': int(Path(f'/proc/{c.p.pid}/statm').read_text().split()[1]) * os.sysconf('SC_PAGESIZE')}


def open_client(legacy=False, slow=False):
    os.environ['XODB_METADATA_AGENT'] = str((a.old_agent if legacy and a.old_agent else a.agent).resolve())
    os.environ['XODB_METADATA_LEGACY_IMAGES'] = '1' if legacy else ''
    os.environ['XODB_METADATA_DELAY'] = '.002' if slow else '0'
    c = Client('control', None, options=['--runtime-agent', str(proxy), '--attach', str(target.pid),
                                       '--image-limit', '3G', '--image-total-limit', '6G'], reply_seconds=30)
    c.stopped()
    return c


def jobs(c):
    return [j for j in c.inspect('get_debug_metadata')['jobs'] if j['kind'] == 'image']


def query(c):
    return c.tool('get_language_stack', tid=target.pid, language='gdscript')['result']


def finish(c):
    deadline = time.monotonic() + 30
    while True:
        reply = query(c)
        why = reply['content'][0]['text'] if reply.get('isError') else None
        if why != 'DebugMetadataPending':
            assert why == 'GDScriptRuntimeUnavailable', reply
            break
        assert time.monotonic() < deadline, (reply, jobs(c))
        time.sleep(.001)
    ready = jobs(c)
    assert len(ready) == 1 and ready[0]['state'] == 'ready', ready
    assert ready[0]['image_bytes'] == ready[0]['image_total'] < 4*mib, ready
    # Full image semantics, not just a successful metadata schema.
    found = c.inspect('find_symbol', name='marker_value')
    memory = c.inspect('read_memory', address=found['address'], length=4)
    expected = struct.pack('<I', 0x1234abcc if a.wrong_result else 0x1234abcd).hex()
    assert memory['hex'] == expected, memory
    main = c.inspect('find_symbol', name='main')
    source = c.inspect('get_source_location', address=main['address'])['source']
    assert source['path'].endswith('main.c'), source
    return ready[0]


def close(c):
    c.p.stdin.close()
    stderr = c.p.stderr.read()
    assert c.p.wait(timeout=30) == 0, stderr


try:
    assert target.stdout.readline() == b'ready\n'
    for label in ('cold', 'warm'):
        client = open_client()
        before = usage(client); started = time.monotonic()
        job = finish(client)
        result['runs'].append({'name': label, 'job': job, 'seconds': time.monotonic() - started,
                               'before': before, 'after': usage(client)})
        close(client); client = None
    cold, warm = [row['job'] for row in result['runs']]
    assert cold['source_bytes'] > 2*mib and warm['source_bytes'] < 65536, (cold, warm)
    # Object preparation retains some header bytes in memory rather than
    # counting them as a disk-cache read; the entire bulk payload is cached.
    assert warm['cached_bytes'] >= 2*mib, warm
    # Pending cancellation withdraws publication; it cannot auto-restart on polling.
    client = open_client(slow=True)
    reply = query(client)
    pending = jobs(client)
    assert reply.get('isError') and reply['content'][0]['text'] == 'DebugMetadataPending', reply
    assert len(pending) == 1 and pending[0]['state'] not in ('ready', 'failed', 'cancelled'), pending
    cancelled = client.inspect('cancel_debug_metadata', id=pending[0]['id'])['jobs']
    assert any(j['id'] == pending[0]['id'] and j['state'] == 'cancelled' for j in cancelled), cancelled
    assert query(client)['content'][0]['text'] == 'DebugMetadataCancelled'
    close(client); client = None
    result['cancel'] = 'pass'
    # A known older capability is a specific refusal, not a generic budget.
    client = open_client(legacy=True)
    reply = query(client)
    assert reply.get('isError') and reply['content'][0]['text'] == 'GDScriptImageBudgetExceeded', reply
    assert 'agent refused: older agent cap (256 MiB)' in reply['content'][1]['text'], reply
    assert jobs(client) == [], jobs(client)
    if a.old_agent:
        deadline = time.monotonic() + 30
        while True:
            symbol = client.tool('find_symbol', name='main')['result']
            if not symbol.get('isError'): break
            assert symbol['content'][0]['text'] == 'SymbolDiscoveryPending' and time.monotonic() < deadline, symbol
            time.sleep(.001)
        refused = client.tool('get_source_location', address=symbol['structuredContent']['address'])['result']
        assert refused.get('isError') and refused['content'][0]['text'] == 'BinarySnapshotLimit', refused
        assert 'agent refused: older agent cap (256 MiB)' in refused['content'][1]['text'], refused
    close(client); client = None
    result['legacy'] = 'pass'
    # No large allocation/read for an extent just beyond the shared new cap.
    target.kill(); target.wait(timeout=10)
    os.truncate(image, (2 << 30) + 1)
    target = subprocess.Popen([str(image)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert target.stdout.readline() == b'ready\n'
    client = open_client()
    reply = query(client)
    assert reply.get('isError') and reply['content'][0]['text'] == 'GDScriptImageBudgetExceeded', reply
    assert 'remote image transfer is capped at 2048 MiB' in reply['content'][1]['text'], reply
    assert jobs(client) == [], jobs(client)
    close(client); client = None
    result['cap'] = 'pass'
    result['status'] = 'pass'
finally:
    if client and client.p.poll() is None:
        client.p.stdin.close()
        try: client.p.wait(timeout=30)
        except subprocess.TimeoutExpired: client.p.kill(); client.p.wait()
    if target.poll() is None: target.kill()
    target.wait(timeout=10)
    image.unlink(missing_ok=True)
    if result['status'] != 'pass': result['status'] = 'failed'
    (w/'results.json').write_text(json.dumps(result, indent=2) + '\n')
print('Image transfer: ranges, cold/warm cache, exact value/source, cancellation, legacy and 2 GiB cap pass')
