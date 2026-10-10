#!/usr/bin/env python3
"""Manual/periodic: owned graph IO, passive MCP and tracing controls on private Sway."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work-dir',type=Path,required=True)
p.add_argument('--binary',type=Path)
p.add_argument('--expect-denied',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
base=a.work_dir.resolve();base.mkdir(parents=True,exist_ok=True);base.chmod(0o755)
assert not list(base.iterdir()),'work dir must be empty and owned by this test'
work=base/'.work/input-flow';work.mkdir(parents=True)
for name in ('tmp','cache'):(work/name).mkdir()
spec=importlib.util.spec_from_file_location('flow_input',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(work);h.HELPER=str(work/'vinput')
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    for mode,suffix in (('client-header','.h'),('private-code','.c')):
        subprocess.run(['wayland-scanner',mode,xml,str(work/(stem+suffix))],check=True,timeout=10)
subprocess.run(['cc','-I',str(work),'tests/helpers/vinput.c',str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=30)
# A supplied wrapper may launch a child. Match only a descendant of our launch,
# in this test's compositor, before injecting input.
def focused(self,seconds=60):
    end=time.monotonic()+seconds
    def walk(node):
        yield node
        for key in ('nodes','floating_nodes'):
            for child in node.get(key,[]):yield from walk(child)
    while self.app.poll() is None and time.monotonic()<end:
        tree=json.loads(subprocess.check_output(['swaymsg','-r','-t','get_tree'],env=self.env,text=True,timeout=10))
        for node in walk(tree):
            if node.get('app_id')!='xodb-overview' or not node.get('focused') or not node.get('visible'):continue
            pid=node.get('pid',0);current=pid;seen=set()
            while current>1 and current not in seen:
                if current==self.app.pid:
                    self.actual_pid=pid;return
                seen.add(current)
                try:status=Path(f'/proc/{current}/status').read_text()
                except FileNotFoundError:break
                current=int(re.search(r'^PPid:\s+(\d+)',status,re.M)[1])
        time.sleep(.02)
    raise RuntimeError('owned window did not map: '+self.tail())
h.Display.wait_focused=focused
fixture_code=r'''
import os,sys,json,ctypes
libc=ctypes.CDLL(None);parent=os.getpid();control=os.pipe();data=os.pipe();ack=os.pipe();ready=os.pipe();children=[]
for role in range(2):
    pid=os.fork()
    if pid==0:
        if libc.prctl(1,9)!=0 or os.getppid()!=parent:os._exit(9)
        os.close(ready[0])
        if role==0:
            os.close(control[1]);os.close(data[0]);os.close(ack[0]);os.close(ack[1])
            os.write(ready[1],b'r');os.close(ready[1])
            while os.read(control[0],1):
                for _ in range(16):
                    if os.write(data[1],b'x'*4096)!=4096:os._exit(3)
        else:
            os.close(control[0]);os.close(control[1]);os.close(data[1]);os.close(ack[0])
            os.write(ready[1],b'r');os.close(ready[1]);total=0
            while True:
                chunk=os.read(data[0],65536)
                if not chunk:break
                total+=len(chunk)
                if total%65536==0:os.write(ack[1],b'b')
        os._exit(0)
    children.append(pid)
os.close(control[0]);os.close(data[0]);os.close(data[1]);os.close(ack[1]);os.close(ready[1])
got=b''
while len(got)<2:got+=os.read(ready[0],2-len(got))
os.close(ready[0]);print(json.dumps(children),flush=True)
for line in sys.stdin:
    if line.strip()!='b':break
    os.write(control[1],b'b');assert os.read(ack[0],1)==b'b';print('burst complete',flush=True)
os.close(control[1]);os.close(ack[0])
for child in children:
    _,status=os.waitpid(child,0);assert status==0,status
'''
fixture=subprocess.Popen([sys.executable,'-c',fixture_code],cwd=work,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
d=None;results=[];began=time.monotonic();blocked=False

def check(label,condition):
    results.append({'check':label,'status':'pass' if condition else 'fail'});print(('PASS ' if condition else 'FAIL ')+label,flush=True);assert condition,label

def until(fn,predicate,label,seconds=20):
    end=time.monotonic()+seconds;last=None
    while time.monotonic()<end:
        last=fn()
        if predicate(last):return last
        assert d.alive(),d.tail();time.sleep(.02)
    raise AssertionError((label,last,d.tail()))

def status():
    reply=d.request('tools/call',{'name':'get_fd_activity','arguments':{'limit':1,'redact':True}})
    if reply.get('isError'):
        assert reply['content'][0]['text']=='FdCacheBusy',reply
        return {}
    return reply['structuredContent']

def flow():return status().get('system_flow',{})

def burst():
    fixture.stdin.write('b\n');fixture.stdin.flush()
    assert select.select([fixture.stdout],[],[],10)[0],'owned pipe burst did not finish'
    assert fixture.stdout.readline().strip()=='burst complete'

def audit():
    text=Path(d.log).read_text(errors='replace')
    return re.findall(r'fdgraph-flow running=(\d+) requested=(\d+) sequence=(\d+) matched=(\d+) bytes=(\d+) unknown=(\d+) rate=([\d.]+) lost=(\d+) cpus=(\d+)/(\d+) status=(\d+)',text)

try:
    pids=json.loads(fixture.stdout.readline());check('two owned pipe endpoints',len(pids)==2)
    os.environ['XODB_OVERVIEW_AUDIT']='1';os.environ['XODB_OVERVIEW_LAYOUT']='1'
    options=['--overview','--panel','galaxy','--redact']
    for pid in pids:options+=['--graph-pid',str(pid)]
    d=h.Display.__new__(h.Display)
    h.Display.__init__(d,str(root),options,trace=True,stdio=True,binary=str(a.binary.resolve()) if a.binary else None)
    f=until(flow,lambda v:v.get('running') or (v.get('state') not in (None,'pending','ok')),'trace activation')
    if not f.get('running'):
        if not a.expect_denied:
            print('BLOCKED: existing tracefs/perf access required:',f,flush=True);blocked=True
        else:
            check('denial is explicit and capture inactive',bool(f.get('failure')) and not f['running'])
            text=h.ocr_until(d,'denied',lambda t:'polling' in t and ('denied' in t or 'unavailable' in t))
            check('visible polling fallback names denial','polling' in text and ('denied' in text or 'unavailable' in text))
            generation=f['generation'];d.keys('tap',18)
            stopped=until(flow,lambda v:v and not v['requested'],'denied capture off')
            check('denied capture can be switched off',not stopped['running'] and stopped['active_cpus']==0)
            d.keys('tap',18)
            retried=until(flow,lambda v:v.get('generation',0)>generation and v.get('failure'),'explicit denial retry')
            check('denied capture retries only on activation',retried['requested'] and not retried['running'])
    else:
        check('default tracing needs no acknowledgement',not a.expect_denied and f['requested'] and f['active_cpus']>0)
        check('MCP reports scoped capture and cost','explicit' in f['scope'] and '~11%' in f['host_cost'])
        text=h.ocr_until(d,'live-banner',lambda t:'live syscall tracing' in t and 'host syscall overhead' in t)
        check('live cost and stop key are visible','live syscall tracing' in text and 'to stop' in text)
        burst() # retire calls already in flight when capture began
        seq=until(status,lambda v:v.get('sequence',0)>0,'first poll')['sequence']
        until(status,lambda v:v.get('sequence',0)>seq,'fresh post-warmup inode sample')
        burst()
        observed=until(audit,lambda rows:any(int(r[3])>0 and float(r[6])>0 for r in rows),'known inode throughput')
        check('C projection publishes live matched inode rates',any(int(r[3])>0 and float(r[6])>0 for r in observed))
        d.shot('galaxy-flow')
        d.keys('tap',34) # G
        check('graph view visible','shared files' in h.ocr_until(d,'graph-flow',lambda t:'shared files' in t))
        burst();until(audit,lambda rows:rows and float(rows[-1][6])>0,'graph pulse rates')
        d.keys('tap',18) # E: stop
        f=until(flow,lambda v:v and not v['running'] and not v['requested'],'E stop')
        check('E closes tracing while observers keep polling',not f['running'] and f['active_cpus']==0)
        total=f['read_bytes']+f['write_bytes'];burst()
        seq=status().get('sequence',0)
        until(status,lambda v:v.get('sequence',0)>seq,'observer polling after stop')
        f=until(flow,bool,'passive flow status');check('observer reads do not restart capture or add bytes',not f['running'] and not f['requested'] and f['read_bytes']+f['write_bytes']==total)
        d.keys('tap',18);until(flow,lambda v:v.get('running'),'E restart')
        d.keys('tap',25) # P: pause
        until(flow,lambda v:v and not v['running'] and not v['requested'],'pause stops trace')
        check('paused view shows capture stopped','tracing stopped' in h.ocr_until(d,'paused',lambda t:'tracing stopped' in t))
        d.keys('tap',25);until(flow,lambda v:v.get('running'),'resume tracing')
        d.keys('tap',2) # 1: Summary, leave graph
        until(flow,lambda v:v and not v['running'] and not v['requested'],'pane exit stops trace')
        check('leaving graph stops tracing',True)
        text=Path(d.log).read_text(errors='replace')
        for panel in ('graph','galaxy'):
            overlaps=re.findall(r'overview layout .*panel='+panel+r' overlaps=(\d+)',text)
            check(panel+' text has no layout overlaps',bool(overlaps) and all(int(n)==0 for n in overlaps))
        check('application remains alive',d.alive())
finally:
    if d and hasattr(d,'procs'):d.close()
    if fixture.poll() is None:
        fixture.stdin.write('q\n');fixture.stdin.flush()
    fixture.wait(timeout=10)
    assert fixture.returncode==0,fixture.stderr.read()
    (work/'results.json').write_text(json.dumps({'checks':results,'blocked':blocked,'elapsed_seconds':time.monotonic()-began},indent=2)+'\n')
if blocked:raise SystemExit(77)
print('owned graph flow GUI checks PASS')
