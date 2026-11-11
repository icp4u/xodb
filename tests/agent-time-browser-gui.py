#!/usr/bin/env python3
"""Fast: synthetic HOME discovery, exact totals, filters and chronological view."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

p=argparse.ArgumentParser();p.add_argument('--binary');args=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
work=root/'.work'/('input-atb'+str(time.time_ns())[-8:]);work.mkdir(parents=True)
spec=importlib.util.spec_from_file_location('input_helper',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(work)
for name in ('tmp','cache/mesa','cache/nvidia'):(work/name).mkdir(parents=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-I',str(work),'tests/helpers/vinput.c',str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True)
home=work/'home';home.mkdir()
os.environ['HOME']=str(home);os.environ['CODEX_HOME']=str(home/'.codex')
def write(path,rows,modified):
    path=home/path;path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(''.join(json.dumps(r)+'\n' for r in rows));os.utime(path,(modified,modified))
def cx(second,kind,**fields):
    return {'type':'response_item' if kind in ('message','function_call','function_call_output') else 'event_msg','timestamp':f'2026-11-01T00:00:{second:02d}Z','payload':{'type':kind,**fields}}
write('.codex/sessions/2026/11/01/rollout-synthetic.jsonl',[
    {'type':'session_meta','timestamp':'2026-11-01T00:00:01Z','payload':{'cwd':'/srv/example'}},
    cx(1,'task_started'),cx(1,'message',role='user',content=[{'type':'input_text','text':'Catalog alpha'}]),
    cx(2,'function_call',call_id='a',name='exec',arguments='{"cmd":"git diff --stat"}'),
    cx(3,'function_call',call_id='b',name='read',arguments='{"path":"src/example.zig"}'),
    cx(6,'function_call_output',call_id='a'),cx(7,'function_call_output',call_id='b'),
    cx(8,'token_count',info={'total_token_usage':{'input_tokens':100,'cached_input_tokens':20,'output_tokens':30,'reasoning_output_tokens':10}}),cx(9,'task_complete')],300)
write('.claude/projects/example/synthetic.jsonl',[
    {'type':'user','timestamp':'2026-11-01T00:00:01Z','cwd':'/srv/example','message':{'content':'Catalog beta'}},
    {'type':'assistant','timestamp':'2026-11-01T00:00:09Z','message':{'id':'m','content':[],'stop_reason':'end_turn','usage':{'input_tokens':10,'output_tokens':2}}}],200)
write('.grok/sessions/example/synthetic/events.jsonl',[
    {'type':'turn_started','ts':'2026-11-01T00:00:01Z'},
    {'type':'turn_ended','ts':'2026-11-01T00:00:09Z','outcome':'success'}],100)
write('.grok/sessions/example/synthetic/chat_history.jsonl',[{'type':'user','content':[{'type':'text','text':'Catalog gamma'}]}],100)

def expect(d,name,needle):
    # These are uniform UI rows, not a document with inferred text columns.
    result=h.ocr_until(d,name,lambda t:needle in t,'--psm','6')
    assert needle in result,result
    return result
def type_text(d,value):
    codes={str(n):n+1 for n in range(1,10)}|{'0':11,'-':12,'.':52}
    commands=[]
    for char in value:commands+=['tap',codes[char]]
    d.keys(*commands)

d=None;started=time.monotonic()
try:
    d=h.Display(str(root),['--agent-time'],stdio=False,binary=args.binary)
    expect(d,'catalog','catalog alpha')
    expect(d,'totals','tokens 130')
    d.keys('tap',30) # A: Codex only.
    expect(d,'agent-filter','agent: codex')
    d.keys('tap',32) # D: date range.
    type_text(d,'2099-01-01');d.keys('tap',28)
    expect(d,'date-filter','no sessions match')
    d.keys('tap',45) # X reset.
    expect(d,'clear','catalog alpha')
    expect(d,'all-indexed','tokens unavailable / turns 1 / indexed')
    d.keys('tap',28)
    expect(d,'opened','model gaps include overhead')
    d.keys('tap',38) # L chronological.
    expect(d,'chronological','parallel activity has separate lanes')
    d.keys('tap',17)
    expect(d,'token-chart','token markers')
    d.keys('tap',48) # B catalog again.
    expect(d,'back','agent sessions')
    d.keys('tap',16)
    assert d.app.wait(timeout=10)==0,d.tail()
    d.close();d=None
    # The same private cache survives a new native window; no full parse needed.
    d=h.Display(str(root),['--agent-time'],stdio=False,binary=args.binary)
    expect(d,'warm','cached totals: 3')
    expect(d,'warm-tokens','tokens 130')
    d.keys('tap',16);assert d.app.wait(timeout=10)==0,d.tail()
    d.close();d=None
    source=home/'.codex/sessions/2026/11/01/rollout-synthetic.jsonl'
    with source.open('a') as f:f.write(json.dumps(cx(10,'token_count',info={'total_token_usage':{'input_tokens':200,'cached_input_tokens':20,'output_tokens':30,'reasoning_output_tokens':10}}))+'\n')
    d=h.Display(str(root),['--agent-time'],stdio=False,binary=args.binary)
    expect(d,'changed','cached totals: 2')
    expect(d,'changed-tokens','tokens 230')
    d.keys('tap',16);assert d.app.wait(timeout=10)==0,d.tail()
    print(json.dumps({'status':'pass','seconds':round(time.monotonic()-started,3)}))
finally:
    if d:d.close()
