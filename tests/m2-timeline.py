#!/usr/bin/env python3
"""Shared CPU timeline/filter contracts over the real stdio MCP + owned perf targets."""
from datetime import datetime
from pathlib import Path
import json
import os
import time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('m2-timeline-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir(parents=True)
fixture = './zig-out/bin/xodb-profile-fixture'

def error(response, name):
    assert response['result']['isError'] and response['result']['content'][0]['text'] == name, response

def checkpoint(client):
    bp = client.action('set_breakpoint', symbol='profile_ready')['id']
    client.action('continue')
    result = client.stopped('breakpoint')
    client.action('remove_breakpoint', id=bp)
    return result

def query(client, capture, **filters):
    return client.inspect('get_profile_timeline', capture_id=capture['id'], revision=capture['revision'], **filters)

def flame_count(client, capture, **filters):
    graph = client.inspect('get_flamegraph', capture_id=capture['id'], revision=capture['revision'], **filters)
    return graph['samples'] + graph['excluded_by_node_limit']

def check(client, capture, **filters):
    data = query(client, capture, bins=7, **filters)
    assert not data['provisional'] and data['scheduling']['status'] == 'disabled'
    assert data['samples'] == sum(b['samples'] for b in data['bins'])
    assert data['samples'] == flame_count(client, capture, **filters)
    next_edge = data['range']['from_ns']
    for b in data['bins']:
        assert next_edge == b['from_ns'] < b['to_ns']
        args = dict(filters, from_ns=b['from_ns'], to_ns=b['to_ns'])
        assert b['samples'] == flame_count(client, capture, **args), b
        next_edge = b['to_ns']
    assert next_edge == data['range']['to_ns']
    return data

client = Client('control', fixture, args=['2', 'threads'])
try:
    tools = client.call('tools/list')['result']['tools']
    tool = next(t for t in tools if t['name'] == 'get_profile_timeline')
    assert tool['annotations']['readOnlyHint'] and tool['inputSchema']['properties']['bins']['maximum'] == 512
    error(client.tool('get_profile_timeline', capture_id=1, revision=1), 'NoProfile')
    stop = checkpoint(client)
    tids = [t['tid'] for t in stop['threads'] if t['state'] != 'exited']
    assert len(tids) == 2
    opened = client.action('start_profile', duration_ms=5000, frequency_hz=199)['capture']
    client.action('continue')
    time.sleep(.3)
    client.action('interrupt')
    client.stopped()
    time.sleep(.08)
    client.action('continue')
    time.sleep(.3)
    capture = client.action('stop_profile', capture_id=opened['id'])['capture']
    assert capture['status'] == 'manual' and capture['stored_samples'] > 15, capture
    client.action('interrupt')
    stop = client.stopped()
    before_regs = client.inspect('get_registers', tid=tids[0])
    before_generation = client.session()['generation']
    data = check(client, capture)
    assert data['samples'] == capture['stored_samples'] and data['invalid_samples'] == 0
    assert data['samples'] == sum(t['samples'] for t in data['threads'])
    assert {t['debugger_id'] for t in data['threads']} == {t['debugger_id'] for t in capture['threads']}
    assert sum(check(client, capture, tid=tid)['samples'] for tid in tids) == data['samples']
    page = query(client, capture, start=0, limit=1)
    assert page['next'] == 1 and page['threads'] == data['threads'][:1]
    last = query(client, capture, start=1, limit=1)
    assert last['next'] is None and last['threads'] == data['threads'][1:]
    assert query(client, capture, start=2)['threads'] == []
    split = data['extent_ns'] // 2
    assert check(client, capture, to_ns=split)['samples'] + check(client, capture, from_ns=split)['samples'] == data['samples']
    empty = check(client, capture, from_ns=data['extent_ns'] + 1000)
    assert empty['bins'] == [] and empty['samples'] == 0
    assert len(query(client, capture, bins=512)['bins']) == 512
    kinds = [m['kind'] for m in data['debugger_markers']]
    assert kinds[0] == 'capture_open_stopped' and kinds.count('continued') >= 2 and 'stop' in kinds, kinds
    assert data['debugger_marker_dropped'] == data['debugger_events_lost'] == 0
    assert [m['offset_ns'] for m in data['debugger_markers']] == sorted(m['offset_ns'] for m in data['debugger_markers'])
    for bad in ({'bins':0}, {'bins':513}, {'from_ns':5,'to_ns':5}, {'tid':0}, {'start':3}, {'limit':65}, {'unexpected':True}):
        response = client.tool('get_profile_timeline', capture_id=capture['id'], revision=capture['revision'], **bad)
        assert response['error']['code'] == -32602, response
    error(client.tool('get_profile_timeline', capture_id=capture['id'], revision=opened['revision']), 'StaleProfile')
    error(client.tool('get_profile_timeline', capture_id=capture['id'], revision=capture['revision'], tid=2147483647), 'UnknownProfileThread')
    assert client.session()['generation'] == before_generation
    assert client.inspect('get_registers', tid=tids[0]) == before_regs
    client.action('continue')
    deadline = time.monotonic() + 5
    while client.session()['state'] != 'exited':
        assert time.monotonic() < deadline
        time.sleep(.02)
    assert query(client, capture, bins=7) == data, 'Completed timeline changed after target exit'
    (run/'timeline.json').write_text(json.dumps(data, indent=2)+'\n')
    print(f'CPU: {data["samples"]} samples; bin/thread/flame conservation, markers, guards, read-only state and exit retention passed', flush=True)
finally:
    (run/'cpu.rpc.json').write_text(json.dumps(client.transcript, indent=2)+'\n')
    client.close()

for mode in ('sleep', 'many'):
    client = Client('control', fixture, args=['5', mode, '65'])
    try:
        checkpoint(client)
        opened = client.action('start_profile', duration_ms=5000)['capture']
        client.action('continue')
        time.sleep(.25)
        capture = client.action('stop_profile', capture_id=opened['id'])['capture']
        data = check(client, capture)
        if mode == 'sleep':
            assert data['samples'] <= 2, data
            assert data['scheduling']['status'] == 'disabled', 'No samples must not imply off CPU'
        else:
            assert data['total_threads'] == 66 and len(data['threads']) == 64 and data['next'] == 64
            last = query(client, capture, start=64)
            assert last['next'] is None and len(last['threads']) == 2
            assert data['samples'] == sum(t['samples'] for t in data['threads'] + last['threads'])
        client.action('interrupt')
        client.stopped()
        new = client.action('start_profile', duration_ms=5000)['capture']
        error(client.tool('get_profile_timeline', capture_id=capture['id'], revision=capture['revision']), 'StaleCapture')
        fresh = client.action('stop_profile', capture_id=new['id'])['capture']
        cleared = query(client, fresh)
        assert cleared['samples'] == 0 and [m['kind'] for m in cleared['debugger_markers']] == ['capture_open_stopped']
        print(f'{mode}: {data["samples"]} samples, {data["total_threads"]} lanes; pagination and capture replacement passed', flush=True)
    finally:
        (run/f'{mode}.rpc.json').write_text(json.dumps(client.transcript, indent=2)+'\n')
        client.close()
print(run)
