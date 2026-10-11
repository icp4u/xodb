#!/usr/bin/env python3
"""Periodic real torch profile: report named self samples at defaults and with
budget advice applied, and require names in libtorch_cpu once it is admitted.
No fixed percentage is an oracle. Optional when the selected Python lacks torch.
"""
import argparse, json, os, re, select, subprocess, time
from pathlib import Path
from client import Client
JOB = '''import torch
torch.set_num_threads(1)
a = torch.randn(64, 64)
print("ready", flush=True)
while True:
    for _ in range(2000): b = torch.tanh(a @ a + a).sum()
'''
def stats(pid):
    s=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
    return dict(cpu_ticks=int(s[11])+int(s[12]),rss_bytes=int(s[21])*os.sysconf('SC_PAGESIZE'),load=os.getloadavg(),cpus=os.cpu_count())
def run(options):
    target=subprocess.Popen([a.python,'-u','-c',JOB],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    c=None
    try:
        assert select.select([target.stdout],[],[],60)[0], 'torch readiness timeout'
        assert target.stdout.readline()=='ready\n',target.stderr.read()
        c=Client('control',None,options=['--attach',str(target.pid),*options],reply_seconds=90);s=c.stopped();before=stats(c.p.pid)
        cap=c.inspect('start_profile',generation=s['generation'],duration_ms=2000,frequency_hz=499,tids=[target.pid])['capture']
        history=cap['mapping_history'];c.action('continue');deadline=time.monotonic()+60
        while True:
            cap=c.inspect('get_profile')['capture']
            if cap['status']!='collecting':break
            assert time.monotonic()<deadline,cap
            time.sleep(.02)
        if c.session()['state']=='running':c.action('interrupt');c.stopped()
        rows=[];start=0;view=None
        while True:
            graph=c.inspect('get_flamegraph',capture_id=cap['id'],revision=cap['revision'],start=start,limit=64,**({'view_id':view} if view else {}))
            view=graph['view_id'];rows+=graph['nodes']
            if graph['next'] is None:break
            start=graph['next']
        totals={}
        for node in rows:
            if not node['self']:continue
            item=totals.setdefault(Path(node.get('module') or '?').name,dict(named=0,unnamed=0))
            item['named' if node['kind']=='code' else 'unnamed']+=node['self']
        total=sum(sum(x.values()) for x in totals.values());assert total,graph
        named=sum(x['named'] for x in totals.values())
        report=dict(options=options,named_self_percent=100*named/total,by_library=totals,images_not_searched=history['images_not_searched'],advice=history['image_budget'],before=before,after=stats(c.p.pid))
        print(json.dumps(report),flush=True)
        return report
    finally:
        if c and c.p.poll() is None:
            c.p.stdin.close()
            try:c.p.wait(timeout=10)
            except subprocess.TimeoutExpired:c.p.kill();c.p.wait()
        if target.poll() is None:target.kill()
        target.wait()
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--python',default=os.environ.get('XODB_TORCH_PYTHON','python3'));p.add_argument('--require',action='store_true');p.add_argument('--wrong-result',action='store_true');a=p.parse_args()
check=subprocess.run([a.python,'-c','import torch; print(torch.__version__)'],capture_output=True,text=True,timeout=60)
if check.returncode:
    if a.require:raise AssertionError(check.stderr)
    print('SKIP: selected Python has no torch');raise SystemExit(77)
print(json.dumps({'torch':check.stdout.strip()}))
first=run([])
options={}
for attempt in range(4):
    torch_row=first['by_library'].get('libtorch_cpu.so',{})
    if torch_row.get('named',0)>0 and first['images_not_searched']==0:break
    match=re.search(r'--image-total-limit (\d+G)',first['advice'] or '')
    assert match,first
    options['--image-total-limit']=match.group(1)
    first=run([v for pair in options.items() for v in pair])
else:raise AssertionError('budget advice did not admit torch images')
assert first['by_library'].get('wrong_library' if a.wrong_result else 'libtorch_cpu.so',{}).get('named',0)>0,first
print('torch image budget: pass')
