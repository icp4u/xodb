#!/usr/bin/env python3
"""Fast GUI lane: the descriptor galaxy's threads, impulses, caps and idle state.

Uses the synthetic scene (--galaxy-demo), so nothing is read from other
processes and no tracing starts. Private headless compositor only."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work-dir',type=Path,required=True,help='empty, physically short directory for private display sockets')
p.add_argument('--binary',type=Path)
a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
base=a.work_dir.resolve();base.mkdir(parents=True,exist_ok=True);base.chmod(0o755)
assert not list(base.iterdir()),'use an empty owned work directory'
work=base/'.work/input-galaxy';work.mkdir(parents=True)
for name in ('tmp','cache'):(work/name).mkdir()
spec=importlib.util.spec_from_file_location('galaxy_input',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(work)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-I',str(work),'tests/helpers/vinput.c',str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True)
# The caps documented in src/ui/overview/galaxy.zig and docs/OVERVIEW.md.
CAPS={'drawn':192,'impulses':320,'cloud':22000,'mesh':7000,'labels':14}
results=[];d=None
def check(label,truth):
    results.append({'check':label,'status':'pass' if truth else 'fail'});print(('PASS ' if truth else 'FAIL ')+label,flush=True)
    assert truth,label
def frames():
    text=Path(d.log).read_text(errors='replace')
    assert 'panic' not in text and 'Draw failed' not in text and 'frame failed' not in text,text[-2000:]
    return [dict(pair.split('=') for pair in line.split()) for line in re.findall(r'galaxy-frame (.*)',text)]
def until(fn,label):
    end=time.monotonic()+20*h.load_scale()
    while True:
        value=fn()
        if value:return value
        assert d.alive() and time.monotonic()<end,(label,d.tail())
        time.sleep(.02)
def show(demo):
    global d
    if d:d.close()
    d=h.Display(str(root),['--overview','--galaxy-demo',demo],trace=False,stdio=False,binary=str(a.binary.resolve()) if a.binary else None)
def frames_during(seconds):
    """Frames presented in a wall-clock window; compared between states, never against a constant."""
    start=len(frames());time.sleep(seconds);return len(frames())-start
began=time.monotonic()
try:
    os.environ['XODB_OVERVIEW_AUDIT']='1';os.environ['XODB_OVERVIEW_LAYOUT']='1'
    show('24')
    first=until(lambda:[f for f in frames() if int(f['strands'])>0 and int(f['impulses'])>0],'threads and impulses')[0]
    check('a scene with flow draws threads and impulses',first['stars']=='24' and int(first['drawn'])>0 and first['moving']=='1')
    text=h.ocr_until(d,'demo',lambda t:'descriptor galaxy' in t and 'synthetic' in t)
    check('the synthetic scene says so on screen','descriptor galaxy' in text and 'synthetic' in text)
    # Thirty animated frames set the window every other state is compared in.
    count=len(frames());started=time.monotonic()
    until(lambda:len(frames())>=count+30,'animation keeps presenting frames')
    window=time.monotonic()-started
    moving=frames()[count:count+30]
    check('impulses move on a clock that advances',len({f['clock'] for f in moving})==30 and all(f['moving']=='1' for f in moving))
    d.keys('tap',25) # P: pause
    until(lambda:frames()[-1]['moving']=='0','pause stops the animation')
    count=len(frames());time.sleep(window);paused=frames()[count:]
    check('paused impulses stay drawn and frozen',all(f['moving']=='0' and int(f['impulses'])>0 for f in paused) and len({f['clock'] for f in paused})<=1)
    check('a paused galaxy stops requesting frames',len(paused)*3<=30)
    d.keys('tap',25)
    until(lambda:frames()[-1]['moving']=='1','resume restarts the animation')
    check('resume restarts the impulses',True)
    overlaps=re.findall(r'overview layout .*panel=galaxy overlaps=(\d+)',Path(d.log).read_text(errors='replace'))
    check('labels do not overlap each other or the text rows',bool(overlaps) and all(int(n)==0 for n in overlaps))

    show('24:idle')
    until(lambda:[f for f in frames() if int(f['strands'])>0],'idle threads')
    idle=frames_during(window)
    quiet=frames()
    check('an idle scene keeps its threads and has no impulses',all(f['impulses']=='0' and f['moving']=='0' and f['strands']==first['strands'] for f in quiet))
    check('an idle galaxy reaches a frame-idle state',idle*3<=30)

    show('1024')
    crowd=until(lambda:[f for f in frames() if f['stars']=='1024'],'crowded scene')[0]
    check('a crowd keeps its clusters and stays inside every cap',int(crowd['clusters'])>=8 and int(crowd['strands'])>CAPS['drawn'] and all(int(crowd[key])<=cap for key,cap in CAPS.items()) and float(crowd['buffer'])<0.9)
    check('application remains alive',d.alive())
finally:
    if d:d.close()
    (work/'results.json').write_text(json.dumps({'checks':results,'elapsed_seconds':time.monotonic()-began},indent=2)+'\n')
print('descriptor galaxy GUI checks PASS')
