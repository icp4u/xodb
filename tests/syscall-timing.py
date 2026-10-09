#!/usr/bin/env python3
"""Owned syscall captures, boundaries, bounded detail and scheduling evidence."""
from datetime import datetime
from pathlib import Path
import argparse, json, os, signal, subprocess, time
from client import Client
root = Path(__file__).resolve().parents[1]
os.chdir(root)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--perf', action='store_true', help='record status latency and resource costs; no speed gate')
parser.add_argument('--work', type=Path)
args = parser.parse_args()
os.umask(0o022)
work = args.work or Path('.work') / ('syscall-timing-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
measurements = []
def resources(client):
    pids = {'frontend': client.p.pid}
    if client.runtime_agent: pids['agent'] = client.collector_pid()
    processes = {}
    for name, pid in pids.items():
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
        processes[name] = dict(cpu_seconds=(int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK'),
                               rss_kib=int(fields[21]) * os.sysconf('SC_PAGE_SIZE') // 1024)
    return dict(processes=processes, load=os.getloadavg(), allowed_cpus=len(os.sched_getaffinity(0)))
(work/'tmp').mkdir(parents=True)
subprocess.run(['cc','-g','-O0','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror','tests/fixtures/syscall-timing.c','-o',str(work/'fixture')], env=dict(os.environ,TMPDIR=str((work/'tmp').resolve())),check=True)
def perf_fds(client):
    out=[]
    for p in Path(f'/proc/{client.collector_pid()}/fd').iterdir():
        try:
            if 'perf_event' in os.readlink(p):out.append(p.name)
        except FileNotFoundError: pass
    return out

def archive_ready(client):
    deadline=time.monotonic()+20
    while True:
        state=client.inspect('get_archive_status')
        if state['job'] and state['job']['done']:
            assert state['job']['error_name'] is None,state
            return
        assert time.monotonic()<deadline,state
        time.sleep(.005)

def rows(client, cap, **filters):
    out=[];start=0
    while True:
        data=client.inspect('get_profile_syscalls',capture_id=cap['id'],revision=cap['revision'],start=start,limit=128,**filters)
        out.extend(data['rows'])
        if data['next'] is None:break
        start=data['next']
    assert len(out)==data['total']
    return out

for mode,limit in [('wait',16384),('sustained',65536),('burst',256),('exit',16384),('exec',16384),('loss',4096)]:
    c=Client('control',str(work/'fixture'),args=['burst' if mode=='loss' else mode])
    try:
        ready=c.action('set_breakpoint',symbol='profile_ready')['id']
        c.action('set_breakpoint',symbol='profile_done')
        c.action('continue');state=c.stopped('breakpoint')
        c.action('remove_breakpoint',id=ready)
        refused=c.tool('start_profile',generation=c.session()['generation'],syscall_timing=True)
        assert refused['result']['content'][0]['text']=='SyscallRequiresExplicitThreads',refused
        assert not perf_fds(c)
        cap=c.action('start_profile',tids=[state['pid']],syscall_timing=True,syscall_limit=limit,context_switch=True,duration_ms=10000)['capture']
        assert len(perf_fds(c))==3,perf_fds(c)
        before = resources(c) if args.perf else None
        c.action('continue')
        if mode=='loss':
            # Stop only this test-owned collector while its own fixture fills the ring.
            os.kill(c.p.pid,signal.SIGSTOP)
            try: time.sleep(.12)
            finally: os.kill(c.p.pid,signal.SIGCONT)
        latencies=[];loads=[];deadline=time.monotonic()+15
        while True:
            then=time.monotonic();state=c.session();latencies.append(time.monotonic()-then)
            if args.perf: loads.append(os.getloadavg())
            cap=c.inspect('get_profile')['capture']
            if state['state'] in ('stopped','exited'):break
            assert time.monotonic()<deadline,state
            time.sleep(.002)
        if cap['status']=='collecting':cap=c.action('stop_profile',capture_id=cap['id'])['capture']
        assert not perf_fds(c)
        after = resources(c) if args.perf else None
        detail=rows(c,cap)
        assert cap['syscalls']['enabled'] and cap['syscalls']['finished'] and detail,cap
        assert not cap['syscalls']['invalid'],cap
        assert cap['status'] in ('manual','syscall_limit','target_ended','image_changed','mappings_changed'),cap
        if mode=='wait':
            reads=[r for r in detail if r['name']=='read' and r['result']==-9]
            sleeps=[r for r in detail if r['name']=='clock_nanosleep' and r['elapsed_ns'] is not None]
            assert reads and reads[0]['return_class']=='errno',detail
            assert len(sleeps)==3 and all(r['elapsed_ns']>=45000000 for r in sleeps),sleeps
            assert any(r['scheduling_overlap']['off_cpu_ns']>40000000 for r in sleeps),sleeps
        if mode=='sustained':
            assert cap['status']=='manual',cap
            calls=[r for r in detail if r['name']=='getpid' and r['reason']=='complete']
            assert len(calls)==19200,(len(calls),cap)
        if mode=='burst':
            assert cap['status']=='syscall_limit' and len(detail)==limit,cap
            assert cap['syscalls']['unread_possible'],cap
        if mode=='loss': assert cap['syscalls']['lost']>0,cap
        if mode=='exec':
            assert cap['status'] in ('image_changed','mappings_changed'),cap
            assert any(r['name']=='execve' and r['elapsed_ns'] is None for r in detail),detail
        if mode=='exit': assert any(r['name']=='exit_group' and r['elapsed_ns'] is None for r in detail),detail
        for r in detail:
            if r['elapsed_ns'] is not None:
                assert r['elapsed_ns']==sum(r['scheduling_overlap'].values()),r
                assert r['reason']=='complete'
            else: assert r['scheduling_overlap'] is None,r
        if mode in ('wait','sustained','burst'):
            archive=work/(mode+'.xcap')
            c.action('save_capture_archive',capture_id=cap['id'],revision=cap['revision'],path=str(archive))
            archive_ready(c)
            offline=Client('observe',None,options=['--open-capture',str(archive)])
            try:
                archive_ready(offline)
                saved=offline.inspect('get_profile')['capture']
                assert saved['syscalls']==cap['syscalls'],(saved['syscalls'],cap['syscalls'])
                assert rows(offline,saved)==detail
            finally:offline.close()
        if args.perf:
            overloaded = any(max(load) > before['allowed_cpus'] for load in [before['load'], *loads, after['load']])
            measurements.append(dict(mode=mode, status='not-measurable' if overloaded else 'measured',
                reason='host load exceeds allowed CPU count' if overloaded else None,
                phase='active capture before continue through stop/drain; includes target execution, transport and harness',
                before=before, after=after, load_samples=loads, status_seconds=latencies,
                max_status_seconds=max(latencies), reference_seconds=.25,
                within_reference=None if overloaded else max(latencies)<.25))
        (work/f'{mode}.json').write_text(json.dumps(dict(capture=cap,rows=detail,max_status_ms=1000*max(latencies)),indent=2)+'\n')
        print(mode,cap['status'],'spans',len(detail),'lost',cap['syscalls']['lost'],'max_status_ms',round(1000*max(latencies),2),flush=True)
    finally:
        (work/f'{mode}-transcript.json').write_text(json.dumps(c.transcript,indent=2)+'\n')
        c.close()
if args.perf:
    report = dict(status='not-measurable' if any(row['status']=='not-measurable' for row in measurements) else 'measured',
                  cases=measurements, reference='historical 250 ms status-query reference, evidence only',
                  cpu_resolution_note='A zero CPU delta is below procfs accounting resolution, not zero overhead.')
    (work/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(work)
