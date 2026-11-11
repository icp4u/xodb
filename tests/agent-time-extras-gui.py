#!/usr/bin/env python3
"""Fast private GUI: fleet window, inferred tasks, cache overlay and live append."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

p=argparse.ArgumentParser();p.add_argument('--binary');p.add_argument('--recovery',action='store_true');args=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
work=root/'.work'/('input-ate'+str(time.time_ns())[-8:]);work.mkdir(parents=True)
spec=importlib.util.spec_from_file_location('input_helper',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(work)
for name in ('tmp','cache/mesa','cache/nvidia'):(work/name).mkdir(parents=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-I',str(work),'tests/helpers/vinput.c',str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True)
home=work/'home';home.mkdir();os.environ['HOME']=str(home);os.environ['CODEX_HOME']=str(home/'.codex')
source=home/'.codex/sessions/1970/01/02/rollout-synthetic.jsonl';source.parent.mkdir(parents=True)
def cx(t,kind,**fields):
    return {'timestamp':t,'type':'response_item' if kind=='message' else 'event_msg','payload':{'type':kind,**fields}}
source.write_text(''.join(json.dumps(r)+'\n' for r in [cx(86401,'task_started'),cx(86401,'message',role='user',content=[{'type':'input_text','text':'A33-M1 synthetic work'}]),cx(86402,'token_count',info={'total_token_usage':{'input_tokens':100,'cached_input_tokens':20,'output_tokens':30}}),cx(86403,'task_complete')]))
other=home/'.claude/projects/example/other.jsonl';other.parent.mkdir(parents=True)
other.write_text(''.join(json.dumps(r)+'\n' for r in [{'timestamp':86401,'type':'user','message':{'content':'A33-M2 synthetic work'}},{'timestamp':86403,'type':'assistant','message':{'content':[],'stop_reason':'end_turn'}}]))
os.utime(other,(100,100));os.utime(source,(200,200))
def expect(d,name,needle,psm='6'):
    text=h.ocr_until(d,name,lambda t:needle in t,'--psm',psm)
    assert needle in text,text
    return text
def wait_log(d,needle,count=1):
    deadline=time.monotonic()+15*h.load_scale()
    while Path(d.log).read_text(errors='replace').count(needle)<count:
        assert d.app.poll() is None,d.tail()
        assert time.monotonic()<deadline,d.tail()
        time.sleep(.02)
def dates(d,value):
    codes={str(n):n+1 for n in range(1,10)}|{'0':11,'-':12,'.':52}
    commands=[]
    for char in value:commands+=['tap',codes[char]]
    d.keys('tap',32,*commands,'tap',28)
d=None;started=time.monotonic();delayed_pid=None
delay_flag=work/'delay-refresh';pidfile=work/'refresh.pid';wrapper=work/'tools/python3'
if args.recovery:
    wrapper.parent.mkdir()
    wrapper.write_text('#!'+sys.executable+'\nimport os,sys,time\nfrom pathlib import Path\n'
        +f'if "--live" in sys.argv and Path({str(delay_flag)!r}).exists():\n'
        +f' Path({str(pidfile)!r}).write_text(str(os.getpid()))\n time.sleep(30)\n'
        +f'os.execv({sys.executable!r},[{sys.executable!r}]+sys.argv[1:])\n')
    wrapper.chmod(0o755)
    os.environ['PATH']=str(wrapper.parent)+os.pathsep+os.environ['PATH']
try:
    d=h.Display(str(root),['--agent-time'],stdio=False,binary=args.binary)
    expect(d,'catalog','tokens 130')
    dates(d,'1970-01-02..1970-01-02')
    d.keys('tap',33) # F fleet
    expect(d,'fleet','fleet / 2 sessions')
    if args.recovery:
        d.keys('tap',20)
        expect(d,'fleet-live-refused','live: single log only')
    d.keys('tap',25) # P task packets
    expect(d,'tasks','task packets (inferred)')
    d.keys('tap',46) # C cache input overlay (also token mode)
    expect(d,'cache','cache read 20/100 input (20.0%)',psm='11')
    d.keys('tap',38) # L time chart
    expect(d,'timeline','token markers')
    d.keys('tap',48) # B then Enter opens selected single log
    expect(d,'back','agent sessions')
    d.keys('tap',28)
    expect(d,'single','a33-m1 synthetic work',psm='11')
    d.keys('tap',20) # T live
    expect(d,'live','live: watching')
    wait_log(d,'agent-time live updated mode=rebuild')
    with source.open('a') as f:
        f.write(''.join(json.dumps(r)+'\n' for r in [cx(86404,'task_started'),cx(86405,'token_count',info={'total_token_usage':{'input_tokens':200,'cached_input_tokens':50,'output_tokens':60}}),cx(86406,'task_complete')]))
    wait_log(d,'agent-time live updated mode=append')
    expect(d,'appended','2 turns')
    d.keys('tap',46)
    expect(d,'live-tokens','cache read 50/200 input (25.0%)',psm='11')
    if args.recovery: # Periodic: extra refresh cycles exceed the fast GUI budget.
        missing=source.with_suffix('.held')
        source.rename(missing)
        try:
            expect(d,'failed-refresh','live: agentlogreadfailed',psm='11')
            expect(d,'retained','cache read 50/200 input (25.0%)',psm='11')
        finally:missing.rename(source)
        wait_log(d,'agent-time live updated mode=rebuild',count=2)
        expect(d,'recovered','live: watching')
    # Unchanged polls are separately proven parser-free in the adapter suite.
    # Here verify stop and clean exit with an enabled refresh owner.
    d.keys('tap',20)
    expect(d,'stopped','live: off')
    if args.recovery:
        # Delay only a refresh helper (not discovery/import). Observe its owned
        # PID before Q, so cleanup proof cannot pass without a live child.
        delay_flag.write_text('owned delay')
        d.keys('tap',20)
        deadline=time.monotonic()+15*h.load_scale()
        while not pidfile.exists():
            assert d.app.poll() is None,d.tail()
            assert time.monotonic()<deadline,d.tail()
            time.sleep(.02)
        delayed_pid=int(pidfile.read_text())
        assert str(wrapper).encode() in Path('/proc',str(delayed_pid),'cmdline').read_bytes()
        d.keys('tap',16)
    else:d.keys('tap',20,'tap',16)
    assert d.app.wait(timeout=10)==0,d.tail()
    if delayed_pid is not None:assert not Path('/proc',str(delayed_pid)).exists(),'refresh helper survived Q'
    print(json.dumps({'status':'pass','seconds':round(time.monotonic()-started,3)}))
finally:
    if d:d.close()
    if delayed_pid is not None:
        command=Path('/proc',str(delayed_pid),'cmdline')
        try:
            if str(wrapper).encode() in command.read_bytes():os.kill(delayed_pid,15)
        except FileNotFoundError:pass
