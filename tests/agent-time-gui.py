#!/usr/bin/env python3
"""Fast private-display work-log flame, weight switch, focus, search and archive."""
import importlib.util
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]
os.chdir(ROOT)
os.umask(0o022)
parser=argparse.ArgumentParser()
parser.add_argument('--binary')
args=parser.parse_args()
work=ROOT/'.work'/('input-at'+str(time.time_ns())[-8:])
work.mkdir(parents=True)
spec=importlib.util.spec_from_file_location('input_helper',ROOT/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
h.WORK=str(work)
for name in ('tmp','cache/mesa','cache/nvidia'):(work/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-I',str(work),'tests/helpers/vinput.c',str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True)

def event(t,kind,**fields):
    return {'timestamp':t,'type':'response_item' if kind in ('message','function_call','function_call_output') else 'event_msg','payload':{'type':kind,**fields}}
rows=[event(1,'task_started'),event(1,'message',role='user',content=[{'type':'input_text','text':'Synthetic work session'}]),event(2,'token_count',info={'total_token_usage':{'input_tokens':100,'cached_input_tokens':20,'output_tokens':30,'reasoning_output_tokens':10}}),event(3,'function_call',call_id='a',name='exec',arguments=json.dumps({'cmd':'scripts/release-check all --only lsof-top'})),event(7,'function_call_output',call_id='a'),event(9,'task_complete')]
fixture=work/'session.jsonl';fixture.write_text(''.join(json.dumps(r)+'\n' for r in rows))
archive=work/'session.agent-time.json'
started=time.monotonic()
d=None
try:
    d=h.Display(str(ROOT),['--agent-time','--agent-kind','codex','--agent-log',str(fixture),'--agent-time-out',str(archive),'--redact'],stdio=False,binary=args.binary)
    deadline=time.monotonic()+15*h.load_scale()
    while 'agent-time ready' not in d.tail():
        assert d.app.poll() is None,d.tail()
        assert time.monotonic()<deadline,d.tail()
        time.sleep(.02)
    text=h.ocr_until(d,'wall',lambda t:'synthetic work session' in t and 'model gaps include overhead' in t)
    assert 'synthetic work session' in text and 'model gaps include overhead' in text,text
    doc=json.loads(archive.read_text())
    assert doc['wall_seconds']==8 and doc['turns'][0]['tool_seconds']==4,doc
    d.keys('tap',17) # W
    text=h.ocr_until(d,'tokens',lambda t:'token burn' in t and 'cached input' in t)
    assert 'token burn' in text and 'cached input' in text,text
    # Search captures Q rather than letting it close the window.
    d.keys('tap',53,'tap',16)
    text=h.ocr_until(d,'search',lambda t:'search: q' in t)
    assert 'search: q' in text and d.app.poll() is None,text
    d.keys('tap',1,'tap',16)
    assert d.app.wait(timeout=10)==0,d.tail()
    d.close();d=None
    d=h.Display(str(ROOT),['--agent-time','--agent-kind','archive','--agent-log',str(archive)],stdio=False,binary=args.binary)
    text=h.ocr_until(d,'reopened',lambda t:'synthetic work session' in t)
    assert 'synthetic work session' in text,text
    d.keys('tap',16)
    assert d.app.wait(timeout=10)==0,d.tail()
    print(json.dumps({'status':'pass','seconds':round(time.monotonic()-started,3)}))
finally:
    if d:d.close()
