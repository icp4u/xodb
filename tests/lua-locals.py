#!/usr/bin/env python3
"""Named bindings through MCP agree with a cooperating Lua debug-API oracle."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
from types import SimpleNamespace
from client import Client
from helpers.readonly import audit

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',required=True)
p.add_argument('--library',required=True)
p.add_argument('--work',required=True,type=Path)
p.add_argument('--strace',action='store_true')
p.add_argument('--agent',type=Path)
a=p.parse_args()
root=Path(__file__).resolve().parents[1]
os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755)
exe=w/'host'
subprocess.run(['cc','-std=c11','-g','-O0','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror',
    '-I'+a.source,'tests/fixtures/lua/named.c',a.library,'-lm','-ldl','-o',str(exe)],check=True,timeout=90)
target=subprocess.Popen([str(exe)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
lines=queue.Queue()
def drain():
    for line in target.stdout:lines.put(line)
thread=threading.Thread(target=drain,daemon=True);thread.start()
client=None;result={'status':'running','checks':[]}
try:
    assert lines.get(timeout=10)=='ready\n'
    client=Client('control',None,options=[*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--attach',str(target.pid)])
    schema=next(x for x in client.call('tools/list')['result']['tools'] if x['name']=='get_language_locals')
    assert schema['annotations']['readOnlyHint'] and schema['annotations']['xodbSessionAccess']=='observer'
    source=root/'tests/fixtures/lua/named.c'
    line=next(i for i,text in enumerate(source.read_text().splitlines(),1) if 'NAMED_STOP' in text)
    client.action('set_breakpoint',file=str(source),line=line)
    client.action('continue');target.stdin.write('g');target.stdin.flush()
    previous_generation=None
    for stop in range(7):
        state=client.stopped('breakpoint');ground=json.loads(lines.get(timeout=10));generation=state['generation']
        regs=client.inspect('get_registers',tid=target.pid)
        stack=client.inspect('get_language_stack',tid=target.pid,language='lua')
        segment=next(i for i,s in enumerate(stack['segments']) if int(s['runtime_instance']['address'],16)==int(ground['state'],16))
        observed=[]
        for expected in ground['frames']:
            frame=expected['frame'];rows=[];start=0
            while True:
                page=client.inspect('get_language_locals',generation=generation,tid=target.pid,language='lua',segment=segment,frame=frame,start=start,limit=3)
                assert page['generation']==generation and page['diagnostic'] is None,page
                assert page['start']==start and len(page['rows'])<=3,page
                rows+=page['rows'];start+=len(page['rows'])
                if not page['truncated']:
                    assert len(rows)==page['total'];break
                assert len(page['rows']) and len(rows)<page['total']
            assert len(rows)==len(expected['bindings']),(rows,expected)
            for row,want in zip(rows,expected['bindings']):
                assert (row['scope'],row['ordinal'],row['name'])==(want['scope'],want['ordinal'],want['name']),(row,want)
                assert row['name_diagnostic'] is None,row
                assert row['address'] is None if row['scope']=='vararg' else row['address'],row
                if want['display'] is not None:assert row['value']['display']==want['display'],(row,want)
            # Runtime ground truth, with innermost local shadowing upvalues.
            wanted={}
            for binding in expected['bindings']:
                if binding['scope']=='vararg':continue
                if binding['scope']=='local' or binding['name'] not in wanted:wanted[binding['name']]=binding
            for name,want in wanted.items():
                found=client.inspect('evaluate_language_expression',generation=generation,tid=target.pid,language='lua',segment=segment,frame=frame,expression=name)
                assert found['diagnostic'] is None and len(found['rows'])==1,found
                row=found['rows'][0]
                assert (row['scope'],row['ordinal'],row['name'])==(want['scope'],want['ordinal'],name),(row,want)
                if want['display'] is not None:assert row['value']['display']==want['display'],(row,want)
            for text,why in [('absent_binding_xyz','LuaNameNotFound'),('probe()','LuaExpressionUnsupported'),('shadow+1','LuaExpressionUnsupported')]:
                found=client.inspect('evaluate_language_expression',generation=generation,tid=target.pid,language='lua',segment=segment,frame=frame,expression=text)
                assert not found['rows'] and found['diagnostic']==why,found
            observed.append({'frame':frame,'rows':rows})
        arguments=dict(generation=generation,tid=target.pid,language='lua',segment=segment,frame=ground['frames'][0]['frame'])
        def refusal(arguments, expected):
            reply=client.tool('get_language_locals',**arguments)
            if expected=='InvalidArguments':
                assert reply.get('error',{}).get('code')==-32602 and reply['error']['message']==expected,reply
            else:
                assert reply.get('result',{}).get('isError') and reply['result']['content'][0]['text']==expected,reply
        for change,expected in [(dict(limit=0),'InvalidArguments'),(dict(limit=33),'InvalidArguments'),
                                (dict(frame=63),'InvalidLanguageFrame'),(dict(segment=63),'InvalidLanguageSegment'),
                                (dict(generation=generation+1),'StaleSnapshot'),(dict(extra=True),'InvalidArguments')]:
            refusal(arguments|change,expected)
        refusal({k:v for k,v in arguments.items() if k!='generation'},'GenerationRequired')
        if previous_generation is not None:refusal(arguments|{'generation':previous_generation},'StaleSnapshot')
        if a.strace and stop==0:
            auditor=SimpleNamespace(p=SimpleNamespace(pid=client.collector_pid()),inspect=client.inspect,session=client.session)
            result['readonly']=audit(auditor,target.pid,w/'locals.strace',lambda:(client.inspect('get_language_locals',**arguments),client.inspect('evaluate_language_expression',**arguments,expression='shadow')))
        assert client.inspect('get_registers',tid=target.pid)==regs and client.session()['generation']==generation
        result['checks'].append({'ground':ground,'observed':observed,'generation':generation})
        previous_generation=generation;client.action('continue')
    target.wait(timeout=10);assert target.returncode==0,target.stderr.read()
    result['status']='pass'
finally:
    if client:
        result['transcript']=client.transcript
        client.close()
    if target.poll() is None:target.kill();target.wait()
    thread.join(timeout=5)
    (w/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Lua named MCP bindings: recursion, shadowing, closures, coroutines, pages and generation guards passed')
