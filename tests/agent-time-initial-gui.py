#!/usr/bin/env python3
"""First-live release, cancellation/reload and pending-view input; private Sway."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
p=argparse.ArgumentParser();p.add_argument('--binary');p.add_argument('--recovery',action='store_true');args=p.parse_args()
work=root/'.work'/('input-ati'+str(time.time_ns())[-8:]);work.mkdir(parents=True)
spec=importlib.util.spec_from_file_location('input_helper',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(work)
for name in ('tmp','cache/mesa','cache/nvidia'):(work/name).mkdir(parents=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-I',str(work),'tests/helpers/vinput.c',str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True)
home=work/'home';home.mkdir();os.environ['HOME']=str(home);os.environ['CODEX_HOME']=str(home/'.codex')
source=work/'session.jsonl'
def cx(t,kind,**fields):return {'timestamp':t,'type':'response_item' if kind=='message' else 'event_msg','payload':{'type':kind,**fields}}
source.write_text(''.join(json.dumps(row)+'\n' for row in [cx(1,'task_started'),cx(1,'message',role='user',content=[{'type':'input_text','text':'Initial live fixture'}]),cx(2,'token_count',info={'total_token_usage':{'input_tokens':100,'cached_input_tokens':20,'output_tokens':30}}),cx(3,'task_complete')]))
flag=work/'hold';pidfile=work/'helper.pid';wrapper=work/'tools/python3';wrapper.parent.mkdir()
wrapper.write_text('#!'+sys.executable+'\nimport os,sys,time\nfrom pathlib import Path\n'
    +f'if "--live" in sys.argv and Path({str(flag)!r}).exists():\n'
    +f' Path({str(pidfile)!r}).write_text(str(os.getpid()))\n'
    +f' while Path({str(flag)!r}).exists():time.sleep(.02)\n'
    +f'os.execv({sys.executable!r},[{sys.executable!r}]+sys.argv[1:])\n')
wrapper.chmod(0o755);os.environ['PATH']=str(wrapper.parent)+os.pathsep+os.environ['PATH']
def wait(d,predicate):
    deadline=time.monotonic()+15*h.load_scale()
    while not predicate():
        assert d.app.poll() is None,d.tail()
        assert time.monotonic()<deadline,d.tail()
        time.sleep(.02)
def logtext(d):return Path(d.log).read_text(errors='replace')
def logged(d,text,count=1):wait(d,lambda:logtext(d).count(text)>=count)
def expect(d,name,needle):
    text=h.ocr_until(d,name,lambda text:needle in text,'--psm','11')
    assert needle in text,text
    return text
def hold(d):
    pidfile.unlink(missing_ok=True);flag.write_text('owned hold');d.keys('tap',20)
    wait(d,pidfile.exists);pid=int(pidfile.read_text())
    assert str(wrapper).encode() in Path('/proc',str(pid),'cmdline').read_bytes()
    return pid
def gone(d,pid):wait(d,lambda:not Path('/proc',str(pid)).exists())
d=None;started=time.monotonic();held=[]
try:
    d=h.Display(str(root),['--agent-time','--agent-kind','codex','--agent-log',str(source)],stdio=False,binary=args.binary)
    logged(d,'agent-time ready');d.keys('tap',46) # C: retain weight choice across startup/cancel.
    pid=hold(d);held.append(pid)
    text=expect(d,'pending','previous snapshot released')
    logged(d,'agent-time live initial view released')
    assert 'initial live fixture' not in text,text
    # Text input must still capture Q when no profile/selection exists.
    d.keys('tap',53,'tap',16);expect(d,'pending-search','search: q')
    d.keys('tap',1,'tap',53,'tap',1) # leave, clear search, leave
    d.keys('tap',20);gone(d,pid)
    logged(d,'cancelled initial live load; reloading offline');logged(d,'agent-time ready',2)
    expect(d,'offline-restored','initial live fixture');expect(d,'weight-retained','token burn')
    flag.unlink();d.keys('tap',20);logged(d,'live updated mode=rebuild')
    expect(d,'live-complete','cache read 20/100 input (20.0%)')
    if args.recovery:
        d.keys('tap',20);expect(d,'before-failure','live: off')
        missing=source.with_suffix('.held');source.rename(missing)
        try:
            d.keys('tap',20)
            expect(d,'initial-failure','work log unavailable: agentlogreadfailed')
            expect(d,'initial-failure-hint','t stops live and reloads offline')
            released=logtext(d).count('live initial view released')
            assert released==3,d.tail()
        finally:missing.rename(source)
        logged(d,'live updated mode=rebuild',2)
        assert logtext(d).count('live initial view released')==released,'automatic recovery discarded a view again'
        expect(d,'initial-recovered','initial live fixture')
        d.keys('tap',20);expect(d,'before-browser','live: off')
        pid=hold(d);held.append(pid);d.keys('tap',48);gone(d,pid)
        expect(d,'browser','agent sessions')
        assert logtext(d).count('reloading offline')==1,'browser entry triggered an unnecessary offline reload'
        d.keys('tap',16)
    else:
        d.keys('tap',20);expect(d,'before-quit','live: off')
        pid=hold(d);held.append(pid);d.keys('tap',16)
    assert d.app.wait(timeout=10)==0,d.tail()
    assert all(not Path('/proc',str(pid)).exists() for pid in held),'held helper survived exit'
    print(json.dumps({'status':'pass','seconds':round(time.monotonic()-started,3)}))
finally:
    if d:d.close()
    for pid in held:
        try:
            if str(wrapper).encode() in Path('/proc',str(pid),'cmdline').read_bytes():os.kill(pid,15)
        except FileNotFoundError:pass
