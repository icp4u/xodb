#!/usr/bin/env python3
"""Owned descriptor graph/galaxy smoke checks on a private headless compositor."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work-dir',type=Path,required=True,help='empty, physically short directory for private display sockets')
p.add_argument('--binary',type=Path)
a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
base=a.work_dir.resolve();base.mkdir(parents=True,exist_ok=True);base.chmod(0o755)
assert not list(base.iterdir()), 'use an empty owned work directory'
work=base/'.work/input-graph';work.mkdir(parents=True)
for name in ('tmp','cache'):(work/name).mkdir()
spec=importlib.util.spec_from_file_location('graph_input',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(work)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-I',str(work),'tests/helpers/vinput.c',str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True)
fixture_code='''
import os,sys,socket,json
control=os.pipe();pipe=os.pipe();pair=socket.socketpair();deleted=open('deleted-fixture','w+b');os.unlink('deleted-fixture')
children=[]
for i in range(2):
    pid=os.fork()
    if pid==0:
        os.close(control[1]);os.read(control[0],1);os._exit(0)
    children.append(pid)
os.close(control[0]);print(json.dumps(children),flush=True)
sys.stdin.readline();os.close(control[1])
for child in children:
    _,status=os.waitpid(child,0);assert status==0
'''
fixture=subprocess.Popen([sys.executable,'-c',fixture_code],cwd=work,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
d=None;results=[]
def check(label,truth):
    results.append({'check':label,'status':'pass' if truth else 'fail'});print(('PASS ' if truth else 'FAIL ')+label,flush=True)
    assert truth,label
try:
    pids=json.loads(fixture.stdout.readline());check('fixture has two owned children',len(pids)==2)
    expected=sum(len(list(Path(f'/proc/{pid}/fd').iterdir())) for pid in pids)
    os.environ['XODB_OVERVIEW_AUDIT']='1';os.environ['XODB_OVERVIEW_LAYOUT']='1'
    options=['--overview','--panel','galaxy','--redact']
    for pid in pids:options+=['--graph-pid',str(pid)]
    d=h.Display(str(root),options,trace=False,stdio=False,binary=str(a.binary.resolve()) if a.binary else None)
    end=time.monotonic()+30
    pattern=r'fdgraph sequence=(\d+) processes=(\d+) descriptors=(\d+) peer_edges=(\d+) stars=(\d+) particles=(\d+) scope_count=(\d+)'
    while True:
        text=Path(d.log).read_text(errors='replace');rows=re.findall(pattern,text)
        if rows and int(rows[-1][0])>=2:break
        if not d.alive() or time.monotonic()>end:raise RuntimeError(text[-3000:])
        time.sleep(.05)
    last=tuple(map(int,rows[-1]));check('actual collector scope excludes all other processes',last[1]==2 and last[6]==2)
    check('two complete snapshots preserve every fixture descriptor',last[2]==expected)
    check('UNIX socketpair link is present after metadata cache refresh',last[3]==1)
    check('redacted galaxy has a visible title', 'descriptor galaxy' in h.ocr_until(d,'galaxy',lambda t:'descriptor galaxy' in t))
    d.keys('tap',46) # C: expand cgroup groups to process stars
    time.sleep(.1)
    d.keys('tap',34) # G: shared topology
    check('graph view renders', 'shared files' in h.ocr_until(d,'graph',lambda t:'shared files' in t))
    # The two process stars sit at the top and bottom of the circle. Focus the
    # top one through the actual hit box, then use its existing Files drill-in.
    positions=re.findall(r'fdgraph-star panel=graph star=\d+ pid=(\d+) x=([\d.]+) y=([\d.]+)',Path(d.log).read_text())
    positions=[row for row in positions if int(row[0]) in pids]
    check('owned process has a rendered hit box',bool(positions))
    _,x,y=positions[-1]
    d.keys('click',round(float(x)),round(float(y)))
    d.keys('tap',38) # L
    text=h.ocr_until(d,'files',lambda t:'file redacted' in t or 'pipe redacted' in t)
    check('focused Files rows are visibly rendered','file redacted' in text or 'pipe redacted' in text)
    # Sidebar titles can remain visible: the collector audit proves the drill-in.
    end=time.monotonic()+10
    while time.monotonic()<end:
        audit=Path(d.log).read_text(errors='replace')
        if re.search(r'files collector .*filter_pid=(?:'+ '|'.join(map(str,pids))+r') ',audit):break
        time.sleep(.05)
    check('node drill-in selects an owned Files identity',bool(re.search(r'files collector .*filter_pid=(?:'+'|'.join(map(str,pids))+r') ',audit)))
    for panel in ('graph','galaxy'):
        counts=re.findall(r'overview layout .*panel='+panel+r' overlaps=(\d+)',audit)
        check(panel+' has audited nonoverlapping text',bool(counts) and all(int(n)==0 for n in counts))
    check('application remains alive',d.alive())
finally:
    if d:d.close()
    if fixture.poll() is None:
        fixture.stdin.write('q\n');fixture.stdin.flush()
    try:fixture.wait(timeout=10)
    except subprocess.TimeoutExpired:
        fixture.send_signal(signal.SIGTERM);fixture.wait(timeout=5)
    assert fixture.returncode==0, fixture.stderr.read()
    (work/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print('descriptor graph GUI checks PASS')
