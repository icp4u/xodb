#!/usr/bin/env python3
"""Prove actual Lua frame reuse, then require an explicitly qualified comparison."""
import argparse,json,os,queue,subprocess,threading,time
from pathlib import Path
from client import Client
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',required=True);p.add_argument('--library',required=True)
p.add_argument('--work',type=Path,required=True);p.add_argument('--agent',type=Path)
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755);exe=w/'host'
subprocess.run(['cc','-std=c11','-g','-O0','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror','-I'+a.source,'tests/fixtures/lua/watch-reuse.c',a.library,'-lm','-ldl','-o',str(exe)],check=True,timeout=90)
target=subprocess.Popen([str(exe)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
lines=queue.Queue()
def drain():
    for line in target.stdout:lines.put(line)
thread=threading.Thread(target=drain,daemon=True);thread.start();client=None;result={'status':'running','stops':[]}
try:
    assert lines.get(timeout=10)=='ready\n'
    client=Client('control',None,options=[*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--attach',str(target.pid)])
    source=root/'tests/fixtures/lua/named.c';line=next(i for i,s in enumerate(source.read_text().splitlines(),1) if 'NAMED_STOP' in s)
    client.action('set_breakpoint',file=str(source),line=line)
    client.continue_initial_stop();target.stdin.write('g');target.stdin.flush()
    location=None
    for stop in range(3):
        state=client.stopped('breakpoint');generation=state['generation'];ground=json.loads(lines.get(timeout=10))
        stack=client.inspect('get_language_stack',tid=target.pid,language='lua')
        if stop<2:
            segment=next(i for i,s in enumerate(stack['segments']) if int(s['runtime_instance']['address'],0)==int(ground['state'],0))
            expected=next(f for f in ground['frames'] if any(b['name']=='x' for b in f['bindings']));frame=expected['frame']
            value=next(b for b in expected['bindings'] if b['name']=='x')['display']
            assert value.split()[-1]==str(10 if stop==0 else 20),ground
            logical=stack['segments'][segment]['frames'][frame]
            actual=logical['call_info'],logical['prototype']
            if stop==0:
                location=actual
                client.inspect('add_language_watch',generation=generation,tid=target.pid,language='lua',segment=segment,frame=frame,expression='x')
            else:
                assert actual==location,('reuse precondition failed',location,actual)
                result['reuse_precondition']={'same_call_info_and_prototype':True,'first':location,'second':actual,'distinct_calls_in_fixture':True}
        deadline=time.monotonic()+30
        while True:
            row=client.inspect('get_language_watches')['watches'][0]
            if row['observed_generation']==generation:break
            assert time.monotonic()<deadline,row;time.sleep(.01)
        if stop==1:
            assert row['changed'] and row['comparison']=='same_slot_different',row
            assert 'unproved' in row['identity'],row
            assert row['previous']['display'].split()[-1]=='10' and row['current']['display'].split()[-1]=='20',row
        elif stop==2:
            assert row['state']=='gone' and not row['changed'] and row['comparison']=='not_compared',row
        result['stops'].append({'ground':ground,'watch':row});client.action('continue')
    target.wait(timeout=10);assert target.returncode==0,target.stderr.read();result['status']='pass'
finally:
    if client:result['transcript']=client.transcript;client.close()
    if target.poll() is None:target.kill();target.wait()
    thread.join(timeout=5);(w/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Distinct Lua calls reuse the proved CallInfo/prototype slot; comparison is explicitly activation-unproved and observed absence retires it')
