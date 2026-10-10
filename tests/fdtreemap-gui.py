#!/usr/bin/env python3
"""Fast lane: owned descriptor treemap, navigation and passive MCP (under 15s).

--live is periodic and requires existing tracing permission; never configures it.
"""
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
from types import SimpleNamespace

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work-dir',type=Path,required=True)
p.add_argument('--binary',type=Path)
p.add_argument('--wrong-oracle',action='store_true')
p.add_argument('--live',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
base=a.work_dir.resolve();base.mkdir(parents=True,exist_ok=True);base.chmod(0o755)
assert not list(base.iterdir()),'use an empty owned directory'
work=base/'.work/input-treemap';work.mkdir(parents=True)
for name in ('tmp','cache'):(work/name).mkdir()
spec=importlib.util.spec_from_file_location('treemap_input',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(work);h.HELPER=str(work/'vinput')
# Privileged wrappers may launch a child; only accept our own descendant in
# this test's private compositor. The unprivileged fast lane has no wrapper.
if a.live:
    def focused(self,seconds=30):
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
                    if current==self.app.pid:self.actual_pid=pid;return
                    seen.add(current)
                    try:status=Path(f'/proc/{current}/status').read_text()
                    except FileNotFoundError:break
                    current=int(re.search(r'^PPid:\s+(\d+)',status,re.M)[1])
            time.sleep(.02)
        raise AssertionError('owned window not mapped: '+self.tail())
    h.Display.wait_focused=focused

for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    for mode,suffix in (('client-header','.h'),('private-code','.c')):
        subprocess.run(['wayland-scanner',mode,xml,str(work/(stem+suffix))],check=True,timeout=10)
subprocess.run(['cc','-I',str(work),'tests/helpers/vinput.c',str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=30)
fixture_code=r'''
import os,sys,json,ctypes
libc=ctypes.CDLL(None);boss=os.getppid();assert libc.prctl(1,9)==0 and os.getppid()==boss
os.mkdir('tree');fds=[os.open('tree/item%03d'%i,os.O_CREAT|os.O_RDWR,0o600) for i in range(80)]
fds.append(os.open(b'tree/nonutf-\xff',os.O_CREAT|os.O_RDWR,0o600));deleted=os.open('gone',os.O_CREAT|os.O_RDWR,0o600);os.unlink('gone')
long='long';os.mkdir(long)
for i in range(16):long+='/'+('z'*210+str(i));os.mkdir(long)
longfds=[os.open(long+'/item%03d'%i,os.O_CREAT|os.O_RDWR,0o600) for i in range(40)]
pipe=os.pipe();print(json.dumps({'pid':os.getpid(),'fd':fds[0],'path':os.path.realpath('tree'),'long':os.path.realpath(long)}),flush=True)
for line in sys.stdin:
    op=line.strip()
    if op=='r':os.rename('tree','renamed')
    elif op=='p':pass
    elif op=='b':
        assert os.write(fds[0],b'x'*65536)==65536
    else:break
    print('ready',flush=True)
'''
fixture=subprocess.Popen([sys.executable,'-c',fixture_code],cwd=work,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
d=None;shared=None;results=[];began=time.monotonic()
def check(label,truth):
    results.append({'check':label,'status':'pass' if truth else 'fail'});print(('PASS ' if truth else 'FAIL ')+label,flush=True);assert truth,label

def until(fn,predicate,label,seconds=15):
    end=time.monotonic()+seconds;last=None
    while time.monotonic()<end:
        last=fn()
        if predicate(last):return last
        assert d.alive(),d.tail();time.sleep(.015)
    raise AssertionError((label,last,d.tail()))

def audit():return Path(d.log).read_text(errors='replace')
def raw(name,args):
    d.serial+=1;d.app.stdin.write((json.dumps({'jsonrpc':'2.0','id':d.serial,'method':'tools/call','params':{'name':name,'arguments':args}})+'\n').encode());d.app.stdin.flush()
    end=time.monotonic()+10
    while time.monotonic()<end:
        assert select.select([d.app.stdout],[],[],max(0,end-time.monotonic()))[0],'MCP timeout'
        reply=json.loads(d.app.stdout.readline())
        if 'id' not in reply:d.notifications.append(reply);continue
        assert reply['id']==d.serial,reply;return reply
    raise AssertionError('MCP timeout')

def tree(**args):
    reply=raw('get_fd_treemap',args)
    assert 'result' in reply,reply
    result=reply['result']
    if result.get('isError'):
        assert result['content'][0]['text'] in ('FdCacheBusy','FdSnapshotPending','FdSnapshotChanged'),result;return {}
    return result['structuredContent']

def tap(*codes):
    helper=d.keys('burst',len(codes),*codes,wait=False);assert helper.wait(timeout=5)==0

def click(x,y):
    helper=d.keys('fastclick',round(x),round(y),wait=False);assert helper.wait(timeout=5)==0

def find_path(path):
    wanted=os.fsencode(path)
    for attempt in range(20):
        current=tree(limit=32);chain=[]
        if not current:continue
        for depth in range(33):
            here=bytes.fromhex(current['path_hex'])
            if here==wanted:return current,chain
            candidates=[t for t in current['tiles'] if t['kind']=='child' and t['namespace_kind']==0 and (wanted==bytes.fromhex(t['path_hex']) or wanted.startswith(bytes.fromhex(t['path_hex'])+b'/'))]
            assert len(candidates)==1,(wanted,current)
            row=candidates[0];chain.append(row['node']);current=tree(node=row['node'],sequence=current['sequence'],limit=32)
            if not current:break
    raise AssertionError('no coherent path traversal')

def latest_tiles():
    # Frames start with the tile whose index is zero.
    content=audit();at=content.rfind('xodb: fdtreemap-tile focus=')
    if at<0:return []
    rows=re.findall(r'fdtreemap-tile focus=(\d+) index=(\d+) node=(\d+) kind=(\d+) fds=(\d+) x=([\d.]+) y=([\d.]+) w=([\d.]+) h=([\d.]+)',content)
    first=max(i for i,r in enumerate(rows) if r[1]=='0');return rows[first:]

def zoom(chain):
    focus=0
    for node in chain:
        row=until(latest_tiles,lambda rows:any(int(r[0])==focus and int(r[2])==node and r[3]=='0' for r in rows),'zoom tile')
        r=next(r for r in row if int(r[0])==focus and int(r[2])==node and r[3]=='0')
        click(float(r[5])+float(r[7])/2,float(r[6])+float(r[8])/2);focus=node
        until(latest_tiles,lambda rows:rows and int(rows[0][0])==focus,'zoom selected')

def command(op):
    fixture.stdin.write(op+'\n');fixture.stdin.flush();assert select.select([fixture.stdout],[],[],10)[0];assert fixture.stdout.readline().strip()=='ready'

def cost():
    pid=getattr(d,'actual_pid',d.app.pid)
    fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
    return {'cpu_ns':int((int(fields[11])+int(fields[12]))*1e9/os.sysconf('SC_CLK_TCK')),'rss':int(Path(f'/proc/{pid}/statm').read_text().split()[1])*os.sysconf('SC_PAGESIZE'),'load':os.getloadavg()}

try:
    setup=json.loads(fixture.stdout.readline());pid=setup['pid'];expected=len(list(Path(f'/proc/{pid}/fd').iterdir()))
    os.environ['XODB_OVERVIEW_AUDIT']='1';os.environ['XODB_OVERVIEW_LAYOUT']='1'
    ipc=work/'ipc';ipc.mkdir(mode=0o700);socket_path=ipc/'session.sock'
    options=['--overview','--panel','treemap','--graph-pid',str(pid)]
    if not a.live:options+=['--session-socket',str(socket_path)]
    d=h.Display(str(root),options,stdio=True,binary=str(a.binary.resolve()) if a.binary else None)
    current=until(tree,lambda t:t.get('metric',{}).get('descriptors')==expected,'complete owned tree')
    check('all owned descriptors counted',current['metric']['descriptors']==expected+int(a.wrong_oracle))
    check('area is handle count and identity uncertainty is explicit','different inodes' in current['evidence'])
    check('fixture deleted-but-open descriptor is represented',current['metric']['deleted']==1)
    definition=next(t for t in d.request('tools/list',{})['tools'] if t['name']=='get_fd_treemap')
    check('MCP tool is observer-only',definition['annotations']['readOnlyHint'] and definition['annotations']['xodbSessionAccess']=='observer')
    if a.live:
        until(tree,lambda t:t.get('system_flow',{}).get('running'),'live capture')
        until(lambda:(command('p'),tree())[1],lambda t:t.get('metric',{}).get('flow_measured',0)>0,'live binding proven by owned pipe IO')
        before,_=find_path(setup['path']+'/item000');command('b')
        after=until(lambda:find_path(setup['path']+'/item000')[0],lambda t:t['metric']['write_bytes']>=before['metric']['write_bytes']+65536,'owned file bytes')
        check('live write bytes match the independent fixture',after['metric']['write_bytes']-before['metric']['write_bytes']==65536)
        until(audit,lambda t:any(int(n)>=65536 for n in re.findall(r'fdtreemap .*running=1 .*write=(\d+)',t)),'GUI live bytes')
        live=h.ocr_until(d,'treemap-live',lambda t:'live syscall tracing' in t)
        check('live tracing cost is visibly disclosed','11%' in live and 'live syscall tracing' in live)
    tap(18) # E stops default-on tracing demand, including a denied start.
    until(tree,lambda t:t and not t['system_flow']['requested'] and not t['system_flow']['running'],'polling only')
    if not a.live:
        spec=importlib.util.spec_from_file_location('treemap_shared',root/'tests/shared-sessions.py')
        peer=importlib.util.module_from_spec(spec);spec.loader.exec_module(peer)
        shared=peer.Client(SimpleNamespace(path=socket_path,clients=[],proc=d.app),'treemap-observer')
        observed=until(lambda:shared.raw('get_fd_treemap'),lambda r:not r.get('result',{}).get('isError'),'shared observer')
        observed=observed['result']['structuredContent']
        check('shared observer sees same owned descriptors without tracing',observed['metric']['descriptors']==expected and not observed['system_flow']['requested'])
    before=cost()
    for _ in range(12):current=tree()
    after=cost();check('passive MCP reads leave capture stopped',current and not current['system_flow']['requested'])
    (work/'cost.json').write_text(json.dumps({'before':before,'after':after},indent=2)+'\n')
    capped=tree(limit=1);check('capped tiles conserve every descriptor',len(capped['tiles'])==1 and sum(t['metric']['descriptors'] for t in capped['tiles'])==expected and capped['tiles'][0]['hidden_items']>0)
    for arguments in ({'node':1},{'limit':33},{'sequence':0}):
        reply=raw('get_fd_treemap',arguments);check('invalid query refused '+str(arguments),reply.get('error',{}).get('message')=='InvalidArguments')
    reply=raw('get_fd_treemap',{'sequence':current['sequence']+100});check('mismatched sequence refused',reply.get('result',{}).get('isError') and reply['result']['content'][0]['text']=='FdSnapshotChanged')
    long,_=find_path(setup['long'])
    check('long-path output is bounded and exact',long['path'] is None and bytes.fromhex(long['path_hex'])==os.fsencode(setup['long']) and len(long['tiles'])==32 and sum(t['metric']['descriptors'] for t in long['tiles'])==40)
    check('long-path reply fits the MCP transport',len(json.dumps({'structuredContent':long,'content':[{'type':'text','text':json.dumps(long)}]}).encode())<1048576)
    selected,chain=find_path(setup['path']);check('literal subtree holds 81 fixture files',selected['metric']['descriptors']==81)
    zoom(chain)
    check('clicks zoom to C-selected directory',int(latest_tiles()[0][0])==selected['node'])
    check('tile cap has an explicit Other tile',any(r[3]=='3' for r in latest_tiles()))
    shot=h.ocr_until(d,'treemap',lambda t:'descriptor path treemap' in t and 'polling' in t)
    check('visible semantics include area and unexpanded counts','handles' in shot and 'unexpanded' in shot)
    tap(13) # + increases tile cap, revealing the non-UTF-8 leaf.
    until(latest_tiles,lambda rows:len(rows)==81,'expanded tile limit')
    tap(12) # - restores cap.
    until(latest_tiles,lambda rows:len(rows)==64,'reduced tile limit')
    seq=tree()['sequence']
    until(tree,lambda t:t.get('sequence',0)>seq,'new poll')
    check('selection persists across snapshots',int(latest_tiles()[0][0])==find_path(setup['path'])[0]['node'])
    command('r')
    until(latest_tiles,lambda rows:rows and rows[0][0]=='0','vanished exact path returns to root')
    renamed,chain=find_path(setup['path'].replace('/tree','/renamed'));zoom(chain)
    tap(14);until(latest_tiles,lambda rows:rows and int(rows[0][0])==renamed['parent'],'Backspace parent')
    tap(1);until(latest_tiles,lambda rows:rows and rows[0][0]=='0','Escape root')
    tap(38) # L: explicitly sampled holder's Files table.
    until(audit,lambda t:bool(re.search(r'files collector .*filter_pid='+str(pid)+r' ',t)),'sampled holder Files')
    check('drill-in opens the owned sampled holder',True)
    tap(48) # B: return to treemap (same polling preference).
    until(audit,lambda t:'panel=treemap' in t.rsplit('overview layout',1)[-1],'return to treemap')
    tap(45) # X: irrevocable redaction.
    redacted=until(tree,lambda t:t.get('redacted'),'redaction')
    check('redaction removes readable and exact path bytes',redacted['path'] is None and redacted['path_hex'] is None and all(t['path'] is None and t['path_hex'] is None for t in redacted['tiles']))
    shot=h.ocr_until(d,'redacted',lambda t:'path redacted' in t)
    check('redaction is visible','path redacted' in shot)
    counts=re.findall(r'overview layout .*panel=treemap overlaps=(\d+)',audit())
    check('text layout has no overlaps',bool(counts) and all(int(n)==0 for n in counts))
    check('application stays alive',d.alive())
finally:
    if shared:shared.close()
    if d:d.close()
    if fixture.poll() is None:fixture.stdin.write('q\n');fixture.stdin.flush()
    try:fixture.wait(timeout=5)
    except subprocess.TimeoutExpired:fixture.send_signal(signal.SIGTERM);fixture.wait(timeout=5)
    assert fixture.returncode==0,fixture.stderr.read()
    (work/'results.json').write_text(json.dumps({'checks':results,'seconds':time.monotonic()-began},indent=2)+'\n')
print('descriptor treemap GUI/MCP PASS')
