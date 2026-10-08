#!/usr/bin/env python3
"""Named Python bindings and expressions on a private headless compositor."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import subprocess
import time
from PIL import Image, ImageOps
from helpers.language_selection import check_native_values

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--python',required=True);p.add_argument('--work',required=True,type=Path);a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=(a.work/'.work/input-pyn').resolve();w.mkdir(parents=True,mode=0o755)
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
component=load('component',root/'tests/python-component.py');component.compile_fixture(a.python,w)
h=load('private_input',root/'tests/helpers/input.py');h.WORK=str(w)
for name in ('tmp','cache/mesa','cache/nvidia'):(w/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(w/(stem+'.h'))],check=True,timeout=10)
    subprocess.run(['wayland-scanner','private-code',xml,str(w/(stem+'.c'))],check=True,timeout=10)
h.HELPER=str(w/'vinput');subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(w),'tests/helpers/vinput.c',str(w/'virtual-pointer.c'),str(w/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=60)
env=dict(os.environ,PYTHONPATH=str(w),XODB_PYTHON_NAMED_READY='1');env.pop('XODB_PYTHON_NAMED_EXPORT',None)
target=subprocess.Popen([a.python,str(root/'tests/fixtures/python/named.py')],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
d=None
try:
    assert select.select([target.stdout],[],[],10)[0] and target.stdout.readline()==b'ready\n'
    d=h.Display(str(root),['--agent-scope','control','--attach',str(target.pid)])
    source=root/'tests/fixtures/python/named.c'
    line=next(i for i,text in enumerate(source.read_text().splitlines(),1) if 'NAMED_STOP' in text)
    d.tool('set_breakpoint',generation=d.session()['generation'],file=str(source),line=line)
    d.tool('continue',generation=d.session()['generation']);target.stdin.write(b'go\n');target.stdin.flush();assert d.stopped('breakpoint')
    generation=d.session()['generation'];tid=target.pid;regs=d.tool('get_registers',tid=tid)
    deadline=time.monotonic()+60
    while True:
        reply=d.request('tools/call',{'name':'get_language_stack','arguments':{'tid':tid,'language':'python'}})
        if not reply.get('isError'):break
        assert reply['content'][0]['text']=='DebugMetadataPending' and time.monotonic()<deadline,reply
        time.sleep(.02)
    stack=reply['structuredContent']
    segment,frame=next((s,f) for s,part in enumerate(stack['segments']) for f,row in enumerate(part['frames']) if row['name']=='recursive')
    native_values=check_native_values(d,tid,'python','python-named')
    args=dict(generation=generation,tid=tid,language='python',segment=segment,frame=frame)
    d.tool('select_language_frame',**args)
    locals_=d.tool('get_language_locals',**args)
    assert next(row for row in locals_['rows'] if row['name']=='depth')['value']['display']=='int 0',locals_
    d.keys('tap',18,'tap',32,'tap',18,'tap',25,'tap',20,'tap',35,'tap',28)
    normalize=lambda text:re.sub(r'[^a-z0-9]','',text.lower())
    def visible(label,wanted,absent=()):
        deadline=time.monotonic()+20
        while True:
            shot=d.shot(label);crop=shot+'.side.png'
            with Image.open(shot) as image:
                pane=ImageOps.invert(image.crop((1013,130,1272,578)).convert('L'));pane.resize((pane.width*3,pane.height*3)).save(crop)
            text=subprocess.run(['tesseract',crop,'stdout','--psm','6'],env=dict(d.env,OMP_THREAD_LIMIT='1'),capture_output=True,text=True,check=True,timeout=30).stdout
            Path(shot+'.side.txt').write_text(text)
            if all(part in normalize(text) for part in wanted) and all(part not in normalize(text) for part in absent):return text
            assert time.monotonic()<deadline,text
            time.sleep(.05)
    # The fixed private 1280x800 view fits one binding after the expression.
    # The hint includes both rows below the viewport and later reader pages.
    first=visible('python-named-depth',['namedlocals',str(locals_['total']-1)+'more','edepthint0','expressionresultabove'])
    d.keys('scroll',1150,540,1)  # one visible row: do not skip the next binding
    row = locals_['rows'][1]
    middle=visible('python-named-scrolled',[normalize(row['name']+'='+row['value']['display']),str(locals_['total']-2)+'more'])
    for _ in range(2,locals_['total']):d.keys('scroll',1150,540,1)
    last=visible('python-named-last',['deleted','pythonunboundlocal'],['more'])
    for _ in range(1,locals_['total']):d.keys('scroll',1150,540,-1)
    visible('python-named-restored',['expressionresultabove',str(locals_['total']-1)+'more'])
    # Selecting a caller resolves the existing expression against that frame.
    d.tool('select_language_frame',**(args|{'frame':frame+1}))
    caller=visible('python-named-caller',['edepthint1'])
    value=d.tool('evaluate_language_expression',**(args|{'frame':frame+1}),expression='depth')
    assert value['rows'][0]['value']['display']=='int 1',value
    assert d.session()['generation']==generation and d.tool('get_registers',tid=tid)==regs
    # Observer scope can read named bindings without changing the target.
    d.keys('tap',66);assert d.wait(lambda state:state['agent_scope']=='observe')
    # Scope changes may advance generation when armed probes are withdrawn.
    generation=d.session()['generation'];args['generation']=generation
    regs=d.tool('get_registers',tid=tid)
    assert d.tool('get_language_locals',**(args|{'frame':frame+1}))['diagnostic'] is None
    assert d.tool('evaluate_language_expression',**(args|{'frame':frame+1}),expression='depth')['rows'][0]['value']['display']=='int 1'
    d.shot('python-named-observer')
    assert d.session()['generation']==generation and d.tool('get_registers',tid=tid)==regs
    (w/'results.json').write_text(json.dumps({'status':'pass','locals':locals_,'native_values':native_values,'caller':value,'first_text':first,'middle_text':middle,'last_text':last,'caller_text':caller,'generation_registers_unchanged':True,'display_dir':d.dir},indent=2)+'\n')
finally:
    if d:d.close()
    if target.poll() is None:target.kill();target.wait()
print('Python named-local pane, labelled expression, caller selection, native objects and observer reads passed')
