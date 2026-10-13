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
results=[];d=None;resources={}
def usage():
    fields=Path('/proc/'+str(d.app.pid)+'/stat').read_text().split(') ',1)[1].split()
    return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),rss_bytes=int(fields[21])*os.sysconf('SC_PAGE_SIZE'))
def check(label,truth):
    results.append({'check':label,'status':'pass' if truth else 'fail'});print(('PASS ' if truth else 'FAIL ')+label,flush=True)
    assert truth,label
def frames():
    text=Path(d.log).read_text(errors='replace')
    assert 'panic' not in text and 'Draw failed' not in text and 'frame failed' not in text,text[-2000:]
    return [dict(pair.split('=') for pair in line.split()) for line in re.findall(r'galaxy-frame (.*)',text)]
def looks():
    return [dict(pair.split('=') for pair in line.split()) for line in re.findall(r'galaxy-look (.*)',Path(d.log).read_text(errors='replace'))]
def point(kind):
    return tuple(round(float(v)) for v in re.findall(r'galaxy-'+kind+r' x=([\d.-]+) y=([\d.-]+)',Path(d.log).read_text())[-1])
def until(fn,label):
    end=time.monotonic()+20*h.load_scale()
    while True:
        value=fn()
        if value:return value
        assert d.alive() and time.monotonic()<end,(label,d.tail())
        time.sleep(.02)
def show(demo,config=None):
    global d
    if d:d.close()
    options=['--overview','--galaxy-demo',demo]
    if config:
        path=work/'look.json';path.write_text(json.dumps({'galaxy':config}))
        options+=['--config',str(path)]
    d=h.Display(str(root),options,trace=False,stdio=False,binary=str(a.binary.resolve()) if a.binary else None)
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
    count=len(frames());started=time.monotonic();resources['before']=usage();resources['load']=os.getloadavg();resources['cpus']=os.cpu_count()
    until(lambda:len(frames())>=count+30,'animation keeps presenting frames')
    window=time.monotonic()-started
    resources['after']=usage();resources['window_seconds']=window;resources['one_core_percent']=100*(resources['after']['cpu_seconds']-resources['before']['cpu_seconds'])/window
    moving=frames()[count:count+30]
    check('impulses move on a clock that advances',len({f['clock'] for f in moving})==30 and all(f['moving']=='1' for f in moving))
    look=looks()
    check('static cloud retained while impulses animate',len({f['builds'] for f in look[-20:]})==1)
    check('additive diffuse clouds and unfolded larger budget are default',look[-1]['additive']=='1' and float(look[-1]['cloud_size'])>1 and look[-1]['unfolded']=='1' and int(look[-1]['max_stars'])>=512)
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

    count=len(looks())
    d.keys('m',*point('cluster'))
    until(lambda:len(looks())>count,'hover frame')
    check('hover does not move the cloud under the pointer',all(float(row['zoom'])==1 and row['camera']=='0' for row in looks()[count:]))
    d.keys('click',*point('cluster'))
    until(lambda:float(looks()[-1]['zoom'])>1.05,'selected camera zoom')
    until(lambda:looks()[-1]['camera']=='0','camera settles')
    d.shot('camera')
    check('camera eases through intermediate zooms',len({f['zoom'] for f in looks() if 1<float(f['zoom'])<1.3})>1)
    d.keys('click',*point('cluster')) # toggle explicit selection off
    until(lambda:looks()[-1]['camera']=='0' and float(looks()[-1]['zoom'])==1,'camera returns')
    d.keys('m',*point('thread'))
    until(lambda:looks()[-1]['thread']!='4294967295','hoverable thread')
    d.shot('thread-tags')
    check('thread hit-test follows the drawn curve',True)

    show('24:idle')
    until(lambda:[f for f in frames() if int(f['strands'])>0],'idle threads')
    idle=frames_during(window)
    quiet=frames()
    check('an idle scene keeps its threads and has no impulses',all(f['impulses']=='0' and f['moving']=='0' and f['strands']==first['strands'] for f in quiet))
    check('an idle galaxy reaches a frame-idle state',idle*3<=30)

    show('1024')
    crowd=until(lambda:[f for f in frames() if f['stars']=='1024'],'crowded scene')[0]
    check('a crowd keeps its clusters and stays inside every cap',int(crowd['clusters'])>=8 and int(crowd['strands'])>CAPS['drawn'] and all(int(crowd[key])<=cap for key,cap in CAPS.items()) and float(crowd['buffer'])<0.9)
    resources['crowd']=usage()
    d.shot('crowd')
    show('24:idle',{'additive':False,'cloud_size':0.8,'brightness':0.5,'camera_zoom':1,'max_stars':128,'unfold':False})
    until(lambda:looks(),'explicit look preferences')
    custom=looks()[-1]
    check('explicit preferences reach the renderer',custom['additive']=='0' and float(custom['cloud_size'])==0.8 and custom['max_stars']=='128' and custom['unfolded']=='0')
    check('application remains alive',d.alive())
finally:
    if d:d.close()
    (work/'results.json').write_text(json.dumps({'checks':results,'resources':resources,'elapsed_seconds':time.monotonic()-began},indent=2)+'\n')
print('descriptor galaxy GUI checks PASS')
