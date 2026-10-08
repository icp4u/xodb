#!/usr/bin/env python3
"""Hidden state-changing tools must be denied when called directly over stdio."""
import argparse,importlib.util,json,os,time
from pathlib import Path
from client import Client

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True)
p.add_argument('--agent',type=Path)
a=p.parse_args();os.umask(0o022)
root=Path(__file__).resolve().parents[1];os.chdir(root)
a.work=a.work.resolve();a.work.mkdir(parents=True,mode=0o755)
if a.agent:os.environ['XODB_RUNTIME_AGENT']=str(a.agent.resolve())
else:os.environ.pop('XODB_RUNTIME_AGENT',None)
report={'status':'running','calls':[]};failures=[]

def error(reply):
    if 'error' in reply:return reply['error']['message']
    result=reply['result']
    return result['content'][0]['text'] if result.get('isError') else None

def stable(c):
    end=time.monotonic()+30
    while True:
        state=c.session()
        if not state['symbol_discovery_pending'] and not state['continue_pending']:return state
        assert time.monotonic()<end,state
        time.sleep(.01)

def close(c,label):
    c.close()
    (a.work/(label+'.stderr')).write_bytes(c.p.stderr.read())
    (a.work/(label+'.rpc.json')).write_text(json.dumps(c.transcript,indent=2)+'\n')

try:
    catalog=Client('mutate')
    try:
        definitions=catalog.call('tools/list')['result']['tools']
        changing=[d for d in definitions if not d['annotations']['readOnlyHint']]
        assert {'add_language_watch','remove_language_watch','write_memory','write_register'} <= {d['name'] for d in changing}
        assert all(d['annotations']['xodbSessionAccess'] in ('controller','mutator') for d in changing)
        report['definitions']=changing
        shared_restricted=[d for d in definitions if d['annotations']['xodbSessionAccess'] in ('controller','mutator')]
        report['shared_definitions']=shared_restricted
    finally:close(catalog,'catalog')
    for scope in ('observe','control'):
        c=Client(scope)
        try:
            state=stable(c);tid=state['pid'];registers=c.inspect('get_registers',tid=tid)
            listed={d['name'] for d in c.call('tools/list')['result']['tools']}
            denied=[d for d in changing if scope=='observe' or d['annotations']['xodbSessionAccess']=='mutator']
            assert all(d['name'] not in listed for d in denied)
            audit=c.inspect('get_audit');watches=c.inspect('get_language_watches')
            for definition in denied:
                name=definition['name']
                # Missing fields must not reach a hidden handler either.
                calls=[{}]
                if name=='add_language_watch':calls.append(dict(generation=state['generation'],language='lua',tid=tid,segment=0,frame=0,expression='x'))
                elif name=='remove_language_watch':calls.append(dict(generation=state['generation'],id=1))
                elif name in ('cancel_debug_metadata','retry_debug_metadata'):calls.append(dict(id=1))
                elif name=='write_memory':calls.append(dict(generation=state['generation'],address='0x0',hex='00'))
                elif name=='write_register':calls.append(dict(generation=state['generation'],tid=tid,name='rip',value='0x0'))
                for arguments in calls:
                    reply=c.tool(name,**arguments);why=error(reply)
                    report['calls'].append(dict(scope=scope,name=name,arguments=arguments,error=why))
                    if why!='AgentScopeDenied':failures.append((scope,name,why))
            after=c.session()
            for key in ('session_id','generation','pid','state'):assert after[key]==state[key],(key,state,after)
            assert c.inspect('get_registers',tid=tid)==registers
            assert c.inspect('get_audit')==audit
            assert c.inspect('get_language_watches')==watches
            assert error(c.tool('not_a_tool'))=='UnknownTool'
            if scope=='observe':
                # Private, target-read-only retained jobs keep their stdio access.
                job=c.action('start_inspection',tid=tid,registers=True,stack=False)
                c.inspect('cancel_inspection',id=job['id'])
                c.inspect('release_inspection',id=job['id'])
            if scope=='control':
                # The gate is not a blanket denial of all non-read-only tools.
                bp=c.action('set_breakpoint',symbol='main')['id']
                c.action('remove_breakpoint',id=bp)
        finally:close(c,scope)
    spec=importlib.util.spec_from_file_location('shared_scope',root/'tests/shared-sessions.py')
    shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)
    binary=Path(os.environ.get('XODB_BIN',root/'zig-out/bin/xodb')).resolve()
    # Same catalog, direct calls from an observer before and after another
    # client claims control. Both global scope and client lease must hold.
    for scope in ('observe','control','mutate'):
        server=shared.Server(root,a.work,binary,root/'zig-out/bin/xodb-m1-fixture',scope)
        try:
            observer=shared.Client(server,'observer');owner=shared.Client(server,'owner')
            state=stable(observer);server.remember_target(state)
            before=observer.tool('get_registers',tid=state['pid']);audit=observer.tool('get_audit')
            for phase in ('unclaimed','claimed') if scope!='observe' else ('unclaimed',):
                if phase=='claimed':owner.claim()
                listed=shared.listed_tools(observer)
                for definition in shared_restricted:
                    name=definition['name'];assert name not in listed
                    reply=observer.raw(name);why=error(reply)
                    report['calls'].append(dict(transport='shared',scope=scope,phase=phase,name=name,error=why))
                    if why not in ('AgentScopeDenied','ControlLeaseRequired'):failures.append(('shared',scope,phase,name,why))
            after=observer.session()
            for key in ('session_id','generation','pid','state'):assert after[key]==state[key],(key,state,after)
            assert observer.tool('get_registers',tid=state['pid'])==before
            assert observer.tool('get_audit')==audit
            assert observer.tool('get_language_watches')['watches']==[]
            server.stop_and_check()
        finally:server.close()
    report['failures']=failures
    assert not failures,failures
    report['status']='pass'
finally:
    if report['status']!='pass':report['status']='failed'
    report['failures']=failures
    (a.work/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print('Every hidden non-read-only tool is scope-denied before dispatch; observer state unchanged and control still works')
