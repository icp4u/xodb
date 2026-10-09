#!/usr/bin/env python3
"""Lossless MCP pointer words, numeric compatibility, and both reply forms."""
import argparse, importlib.util, json, os, re, shutil, subprocess, time
from pathlib import Path
from client import Client
from helpers.exact import legacy

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, default=Path('.work/mcp-precision'))
p.add_argument('--node', default=shutil.which('node'))
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
w = a.work.resolve(); w.mkdir(parents=True, exist_ok=True)
source = root / 'tests/fixtures/mcp-precision.c'
fixture = w / 'fixture'
subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(fixture)], check=True, timeout=60)
line = next(i for i, text in enumerate(source.read_text().splitlines(), 1) if 'PRECISION_STOP' in text)
result = {'status': 'running', 'transports': [], 'node': 'pending' if a.node else 'skipped: Node.js unavailable'}


def usage(pid):
    stat = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    rss = int(re.search(r'^VmRSS:\s*(\d+)', Path(f'/proc/{pid}/status').read_text(), re.M)[1])
    return {'cpu_seconds': (int(stat[11]) + int(stat[12])) / os.sysconf('SC_CLK_TCK'), 'rss_kib': rss}


def exact(reply):
    assert 'error' not in reply and not reply['result'].get('isError'), reply
    v = reply['result']['structuredContent']
    assert json.loads(reply['result']['content'][0]['text']) == v
    return v


def check(raw, state):
    assert state['running_to_hex'] is None if state['running_to'] is None else int(state['running_to_hex'], 16) == state['running_to']
    tid = state['threads'][0]['tid']
    answer = exact(raw('evaluate_expression', tid=tid, expression='wide'))
    assert answer['value']['bits'] == 0x20000000000001 and answer['value']['bits_hex'] == '0x20000000000001', answer
    assert legacy(answer)['value']['bits'] == 0x20000000000001
    pointer = exact(raw('evaluate_expression', tid=tid, expression='pointer'))
    assert pointer['value']['bits'] == 0xffffffffffffffff and pointer['value']['bits_hex'] == '0xffffffffffffffff', pointer
    stack = exact(raw('get_stack', tid=tid))
    for f in stack['frames']:
        assert int(f['pc_hex'], 16) == f['pc']
        assert int(f['lookup_pc_hex'], 16) == f['lookup_pc']
        assert [None if s is None else int(s, 16) for s in f['registers_hex']] == f['registers']
        assert f['cfa_hex'] is None if f['cfa'] is None else int(f['cfa_hex'], 16) == f['cfa']
    assert stack['frames']
    memory = exact(raw('list_modules'))
    for row in memory['regions']:
        for field in ('start', 'end', 'offset'): assert int(row[field + '_hex'], 16) == row[field]
    assert memory['regions']
    view = exact(raw('get_debug_view', tid=tid))
    for row in view['registers']:
        assert row['value_hex'] is None if row['value'] is None else int(row['value_hex'], 16) == row['value']
    for row in view['frames']: assert int(row['pc_hex'], 16) == row['pc']
    for row in view['breakpoints']: assert int(row['address_hex'], 16) == row['address']
    for row in view['locals']:
        assert row['address_hex'] is None if row['address'] is None else int(row['address_hex'], 16) == row['address']
    events = exact(raw('query_events'))['events']
    for event in events:
        for field in ('pc', 'address', 'before', 'after'):
            assert int(event[field + '_hex'], 16) == event[field]
    # The old get_registers/read_memory hex string contract stays unchanged.
    regs = exact(raw('get_registers', tid=tid))
    assert all(isinstance(v, str) for v in regs['registers'].values())
    if a.node:
        js = """
        const assert = require('node:assert/strict');
        const data = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
        for (const [reply, expected] of [[data.wide, 0x20000000000001n], [data.pointer, 0xffffffffffffffffn]]) {
          for (const result of [reply.result.structuredContent, JSON.parse(reply.result.content[0].text)]) {
            assert.equal(typeof result.value.bits, 'number');
            assert.notEqual(BigInt(result.value.bits), expected); // Actually exercises rounding.
            assert.equal(BigInt(result.value.bits_hex), expected);
          }
        }
        process.stdout.write('exact BigInt round trip; legacy numbers demonstrably rounded\\n');
        """
        payload = {'wide': raw('evaluate_expression', tid=tid, expression='wide'), 'pointer': raw('evaluate_expression', tid=tid, expression='pointer')}
        node = subprocess.run([a.node, '-e', js], input=json.dumps(payload), text=True, capture_output=True, check=True, timeout=15)
        result['node'] = 'pass'; print(node.stdout.strip())
    return {'queries': ['evaluate_expression', 'get_stack', 'list_modules', 'get_debug_view', 'query_events', 'get_registers'], 'wide': answer, 'pointer': pointer}

try:
    # Owned fixtures only. The synthetic pointer words are never dereferenced.
    for agent in (False, True):
        client = Client('control', str(fixture), options=['--runtime-agent', str(root/'zig-out/bin/xodb-agent')] if agent else [])
        try:
            client.stopped()
            deadline = time.monotonic() + 60
            while client.session()['symbol_discovery_pending']:
                assert time.monotonic() < deadline; time.sleep(.01)
            client.action('set_breakpoint', file=str(source), line=line)
            client.action('continue'); state = client.stopped('breakpoint')
            before = usage(client.p.pid)
            checked = check(client.tool, state)
            after = usage(client.p.pid)
            result['transports'].append({'name': 'agent' if agent else 'native', 'check': checked, 'before': before, 'after': after, 'load': os.getloadavg()})
        finally: client.close()
    spec = importlib.util.spec_from_file_location('shared', root/'tests/shared-sessions.py')
    s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)
    (w/'shared').mkdir(exist_ok=True)
    server = s.Server(root, w/'shared', root/'zig-out/bin/xodb', fixture, 'control', fixture_args=())
    try:
        owner, observer = s.Client(server, 'owner'), s.Client(server, 'observer')
        owner.claim(ttl_ms=60000)
        initial = s.eventually(owner.session, lambda v:v['state']=='stopped' and not v['symbol_discovery_pending'], 'initial stop')
        server.remember_target(initial)
        owner.action('set_breakpoint', file=str(source), line=line); owner.action('continue')
        state = s.eventually(owner.session, lambda v:v['state']=='stopped' and not v['continue_pending'] and any(t['reason']=='breakpoint' for t in v['threads']), 'precision stop')
        checked = check(observer.raw, state)
        result['transports'].append({'name': 'shared observer', 'check': checked})
    finally: server.close()
    result['status'] = 'pass'
finally:
    (w/'results.json').write_text(json.dumps(result, indent=2)+'\n')
print('MCP exact pointer fields: native, agent, shared observer and both reply forms passed')
