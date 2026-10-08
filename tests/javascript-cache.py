#!/usr/bin/env python3
"""Owned Node stacks remain available when persistent caching is unavailable."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import threading
import time

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('shared', root / 'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', required=True, type=Path)
p.add_argument('--node', required=True)
p.add_argument('--include', default='/usr/include/node')
p.add_argument('--agent', type=Path)
p.add_argument('--delay', type=float, default=0)
p.add_argument('--latency-only', action='store_true', help='Compare pending stack polls with metadata-only polls')
a = p.parse_args()
os.umask(0o022)
os.chdir(root)
w = a.work.resolve()
w.mkdir(parents=True, mode=0o755)
binary = Path(os.environ.get('XODB_BIN', root / 'zig-out/bin/xodb')).resolve()
shared.Client.receive.__defaults__ = (120.0,)
addon = w / 'probe.node'
subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-g', '-O0',
    '-fno-omit-frame-pointer', '-fPIC', '-shared', '-I' + a.include,
    '-DNODE_GYP_MODULE_NAME=xodb_probe', str(root / 'examples/node-probe.cc'),
    '-o', str(addon)], check=True, timeout=90)
script = w / 'fixture.js'
script.write_text('const p = require(process.argv[2]);\n'
    'function cache_fixture() { const value = 42; p.probe(value); }\ncache_fixture();\n')
if a.agent:
    os.environ['XODB_RUNTIME_AGENT'] = str(root / 'tests/fixtures/metadata-agent-proxy.py')
    os.environ['XODB_METADATA_AGENT'] = str(a.agent.resolve())
    os.environ['XODB_METADATA_DELAY'] = str(a.delay)
rows = []
metadata_only = False


def setup(name):
    part = w / name
    part.mkdir(mode=0o755)
    server = shared.Server(root, part, binary, a.node, 'control',
        options=('--break', 'xodb_node_stop'), fixture_args=(str(script), str(addon)))
    try:
        client = shared.Client(server, name)
        state = shared.eventually(client.session, lambda s: s['state'] == 'stopped', 'exec stop', timeout=60)
        server.remember_target(state)
        client.claim(ttl_ms=60000)
        client.tool('continue', generation=state['generation'])
        state = shared.eventually(client.session,
            lambda s: s['state'] == 'stopped' and not s['symbol_discovery_pending'] and not s['continue_pending']
                and any(t['reason'] == 'breakpoint' for t in s['threads']),
            'native probe', timeout=180)
        symbol = client.call('tools/call', {'name': 'find_symbol',
            'arguments': {'name': 'xodb_node_stop'}})['result']['structuredContent']
        registers = client.tool('get_registers', tid=state['pid'])
        assert int(registers['registers']['rip'], 16) == int(symbol['address'], 16), (state, symbol, registers)
        return server, client, state
    except BaseException:
        server.close()
        raise


def inspect(item, barrier=None):
    server, client, before = item
    if barrier:
        barrier.wait(timeout=10)
    start = time.monotonic()
    pending = []
    ready_seconds = None
    calls = 0
    deadline = start + 600
    while True:
        t = time.monotonic()
        jobs = client.tool('get_debug_metadata')['jobs'] if calls else []
        js = [j for j in jobs if j['kind'] == 'javascript']
        if a.latency_only and js and js[0]['state'] in ('ready', 'verifying'):
            # This measures worker progress while metadata is pending. A full
            # native unwind after readiness is a different foreground operation.
            after = client.session()
            assert after['state'] == 'stopped' and after['generation'] == before['generation'], (before, after)
            row = {'name': client.label, 'status': 'pass',
                   'metadata_ready_seconds': time.monotonic() - start,
                   'pending_call_seconds': pending, 'jobs': jobs}
            rows.append(row)
            return row
        if js and js[0]['state'] == 'ready' and ready_seconds is None:
            ready_seconds = time.monotonic() - start
        if calls and metadata_only and js and js[0]['state'] not in ('ready', 'failed', 'cancelled'):
            assert time.monotonic() < deadline, js
            time.sleep(.5)
            continue
        reply = client.raw('get_language_stack', tid=before['pid'], language='javascript')
        calls += 1
        elapsed = time.monotonic() - t
        result = reply.get('result', {})
        if not result.get('isError'):
            stack = result['structuredContent']
            break
        assert result['content'][0]['text'] == 'DebugMetadataPending', reply
        pending.append(elapsed)
        assert time.monotonic() < deadline, client.tool('get_debug_metadata')
        time.sleep(.5 if a.delay else .02)
    assert any(f['name'] == 'cache_fixture' for s in stack['segments'] for f in s['frames']), stack
    after = client.session()
    assert after['state'] == 'stopped' and after['generation'] == before['generation'], (before, after)
    jobs = client.tool('get_debug_metadata')['jobs']
    if not a.agent:
        assert all(j['cached_bytes'] == 0 for j in jobs), jobs
    row = {'name': client.label, 'status': 'pass', 'seconds': time.monotonic() - start,
           'pending_call_seconds': pending, 'metadata_ready_seconds': ready_seconds, 'jobs': jobs, 'stack': stack}
    rows.append(row)
    return row


def group(name, count=1):
    active = []
    try:
        for n in range(count):
            active.append(setup(name + '-' + str(n)))
        barrier = threading.Barrier(count) if count > 1 else None
        with ThreadPoolExecutor(max_workers=count) as pool:
            list(pool.map(lambda item: inspect(item, barrier), active))
    finally:
        for server, _, _ in active:
            server.close()
            assert server.proc.returncode == 0, (server.work / 'server.log').read_text()
        (w / 'results.json').write_text(json.dumps({'checks': rows}, indent=2) + '\n')


if a.latency_only:
    assert a.agent and a.delay > 0
    for label, metadata_only in [('metadata-only', True), ('stack-polls', False)]:
        cache = w / (label + '-cache')
        cache.mkdir(mode=0o700)
        os.environ['XDG_CACHE_HOME'] = str(cache)
        group(label)
    direct, polled = rows
    assert direct['metadata_ready_seconds'] is not None and polled['metadata_ready_seconds'] is not None, rows
    # Allow normal shared-host scheduling variation; starvation previously left
    # the symbol worker pending indefinitely under repeated foreground unwinds.
    assert polled['metadata_ready_seconds'] <= direct['metadata_ready_seconds'] * 1.5 + 5, rows
    print('Pending stack polls do not starve metadata:',
          direct['metadata_ready_seconds'], polled['metadata_ready_seconds'])
    raise SystemExit(0)

cache = w / 'group-cache'
cache.mkdir(mode=0o775)
cache.chmod(0o775)
os.environ['XDG_CACHE_HOME'] = str(cache)
group('group-writable')
os.environ.pop('XDG_CACHE_HOME')
os.environ.pop('HOME', None)
group('no-home')
cache = w / 'busy-cache'
private = cache / 'xodb-debug-v1'
private.mkdir(mode=0o700, parents=True)
os.environ['XDG_CACHE_HOME'] = str(cache)
leases = []
try:
    for n in range(2):
        fd = os.open(private / (str(n) + '.lease'), os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        leases.append(fd)
    group('all-slots-busy')
finally:
    for fd in leases:
        os.close(fd)
for n in range(8):
    cache = w / ('pair-cache-' + str(n))
    cache.mkdir(mode=0o700)
    os.environ['XDG_CACHE_HOME'] = str(cache)
    group('pair-' + str(n), 2)
print('JavaScript cache availability checks passed:', len(rows))
