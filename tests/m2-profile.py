#!/usr/bin/env python3
"""Live perf/capture/flame contracts; requires workstation ptrace + perf access."""
from datetime import datetime
from pathlib import Path
import json, os, time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('m2-profile-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
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

def graph(client, capture, **filters):
    rows, start, view_id = [], 0, None
    while True:
        data = client.inspect('get_flamegraph', capture_id=capture['id'], revision=capture['revision'], start=start, limit=3, **({"view_id": view_id} if view_id else {}), **filters)
        view_id = data["view_id"]
        rows += data['nodes']
        if data['next'] is None: break
        start = data['next']
    assert len(rows) == data['total_nodes']
    assert sum(n['self'] for n in rows) == data['samples']
    for node in rows:
        children = [n for n in rows if n['parent'] == node['id']]
        assert node['inclusive'] == node['self'] + sum(n['inclusive'] for n in children), node
        children.sort(key=lambda n:n['x'])
        end = node['x']
        for child in children:
            assert child['x'] == end
            end += child['inclusive']
    return dict(data, nodes=rows)

def perf_fds(client):
    return [os.readlink(p) for p in Path(f'/proc/{client.p.pid}/fd').iterdir() if 'perf_event' in os.readlink(p)]

client = Client('control', fixture, args=['3'])
try:
    stop = checkpoint(client)
    tid = stop['threads'][0]['tid']
    assert not perf_fds(client)
    initial = client.session()
    error(client.tool('start_profile',generation=initial['generation']-1), 'StaleSnapshot')
    error(client.tool('start_profile',generation=initial['generation'],tids=[tid,tid]), 'InvalidProfileThreads')
    for bad in ({'frequency_hz':0},{'duration_ms':4294967296},{'tids':[]},{'tids':[0]},{'inherit':True}):
        assert client.tool('start_profile',generation=initial['generation'],**bad)['error']['code'] == -32602
    opened = client.action('start_profile',duration_ms=5000,frequency_hz=199,tids=[tid])['capture']
    assert len(perf_fds(client)) == 1
    assert opened['accepted']['event'] == 'task_clock' and opened['accepted']['exclude_kernel']
    assert opened['threads'][0]['debugger_id'] == stop['threads'][0]['id']
    assert opened['threads'][0]['perf']['start_time_known']
    time.sleep(.05)
    assert client.inspect('get_profile')['capture']['stored_samples'] == 0
    error(client.tool('start_profile',generation=client.session()['generation']), 'ProfileAlreadyRunning')
    client.action('continue')
    time.sleep(.85)
    live = client.inspect('get_profile')['capture']
    assert live['stored_samples'] > 15 and live['status'] == 'collecting', live
    stopped_capture = client.action('stop_profile',capture_id=opened['id'])['capture']
    assert not perf_fds(client)
    assert client.session()['state'] == 'running', 'Stopping perf paused execution'
    error(client.tool('get_flamegraph',capture_id=opened['id'],revision=opened['revision']), 'StaleProfile')
    error(client.tool('get_profile',capture_id=opened['id']+1), 'StaleCapture')
    captured = graph(client,stopped_capture)
    rows = captured['nodes']
    assert captured['samples'] == stopped_capture['stored_samples'] and captured['excluded_by_node_limit']==0
    hot = {n['name']:n for n in rows if n['name'] in ('hot_mix','hot_hash')}
    assert hot.keys() == {'hot_mix','hot_hash'}, rows
    assert all(n['self'] > 0 for n in hot.values())
    rec = [n for n in rows if n['name']=='recursive_mix']
    assert len(rec)==4, rec
    assert any(n['parent'] in {r['id'] for r in rec} for n in rec)
    first = graph(client, stopped_capture, to_ns=400_000_000)
    second = graph(client, stopped_capture, from_ns=400_000_000)
    assert first['samples']+second['samples']==captured['samples']
    assert graph(client,stopped_capture,tid=tid)['nodes']==rows
    assert graph(client,stopped_capture,from_ns=10_000_000_000)['samples']==0
    captured = graph(client, stopped_capture)
    detail = client.inspect('get_profile_frame',capture_id=opened['id'],revision=stopped_capture['revision'],node=hot['hot_mix']['id'],view_id=captured['view_id'])
    assert detail['source']['path'].endswith('tests/fixtures/profile.c') and detail['instructions'], detail
    client.action('interrupt'); stop=client.stopped()
    regs = client.inspect('get_registers',tid=tid)
    stable = client.session()['generation']
    graph(client,stopped_capture)
    assert client.session()['generation']==stable and client.inspect('get_registers',tid=tid)==regs
    # A stopped capture survives actual process exit, including ELF-backed source/assembly.
    client.action('continue')
    deadline=time.monotonic()+5
    while client.session()['state']!='exited':
        assert time.monotonic()<deadline
        time.sleep(.02)
    assert graph(client,stopped_capture)['nodes']==rows
    after = client.inspect('get_profile_frame',capture_id=opened['id'],revision=stopped_capture['revision'],node=hot['hot_mix']['id'],view_id=captured['view_id'])
    assert after['source']==detail['source'] and after['instructions']==detail['instructions']
    (run/'capture.json').write_text(json.dumps(stopped_capture,indent=2)+'\n')
    (run/'flames.json').write_text(json.dumps(captured,indent=2)+'\n')
    (run/'frame.json').write_text(json.dumps(detail,indent=2)+'\n')
    print(f'capture: {captured["samples"]} samples; two CPU paths, recursive ancestry, conservation, filters, source, exit retention and fd cleanup',flush=True)
finally:
    (run/'manual.rpc.json').write_text(json.dumps(client.transcript,indent=2)+'\n')
    client.close()

for mode in ('duration','mappings','exit'):
    client=Client('control',fixture,args=['1', 'map'] if mode=='mappings' else ['1'])
    try:
        checkpoint(client)
        opened=client.action('start_profile',duration_ms=250 if mode=='duration' else 5000,frequency_hz=199)['capture']
        client.action('continue')
        deadline=time.monotonic()+5
        while True:
            capture=client.inspect('get_profile')['capture']
            if capture['status']!='collecting':break
            assert time.monotonic()<deadline
            time.sleep(.02)
        expected={'duration':'duration','mappings':'target_ended','exit':'target_ended'}[mode]
        assert capture['status']==expected and capture['stored_samples']>5, capture
        assert not perf_fds(client)
        data=graph(client,capture)
        assert data['samples']==capture['stored_samples']
        if mode=='mappings':
            assert capture['mapping_events'] and capture['mapping_history']['recorded_changes']
            assert capture['trusted_before_ns'] is None
            assert any(n['name']=='hot_mix' for n in data['nodes'])
        if mode=='duration':
            client.action('interrupt'); client.stopped()
            newer=client.action('start_profile',duration_ms=100)['capture']
            assert newer['id']>capture['id']
            error(client.tool('stop_profile',capture_id=capture['id'],generation=client.session()['generation']),'StaleCapture')
            client.action('stop_profile',capture_id=newer['id'])
        print(f'{mode}: automatic stop, final drain, stable graph and fd cleanup',flush=True)
    finally:
        (run/(mode+'.rpc.json')).write_text(json.dumps(client.transcript,indent=2)+'\n')
        client.close()

# Explicit scope and thread identity: all threads yield symbols; subsets retain
# addresses without assuming that an unobserved thread left mappings unchanged.
for subset in (False,True):
    client=Client('control',fixture,args=['2','threads'])
    try:
        stop=checkpoint(client)
        tids=[t['tid'] for t in stop['threads'] if t['state']!='exited']
        assert len(tids)==2,stop
        selected=tids[:1] if subset else tids
        opened=client.action('start_profile',tids=selected,frequency_hz=199,duration_ms=5000)['capture']
        assert len(perf_fds(client))==len(selected)
        client.action('continue');time.sleep(.45)
        capture=client.action('stop_profile',capture_id=opened['id'])['capture']
        data=graph(client,capture)
        counts=[graph(client,capture,tid=tid)['samples'] for tid in selected]
        assert sum(counts)==data['samples'] and all(count>5 for count in counts),counts
        assert capture['unselected_threads']==int(subset)
        if subset:
            assert data['unverified_mapping_samples']==data['samples']
            assert all(n['kind']!='code' for n in data['nodes'])
        else:
            assert data['unverified_mapping_samples']==0
            assert any(n['name']=='hot_hash' for n in data['nodes'])
        assert not perf_fds(client)
        print(f'thread scope subset={subset}: sampled {counts}, identities/filters/metadata coverage verified',flush=True)
    finally:
        (run/f'threads-{subset}.rpc.json').write_text(json.dumps(client.transcript,indent=2)+'\n')
        client.close()

# Kernel-heavy work may yield almost no user samples despite substantial CPU;
# sleeping is a separate low-CPU case. Many idle threads exercise the old cap,
# reply size, all-thread accounting and fd cleanup without saturating the host.
for mode in ('kernel', 'sleep', 'many'):
    client=Client('control',fixture,args=['5',mode])
    try:
        stop=checkpoint(client)
        count=sum(t['state']!='exited' for t in stop['threads'])
        assert count==(640 if mode=='many' else 1),count
        metadata=client.inspect('get_profile')
        assert metadata['thread_limit']==1024
        opened=client.action('start_profile',duration_ms=5000,frequency_hz=199)['capture']
        assert len(perf_fds(client))==count
        client.action('continue');time.sleep(.65)
        capture=client.action('stop_profile',capture_id=opened['id'])['capture']
        cpu=capture['cpu_activity']
        assert cpu['complete'] and cpu['available_threads']==count,cpu
        assert capture['status']=='manual' and not perf_fds(client),capture
        if mode=='kernel':
            assert cpu['kernel_ms']>300 and cpu['kernel_ms']>5*cpu['user_ms'],cpu
        elif mode=='sleep':
            assert cpu['user_ms']+cpu['kernel_ms']<200,cpu
        else:
            assert cpu['user_ms']>300 and cpu['user_ms']<1600,cpu
            assert capture['stored_samples']>15,capture
        print(f'{mode}: {count} threads; {capture["stored_samples"]} samples; CPU {cpu["user_ms"]} ms user / {cpu["kernel_ms"]} ms kernel; all fds closed',flush=True)
        (run/(mode+'.capture.json')).write_text(json.dumps(capture,indent=2)+'\n')
    finally:
        (run/(mode+'.rpc.json')).write_text(json.dumps(client.transcript,indent=2)+'\n')
        client.close()

client=Client('observe',fixture,args=['1'])
try:
    names={t['name'] for t in client.call('tools/list')['result']['tools']}
    assert {'get_profile','get_flamegraph','get_profile_frame'} <= names
    assert not {'start_profile','stop_profile'} & names
    error(client.tool('start_profile',generation=client.session()['generation']), 'AgentScopeDenied')
    assert client.inspect('get_profile')['capture'] is None
finally:client.close()
print(f'M2 profile artifacts: {run}',flush=True)
