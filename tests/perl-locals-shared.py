#!/usr/bin/env python3
"""Named Perl bindings stay read-only across actual shared observer clients."""
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
p.add_argument('--perl',required=True);p.add_argument('--padwalker',required=True,type=Path)
p.add_argument('--work',required=True,type=Path);p.add_argument('--agent',type=Path);p.add_argument('--strace',action='store_true');a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755);(w/'run').mkdir(mode=0o700)
cfg=json.loads(subprocess.check_output([a.perl,'-MConfig','-MJSON::PP','-e','print JSON::PP::encode_json({map {$_=>$Config{$_}} qw(archlib cc ccflags)})'],timeout=30))
source=root/'tests/fixtures/perl/named.c';shared=w/'named.so'
subprocess.run([*shlex.split(cfg['cc']),*shlex.split(cfg['ccflags']),'-U_FORTIFY_SOURCE','-shared','-fPIC','-g3','-O0','-fno-omit-frame-pointer','-I'+cfg['archlib']+'/CORE',str(source),'-o',str(shared)],check=True,timeout=90)
env=dict(os.environ,PERL5LIB=str(a.padwalker.resolve()/'blib/lib')+':'+str(a.padwalker.resolve()/'blib/arch'),XODB_PERL_NAMED_READY='1');env.pop('XODB_PERL_NAMED_EXPORT',None)
target=subprocess.Popen([a.perl,str(root/'tests/fixtures/perl/named.pl'),str(shared)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
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
    generation=state['generation'];tid=target.pid;args=dict(generation=generation,tid=tid,language='perl',segment=0,frame=0)
    for name in ('get_language_locals','evaluate_language_expression'):
        definition=next(t for t in observer.call('tools/list')['result']['tools'] if t['name']==name)
        assert definition['annotations']['readOnlyHint'] and definition['annotations']['xodbSessionAccess']=='observer'
    s.expect_error(observer.raw('select_language_frame',**args),'ControlLeaseRequired')
    first=observer.tool('get_language_locals',**args);assert first==owner.tool('get_language_locals',**args)
    found=observer.tool('evaluate_language_expression',**args,expression='$shadow');assert found==owner.tool('evaluate_language_expression',**args,expression='$shadow')
    assert found['rows'][0]['value']['display']=='IV 100',found
    owner.tool('release_session_control');assert observer.info()['controller_id'] is None
    assert observer.tool('get_language_locals',**args)==first
    if a.strace:
        collector=proc.pid
        if a.agent:
            children=Path(f'/proc/{collector}/task/{collector}/children').read_text().split();assert len(children)==1;collector=int(children[0])
        adapter=SimpleNamespace(p=SimpleNamespace(pid=collector),inspect=observer.tool,session=observer.session)
        result['readonly']=audit(adapter,tid,w/'named.strace',lambda:(observer.tool('get_language_locals',**args),observer.tool('evaluate_language_expression',**args,expression='$shadow')))
    assert observer.info()['controller_id'] is None
    owner.claim(ttl_ms=60000);owner.action('continue')
    s.eventually(owner.session,lambda state:state['generation']!=generation and state['state']=='stopped','next named stop')
    s.expect_error(observer.raw('get_language_locals',**args),'StaleSnapshot')
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
print('Shared Perl locals: owner/observer agreement, no-controller reads, stale generation and readonly checks passed')
