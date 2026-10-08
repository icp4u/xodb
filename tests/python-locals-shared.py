#!/usr/bin/env python3
"""Named Python bindings stay read-only across actual shared observer clients."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import select
import shlex
import signal
import subprocess
import time
from types import SimpleNamespace
from helpers.readonly import audit
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--python',required=True)
p.add_argument('--work',required=True,type=Path);p.add_argument('--agent',type=Path);p.add_argument('--strace',action='store_true');a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755);(w/'run').mkdir(mode=0o700)
spec=importlib.util.spec_from_file_location('component',root/'tests/python-component.py');component=importlib.util.module_from_spec(spec);spec.loader.exec_module(component)
component.compile_fixture(a.python,w)
source=root/'tests/fixtures/python/named.c'
env=dict(os.environ,PYTHONPATH=str(w),XODB_PYTHON_NAMED_READY='1');env.pop('XODB_PYTHON_NAMED_EXPORT',None)
target=subprocess.Popen([a.python,str(root/'tests/fixtures/python/named.py')],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
spec=importlib.util.spec_from_file_location('shared',root/'tests/shared-sessions.py');s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)
server=SimpleNamespace(path=w/'run/s',clients=[]);proc=None;result={'status':'running'}
try:
    assert select.select([target.stdout],[],[],10)[0] and target.stdout.readline()==b'ready\n'
    args=[str(root/'zig-out/bin/xodb'),'--headless','--session-socket',str(server.path),'--agent-scope','control',*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--attach',str(target.pid)]
    with (w/'server.log').open('wb') as log:proc=subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
    deadline=time.monotonic()+30
    while True:
        assert proc.poll() is None,(w/'server.log').read_text()
        try:owner=s.Client(server,'owner');break
        except (FileNotFoundError,ConnectionRefusedError):
            assert time.monotonic()<deadline;time.sleep(.02)
    observer=s.Client(server,'observer');owner.claim(ttl_ms=60000)
    line=next(i for i,text in enumerate(source.read_text().splitlines(),1) if 'NAMED_STOP' in text)
    owner.action('set_breakpoint',file=str(source),line=line);owner.action('continue');target.stdin.write(b'go\n');target.stdin.flush()
    state=s.eventually(owner.session,lambda state:state['state']=='stopped' and any(t['reason']=='breakpoint' for t in state['threads']),'named stop')
    generation=state['generation'];tid=target.pid
    # Debug metadata preparation is asynchronous; use its explicit pending state.
    deadline=time.monotonic()+60
    while True:
        reply=owner.raw('get_language_stack',tid=tid,language='python')
        if not reply['result'].get('isError'):break
        assert reply['result']['content'][0]['text']=='DebugMetadataPending' and time.monotonic()<deadline,reply
        time.sleep(.01)
    stack=reply['result']['structuredContent']
    segment,frame=next((s,f) for s,part in enumerate(stack['segments']) for f,row in enumerate(part['frames']) if row['name']=='recursive')
    args=dict(generation=generation,tid=tid,language='python',segment=segment,frame=frame)
    for name in ('get_language_locals','evaluate_language_expression'):
        definition=next(t for t in observer.call('tools/list')['result']['tools'] if t['name']==name)
        assert definition['annotations']['readOnlyHint'] and definition['annotations']['xodbSessionAccess']=='observer'
    s.expect_error(observer.raw('select_language_frame',**args),'ControlLeaseRequired')
    first=observer.tool('get_language_locals',**args);assert first==owner.tool('get_language_locals',**args)
    found=observer.tool('evaluate_language_expression',**args,expression='local');assert found==owner.tool('evaluate_language_expression',**args,expression='local')
    assert found['rows'][0]['value']['display']=='int 100',found
    watch_args=args|{'expression':'depth'}
    s.expect_error(observer.raw('add_language_watch',**watch_args),'ControlLeaseRequired')
    added=owner.tool('add_language_watch',**watch_args)['added']
    watches=observer.tool('get_language_watches')['watches']
    assert watches==owner.tool('get_language_watches')['watches'] and len(watches)==1,watches
    assert watches[0]['language']=='python' and watches[0]['current']['display']=='int 0',watches
    s.expect_error(observer.raw('remove_language_watch',generation=generation,id=added),'ControlLeaseRequired')
    owner.tool('release_session_control');assert observer.info()['controller_id'] is None
    assert observer.tool('get_language_locals',**args)==first
    assert observer.tool('get_language_watches')['watches']==watches
    if a.strace:
        collector=proc.pid
        if a.agent:
            children=Path(f'/proc/{collector}/task/{collector}/children').read_text().split();assert len(children)==1;collector=int(children[0])
        adapter=SimpleNamespace(p=SimpleNamespace(pid=collector),inspect=observer.tool,session=observer.session)
        result['readonly']=audit(adapter,tid,w/'named.strace',lambda:(observer.tool('get_language_locals',**args),observer.tool('evaluate_language_expression',**args,expression='local')))
    assert observer.info()['controller_id'] is None
    owner.claim(ttl_ms=60000);owner.action('continue')
    s.eventually(owner.session,lambda state:state['generation']!=generation and state['state']=='stopped','next named stop')
    s.expect_error(observer.raw('get_language_locals',**args),'StaleSnapshot')
    s.eventually(lambda:observer.tool('get_language_watches')['watches'],lambda rows:rows[0]['state']=='gone','watched recursion frame retired')
    owner.tool('remove_language_watch',generation=owner.session()['generation'],id=added)
    assert observer.tool('get_language_watches')['watches']==[]
    owner.action('detach');result.update(status='pass',owner_observer_equal=True,reads_without_any_controller=True)
finally:
    for c in server.clients:c.close()
    if proc and proc.poll() is None:
        proc.send_signal(signal.SIGINT)
        try:proc.wait(timeout=10)
        except subprocess.TimeoutExpired:proc.kill();proc.wait()
    if target.poll() is None:target.kill();target.wait()
    result['transcripts']=[c.transcript for c in server.clients]
    (w/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Shared Python locals: owner/observer agreement, no-controller reads, stale generation and readonly checks passed')
