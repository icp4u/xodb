#!/usr/bin/env python3
"""A Lua watch follows one coroutine and refuses an unobserved coroutine."""
import argparse,json,os,queue,subprocess,threading,time
from pathlib import Path
from client import Client
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',required=True);p.add_argument('--library',required=True);p.add_argument('--work',type=Path,required=True);p.add_argument('--agent',type=Path);a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022);w=a.work.resolve();w.mkdir(parents=True,mode=0o755);exe=w/'host';source=root/'tests/fixtures/lua/named.c'
subprocess.run(['cc','-std=c11','-g','-O0','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror','-I'+a.source,str(source),a.library,'-lm','-ldl','-o',str(exe)],check=True,timeout=90)
target=subprocess.Popen([str(exe)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1);lines=queue.Queue()
def drain():
    for line in target.stdout:lines.put(line)
thread=threading.Thread(target=drain,daemon=True);thread.start();client=None;result={'status':'running','stops':[]}
try:
    assert lines.get(timeout=10)=='ready\n'
    client=Client('control',None,options=[*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--attach',str(target.pid)])
    line=next(i for i,s in enumerate(source.read_text().splitlines(),1) if 'NAMED_STOP' in s);client.action('set_breakpoint',file=str(source),line=line);client.action('continue');target.stdin.write('g');target.stdin.flush()
    for stop in range(7):
        state=client.stopped('breakpoint');generation=state['generation'];ground=json.loads(lines.get(timeout=10))
        if stop==2:
            expected=next(f for f in ground['frames'] if any(v['name']=='retained' for v in f['bindings']))
            want=next(v['display'] for v in expected['bindings'] if v['name']=='retained')
            stack=client.inspect('get_language_stack',tid=target.pid,language='lua');segment=next(i for i,s in enumerate(stack['segments']) if int(s['runtime_instance']['address'],16)==int(ground['state'],16))
            client.inspect('add_language_watch',generation=generation,tid=target.pid,language='lua',segment=segment,frame=expected['frame'],expression='retained')
        if stop>=2:
            deadline=time.monotonic()+30
            while True:
                values=client.inspect('get_language_watches')['watches'];assert len(values)==1,values;v=values[0]
                if v['observed_generation']==generation:break
                assert time.monotonic()<deadline,v;time.sleep(.01)
            if stop<=3:assert v['state']=='value' and v['current']['display']==want and not v['changed'],v
            else:assert v['state']=='unavailable' and v['diagnostic']=='LuaWatchCoroutineNotObserved' and not v['changed'],v
            result['stops'].append({'ground':ground,'watch':v})
        client.action('continue')
    target.wait(timeout=10);assert target.returncode==0;result['status']='pass'
finally:
    if client:result['transcript']=client.transcript;client.close()
    if target.poll() is None:target.kill();target.wait()
    thread.join(timeout=5);(w/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Lua watch: suspended/resumed coroutine matched; unobserved coroutine stays unavailable')
