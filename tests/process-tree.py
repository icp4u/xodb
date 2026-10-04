#!/usr/bin/env python3
"""Process routing and scoped controls against owned fork/vfork fixtures."""
from datetime import datetime
import json, os, subprocess, time
from pathlib import Path
from client import Client
root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('process-tree-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir()
fixture = os.environ.get('XODB_PROCESS_FIXTURE', str(root / 'zig-out/bin/xodb-process-fixture'))
def check_error(c, name, expected, **args):
    value = c.tool(name, **args)
    assert value['result']['isError'] and value['result']['content'][0]['text'] == expected, value
def wait(c, predicate):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        value = c.inspect('get_processes')
        if predicate(value): return value
        time.sleep(.003)
    raise AssertionError(value)
def snap(c, process=1): return c.inspect('get_session', process_id=process)
def action(c, name, process=1, **args):
    return c.inspect(name, process_id=process, generation=snap(c,process)['generation'], **args)
def stopped(c, process, reason=None):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        s = snap(c, process)
        if s['state'] == 'stopped' and (reason is None or any(t['reason']==reason for t in s['threads'])): return s
        assert s['state'] != 'exited', s
        time.sleep(.003)
    raise AssertionError(s)
def finish(c):
    deadline = time.monotonic()+8
    while time.monotonic()<deadline:
        tree=c.inspect('get_processes')
        if all(p['state']=='exited' for p in tree['processes']): return tree
        for p in reversed(tree['processes']):
            if p['state']=='stopped':
                result=c.tool('continue',process_id=p['process_id'],generation=p['generation'])
                if result['result']['isError']:
                    assert result['result']['content'][0]['text'] in ('VforkParentBlocked','StaleSnapshot'),result
        time.sleep(.003)
    raise AssertionError(tree)
for mode in ('fork','vfork-exec','vfork-detach','limit','clone-vm','owned-close'):
    c=Client('control',fixture,args=('fork' if mode in ('limit','owned-close') else mode,),options=('--follow-forks','--process-limit','1' if mode=='limit' else '32','--break','tree_ready'))
    try:
        action(c,'continue'); stopped(c,1,'breakpoint')
        probe=action(c,'set_breakpoint',symbol='tree_child')['id']
        action(c,'configure_breakpoint',id=probe,condition='tree_value == 0',ignore_count=0)
        original=snap(c)
        action(c,'continue')
        if mode in ('fork','vfork-exec','vfork-detach','owned-close'):
            tree=wait(c,lambda t:t['total']==2)
            child=tree['processes'][1]
            assert child['parent_process_id']==1 and child['following'],tree
            assert child['state']=='stopped',tree
            assert tree['default_process_id']==1 and snap(c)['process_id']==1
            check_error(c,'get_session','UnknownProcess',process_id=99)
            check_error(c,'continue','StaleSnapshot',process_id=1,generation=original['generation'])
            if mode=='owned-close': continue
            if mode=='vfork-detach':
                action(c,'detach_process_family',2)
                assert snap(c)['state']=='idle' and snap(c,2)['state']=='idle'
                continue
            if mode=='vfork-exec':
                assert child['shared_vm'],child
                check_error(c,'continue','VforkParentBlocked',generation=snap(c)['generation'])
            action(c,'continue',2)
            cs=stopped(c,2,'breakpoint')
            assert cs['process_id']==2 and cs['pid']==child['pid']
            value=c.inspect('evaluate_expression',process_id=2,tid=child['pid'],expression='tree_value')
            assert value['value']['display']=='0',value
            frames=c.inspect('get_stack',process_id=2,tid=child['pid'])
            assert frames['process_id']==2,frames
            finish(c)
            if mode=='vfork-exec':
                child=wait(c,lambda t:t['processes'][1]['state']=='exited')['processes'][1]
                assert not child['shared_vm'] and child['image_epoch']>1,child
        elif mode=='limit':
            tree=wait(c,lambda t:t['processes'][0]['admission_error']=='ProcessLimit')
            assert tree['total']==1 and tree['processes'][0]['pending_count']==1,tree
            # Idempotent following can raise the global limit while a birth is held.
            action(c,'set_process_following',enabled=True,process_limit=2)
            tree=wait(c,lambda t:t['total']==2)
            assert tree['process_limit']==2
            finish(c)
        else:
            tree=wait(c,lambda t:t['processes'][0]['admission_error'] is not None)
            assert tree['processes'][0]['admission_error']=='SharedCloneRequiresCoordination',tree
            action(c,'detach_process_family')
            assert snap(c)['state']=='idle'
    finally:
        c.close()
        (run/(mode+'.json')).write_text(json.dumps(c.transcript,indent=2))
        (run/(mode+'.stderr')).write_bytes(c.p.stderr.read())
# Following off still holds the child before inherited traps can execute.
# Enable following at that stop, then release both through ordinary controls.
c=Client('control',fixture,options=('--break','tree_ready'))
try:
    action(c,'continue');stopped(c,1,'breakpoint')
    action(c,'set_breakpoint',symbol='tree_child')
    action(c,'continue')
    tree=wait(c,lambda t:t['processes'][0]['admission_error']=='ProcessFollowingDisabled')
    assert tree['total']==1 and tree['processes'][0]['pending_count']==1,tree
    assert snap(c)['state']=='stopped'
    action(c,'set_process_following',enabled=True)
    wait(c,lambda t:t['total']==2)
    action(c,'continue',2);stopped(c,2,'breakpoint')
    finish(c)
finally:
    c.close()
    (run/'following-off.json').write_text(json.dumps(c.transcript,indent=2))
    (run/'following-off.stderr').write_bytes(c.p.stderr.read())
# Both worker threads can fork before their parent is quiescent. Resume the
# parent when needed, preserving each child at its inherited breakpoint.
workers=run/'workers'
subprocess.run(['cc','-g','-O0','-pthread','-fno-omit-frame-pointer','tests/fixtures/process-workers.c','-o',str(workers)],check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
c=Client('control',str(workers),options=('--follow-forks','--break','tree_ready'))
try:
    action(c,'continue');stopped(c,1,'breakpoint')
    action(c,'set_breakpoint',symbol='tree_child')
    action(c,'continue')
    deadline=time.monotonic()+8
    while True:
        tree=c.inspect('get_processes')
        if tree['total']==3:break
        assert time.monotonic()<deadline,tree
        parent=tree['processes'][0]
        if parent['state']=='stopped' and not parent['pending_count']:action(c,'continue')
        time.sleep(.003)
    assert all(p['parent_process_id']==1 for p in tree['processes'][1:]),tree
    for child in tree['processes'][1:]:
        action(c,'continue',child['process_id'])
        stopped(c,child['process_id'],'breakpoint')
        value=c.inspect('evaluate_expression',process_id=child['process_id'],tid=child['pid'],expression='tree_value')
        assert value['value']['display']=='0',value
    finish(c)
finally:
    c.close()
    (run/'workers.json').write_text(json.dumps(c.transcript,indent=2))
    (run/'workers.stderr').write_bytes(c.p.stderr.read())
# Observe cannot change following or detach; readonly pages remain available.
c=Client('observe',fixture)
try:
    generation=snap(c)['generation']
    for name,extra in [('set_process_following',{'enabled':True}),('retry_process_admission',{}),('detach_process_family',{})]:
        check_error(c,name,'AgentScopeDenied',generation=generation,**extra)
    assert c.inspect('get_processes')['total']==1
finally:c.close()
print('Process-tree MCP: fork, vfork/exec, policy inheritance, scope, limits, explicit detach, owned cleanup:',run.relative_to(root))
