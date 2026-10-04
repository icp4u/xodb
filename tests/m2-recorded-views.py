#!/usr/bin/env python3
"""Live immutable flame snapshots, paging and collector progress on owned tasks."""
from datetime import datetime
from pathlib import Path
import json, os, time
from client import Client
root=Path(__file__).resolve().parents[1];os.chdir(root)
work=root/'.work'/('m2-recorded-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));work.mkdir()
c=Client('control','./zig-out/bin/xodb-profile-fixture',args=['30','many','6'])
metrics={}
try:
    bp=c.action('set_breakpoint',symbol='profile_ready')['id']
    c.action('continue');c.stopped('breakpoint');c.action('remove_breakpoint',id=bp)
    cap=c.action('start_profile',frequency_hz=1000,duration_ms=0)['capture']
    c.action('continue')
    deadline=time.monotonic()+10
    while True:
        cap=c.inspect('get_profile')['capture']
        if cap['stored_samples']>=7000 or cap['status']!='collecting':break
        assert time.monotonic()<deadline,cap
        time.sleep(.05)
    assert cap['status']=='collecting',cap
    # Omit revision only on the first request: the server binds the snapshot
    # without racing a continuously advancing collector revision.
    args=dict(capture_id=cap['id'],limit=1)
    started=time.monotonic_ns();response=c.tool('get_flamegraph',**args)
    metrics['dispatch_ms']=(time.monotonic_ns()-started)/1e6
    data=response['result']['structuredContent'];assert data['pending'],data
    args.update(view_id=data['view_id'],revision=data['revision']);snapshot_count=data['snapshot_samples']
    metrics['snapshot_samples']=snapshot_count
    pings=[];deadline=time.monotonic()+10
    while data.get('pending'):
        started=time.monotonic_ns();assert c.call('ping')['result']=={}
        pings.append((time.monotonic_ns()-started)/1e6)
        assert time.monotonic()<deadline,data
        data=c.tool('get_flamegraph',**args)['result']['structuredContent']
    metrics['max_ping_ms']=max(pings);metrics['worker']=data['worker']
    # Collection proceeds without invalidating the pinned published graph.
    time.sleep(.3)
    current=c.inspect('get_profile')['capture'];assert current['stored_samples']>snapshot_count,current
    page=c.inspect('get_flamegraph',**args)
    assert page['snapshot_samples']==snapshot_count and page['revision']==args['revision']
    assert page['current_revision']>page['revision'],page
    rows=list(page['nodes'])
    while page['next'] is not None:
        page=c.inspect('get_flamegraph',**dict(args,start=page['next'],limit=64));rows+=page['nodes']
    assert len(rows)==page['total_nodes'] and sum(n['self'] for n in rows)==page['samples']
    code=next(n for n in rows if n['kind']=='code')
    frame=c.inspect('get_profile_frame',capture_id=cap['id'],revision=args['revision'],view_id=args['view_id'],node=code['id'])
    assert frame['revision']==args['revision'] and frame['source'] and frame['instructions']
    c.action('stop_profile',capture_id=cap['id'])
    c.action('interrupt');c.stopped()
    stopped=c.inspect('get_profile')['capture']
    other=c.inspect('get_flamegraph',capture_id=cap['id'],revision=stopped['revision'],tid=stopped['threads'][0]['perf']['tid'])
    assert other['view_id']!=args['view_id']
    stale=c.tool('get_flamegraph',**args)
    assert stale['result']['isError'] and stale['result']['content'][0]['text']=='StaleProfileView',stale
    # A completed capture may be replaced while an old view is queued; no target
    # state changes are implied by view construction itself.
    new=c.action('start_profile',duration_ms=0)['capture'];assert new['id']!=cap['id']
    stale=c.tool('get_flamegraph',**args)
    assert stale['result']['content'][0]['text']=='StaleCapture',stale
    assert c.session()['state']=='stopped'
    c.action('stop_profile',capture_id=new['id'])
    metrics['advanced_samples']=current['stored_samples']
    print(json.dumps(metrics,indent=2));print(work)
finally:
    (work/'rpc.json').write_text(json.dumps(c.transcript,indent=2)+'\n')
    (work/'metrics.json').write_text(json.dumps(metrics,indent=2)+'\n')
    c.close()
