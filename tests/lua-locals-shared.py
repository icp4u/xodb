#!/usr/bin/env python3
"""Lease-free named-local reads agree across real shared clients."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
from types import SimpleNamespace
from helpers.readonly import audit
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',required=True);p.add_argument('--library',required=True)
p.add_argument('--work',required=True,type=Path);p.add_argument('--agent',type=Path);p.add_argument('--strace',action='store_true');a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755);fixture=w/'host';source=root/'tests/fixtures/lua/named.c'
subprocess.run(['cc','-std=c11','-g','-O0','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror','-I'+a.source,str(source),a.library,'-lm','-ldl','-o',str(fixture)],check=True,timeout=90)
spec=importlib.util.spec_from_file_location('shared',root/'tests/shared-sessions.py');s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)
os.environ['XODB_LUA_NAMED_AUTO']='1'
if a.agent:os.environ['XODB_RUNTIME_AGENT']=str(a.agent.resolve())
server=s.Server(root,w,root/'zig-out/bin/xodb',fixture,'control',fixture_args=())
try:
    owner,observer=s.Client(server,'owner'),s.Client(server,'observer');owner.claim(ttl_ms=60000)
    initial=s.eventually(owner.session,lambda state:state['state']=='stopped','initial stop');server.remember_target(initial)
    line=next(i for i,text in enumerate(source.read_text().splitlines(),1) if 'NAMED_STOP' in text)
    owner.action('set_breakpoint',file=str(source),line=line);owner.action('continue')
    state=s.eventually(owner.session,lambda state:state['state']=='stopped' and any(t['reason']=='breakpoint' for t in state['threads']),'named stop')
    generation=state['generation'];tid=state['threads'][0]['tid'];args=dict(generation=generation,tid=tid,language='lua',segment=0,frame=1)
    tools={t['name']:t for t in observer.call('tools/list')['result']['tools']}
    for name in ('get_language_locals','evaluate_language_expression'):
        assert tools[name]['annotations']['readOnlyHint'] and tools[name]['annotations']['xodbSessionAccess']=='observer'
    s.expect_error(observer.raw('select_language_frame',**args),'ControlLeaseRequired')
    first=observer.tool('get_language_locals',**args);assert first==owner.tool('get_language_locals',**args)
    value=observer.tool('evaluate_language_expression',**args,expression='shadow');assert value==owner.tool('evaluate_language_expression',**args,expression='shadow');assert value['rows'][0]['value']['display'].endswith(' 100'),value
    report={'status':'pass','owner_observer_values_equal':True,'no_selection_lease':True}
    if a.strace:
        collector=server.proc.pid
        if a.agent:
            children=Path(f'/proc/{collector}/task/{collector}/children').read_text().split();assert len(children)==1;collector=int(children[0])
        adapter=SimpleNamespace(p=SimpleNamespace(pid=collector),inspect=observer.tool,session=observer.session)
        report['readonly']=audit(adapter,tid,w/'named.strace',lambda:(observer.tool('get_language_locals',**args),observer.tool('evaluate_language_expression',**args,expression='shadow')))
    s.expect_error(observer.raw('evaluate_language_expression',**(args|{'generation':generation+1}),expression='shadow'),'StaleSnapshot')
    owner.action('continue')
    second=s.eventually(owner.session,lambda state:state['generation']!=generation and state['state']=='stopped','next named stop')
    s.expect_error(observer.raw('get_language_locals',**args),'StaleSnapshot')
    owner.action('detach');(w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
finally:server.close()
print('Shared Lua locals: observer reads without lease, identity, stale generation and readonly audit passed')
