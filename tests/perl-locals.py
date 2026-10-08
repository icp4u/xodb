#!/usr/bin/env python3
"""Stopped Perl named bindings agree with an owned PadWalker oracle."""
import argparse
import json
import os
from pathlib import Path
import queue
import shlex
import subprocess
import threading
from types import SimpleNamespace
from client import Client
from helpers.readonly import audit

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--perl',required=True)
p.add_argument('--padwalker',required=True,type=Path)
p.add_argument('--work',required=True,type=Path)
p.add_argument('--strace',action='store_true')
p.add_argument('--agent',type=Path)
a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755)
config=json.loads(subprocess.check_output([a.perl,'-MConfig','-MJSON::PP','-e','print JSON::PP::encode_json({map {$_=>$Config{$_}} qw(archlib cc ccflags)})'],timeout=30))
source=root/'tests/fixtures/perl/named.c';shared=w/'named.so'
subprocess.run([*shlex.split(config['cc']),*shlex.split(config['ccflags']),'-U_FORTIFY_SOURCE','-shared','-fPIC','-g3','-O0','-fno-omit-frame-pointer','-I'+config['archlib']+'/CORE',str(source),'-o',str(shared)],check=True,timeout=90)
env=dict(os.environ,PERL5LIB=str(a.padwalker.resolve()/'blib/lib')+':'+str(a.padwalker.resolve()/'blib/arch'),XODB_PERL_NAMED_READY='1',XODB_PERL_NAMED_EXPORT='1')
target=subprocess.Popen([a.perl,str(root/'tests/fixtures/perl/named.pl'),str(shared)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
lines=queue.Queue()
def drain():
    for line in target.stdout:lines.put(line)
thread=threading.Thread(target=drain,daemon=True);thread.start()
client=None;result={'status':'running','checks':[]}
try:
    assert lines.get(timeout=10)=='ready\n'
    client=Client('control',None,options=[*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--attach',str(target.pid)])
    tools={x['name']:x for x in client.call('tools/list')['result']['tools']}
    for name in ('get_language_locals','evaluate_language_expression'):
        assert tools[name]['annotations']['readOnlyHint'] and tools[name]['annotations']['xodbSessionAccess']=='observer'
    line=next(i for i,text in enumerate(source.read_text().splitlines(),1) if 'NAMED_STOP' in text)
    client.action('set_breakpoint',file=str(source),line=line)
    client.action('continue');target.stdin.write('go\n');target.stdin.flush()
    previous_generation=None;bindings=0
    for stop in range(9):
        state=client.stopped('breakpoint');ground=json.loads(lines.get(timeout=10));generation=state['generation'];tid=target.pid
        regs=client.inspect('get_registers',tid=tid)
        stack=client.inspect('get_language_stack',tid=tid,language='perl')
        assert len(stack['segments'])==1,stack
        segment=stack['segments'][0]
        assert len(segment['frames'])==len(ground['frames']),(segment,ground)
        observed=[]
        for frame,expected in enumerate(ground['frames']):
            arguments=dict(generation=generation,tid=tid,language='perl',segment=0,frame=frame)
            rows=[];start=0
            while True:
                page=client.inspect('get_language_locals',**arguments,start=start,limit=3)
                assert page['generation']==generation and page['diagnostic'] is None,page
                assert page['start']==start and len(page['rows'])<=3,page
                rows+=page['rows'];start+=len(page['rows'])
                if not page['truncated']:
                    assert len(rows)==page['total'];break
                assert page['rows'] and len(rows)<page['total']
            wanted={row['name']:row for row in expected['bindings']}
            assert len(rows)==len(wanted),(rows,wanted)
            for row in rows:
                want=wanted[row['name']]
                assert row['name_diagnostic'] is None and row['address']==want['address'] and row['slot_address'],(row,want)
                if want['display'] is not None:assert row['value']['display']==want['display'],(row,want)
                found=client.inspect('evaluate_language_expression',**arguments,expression=row['name'])
                assert found['diagnostic'] is None and found['rows']==[row],(found,row)
                bindings+=1
            for expression,why in [('$absent_binding_xyz','PerlOuterScopeUnread'),('$n+1','UnsupportedPerlExpression'),('system()','UnsupportedPerlExpression'),('$n[0]','UnsupportedPerlExpression')]:
                found=client.inspect('evaluate_language_expression',**arguments,expression=expression)
                assert not found['rows'] and found['diagnostic']==why,found
            if stop==3 and frame==0:
                package=client.inspect('evaluate_language_expression',**arguments,expression='$masked')
                assert package['diagnostic']=='PerlPackageVariableUnread' and not package['rows'],package
            observed.append({'frame':frame,'rows':rows})
        arguments=dict(generation=generation,tid=tid,language='perl',segment=0,frame=0)
        def refusal(args,why):
            reply=client.tool('get_language_locals',**args)
            if why=='InvalidArguments':assert reply.get('error',{}).get('code')==-32602 and reply['error']['message']==why,reply
            else:assert reply.get('result',{}).get('isError') and reply['result']['content'][0]['text']==why,reply
        for change,why in [(dict(limit=0),'InvalidArguments'),(dict(limit=33),'InvalidArguments'),(dict(frame=63),'InvalidLanguageFrame'),(dict(segment=63),'InvalidLanguageSegment'),(dict(generation=generation+1),'StaleSnapshot'),(dict(cv='0x1234'),'InvalidArguments')]:refusal(arguments|change,why)
        refusal({k:v for k,v in arguments.items() if k!='generation'},'GenerationRequired')
        if previous_generation is not None:refusal(arguments|{'generation':previous_generation},'StaleSnapshot')
        if a.strace and stop==0:
            adapter=SimpleNamespace(p=SimpleNamespace(pid=client.collector_pid()),inspect=client.inspect,session=client.session)
            result['readonly']=audit(adapter,tid,w/'locals.strace',lambda:(client.inspect('get_language_locals',**arguments),client.inspect('evaluate_language_expression',**arguments,expression='$shadow')))
        assert client.inspect('get_registers',tid=tid)==regs and client.session()['generation']==generation
        result['checks'].append({'ground':ground,'observed':observed,'generation':generation})
        previous_generation=generation;client.action('continue')
    target.wait(timeout=10);assert target.returncode==0,target.stderr.read()
    assert bindings==81,bindings
    result['status']='pass';result['bindings']=bindings
finally:
    if client:result['transcript']=client.transcript;client.close()
    if target.poll() is None:target.kill();target.wait()
    thread.join(timeout=5)
    (w/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Perl named MCP bindings: 81 bindings, recursion, closure, state, shadowing, pages and retained identity passed')
