#!/usr/bin/env python3
"""Measure this owned 64-pair burst with no probes, pairing only, and stacks."""
import argparse,json,os,statistics,subprocess,time
from pathlib import Path
from client import Client
parser=argparse.ArgumentParser();parser.add_argument('--helper',required=True);options=parser.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root)
work=root/'.work'/('allocation-cost-'+str(time.time_ns())[-10:]);work.mkdir();(work/'tmp').mkdir()
fixture=work/'fixture'
subprocess.run(['cc','-pthread','-g','-O0','-fno-builtin','-fno-omit-frame-pointer','tests/fixtures/allocations.c','-o',str(fixture)],check=True,env=dict(os.environ,TMPDIR=str(work/'tmp')))
rows=[]
for repeat in range(5):
    for mode in ('baseline','pairing','stacks'):
        c=Client('control',str(fixture),args=['benchmark'],options=['--allocation-helper',options.helper] if mode!='baseline' else [])
        try:
            ready=c.action('set_breakpoint',symbol='allocation_ready')['id'];c.action('set_breakpoint',symbol='allocation_done')
            c.action('continue');state=c.stopped('breakpoint');c.action('remove_breakpoint',id=ready)
            if mode!='baseline':
                c.action('start_allocations',tids=[state['pid']],duration_ms=10000,record_limit=32768,callstacks=mode=='stacks')
                deadline=time.monotonic()+10
                while True:
                    cap=c.inspect('get_allocation_capture')
                    if not cap['preparing']:break
                    assert time.monotonic()<deadline,cap
                    time.sleep(.003)
                assert cap['collecting'],cap
            c.action('continue');c.stopped('breakpoint')
            ns=int(c.inspect('evaluate_expression',tid=state['pid'],frame=1,expression='workload_ns')['value']['display'])
            records=0
            if mode!='baseline':
                c.action('stop_allocations',session_id=state['session_id'],capture_id=cap['key']['identity']['capture_id'])
                deadline=time.monotonic()+10
                while True:
                    cap=c.inspect('get_allocation_capture')
                    if cap['state'] in ('ready','unavailable'):break
                    assert time.monotonic()<deadline,cap
                    time.sleep(.003)
                assert cap['state']=='ready',cap
                assert cap['summary']['successful_allocations']==64 and cap['summary']['outstanding_count']==0,cap
                records=cap['record_count']
            rows.append(dict(mode=mode,repeat=repeat,workload_ns=ns,records=records))
        finally:c.close()
summary={mode:statistics.median(r['workload_ns'] for r in rows if r['mode']==mode) for mode in ('baseline','pairing','stacks')}
(work/'result.json').write_text(json.dumps(dict(rows=rows,median_ns=summary),indent=2)+'\n')
print(json.dumps(summary),work,flush=True)
