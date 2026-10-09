#!/usr/bin/env python3
"""Stopped Lua table paths, compared with an owned public-API producer."""
import argparse,importlib.util,json,os,queue,re,subprocess,threading,time
from pathlib import Path
from types import SimpleNamespace
from client import Client
from helpers.readonly import audit

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',required=True);p.add_argument('--library',required=True)
p.add_argument('--work',type=Path,required=True);p.add_argument('--agent',type=Path);p.add_argument('--strace',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755);fixture=w/'host';source=root/'tests/fixtures/lua/named.c'
subprocess.run(['cc','-std=c11','-g','-O0','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror','-I'+a.source,'tests/fixtures/lua/path-watches.c',a.library,'-lm','-ldl','-o',str(fixture)],check=True,timeout=90)
target=subprocess.Popen([str(fixture)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
lines=queue.Queue()
def drain():
    for line in target.stdout:lines.put(line)
thread=threading.Thread(target=drain,daemon=True);thread.start();client=None
result={'status':'running','stops':[],'resources':[]};ids={};last={}
def usage(pid):
    fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
    rss=int(re.search(r'^VmRSS:\s*(\d+)',Path(f'/proc/{pid}/status').read_text(),re.M)[1])
    return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),rss_kib=rss)
try:
    assert lines.get(timeout=10)=='ready\n'
    client=Client('control',None,options=[*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--attach',str(target.pid)])
    line=next(i for i,text in enumerate(source.read_text().splitlines(),1) if 'NAMED_STOP' in text)
    client.action('set_breakpoint',file=str(source),line=line);client.action('continue');target.stdin.write('g');target.stdin.flush()
    for stop in range(13):
        state=client.stopped('breakpoint');generation=state['generation'];ground=json.loads(lines.get(timeout=10));phase=ground['phase']
        oracle={v['expression']:v for v in ground['values']};regs=client.inspect('get_registers',tid=target.pid)
        if stop==0:
            stack=client.inspect('get_language_stack',tid=target.pid,language='lua')
            segment=next(i for i,s in enumerate(stack['segments']) if int(s['runtime_instance']['address'],16)==int(ground['state'],16))
            args=dict(generation=generation,tid=target.pid,language='lua',segment=segment,frame=1)
            measured={'frontend':client.p.pid}
            if a.agent:measured['runtime_agent']=client.collector_pid()
            result['resources'].append({'phase':'metadata ready before watch creation','processes':{k:usage(pid) for k,pid in measured.items()},'load':os.getloadavg()})
            invalid=('object.a.b.c.d.e','object["a"]','object[true]','object.a:b()',
                     'object[2147483648]','object[-2147483649]','object[1.5]')
            for expression in invalid:
                refused=client.tool('add_language_watch',**args,expression=expression)['result']
                assert refused.get('isError') and refused['content'][0]['text']=='LuaExpressionUnsupported',refused
            assert client.inspect('get_language_watches')['watches']==[]
            temporary=client.inspect('add_language_watch',**args,expression='absent.value')['added']
            missing=client.inspect('get_language_watches')['watches'][0]
            assert missing['state']=='unavailable' and missing['diagnostic']=='LuaNameNotFound',missing
            client.inspect('remove_language_watch',generation=generation,id=temporary)
            result['syntax_refused_before_add']=list(invalid)
            for expression in (*oracle,'large.key1'):
                ids[expression]=client.inspect('add_language_watch',**args,expression=expression)['added']
            evaluated=client.inspect('evaluate_language_expression',**args,expression='object.a')
            assert evaluated['diagnostic'] is None and evaluated['rows'][0]['name']=='object.a' and evaluated['rows'][0]['value']['display']==oracle['object.a']['display'],evaluated
            if a.strace:
                def observed():
                    extra=client.inspect('add_language_watch',**args,expression='object.child.value')['added']
                    client.inspect('evaluate_language_expression',**args,expression='object.missing')
                    client.inspect('remove_language_watch',generation=generation,id=extra)
                adapter=SimpleNamespace(p=SimpleNamespace(pid=client.collector_pid() if a.agent else client.p.pid),inspect=client.inspect,session=client.session)
                result['readonly']=audit(adapter,target.pid,w/'paths.strace',observed)
        deadline=time.monotonic()+60
        while True:
            rows=client.inspect('get_language_watches')['watches'];byid={v['id']:v for v in rows};seen={key:byid[id] for key,id in ids.items()}
            if all(v['state'] in ('gone','context_changed') or (v['observed_generation']==generation and not (v.get('diagnostic') or '').endswith('DebugMetadataPending')) for v in rows):break
            assert time.monotonic()<deadline,seen;time.sleep(.01)
        if stop>=10:
            assert all(v['state']=='gone' and not v['changed'] for v in rows),seen
        else:
            for expression,v in seen.items():
                if phase==8 and v['state']=='unavailable' and v['diagnostic']=='LuaWatchCoroutineNotObserved':
                    assert not v['changed'];continue
                expected=last.get(expression) if phase==8 else oracle.get(expression)
                error='LuaPathWorkLimit' if expression=='large.key1' else 'LuaPathMetatableUnsupported' if phase==4 and expression.startswith('object') else 'LuaPathNotTable' if phase==3 and expression=='object.child.value' else None
                if error:
                    assert v['state']=='unavailable' and v['diagnostic']==error and not v['changed'],(stop,expression,v,error)
                    continue
                assert v['state']=='value' and v['current']['kind']==expected['kind'] and v['current']['comparison_bytes']==expected['length'],(stop,expression,v,expected)
                if expected['kind']!=4:assert v['current']['display']==expected['display'],(stop,expression,v,expected)
                changed=expression in last and (last[expression]['kind'],last[expression]['bytes'])!=(expected['kind'],expected['bytes'])
                assert v['changed']==changed,(stop,expression,v,last.get(expression),expected)
                if stop==1 and expression=='object.child.value':
                    assert changed and v['previous']['display']==v['current']['display'] and expected['length']==301,v
                last[expression]=expected
        if stop==1:
            assert ground['root']!=result['stops'][0]['ground']['root'];result['root_replacement_observed']=True
        assert client.inspect('get_language_watches')['watches']==rows and client.session()['generation']==generation
        assert client.inspect('get_registers',tid=target.pid)==regs
        result['stops'].append({'ground':ground,'watches':rows})
        result['resources'].append({'phase':f'completed stop {stop}','processes':{k:usage(pid) for k,pid in measured.items()},'load':os.getloadavg()})
        client.action('continue')
    target.wait(timeout=10);assert target.returncode==0,target.stderr.read();result['transcript']=client.transcript;client.close();client=None
    # Real shared observers may evaluate and read cached paths, but cannot
    # mutate the watch set by directly calling hidden controller tools.
    spec=importlib.util.spec_from_file_location('shared',root/'tests/shared-sessions.py');s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)
    os.environ['XODB_LUA_NAMED_AUTO']='1'
    if a.agent:os.environ['XODB_RUNTIME_AGENT']=str(a.agent.resolve())
    (w/'shared').mkdir()
    server=s.Server(root,w/'shared',root/'zig-out/bin/xodb',fixture,'control',fixture_args=())
    try:
        owner,observer=s.Client(server,'owner'),s.Client(server,'observer');owner.claim(ttl_ms=60000)
        initial=s.eventually(owner.session,lambda v:v['state']=='stopped' and not v['symbol_discovery_pending'],'initial stop');server.remember_target(initial)
        owner.action('set_breakpoint',file=str(source),line=line);owner.action('continue')
        state=s.eventually(owner.session,lambda v:v['state']=='stopped' and not v['symbol_discovery_pending'] and not v['continue_pending'] and any(t['reason']=='breakpoint' for t in v['threads']),'path stop')
        tid=state['threads'][0]['tid']
        deadline=time.monotonic()+60
        while True:
            answer=owner.raw('get_language_stack',tid=tid,language='lua')
            if not answer['result'].get('isError'):break
            s.expect_error(answer,'DebugMetadataPending');assert time.monotonic()<deadline;time.sleep(.02)
        generation=owner.session()['generation'];args=dict(generation=generation,tid=tid,language='lua',segment=0,frame=1)
        # Metadata can initially be pending, as in the stdio transport.
        deadline=time.monotonic()+60
        while True:
            answer=owner.raw('evaluate_language_expression',**args,expression='object.a')
            if not answer['result'].get('isError'):break
            s.expect_error(answer,'DebugMetadataPending');assert time.monotonic()<deadline;time.sleep(.02)
        expected=answer['result']['structuredContent'];assert observer.tool('evaluate_language_expression',**args,expression='object.a')==expected
        s.expect_error(observer.raw('add_language_watch',**args,expression='object.a'),'ControlLeaseRequired')
        created=owner.tool('add_language_watch',**args,expression='object.a')['added']
        watched=owner.tool('get_language_watches');assert observer.tool('get_language_watches')==watched
        s.expect_error(observer.raw('remove_language_watch',generation=generation,id=created),'ControlLeaseRequired')
        owner.tool('release_session_control')
        assert observer.tool('get_language_watches')==watched
        result['shared_observer']={'status':'pass','direct_mutations_refused':True,'reads_without_lease':True}
    finally:server.close()
    result['status']='pass'
finally:
    if client:result['transcript']=client.transcript;client.close()
    if target.poll() is None:target.kill();target.wait()
    thread.join(timeout=5);(w/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Lua table paths: replacement, complete bytes, nil/refusal, shadow/coroutine, retirement, shared observers passed')
