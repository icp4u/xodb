#!/usr/bin/env python3
"""Bounded T04 native / CPU-only / scheduling comparisons; artifacts in .work.

Includes debugger startup pauses in target timing; excludes frame zero from
CSV quantiles. Two repetitions characterize this run, not general overhead.
"""
from datetime import datetime
from pathlib import Path
import csv, json, os, subprocess, time
from client import Client
root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root/'.work'/('m2-workload-cost-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir()
env=dict(os.environ,TMPDIR=str(root/'.work/tmp'))
for name in ['frameloop','reqserver']:
    subprocess.run(['cc','-O2','-g','-fno-omit-frame-pointer','-mno-omit-leaf-frame-pointer','-fno-optimize-sibling-calls','-Wall','-Wextra','-Werror','-pthread',f'tests/workloads/{name}.c','-lm','-o',str(run/name)],env=env,check=True)

def cpu(pid):
    fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
    return (int(fields[11])+int(fields[12]))*1000/os.sysconf('SC_CLK_TCK')

def result_json(text):
    start=text.index('{"workload"')
    return json.JSONDecoder().raw_decode(text[start:])[0]

results=[]
for name in ['frameloop','reqserver']:
 for repeat in range(2):
  for mode in ['native','cpu','scheduling']:
    label=f'{name}-{repeat}-{mode}'
    args=['--frames','120','--stall','lock','--stall-first','60','--max-seconds','15','--csv',str(run/(label+'.csv'))] if name=='frameloop' else ['--seconds','2','--workers','4','--clients','4','--hold','50000','--shards','1','--max-seconds','15']
    capture=None; profiler_cpu=None; transcript=None
    if mode=='native':
        p=subprocess.run([str(run/name),*args],capture_output=True,text=True,timeout=20)
        assert p.returncode==0,(p.stdout,p.stderr)
        output=p.stdout+p.stderr
    else:
        c=Client('control',str(run/name),args=args)
        try:
            bp=c.action('set_breakpoint',symbol='main')['id']
            c.action('continue'); c.stopped('breakpoint'); c.action('remove_breakpoint',id=bp)
            bp=c.action('set_breakpoint',symbol='frame_begin' if name=='frameloop' else 'pthread_join')['id']
            c.action('continue'); stopped=c.stopped('breakpoint'); c.action('remove_breakpoint',id=bp)
            expected=6 if name=='frameloop' else 9
            assert len(stopped['threads'])==expected, stopped
            before=cpu(c.p.pid)
            capture=c.action('start_profile',frequency_hz=99,duration_ms=5000,context_switch=mode=='scheduling')['capture']
            c.action('continue')
            deadline=time.monotonic()+15
            while c.session()['state']!='exited':
                assert time.monotonic()<deadline
                time.sleep(.05)
            profiler_cpu=cpu(c.p.pid)-before
            capture=c.inspect('get_profile')['capture']
            assert capture['status']!='collecting'
            assert capture['lost_records']==capture['lost_samples']==0,capture
            assert capture['scheduling']['discarded_events']==capture['scheduling']['invalid_events']==0,capture
            if mode=='scheduling': assert capture['scheduling']['recorded_events']>100
        finally:
            c.close()
            output=c.p.stderr.read().decode()
            (run/(label+'.rpc.json')).write_text(json.dumps(c.transcript,indent=2)+'\n')
    (run/(label+'.log')).write_text(output)
    result=result_json(output)
    assert not result['interrupted']
    row=dict(name=name,repeat=repeat,mode=mode,workload=result,capture=capture,profiler_cpu_ms=profiler_cpu)
    if name=='frameloop':
        values=sorted(int(r['work_us']) for r in csv.DictReader(open(run/(label+'.csv'))) if int(r['frame'])>0)
        row['frame_work_excluding_start_us']={k:values[int((len(values)-1)*q)] for k,q in [('p50',.5),('p99',.99),('max',1)]}
        assert result['frames']==120 and result['injected']==1
    results.append(row)
    # A new filename each iteration preserves partial evidence on failure.
    (run/(label+'.json')).write_text(json.dumps(row,indent=2)+'\n')
    print(label,'cpu_ms',result['rusage']['user_ms']+result['rusage']['system_ms'],'xodb_cpu_ms',profiler_cpu,'switches',capture['scheduling']['recorded_events'] if capture else None,'timing',row.get('frame_work_excluding_start_us',result.get('latency_us')),flush=True)
(run/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print(run,flush=True)
