#!/usr/bin/env python3
"""Fast lane: owned parent/child descriptors on a private compositor (under 15s)."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work-dir',type=Path,required=True)
p.add_argument('--binary',type=Path)
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
base=a.work_dir.resolve();base.mkdir(parents=True,exist_ok=True);base.chmod(0o755)
assert not list(base.iterdir()),'use an empty owned directory'
work=base/'.work/input-inherit';work.mkdir(parents=True)
for name in ('tmp','cache'):(work/name).mkdir()
spec=importlib.util.spec_from_file_location('inherit_input',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(work);h.HELPER=str(work/'vinput')
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    for mode,suffix in (('client-header','.h'),('private-code','.c')):
        subprocess.run(['wayland-scanner',mode,xml,str(work/(stem+suffix))],check=True,timeout=10)
subprocess.run(['cc','-I',str(work),'tests/helpers/vinput.c',str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=30)
fixture_code=r'''
import os,sys,json,fcntl,ctypes
libc=ctypes.CDLL(None);boss=os.getppid();assert libc.prctl(1,9)==0 and os.getppid()==boss
parent=os.getpid();data=os.pipe();command=os.pipe();reply=os.pipe();clo=fcntl.fcntl(data[0],fcntl.F_DUPFD_CLOEXEC,50)
for fd in (data[0],command[0],reply[1]):os.set_inheritable(fd,True)
child=os.fork()
if child==0:
    assert libc.prctl(1,9)==0 and os.getppid()==parent
    os.close(command[1]);os.close(reply[0]);os.write(reply[1],b'r')
    while True:
        ch=os.read(command[0],1)
        if ch==b't':
            os.set_inheritable(clo,True);os.write(reply[1],b't')
        elif ch==b'e':
            os.set_inheritable(clo,False)
            code='import os,sys,fcntl,errno; c,r,k,f=map(int,sys.argv[1:]); assert f not in [int(x) for x in os.listdir("/proc/self/fd")]; assert fcntl.fcntl(k,fcntl.F_GETFD)>=0; os.write(r,b"x"); assert os.read(c,1)==b"q"'
            os.execv(sys.executable,[sys.executable,'-c',code,str(command[0]),str(reply[1]),str(data[0]),str(clo)])
        else:os._exit(0)
os.close(command[0]);os.close(reply[1]);assert os.read(reply[0],1)==b'r'
print(json.dumps({'pids':[parent,child],'clo':clo,'keep':data[0]}),flush=True)
for line in sys.stdin:
    op=line.strip()
    if op not in ('t','e'):break
    os.write(command[1],op.encode());assert os.read(reply[0],1)==(b't' if op=='t' else b'x');print('ready',flush=True)
os.write(command[1],b'q');os.close(command[1]);os.close(reply[0]);_,status=os.waitpid(child,0);assert status==0,status
'''
fixture=subprocess.Popen([sys.executable,'-c',fixture_code],cwd=work,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
d=None;results=[];started=time.monotonic()
def check(label,value):
    results.append({'check':label,'status':'pass' if value else 'fail'});print(('PASS ' if value else 'FAIL ')+label,flush=True);assert value,label

def until(fn,predicate,label,seconds=20):
    end=time.monotonic()+seconds;last=None
    while time.monotonic()<end:
        last=fn()
        if predicate(last):return last
        assert d.alive(),d.tail();time.sleep(.02)
    raise AssertionError((label,last,d.tail()))

def audit():return Path(d.log).read_text(errors='replace')
def rows():return re.findall(r'fdinherit-row parent=(\d+) child=(\d+) fd=(\d+) flags=(\d+) x=([\d.]+) y=([\d.]+)',audit())
def latest_fd(fd):
    found=[r for r in rows() if int(r[1])==child and int(r[2])==fd]
    return found[-1] if found else None

def flow():
    reply=d.request('tools/call',{'name':'get_fd_activity','arguments':{'limit':1,'redact':True}})
    if reply.get('isError'):
        assert reply['content'][0]['text']=='FdCacheBusy',reply;return {}
    return reply['structuredContent'].get('system_flow',{})

def raw_call(name,args):
    # Display.request returns only result; invalid parameters are JSON-RPC
    # errors, so keep the envelope for this explicit refusal oracle.
    d.serial+=1
    message={'jsonrpc':'2.0','id':d.serial,'method':'tools/call','params':{'name':name,'arguments':args}}
    d.app.stdin.write((json.dumps(message)+'\n').encode());d.app.stdin.flush()
    end=time.monotonic()+10
    while time.monotonic()<end:
        if not select.select([d.app.stdout],[],[],end-time.monotonic())[0]:break
        line=d.app.stdout.readline();assert line,'MCP closed'
        reply=json.loads(line)
        if 'id' not in reply:d.notifications.append(reply);continue
        assert reply['id']==d.serial,reply
        return reply
    raise AssertionError('no raw MCP reply')

def comparisons(**extra):
    args={'limit':500,'redact':True,'pid':child};args.update(extra)
    reply=d.request('tools/call',{'name':'get_fd_inheritance','arguments':args})
    if reply.get('isError'):
        assert reply['content'][0]['text'] in ('FdCacheBusy','FdSnapshotChanged'),reply
        return {}
    return reply['structuredContent']

def command(op):
    fixture.stdin.write(op+'\n');fixture.stdin.flush()
    assert select.select([fixture.stdout],[],[],10)[0],'fixture command timeout'
    assert fixture.stdout.readline().strip()=='ready',fixture.stderr.read() if fixture.poll() is not None else 'fixture command failed'

try:
    setup=json.loads(fixture.stdout.readline());parent,child=setup['pids'];clo=setup['clo'];keep=setup['keep']
    os.environ['XODB_OVERVIEW_AUDIT']='1';os.environ['XODB_OVERVIEW_LAYOUT']='1'
    options=['--overview','--panel','inheritance','--redact','--graph-pid',str(parent),'--graph-pid',str(child)]
    d=h.Display(str(root),options,stdio=True,binary=str(a.binary.resolve()) if a.binary else None)
    row=until(lambda:latest_fd(clo),lambda r:r and int(r[3])&64,'current CLOEXEC row')
    check('actual parent/child row has current CLOEXEC',int(row[0])==parent and int(row[1])==child and int(row[3])&16)
    f=until(flow,lambda v:v and not v['requested'],'polling default')
    check('comparison starts without tracing',not f['running'] and f['active_cpus']==0)
    observed=until(comparisons,lambda v:any(r['fd']==clo and r['child_cloexec'] is True for r in v.get('rows',[])),'MCP current flags')
    check('MCP identifies the same owned parent and child',all(r['parent']['pid']==parent and r['child']['pid']==child for r in observed['rows']))
    check('MCP labels origin unproved and omits paths','unproved' in observed['evidence'] and all('path' not in r for r in observed['rows']))
    for attempt in range(10):
        page=comparisons(limit=1)
        if not page.get('next_offset'):continue
        next_page=comparisons(limit=1,offset=page['next_offset'],sequence=page['sequence'])
        if next_page:
            check('MCP pagination stays on one snapshot',len(next_page['rows'])==1 and next_page['sequence']==page['sequence'] and next_page['rows'][0]['fd']!=page['rows'][0]['fd'])
            break
    else:raise AssertionError('no coherent comparison pages')
    check('MCP comparison never starts tracing',not flow().get('requested',True))
    definitions=d.request('tools/list',{})['tools']
    definition=next(tool for tool in definitions if tool['name']=='get_fd_inheritance')
    check('comparison is advertised as an observer read',definition['annotations']['readOnlyHint'] and definition['annotations']['xodbSessionAccess']=='observer')
    bad=raw_call('get_fd_inheritance',{'offset':1})
    check('pagination refuses an unpinned offset',bad.get('error',{}).get('code')==-32602 and bad['error']['message']=='InvalidArguments')
    text=h.ocr_until(d,'comparison',lambda t:'parent & child descriptors' in t and 'unproved' in t)
    check('sampled-match limitation is visible','unproved' in text and 'polling' in text)
    check('close-on-exec states are visible','cloexec' in text and 'unknown' in text)
    check('paths are redacted','path redacted' in text)
    command('t')
    row=until(lambda:latest_fd(clo),lambda r:r and int(r[3])&16 and not int(r[3])&64,'changed descriptor flags')
    check('later flag change is freshly observed',int(row[3])&32 and int(row[3])&16 and not int(row[3])&64)
    observed=until(comparisons,lambda v:any(r['fd']==clo and r['child_cloexec'] is False and r['parent_cloexec'] is True for r in v.get('rows',[])),'MCP changed flags')
    check('MCP distinguishes parent and changed child flags',True)
    command('e')
    previous=int(re.findall(r'fdinherit sequence=(\d+)',audit())[-1])
    until(audit,lambda t:any(int(x)>previous for x in re.findall(r'fdinherit sequence=(\d+)',t)),'post-exec snapshot')
    d.shot('after-exec')
    # Only records drawn after the newest sequence are relevant.
    def current_rows():
        current=audit().rsplit('xodb: fdinherit sequence=',1)[1]
        return re.findall(r'fdinherit-row parent=(\d+) child=(\d+) fd=(\d+) flags=(\d+) x=([\d.]+) y=([\d.]+)',current)
    live_rows=until(current_rows,lambda rows:any(int(r[1])==child and int(r[2])==keep for r in rows),'post-exec rows rendered')
    check('CLOEXEC row disappears after actual exec',not any(int(r[1])==child and int(r[2])==clo for r in live_rows))
    kept=[r for r in live_rows if int(r[1])==child and int(r[2])==keep]
    check('ordinary descriptor remains visible after exec',bool(kept))
    _,_,_,_,x,y=kept[-1];d.keys('click',round(float(x)),round(float(y)))
    until(audit,lambda t:bool(re.search(r'files collector .*filter_pid='+str(child)+r' ',t)),'child Files drill-in')
    check('row click opens the sampled child Files identity',True)
    d.keys('tap',34) # G requests tracing only for our two owned processes.
    until(flow,lambda v:v.get('requested'),'graph capture demand')
    d.keys('tap',23) # I returns to polling comparison.
    f=until(flow,lambda v:v and not v['requested'] and not v['running'],'return to polling')
    check('comparison stops graph tracing',f['active_cpus']==0)
    counts=re.findall(r'overview layout .*panel=inheritance overlaps=(\d+)',audit())
    check('comparison text has no overlap',bool(counts) and all(int(n)==0 for n in counts))
    check('application remains alive',d.alive())
finally:
    if d:d.close()
    if fixture.poll() is None:fixture.stdin.write('q\n');fixture.stdin.flush()
    try:fixture.wait(timeout=10)
    except subprocess.TimeoutExpired:fixture.send_signal(signal.SIGTERM);fixture.wait(timeout=5)
    assert fixture.returncode==0,fixture.stderr.read()
    (work/'results.json').write_text(json.dumps({'checks':results,'seconds':time.monotonic()-started},indent=2)+'\n')
print('parent/child descriptor GUI checks PASS')
