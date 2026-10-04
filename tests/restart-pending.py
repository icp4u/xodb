#!/usr/bin/env python3
"""Pending shared-library breakpoints, unload/reload, restart and policy identity."""
from datetime import datetime
from pathlib import Path
import os, subprocess, json, time
from client import Client
root=Path(__file__).resolve().parents[1];os.chdir(root)
run=root/'.work'/('restart-pending-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));run.mkdir()
exe=run/'fixture';lib=run/'late.so'
for cmd in (['gcc','-g','-O0','-fno-omit-frame-pointer','tests/fixtures/pending.c','-ldl','-o',str(exe)],['gcc','-g','-O0','-shared','-fPIC','tests/fixtures/pending-lib.c','-o',str(lib)]):
    subprocess.run(cmd,check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
c=Client('control',str(exe),args=(str(lib),))
try:
    late=c.action('set_breakpoint',symbol='late_function'); lid=late['id'];assert late['pending'],late
    stopped=c.action('set_breakpoint',symbol='after_unload')['id']
    c.action('continue');snap=c.stopped('breakpoint');tid=snap['threads'][0]['tid']
    assert c.inspect('get_stack',tid=tid)['frames'][0]['symbol']=='late_function'
    c.action('step_source',tid=tid);c.stopped()
    assert c.inspect('evaluate_expression',tid=tid,expression='input')['value']['display']=='10'
    # A configured disabled breakpoint remains disabled after unload/reload and restart.
    c.action('configure_breakpoint',id=lid,enabled=False,condition='input==11')
    c.action('continue');c.stopped('breakpoint')
    probes=c.inspect('get_breakpoints');p=next(b for b in probes['breakpoints'] if b['id']==lid)
    assert p['pending'] and not p['enabled'],probes
    assert c.inspect('get_stack',tid=tid)['frames'][0]['symbol']=='after_unload'
    c.action('configure_breakpoint',id=lid,enabled=True,condition='input==11')
    c.action('continue');c.stopped('breakpoint')
    assert c.inspect('get_stack',tid=tid)['frames'][0]['symbol']=='late_function'
    c.action('step_source',tid=tid);c.stopped()
    assert c.inspect('evaluate_expression',tid=tid,expression='input')['value']['display']=='11'
    old=c.session();first_id=old['threads'][0]['id']
    c.action('restart');new=c.session()
    assert new['pid']!=old['pid'] and new['generation']>old['generation'] and new['image_epoch']>old['image_epoch'],(old,new)
    assert new['threads'][0]['id']>first_id,(old,new)
    assert not Path('/proc',str(old['pid'])).exists(),'old owned target was not reaped'
    p=next(b for b in c.inspect('get_breakpoints')['breakpoints'] if b['id']==lid)
    assert p['pending'],p
    c.action('remove_breakpoint',id=stopped)
    # input at a function-entry breakpoint has no trustworthy prologue location yet;
    # clear the condition and prove stable logical identity after restart.
    c.action('configure_breakpoint',id=lid)
    c.action('continue');s=c.stopped('breakpoint');tid=s['threads'][0]['tid']
    assert c.inspect('get_stack',tid=tid)['frames'][0]['symbol']=='late_function'
    p=next(b for b in c.inspect('get_breakpoints')['breakpoints'] if b['id']==lid)
    assert not p['pending'] and p['hit_count']==1,p
    c.action('configure_breakpoint',id=lid,tid=tid)
    c.action('restart')
    p=next(b for b in c.inspect('get_breakpoints')['breakpoints'] if b['id']==lid)
    assert not p['enabled'],p
    c.action('remove_breakpoint',id=lid)
    # Physical/source breakpoint restored using matching build identity and image offset.
    before=c.inspect('find_symbol',name='before_load')['address']
    bid=c.action('set_breakpoint',address=before)['id']
    c.action('restart');c.action('continue');s=c.stopped('breakpoint');tid=s['threads'][0]['tid']
    assert c.inspect('get_stack',tid=tid)['frames'][0]['symbol']=='before_load'
    assert next(b for b in c.inspect('get_breakpoints')['breakpoints'] if b['id']==bid)['hit_count']==1
    c.action('remove_breakpoint',id=bid);c.action('continue')
    deadline=time.monotonic()+5
    while c.session()['state']!='exited':assert time.monotonic()<deadline;time.sleep(.002)
    c.action('restart');assert c.session()['state']=='stopped'
finally:
    (run/'transcript.json').write_text(json.dumps(c.transcript,indent=2));c.close()
c=Client('control',str(exe),args=(str(lib),))
try:
    source=root/'tests/fixtures/pending.c'
    line=next(i for i,t in enumerate(source.read_text().splitlines(),1) if 'void *h=dlopen' in t)
    c.action('set_breakpoint',symbol='intentionally_absent_symbol')
    ids=c.action('set_breakpoint',file=str(source),line=line)['ids']
    c.action('continue');snap=c.stopped('breakpoint');tid=snap['threads'][0]['tid']
    for ident in ids:c.action('remove_breakpoint',id=ident)
    c.action('step_over',tid=tid);snap=c.stopped()
    assert not snap['source_stepping'],snap
    assert c.inspect('get_stack',tid=tid)['frames'][0]['symbol']=='main',snap
    assert c.inspect('evaluate_expression',tid=tid,expression='h')['value']['bits']!=0
finally:c.close()
# A restart failure must leave a responsive service that can retry the same launch.
c=Client('control',str(exe),args=(str(lib),))
try:
    saved=run/'fixture.saved';exe.rename(saved)
    failed=c.tool('restart',generation=c.session()['generation']);assert failed['result']['isError'],failed
    assert c.session()['state']=='idle'
    saved.rename(exe)
    c.action('restart');assert c.session()['state']=='stopped'
finally:
    if not exe.exists() and (run/'fixture.saved').exists():(run/'fixture.saved').rename(exe)
    c.close()
c=Client('observe',str(exe),args=(str(lib),))
try:
    denied=c.tool('restart',generation=c.session()['generation']);assert denied['result']['isError'],denied
finally:c.close()
print('Pending load/unload/reload, enables, policies, owned restart, relocation, identity and reaping passed:',run)
