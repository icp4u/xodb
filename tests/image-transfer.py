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
from helpers import orphans

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--agent', type=Path, required=True)
p.add_argument('--old-agent', type=Path, help='Also verify the actual previous agent file-open refusal')
p.add_argument('--wrong-result', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root); os.umask(0o022)
orphans.adopt()
w = a.work.resolve(); w.mkdir(parents=True, mode=0o755)
cache = w/'cache'; cache.mkdir(mode=0o700)
os.environ.update(XDG_CACHE_HOME=str(cache), XODB_METADATA_AGENT=str(a.agent.resolve()))
proxy = root/'tests/fixtures/metadata-agent-proxy.py'
mib = 1 << 20
image = w/'image'
(w/'main.c').write_text('''
#include <stdio.h>
#include <unistd.h>
#include <signal.h>
#include <sys/prctl.h>
volatile unsigned marker_value = 0x1234abcd;
__attribute__((noinline)) void sharing_ready(void) { __asm__ volatile("" ::: "memory"); }
int main(int argc, char **argv) {
    (void)argv;
    if (argc > 1) {
        pid_t parent = getpid(), child = fork();
        if (child < 0) return 2;
        if (!child) {
            if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent) return 3;
        }
        sharing_ready();
        for (;;) pause();
    }
    char byte; puts("ready"); fflush(stdout); return read(0, &byte, 1) < 0;
}
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
    mapped = 0
    for row in Path(f'/proc/{c.p.pid}/maps').read_text().splitlines():
        if '/memfd:xodb-image-types ' not in row: continue
        columns = row.split(); first, last = (int(v, 16) for v in columns[0].split('-'))
        assert columns[1] == 'r--p', row
        mapped += last - first
    return {'cpu_seconds': (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK'),
            'rss_bytes': int(Path(f'/proc/{c.p.pid}/statm').read_text().split()[1]) * os.sysconf('SC_PAGESIZE'),
            'prepared_mapping_bytes': mapped}


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
    # The 2 MiB unrelated debug payload is not a layout demand. The old
    # all-sections worker fails this bound on the same fixture.
    assert ready[0]['image_bytes'] == ready[0]['image_total'] < 256*1024, ready
    # The snapshot maps the worker's immutable pages, not another full copy.
    assert usage(c)['prepared_mapping_bytes'] == 300*mib, usage(c)
    # Full image semantics, not just a successful metadata schema.
    found = c.inspect('find_symbol', name='marker_value')
    memory = c.inspect('read_memory', address=found['address'], length=4)
    expected = struct.pack('<I', 0x1234abcc if a.wrong_result else 0x1234abcd).hex()
    assert memory['hex'] == expected, memory
    main = c.inspect('find_symbol', name='main')
    # A types projection must not be returned as a complete source image.
    upgrade = c.tool('get_source_location', address=main['address'])['result']
    assert upgrade.get('isError') and upgrade['content'][0]['text'] == 'DebugMetadataPending', upgrade
    source = c.inspect('get_source_location', address=main['address'])['source']
    assert source['path'].endswith('main.c'), source
    assert usage(c)['prepared_mapping_bytes'] == 0, usage(c)
    held = c.inspect('list_modules', limit=1)['image_bytes']
    assert held['held'] <= 301*mib and held['peak'] <= 301*mib, held
    return ready[0]


def close(c):
    c.p.stdin.close()
    stderr = c.p.stderr.read()
    assert c.p.wait(timeout=30) == 0, stderr


def concurrent_coverage():
    """A retained types view in one owner cannot satisfy another's full view."""
    os.environ['XODB_METADATA_LEGACY_IMAGES'] = ''
    os.environ['XODB_METADATA_DELAY'] = '0'
    os.environ['XODB_METADATA_AGENT'] = str(a.agent.resolve())
    c = Client('control', str(image), args=['fork'], options=[
        '--runtime-agent', str(proxy), '--follow-forks', '--break', 'sharing_ready',
        '--image-limit', '3G', '--image-total-limit', '6G'], reply_seconds=30)
    try:
        c.continue_initial_stop()
        deadline = time.monotonic() + 30
        while True:
            tree = c.inspect('get_processes')['processes']
            stopped = {}
            for process in tree:
                ident = process['process_id']
                state = c.inspect('get_session', process_id=ident)
                if state['state'] != 'stopped' or state['continue_pending'] or state['symbol_discovery_pending']:
                    continue
                if any(t['reason'] == 'breakpoint' for t in state['threads']):
                    stopped[ident] = state
                else:
                    c.inspect('continue', process_id=ident, generation=state['generation'])
            if len(tree) == len(stopped) == 2: break
            assert time.monotonic() < deadline, (tree, stopped)
            time.sleep(.005)
        parent, child = sorted(stopped)
        before = usage(c)
        deadline = time.monotonic() + 30
        while True:
            reply = c.tool('get_language_stack', process_id=parent, tid=stopped[parent]['pid'], language='gdscript')['result']
            why = reply['content'][0]['text'] if reply.get('isError') else None
            if why != 'DebugMetadataPending': break
            assert time.monotonic() < deadline, reply
            time.sleep(.001)
        assert why == 'GDScriptRuntimeUnavailable', reply
        assert usage(c)['prepared_mapping_bytes'] == 300*mib, usage(c)
        types = jobs(c)
        assert len(types) == 1 and types[0]['state'] == 'ready' and types[0]['image_total'] < 256*1024, types
        main = c.inspect('find_symbol', process_id=child, name='main')
        source = c.inspect('get_source_location', process_id=child, address=main['address'])['source']
        assert source and source['path'].endswith('main.c'), source
        # Prove overlap: the parent's types mapping survives the child's source
        # lookup. Forcing all sharing keys to full aliases this mapping and
        # loses the child's line table, even though each owner alone works.
        assert usage(c)['prepared_mapping_bytes'] == 300*mib, usage(c)
        held = c.inspect('list_modules', process_id=child, limit=1)['image_bytes']
        assert 600*mib <= held['held'] <= 601*mib and held['peak'] <= 601*mib, held
        value = c.inspect('find_symbol', process_id=child, name='marker_value')
        memory = c.inspect('read_memory', process_id=child, address=value['address'], length=4)
        assert memory['hex'] == struct.pack('<I', 0x1234abcd).hex(), memory
        return {'types': types[0], 'held': held, 'before': before, 'after': usage(c), 'source_line': source['line']}
    finally:
        close(c)


try:
    assert target.stdout.readline() == b'ready\n'
    # In-process local source loads keep the synchronous contract. The same
    # large file below must use Pending only when reached through the agent.
    lane = {key: os.environ.pop(key, None) for key in ('XODB_RUNTIME_AGENT', 'XODB_TEST_RUNTIME_AGENT')}
    try:
        client = Client('control', None, options=['--attach', str(target.pid), '--image-limit', '3G'], reply_seconds=30)
        client.stopped()
        deadline = time.monotonic() + 30
        while client.session().get('symbol_discovery_pending'):
            assert time.monotonic() < deadline, 'local symbol discovery did not settle'
            time.sleep(.005)
        main = client.inspect('find_symbol', name='main')
        local = client.tool('get_source_location', address=main['address'])['result']
        assert not local.get('isError'), local
        assert local['structuredContent']['source']['path'].endswith('main.c'), local
        assert jobs(client) == [], jobs(client)
        result['local_source_synchronous'] = True
        close(client); client = None
    finally:
        for key, value in lane.items():
            if value is not None: os.environ[key] = value
    # Source selection is a generic loadRange caller, not the PHDR/runtime
    # shortcut. It must prepare a >256 MiB image without an inline transfer.
    client = open_client()
    main = client.inspect('find_symbol', name='main')
    before = usage(client); started = time.monotonic()
    reply = client.tool('get_source_location', address=main['address'])['result']
    assert reply.get('isError') and reply['content'][0]['text'] == 'DebugMetadataPending', reply
    pending = jobs(client)
    assert len(pending) == 1 and pending[0]['kind'] == 'image', pending
    deadline = time.monotonic() + 30
    while reply.get('isError') and reply['content'][0]['text'] == 'DebugMetadataPending':
        assert time.monotonic() < deadline, (reply, jobs(client))
        time.sleep(.001)
        reply = client.tool('get_source_location', address=main['address'])['result']
    assert not reply.get('isError') and reply['structuredContent']['source']['path'].endswith('main.c'), reply
    value = client.inspect('find_symbol', name='marker_value')
    memory = client.inspect('read_memory', address=value['address'], length=4)
    assert memory['hex'] == struct.pack('<I', 0x1234abcc if a.wrong_result else 0x1234abcd).hex(), memory
    result['runs'].append({'name': 'generic-source', 'seconds': time.monotonic() - started,
                           'before': before, 'after': usage(client)})
    close(client); client = None
    client = open_client(slow=True)
    main = client.inspect('find_symbol', name='main')
    reply = client.tool('get_source_location', address=main['address'])['result']
    assert reply.get('isError') and reply['content'][0]['text'] == 'DebugMetadataPending', reply
    pending = jobs(client)
    assert len(pending) == 1, pending
    client.inspect('cancel_debug_metadata', id=pending[0]['id'])
    for _ in range(3):
        reply = client.tool('get_source_location', address=main['address'])['result']
        assert reply.get('isError') and reply['content'][0]['text'] == 'DebugMetadataCancelled', reply
    close(client); client = None
    for label in ('cold', 'warm'):
        client = open_client()
        before = usage(client); started = time.monotonic()
        job = finish(client)
        result['runs'].append({'name': label, 'job': job, 'seconds': time.monotonic() - started,
                               'before': before, 'after': usage(client)})
        close(client); client = None
    cold, warm = [row['job'] for row in result['runs'] if row['name'] in ('cold', 'warm')]
    # The generic source projection above populated the managed range cache.
    # Both later layout projections reuse it rather than fetching their image
    # ranges again; object preparation still performs bounded header reads.
    assert cold['image_total'] == warm['image_total'] > 0, (cold, warm)
    for reused in (cold, warm):
        assert reused['source_bytes'] < 65536 and reused['cached_bytes'] >= reused['image_total'], reused
    # Cancelling a debugger-image upgrade preserves its visible cancellation but releases
    # the cache lease, so rebuilding the language projection reuses its bytes.
    for cancel_when in ('active', 'ready'):
        client = open_client(slow=True)
        deadline = time.monotonic() + 30
        while True:
            reply = query(client)
            why = reply['content'][0]['text'] if reply.get('isError') else None
            if why != 'DebugMetadataPending': break
            assert time.monotonic() < deadline, reply
            time.sleep(.001)
        assert why == 'GDScriptRuntimeUnavailable', reply
        types = jobs(client)
        assert len(types) == 1 and types[0]['state'] == 'ready', types
        main = client.inspect('find_symbol', name='main')
        reply = client.tool('get_source_location', address=main['address'])['result']
        assert reply.get('isError') and reply['content'][0]['text'] == 'DebugMetadataPending', reply
        full = jobs(client)
        assert len(full) == 1 and full[0]['id'] != types[0]['id'], full
        deadline = time.monotonic() + 30
        while full[0]['cached_bytes'] == 0 or (cancel_when == 'ready' and full[0]['state'] != 'ready'):
            assert full[0]['state'] not in ('failed', 'cancelled') and time.monotonic() < deadline, full
            time.sleep(.001)
            full = jobs(client)
        assert (full[0]['state'] == 'ready') == (cancel_when == 'ready'), full
        client.inspect('cancel_debug_metadata', id=full[0]['id'])
        deadline = time.monotonic() + 30
        while True:
            reply = query(client)
            why = reply['content'][0]['text'] if reply.get('isError') else None
            if why != 'DebugMetadataPending': break
            assert time.monotonic() < deadline, reply
            time.sleep(.001)
        assert why == 'GDScriptRuntimeUnavailable', reply
        rebuilt = [j for j in jobs(client) if j['state'] == 'ready']
        assert len(rebuilt) == 1 and rebuilt[0]['image_total'] == types[0]['image_total'], rebuilt
        assert rebuilt[0]['cached_bytes'] >= rebuilt[0]['image_total'], rebuilt
        assert rebuilt[0]['source_bytes'] < rebuilt[0]['image_total'], rebuilt
        assert usage(client)['prepared_mapping_bytes'] == 300*mib, usage(client)
        for _ in range(3):
            reply = client.tool('get_source_location', address=main['address'])['result']
            assert reply.get('isError') and reply['content'][0]['text'] == 'DebugMetadataCancelled', reply
        result['cancel_rebuild_' + cancel_when] = rebuilt[0]
        close(client); client = None
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
    result['concurrent_coverage'] = concurrent_coverage()
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
    assert orphans.reap(), 'an owned followed child remains'
    image.unlink(missing_ok=True)
    if result['status'] != 'pass': result['status'] = 'failed'
    (w/'results.json').write_text(json.dumps(result, indent=2) + '\n')
print('Image transfer: ranges, cold/warm cache, exact value/source, cancellation, legacy and 2 GiB cap pass')
