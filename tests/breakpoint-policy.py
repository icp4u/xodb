#!/usr/bin/env python3
"""Real breakpoint policy, failure stops, bounded logs and scope checks."""
from datetime import datetime
import os
from pathlib import Path
import subprocess
from client import Client
root=Path(__file__).resolve().parents[1]
os.chdir(root)
run=root/'.work'/('breakpoint-policy-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir(parents=True)
source=root/'tests/fixtures/breakpoint-policy.c'
binary=run/'fixture'
subprocess.run(['gcc','-pthread','-g','-O0','-fno-omit-frame-pointer',str(source),'-o',str(binary)],check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
line=next(i for i,s in enumerate(source.read_text().splitlines(),1) if 'POLICY_STOP' in s)
c=Client('control',str(binary))
try:
    ids=c.action('set_breakpoint',file=str(source),line=line)['ids']
    b=ids[0]
    for extra in ids[1:]: c.action('remove_breakpoint',id=extra)
    c.action('configure_breakpoint',id=b,condition='n == 5')
    c.action('continue')
    tid=c.stopped('breakpoint')['threads'][0]['tid']
    assert c.inspect('evaluate_expression',tid=tid,expression='n')['value']['display']=='5'
    assert c.inspect('get_breakpoints')['breakpoints'][0]['hit_count']==6
    c.action('configure_breakpoint',id=b,condition='missing_variable')
    c.action('continue')
    c.stopped('breakpoint')
    policy=next(p for p in c.inspect('get_breakpoints')['policies'] if p['id']==b)
    assert policy['last_error']=='UnknownVariable',policy
    assert c.inspect('evaluate_expression',tid=tid,expression='n')['value']['display']=='6'
    c.action('configure_breakpoint',id=b,ignore_count=3,tid=tid)
    c.action('continue')
    c.stopped('breakpoint')
    assert c.inspect('evaluate_expression',tid=tid,expression='n')['value']['display']=='10'
    c.action('configure_breakpoint',id=b,enabled=False)
    assert not c.inspect('get_breakpoints')['breakpoints'][0]['enabled']
    c.action('configure_breakpoint',id=b,mode='log',log_expression='n')
    end=c.action('set_breakpoint',symbol='policy_done')['id']
    c.action('continue')
    c.stopped('breakpoint')
    logs=[]
    after=0
    while True:
        page=c.inspect('get_breakpoint_logs',after=after,limit=64)
        logs.extend(page['records'])
        if not page['has_more']: break
        after=logs[-1]['sequence']
    assert len(logs)==256 and page['dropped']==33,(len(logs),page['dropped'])
    assert logs[0]['display']=='44' and logs[-1]['display']=='299',logs[-1]
    assert all(x['tid']==tid and x['breakpoint_id']==b for x in logs)
    assert c.inspect('evaluate_expression',tid=tid,expression='result')['value']['display']=='44850'
    c.action('remove_breakpoint',id=b)
    c.action('remove_breakpoint',id=end)
finally: c.close()
c=Client('observe',str(binary))
try:
    result=c.tool('configure_breakpoint',id=1,generation=c.session()['generation'])
    assert result['result']['isError'] and result['result']['content'][0]['text']=='AgentScopeDenied'
finally: c.close()
c=Client('control',str(binary),args=('threads',))
try:
    ready=c.action('set_breakpoint',symbol='threads_ready')['id']
    c.action('continue')
    snap=c.stopped('breakpoint');tid=snap['pid']
    assert len(snap['threads'])==2,snap
    c.action('remove_breakpoint',id=ready)
    event=c.action('set_breakpoint',symbol='policy_event')['id']
    c.action('configure_breakpoint',id=event,tid=tid,ignore_count=1,mode='log',log_expression='$rdi')
    c.action('set_breakpoint',symbol='policy_done')
    c.action('continue');c.stopped('breakpoint')
    logs=c.inspect('get_breakpoint_logs')['records']
    assert [int(x['bits']) for x in logs]==[101,102,103],logs
    assert all(x['tid']==tid for x in logs),logs
    probe=next(p for p in c.inspect('get_breakpoints')['breakpoints'] if p['id']==event)
    assert probe['hit_count']==8,probe
finally:c.close()
print('Breakpoint conditions, ignore counts, error stops, toggles, bounded log history, thread filters and scope passed:',run)
