#!/usr/bin/env python3
"""Owned allocation workload; --helper explicitly enables the reviewed sudo path.
No privilege escalation without that argument. Outputs stay in the checkout.
"""
import argparse,json,os,signal,subprocess,time
from pathlib import Path
from datetime import datetime
from client import Client
parser=argparse.ArgumentParser()
parser.add_argument('--helper')
parser.add_argument('--expect-denial',action='store_true')
parser.add_argument('--modes',default='balanced,threads,limit,loss,exit,exec,fork,cancel,stale')
options=parser.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root)
work=Path('.work')/('allocations-live-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));(work/'tmp').mkdir(parents=True)
fixture=work/'fixture'
subprocess.run(['cc','-pthread','-g','-O0','-fno-builtin','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror','tests/fixtures/allocations.c','-o',str(fixture)],env=dict(os.environ,TMPDIR=str((work/'tmp').resolve())),check=True)
def perf_fds(client):
    count=0
    for p in Path(f'/proc/{client.p.pid}/fd').iterdir():
        try:count+='perf_event' in os.readlink(p)
        except FileNotFoundError:pass
    return count
def wait_capture(client,condition,seconds=8):
    deadline=time.monotonic()+seconds
    while True:
        value=client.inspect('get_allocation_capture')
        if condition(value):return value
        assert time.monotonic()<deadline,value
        time.sleep(.003)
def pages(client,name,cap):
    key=cap['key'];start=0;rows=[]
    args=dict(session_id=key['identity']['session_id'],capture_id=key['identity']['capture_id'],revision=key['revision'])
    field={'get_allocation_events':'events','get_allocation_calls':'calls','get_allocation_lifetimes':'lifetimes'}[name]
    while True:
        page=client.inspect(name,**args,start=start,limit=128)
        if page.get('pending'):time.sleep(.003);continue
        rows+=page[field]
        if page['next'] is None:return rows
        start=page['next']
modes=['denial'] if options.expect_denial else options.modes.split(',')
for mode in modes:
    c=Client('control',str(fixture),args=['burst' if mode in ('limit','loss') else mode],options=['--allocation-helper',options.helper] if options.helper else [])
    try:
        ready=c.action('set_breakpoint',symbol='allocation_ready')['id']
        c.action('set_breakpoint',symbol='allocation_done')
        c.action('continue');state=c.stopped('breakpoint')
        c.action('remove_breakpoint',id=ready)
        before_fds=perf_fds(c)
        pending=c.action('start_allocations',tids=[t['tid'] for t in state['threads'] if t['state']=='stopped'] if mode=='threads' else [state['pid']],duration_ms=10000,record_limit=64 if mode=='limit' else 32768)
        capture_id=pending['preparation_id']
        if mode=='cancel':
            c.action('stop_allocations',session_id=state['session_id'],capture_id=capture_id)
        elif mode=='stale':
            c.action('step_instruction',tid=state['pid'])
        cap=wait_capture(c,lambda v:not v['preparing'])
        if mode in ('denial','cancel','stale'):
            assert not cap['collecting'] and cap['error'] is not None,cap
            if mode=='denial':assert cap['failure'] and cap['failure']['kind']=='permission',cap
            assert perf_fds(c)==before_fds
            (work/f'{mode}.json').write_text(json.dumps(cap,indent=2)+'\n')
            print(mode,cap['error'],flush=True)
            continue
        assert cap['collecting'] and cap['error'] is None,cap
        assert perf_fds(c)==before_fds+8*(2 if mode=='threads' else 1),(mode,perf_fds(c))
        c.action('continue')
        if mode=='loss':
            os.kill(c.p.pid,signal.SIGSTOP)
            try:time.sleep(.2)
            finally:os.kill(c.p.pid,signal.SIGCONT)
        latencies=[];deadline=time.monotonic()+15
        while True:
            then=time.monotonic();s=c.session();latencies.append(time.monotonic()-then)
            cap=c.inspect('get_allocation_capture')
            if s['state'] in ('stopped','exited'):break
            assert time.monotonic()<deadline,s
            time.sleep(.002)
        if cap['collecting']:
            c.action('stop_allocations',session_id=state['session_id'],capture_id=capture_id)
        cap=wait_capture(c,lambda v:not v['collecting'] and v['state'] not in ('analyzing','finalized'))
        assert perf_fds(c)==before_fds
        calls=pages(c,'get_allocation_calls',cap)
        events=pages(c,'get_allocation_events',cap)
        if mode=='balanced':
            assert cap['first_gap'] is None and cap['state']=='ready',cap
            assert sum(row['parent'] is None for row in calls)==10 and all(row['reason']=='complete' for row in calls),(calls,events)
            assert len(events)==2*len(calls),(calls,events)
            summary=cap['summary']
            assert summary['outstanding_count']==1 and summary['outstanding_bytes']==29,summary
            assert summary['successful_allocations']==5 and summary['failed_allocations']==1,summary
            lifetimes=pages(c,'get_allocation_lifetimes',cap)
            assert len(lifetimes)==5 and sum(v['state']=='outstanding' for v in lifetimes)==1,lifetimes
        if mode=='threads':
            assert cap['state']=='ready' and cap['first_gap'] is None,cap
            assert len(cap['threads'])==2 and cap['summary']['outstanding_bytes']==0,cap
            assert len({r['thread_id'] for r in calls})==2,calls
            assert any(r['release_span'] is not None and calls[r['release_span']]['thread_id']!=r['allocation_thread_id'] for r in pages(c,'get_allocation_lifetimes',cap)),calls
        if mode=='limit':assert cap['stop_reason']=='record_limit' and cap['first_gap'],cap
        if mode=='loss':assert cap['first_gap'] is not None and cap['summary'] is None,cap
        if mode=='exec':assert cap['stop_reason']=='image_changed',cap
        if mode=='fork':assert cap['stop_reason']=='scope_changed',cap
        if mode=='exit':assert cap['stop_reason']=='target_ended',cap
        assert max(latencies)<.5,max(latencies)
        (work/f'{mode}.json').write_text(json.dumps(dict(capture=cap,calls=calls,events=events,max_status_ms=1000*max(latencies)),indent=2)+'\n')
        print(mode,cap['stop_reason'],'records',cap['record_count'],'state',cap['state'],'max status ms',round(1000*max(latencies),2),flush=True)
    finally:
        (work/f'{mode}-transcript.json').write_text(json.dumps(c.transcript,indent=2)+'\n')
        c.close()
        (work/f'{mode}-stderr.log').write_bytes(c.p.stderr.read())
print(work)
