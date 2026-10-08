#!/usr/bin/env python3
"""Stop-to-stop watches against an owned Lua debug-API oracle."""
import argparse,json,os,queue,re,subprocess,threading,time
from types import SimpleNamespace
from helpers.readonly import audit
from pathlib import Path
from client import Client
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--strace',action='store_true')
p.add_argument('--source',required=True);p.add_argument('--library',required=True)
p.add_argument('--work',type=Path,required=True);p.add_argument('--agent',type=Path)
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755);exe=w/'host'
subprocess.run(['cc','-std=c11','-g','-O0','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror','-I'+a.source,'tests/fixtures/lua/watches.c',a.library,'-lm','-ldl','-o',str(exe)],check=True,timeout=90)
target=subprocess.Popen([str(exe)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
lines=queue.Queue()
def drain():
    for line in target.stdout:lines.put(line)
thread=threading.Thread(target=drain,daemon=True);thread.start();client=None
result={'status':'running','stops':[],'resources':[]};ids={}
def usage(pid):
    fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
    rss=int(re.search(r'^VmRSS:\s*(\d+)',Path(f'/proc/{pid}/status').read_text(),re.M)[1])
    return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),rss_kib=rss)

try:
    assert lines.get(timeout=10)=='ready\n'
    client=Client('control',None,options=[*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--attach',str(target.pid)])
    source=root/'tests/fixtures/lua/named.c';line=next(i for i,s in enumerate(source.read_text().splitlines(),1) if 'NAMED_STOP' in s)
    client.action('set_breakpoint',file=str(source),line=line)
    measured={'frontend':client.p.pid}
    if a.agent:measured['runtime_agent']=client.collector_pid()
    before={k:usage(pid) for k,pid in measured.items()};started=time.monotonic()
    client.action('continue');target.stdin.write('g');target.stdin.flush()
    for stop in range(14):
        state=client.stopped('breakpoint');generation=state['generation'];ground=json.loads(lines.get(timeout=10))
        regs=client.inspect('get_registers',tid=target.pid)
        if stop==0:
            stack=client.inspect('get_language_stack',tid=target.pid,language='lua')
            segment=next(i for i,s in enumerate(stack['segments']) if int(s['runtime_instance']['address'],16)==int(ground['state'],16))
            expected=next(f for f in ground['frames'] if sum(b['name']=='shadow' for b in f['bindings'])==2);frame=expected['frame']
            bindings=client.inspect('get_language_locals',generation=generation,tid=target.pid,language='lua',segment=segment,frame=frame)['rows']
            args=dict(generation=generation,tid=target.pid,language='lua',segment=segment,frame=frame)
            shadows=[i for i,b in enumerate(bindings) if b['name']=='shadow'];assert len(shadows)==2
            for key,select in [('outer',{'row':shadows[0]}),('inner',{'row':shadows[1]}),('lexical',{'expression':'shadow'}),*[(name,{'expression':name}) for name in ('x','text','huge','object','captured')]]:
                response=client.inspect('add_language_watch',**args,**select);ids[key]=response['added']
            if a.strace:
                def observed():
                    extra=client.inspect('add_language_watch',**args,expression='x')['added']
                    client.inspect('remove_language_watch',generation=generation,id=extra)
                auditor=SimpleNamespace(p=SimpleNamespace(pid=client.collector_pid() if a.agent else client.p.pid),inspect=client.inspect,session=client.session)
                result['readonly']=audit(auditor,target.pid,w/'watches.strace',observed)
            for change,expected in [(dict(row=0,expression='x'),'InvalidArguments'),(dict(row=4096),'InvalidArguments'),(dict(expression='x',generation=generation+1),'StaleSnapshot')]:
                response=client.tool('add_language_watch',**(args|change))
                error=response.get('error',{}).get('message') or response.get('result',{}).get('content',[{}])[0].get('text')
                assert error==expected,response
        deadline=time.monotonic()+60
        while True:
            watches=client.inspect('get_language_watches')['watches']
            byid={v['id']:v for v in watches};seen={key:byid[id] for key,id in ids.items()}
            if all(v['observed_generation']==generation or v['state'] in ('gone','context_changed') for v in watches):break
            assert time.monotonic()<deadline,seen
            time.sleep(.01)
        def number(key,n,changed):
            v=seen[key];assert v['state']=='value' and v['current']['display'].split()[-1]==str(n) and v['changed']==changed,(stop,key,v)
        if stop<6:
            expected=next(f for f in ground['frames'] if any(b['name']=='x' for b in f['bindings']))
            runtime={b['name']:b for b in expected['bindings']}
            for key in ('x','huge','object','captured','lexical'):
                name='shadow' if key=='lexical' else key;v=seen[key];want=runtime[name]['display']
                if v['state']=='value' and want is not None:assert v['current']['display']==want,(stop,key,v,want)
            number('outer',10,False)
        if stop==0:
            number('inner',20,False);number('lexical',20,False);number('x',7,False)
            assert seen['huge']['state']=='unavailable' and seen['huge']['diagnostic']=='LuaWatchSampleLimit',seen
            assert seen['object']['state']=='unavailable' and seen['object']['diagnostic']=='LuaWatchValueUnsupported',seen
        if stop==1:
            number('inner',21,True);number('lexical',21,True);number('x',8,True);number('captured',74,True)
            v=seen['text'];assert v['changed'] and v['previous']['display']==v['current']['display'] and v['current']['comparison_bytes']==301,v
        if stop==2:
            assert all(not v['changed'] for v in watches),watches
        if stop==3:
            assert seen['inner']['state']=='unavailable' and seen['inner']['diagnostic']=='LuaWatchBindingNotActive',seen
            number('lexical',10,True)
        if stop in (4,5):
            assert seen['x']['current']['display']=='nil' and seen['huge']['current']['display']=='string "small"' and seen['object']['current']['display']=='false',seen
            assert seen['inner']['state']=='unavailable',seen
            assert seen['x']['changed']==(stop==4),seen
        if stop>=6:
            assert all(v['state']=='gone' and not v['changed'] for v in watches),watches
        assert client.inspect('get_language_watches')['watches']==watches
        assert client.inspect('get_registers',tid=target.pid)==regs and client.session()['generation']==generation
        result['stops'].append({'generation':generation,'ground':ground,'watches':watches})
        after={k:usage(pid) for k,pid in measured.items()}
        result['resources'].append({'stop':stop,'before':before,'after':after,'elapsed_seconds':time.monotonic()-started,'load':os.getloadavg(),'allowed_cpus':len(os.sched_getaffinity(0)),'phase':'previous completed inspection to this completed inspection; includes run-control and fixture interval, not isolated watch cost'})
        before=after;started=time.monotonic();client.action('continue')
    target.wait(timeout=10);assert target.returncode==0,target.stderr.read();result['status']='pass'
finally:
    if client:result['transcript']=client.transcript;client.close()
    if target.poll() is None:target.kill();target.wait()
    thread.join(timeout=5);(w/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Lua watches: exact bytes, shadow binding/expression distinction, stop equality/change, GC, stack growth, unavailable recovery and retired frame passed')
