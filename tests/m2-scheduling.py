#!/usr/bin/env python3
"""Live integrated scheduling capture, shared interval queries and CPU conservation."""
from datetime import datetime
from pathlib import Path
import json, os, time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('m2-scheduling-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir()

def schedule(client, capture, tid, **filters):
    start, spans = 0, []
    while True:
        data = client.inspect('get_profile_schedule', capture_id=capture['id'], revision=capture['revision'], tid=tid, start=start, limit=17, **filters)
        spans += data['spans']
        if data['next'] is None: break
        start = data['next']
    assert len(spans) == data['total_spans']
    cursor = data['range']['from_ns']
    totals = dict(running_ns=0, off_cpu_ns=0, unknown_ns=0)
    for span in spans:
        assert span['from_ns'] == cursor < span['to_ns']
        totals[span['state'] + '_ns'] += span['to_ns'] - cursor
        cursor = span['to_ns']
        if span['state'] == 'unknown': assert span['unknown_reason']
        else: assert span['unknown_reason'] is None
    assert cursor == data['range']['to_ns'] and totals == data['totals']
    return dict(data, spans=spans)

for mode, enabled in [('sleep', True), ('threads', True), ('kernel', True), ('sleep', False)]:
    name = f'{mode}-{enabled}'
    client = Client('control', './zig-out/bin/xodb-profile-fixture', args=['2', mode])
    try:
        bp = client.action('set_breakpoint', symbol='profile_ready')['id']
        client.action('continue')
        stop = client.stopped('breakpoint')
        client.action('remove_breakpoint', id=bp)
        tids = [t['tid'] for t in stop['threads'] if t['state'] != 'exited']
        generation = client.session()['generation']
        bad = client.tool('start_profile', generation=generation, context_switch=1)
        assert bad['error']['code'] == -32602, bad
        capture = client.action('start_profile', context_switch=enabled, frequency_hz=199, duration_ms=5000)['capture']
        assert capture['accepted']['context_switch'] == enabled
        client.action('continue')
        time.sleep(.65)
        capture = client.action('stop_profile', capture_id=capture['id'])['capture']
        assert capture['status'] == 'manual', capture
        assert capture['scheduling']['discarded_events'] == capture['scheduling']['invalid_events'] == 0
        assert capture['lost_records'] == capture['lost_samples'] == 0
        client.action('interrupt')
        stopped = client.stopped()
        generation = stopped['generation']
        regs = client.inspect('get_registers', tid=tids[0])
        lanes = [schedule(client, capture, tid) for tid in tids]
        whole = lanes[0]
        extent = whole['range']['to_ns']
        split = extent // 2
        left = schedule(client, capture, tids[0], to_ns=split)
        right = schedule(client, capture, tids[0], from_ns=split)
        for key in whole['totals']:
            assert left['totals'][key] + right['totals'][key] == whole['totals'][key]
        assert schedule(client, capture, tids[0], from_ns=extent + 1000)['spans'] == []
        if enabled:
            assert capture['scheduling']['status'] == 'available' and capture['scheduling']['recorded_events'] > 1
            assert all(s['state'] != 'unknown' or s['unknown_reason'] == 'unmatched_boundary' for lane in lanes for s in lane['spans'])
            if mode == 'sleep': assert whole['totals']['off_cpu_ns'] > 400_000_000, whole['totals']
            if mode == 'threads':
                # A spinning thread may never switch out before disable: its
                # final interval must stay unknown even when CPU samples exist.
                assert capture['cpu_activity']['user_ms'] > 500
                assert all(lane['spans'][-1]['state'] == 'unknown' for lane in lanes)
            if mode == 'kernel': assert capture['cpu_activity']['kernel_ms'] > 100
        else:
            assert capture['scheduling']['recorded_events'] == 0
            assert whole['totals']['unknown_ns'] == extent
            assert all(s['unknown_reason'] == 'disabled' for s in whole['spans'])
        density = client.inspect('get_profile_timeline', capture_id=capture['id'], revision=capture['revision'])
        graph = client.inspect('get_flamegraph', capture_id=capture['id'], revision=capture['revision'])
        assert density['samples'] == graph['samples'] + graph['excluded_by_node_limit']
        assert density['scheduling'] == capture['scheduling']
        for bad in ({'limit':129}, {'to_ns':0}, {'from_ns':5,'to_ns':5}):
            r = client.tool('get_profile_schedule', capture_id=capture['id'], revision=capture['revision'], tid=tids[0], **bad)
            assert r['error']['code'] == -32602, r
        r = client.tool('get_profile_schedule', capture_id=capture['id'], revision=capture['revision'] - 1, tid=tids[0])
        assert r['result']['isError'] and r['result']['content'][0]['text'] == 'StaleProfile'
        assert client.session()['generation'] == generation and client.inspect('get_registers', tid=tids[0]) == regs
        assert not any('perf_event' in os.readlink(p) for p in Path(f'/proc/{client.p.pid}/fd').iterdir())
        client.action('continue')
        deadline = time.monotonic() + 5
        while client.session()['state'] != 'exited':
            assert time.monotonic() < deadline
            time.sleep(.03)
        assert schedule(client, capture, tids[0]) == whole
        (run/(name+'.json')).write_text(json.dumps({'capture':capture,'lanes':lanes}, indent=2)+'\n')
        print(name, 'samples', capture['stored_samples'], 'switches', capture['scheduling']['recorded_events'], 'totals', whole['totals'], flush=True)
    finally:
        (run/(name+'.rpc.json')).write_text(json.dumps(client.transcript, indent=2)+'\n')
        client.close()
print(run)
