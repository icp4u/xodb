#!/usr/bin/env python3
"""Fast private GUI: a new child appears without restarting the live helper."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
p=argparse.ArgumentParser();p.add_argument('--binary');args=p.parse_args()
work=root/'.work'/('input-atc'+str(time.time_ns())[-8:]);work.mkdir(parents=True)
spec=importlib.util.spec_from_file_location('input_helper',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(work)
for name in ('tmp','cache/mesa','cache/nvidia'):(work/name).mkdir(parents=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-I',str(work),'tests/helpers/vinput.c',str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True)
source=work/'parent.jsonl';children=work/'parent/subagents';children.mkdir(parents=True)
def transcript(path,title,start,end,usage=None):
    path.write_text(''.join(json.dumps(row)+'\n' for row in [
        {'timestamp':start,'type':'user','message':{'content':title}},
        {'timestamp':end,'type':'assistant','message':{'id':title,'usage':usage or {},'content':[],'stop_reason':'end_turn'}}]))
transcript(source,'parent work',1,10)
transcript(children/'agent-z.jsonl','existing child',2,4)
def wait_log(d,needle):
    deadline=time.monotonic()+15*h.load_scale()
    while needle not in d.tail():
        assert d.app.poll() is None,d.tail()
        assert time.monotonic()<deadline,d.tail()
        time.sleep(.02)
def helpers(pid):
    result=[]
    for task in Path('/proc',str(pid),'task').glob('*'):
        try:
            for child in (task/'children').read_text().split():
                if 'python' in Path('/proc',child,'comm').read_text():result.append(int(child))
        except FileNotFoundError:pass
    return result
d=None;started=time.monotonic()
try:
    d=h.Display(str(root),['--agent-time','--agent-kind','claude','--agent-log',str(source)],stdio=False,binary=args.binary)
    wait_log(d,'agent-time ready');d.keys('tap',20)
    wait_log(d,'live updated mode=rebuild');before=helpers(d.app.pid);assert len(before)==1,before
    transcript(children/'agent-a.jsonl','new child',3,7,{'input_tokens':23,'cache_read_input_tokens':10,'output_tokens':7})
    wait_log(d,'live updated mode=append')
    assert helpers(d.app.pid)==before,'child discovery restarted the helper'
    assert d.tail().count('live updated mode=rebuild')==1,d.tail()
    d.keys('tap',46) # C selects tokens and cache overlay, including new child usage.
    needle='cache read 10/33 input (30.3%)'
    text=h.ocr_until(d,'new-child',lambda text:needle in text,'--psm','11')
    assert needle in text,text
    d.keys('tap',16);assert d.app.wait(timeout=10)==0,d.tail()
    assert all(not Path('/proc',str(pid)).exists() for pid in before),'helper survived Q'
    print(json.dumps({'status':'pass','seconds':round(time.monotonic()-started,3)}))
finally:
    if d:d.close()
