#!/usr/bin/env python3
"""Public review regressions: ownership, partial mutations and transport pressure.

Run from an external source snapshot to keep binaries/logs out of the checkout.
Individual case names can be supplied to reproduce failures independently.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = Path(tempfile.mkdtemp(prefix='review-boundaries-', dir=root / '.work'))
source = root / 'tests/fixtures/review-boundaries.c'
exe = run / 'fixture'
subprocess.run(['gcc', '-gdwarf-4', '-O0', '-fno-omit-frame-pointer', str(source), '-ldl', '-o', str(exe)], check=True)
line = next(i for i, text in enumerate(source.read_text().splitlines(), 1) if 'ready-line' in text)

def start(*args, options=()):
    client = Client('mutate', str(exe), args=args, options=options)
    client.action('set_breakpoint', file=str(source), line=line)
    client.action('continue')
    state = client.stopped('breakpoint')
    return client, state['threads'][0]['tid']

def value(client, tid, expression):
    return client.inspect('evaluate_expression', tid=tid, expression=expression)['value']

def finish(client, label):
    (run / (label + '.json')).write_text(json.dumps(client.transcript, indent=2))
    client.close()

def memory():
    client, tid = start()
    try:
        address = value(client, tid, 'boundary')['bits']
        before = client.session()['generation']
        failed = client.tool('write_memory', generation=before, address=hex(address), hex='11223344')
        assert failed['result']['isError'] and failed['result']['content'][0]['text'] == 'PartialMemoryWrite', failed
        after = client.session()['generation']
        data = client.inspect('read_memory', address=hex(address), length=2)
        assert data['hex'] == '1122', data
        assert after > before, (before, after)
        audit = client.inspect('get_audit')
        assert any(a['action'] == 'write_memory_partial' for a in audit['actions']), audit
        events = client.inspect('query_events')['events']
        assert any(e['kind'] == 'memory_written' and e['address'] == address and e['detail'] == 2 for e in events), events
        stale = client.tool('write_memory', generation=before, address=hex(address), hex='00')
        assert stale['result']['content'][0]['text'] == 'StaleSnapshot', stale
        # A failure before the first byte must not invalidate the snapshot.
        before = client.session()['generation']
        failed = client.tool('write_memory', generation=before, address=hex(address + 2), hex='00')
        assert failed['result']['isError'] and client.session()['generation'] == before, failed
    finally:
        finish(client, 'memory')

def burst():
    for eof in (False, True):
        client = Client('observe', str(exe))
        pid = client.session()['pid']
        count = 64
        ids = list(range(client.id + 1, client.id + count + 1))
        requests = b''.join((json.dumps({'jsonrpc': '2.0', 'id': i, 'method': 'tools/list'}) + '\n').encode() for i in ids)
        def receive():
            responses = []
            while len(responses) < count:
                line = client.p.stdout.readline()
                assert line, client.p.stderr.read().decode()
                response = json.loads(line)
                if 'id' in response:
                    responses.append(response)
            return responses
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(receive)
                client.p.stdin.write(requests)
                client.p.stdin.flush()
                if eof:
                    client.p.stdin.close()
                responses = future.result(timeout=15)
            assert [r['id'] for r in responses] == ids
            assert all('tools' in r['result'] for r in responses)
            client.id = ids[-1]
            if eof:
                assert client.p.wait(timeout=5) == 0
            else:
                assert client.session()['pid'] == pid and Path('/proc', str(pid)).exists()
        finally:
            if not client.p.stdin.closed:
                client.close()
            elif client.p.poll() is None:
                client.p.kill(); client.p.wait()

def overlay():
    client, tid = start('unmap')
    try:
        address = value(client, tid, 'boundary')['bits']
        probe = client.action('set_breakpoint', address=hex(address))['id']
        client.action('configure_breakpoint', id=probe, enabled=False)
        client.action('set_breakpoint', symbol='after_unmap')
        client.action('continue'); client.stopped('breakpoint')
        original = next(b for b in client.inspect('get_breakpoints')['breakpoints'] if b['id'] == probe)
        before = client.session()['generation']
        failed = client.tool('write_memory', generation=before, address=hex(address), hex='55')
        assert failed['result']['isError'], failed
        after = next(b for b in client.inspect('get_breakpoints')['breakpoints'] if b['id'] == probe)
        assert after['original'] == original['original'], (original, after)
        assert client.session()['generation'] == before
    finally:
        finish(client, 'overlay')

def recursive():
    expressions = ['p->value', 'p->next->value', 'alias->next->value', 'head.next->value']
    for order in (expressions, list(reversed(expressions))):
        client, tid = start()
        try:
            for expression in order:
                assert value(client, tid, expression)['bits'] == (11 if expression == 'p->value' else 22)
        finally:
            finish(client, 'recursive-' + str(order == expressions))

def library(truncate=False):
    lib = run / ('truncate.so' if truncate else 'twice.so')
    subprocess.run(['gcc', '-g', '-O0', '-shared', '-fPIC', 'tests/fixtures/review-library.c', '-o', str(lib)], check=True)
    client, tid = start('library', str(lib))
    try:
        addresses = [value(client, tid, name)['bits'] for name in ('first_func', 'second_func')]
        assert addresses[0] != addresses[1]
        if truncate:
            addresses.sort()
            for address in addresses:
                client.inspect('get_source_location', address=hex(address))
            with lib.open('wb'):
                pass
            client.inspect('find_symbol', name='library_func')
        for address in addresses:
            loc = client.inspect('get_source_location', address=hex(address))['source']
            assert loc['path'].endswith('review-library.c'), loc
    finally:
        finish(client, 'truncate' if truncate else 'library')

def evidence():
    export = run / 'evidence-export.json'
    client, tid = start('exec', options=('--record', str(export)))
    try:
        investigation = client.action('investigate_write', tid=tid, expression='mode', question='Who changes mode?')['id']
        initial = client.inspect('get_investigation', id=investigation)
        assert 'FIRST' in json.dumps(initial), initial
        client.action('continue'); client.stopped('watchpoint')
        recorded = client.inspect('get_investigation', id=investigation)
        assert 'local_mode' in json.dumps(recorded) and 'FIRST' in json.dumps(recorded), recorded
        client.action('continue'); client.stopped('exec')
        # Force old debug images to be destroyed, then serialize retained data.
        client.tool('find_symbol', name='main')
        retained = client.inspect('get_investigation', id=investigation)
        assert retained['initial'] == initial['initial'], retained
        assert retained['observations'] == recorded['observations'], retained
    finally:
        finish(client, 'evidence')
    saved = json.loads(export.read_text())['investigations'][0]
    assert saved['initial'] == initial['initial'] and saved['observations'] == recorded['observations'], saved

def sigpipe():
    assert subprocess.run([str(exe), 'signal']).returncode == -signal.SIGPIPE
    client = Client('control', str(exe), args=('signal',))
    try:
        client.action('continue'); state = client.stopped('signal')
        assert state['threads'][0]['signal'] == signal.SIGPIPE, state
        client.action('continue')
        deadline = time.monotonic() + 5
        while client.session()['state'] != 'exited':
            assert time.monotonic() < deadline
            time.sleep(.002)
        events = client.inspect('query_events')['events']
        assert any(e['kind'] == 'exit' and e['detail'] == -signal.SIGPIPE for e in events), events
    finally:
        finish(client, 'signal')

cases = dict(memory=memory, overlay=overlay, burst=burst, recursive=recursive, library=library,
             truncate=lambda: library(True), evidence=evidence, sigpipe=sigpipe)
failures = []
for name in sys.argv[1:] or cases:
    try:
        cases[name]()
        print('PASS', name, flush=True)
    except Exception as error:
        failures.append(name)
        print('FAIL', name, repr(error), flush=True)
print('Artifacts:', run)
sys.exit(bool(failures))
