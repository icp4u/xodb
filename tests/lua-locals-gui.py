#!/usr/bin/env python3
"""Owned Lua named locals and expression entry on a private compositor."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
import re
from PIL import Image, ImageOps
from helpers.language_selection import check_native_values
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',required=True);p.add_argument('--library',required=True)
p.add_argument('--work',required=True,type=Path);p.add_argument('--binary',type=Path);a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=(a.work/'.work/input-named').resolve();w.mkdir(parents=True,mode=0o755)
fixture=w/'host';source=root/'tests/fixtures/lua/named.c'
subprocess.run(['cc','-std=c11','-g','-O0','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror','-I'+a.source,str(source),a.library,'-lm','-ldl','-o',str(fixture)],check=True,timeout=90)
spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(w)
for name in ('tmp','cache/mesa','cache/nvidia'):(w/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(w/(stem+'.h'))],check=True,timeout=10)
    subprocess.run(['wayland-scanner','private-code',xml,str(w/(stem+'.c'))],check=True,timeout=10)
h.HELPER=str(w/'vinput');subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(w),'tests/helpers/vinput.c',str(w/'virtual-pointer.c'),str(w/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=60)
os.environ['XODB_LUA_NAMED_AUTO']='1';d=None
try:
    tree=root
    if a.binary:
        tree=w/'tree';(tree/'zig-out/bin').mkdir(parents=True);(tree/'zig-out/bin/xodb').symlink_to(a.binary.resolve())
    d=h.Display(str(tree),['--agent-scope','control','--',str(fixture)])
    line=next(i for i,s in enumerate(source.read_text().splitlines(),1) if 'NAMED_STOP' in s)
    d.tool('set_breakpoint',generation=d.session()['generation'],file=str(source),line=line)
    d.tool('continue',generation=d.session()['generation']);assert d.stopped('breakpoint')
    state=d.session();generation=state['generation'];tid=state['threads'][0]['tid'];regs=d.tool('get_registers',tid=tid)
    deadline=time.monotonic()+30
    while not any(t['tab']=='lua' and t['visible'] for t in d.tool('get_language_tabs')['view']['tabs']):
        assert time.monotonic()<deadline;time.sleep(.02)
    native_values=check_native_values(d,tid,'lua','lua-named')
    d.tool('select_language_frame',generation=generation,tid=tid,language='lua',segment=0,frame=1)
    args=dict(generation=generation,tid=tid,language='lua',segment=0,frame=1)
    locals_=d.tool('get_language_locals',**args);assert [r['value']['display'] for r in locals_['rows'] if r['name']=='shadow']==[locals_['rows'][0]['value']['type']+' 0',locals_['rows'][0]['value']['type']+' 100'],locals_
    expression=d.tool('evaluate_language_expression',**args,expression='shadow');assert expression['rows'][0]['value']['display']==expression['rows'][0]['value']['type']+' 100',expression
    d.keys('tap',18,'tap',31,'tap',35,'tap',30,'tap',32,'tap',24,'tap',17,'tap',28)
    # Let the private compositor present the submitted text; semantic assertions
    # above and below use the same retained reader and unchanged stop.
    expected_frame=d.tool('get_language_stack',tid=tid,language='lua')['segments'][0]['frames'][1]['name']
    normalize=lambda text: re.sub(r'[^a-z0-9]', '', text.lower())
    deadline=time.monotonic()+20
    while True:
        screenshot=d.shot('lua-named-shadow');crop=screenshot+'.side.png'
        with Image.open(screenshot) as image:
            pane=ImageOps.invert(image.crop((1013,130,1272,578)).convert('L'))
            pane.resize((pane.width*3,pane.height*3)).save(crop)
        text=subprocess.run(['tesseract',crop,'stdout','--psm','6'],env=dict(d.env,OMP_THREAD_LIMIT='1'),capture_output=True,text=True,check=True,timeout=30).stdout
        Path(screenshot+'.side.txt').write_text(text)
        if normalize(expected_frame) in normalize(text) and normalize('shadow = '+expression['rows'][0]['value']['display']) in normalize(text):break
        assert time.monotonic()<deadline,(expected_frame,text)
        time.sleep(.1)
    assert d.session()['generation']==generation and d.tool('get_registers',tid=tid)==regs
    d.tool('select_language_frame',generation=generation,tid=tid,language='lua',segment=0,frame=2)
    expression=d.tool('evaluate_language_expression',**(args|{'frame':2}),expression='shadow');assert expression['rows'][0]['value']['display']==expression['rows'][0]['value']['type']+' 101',expression
    d.shot('lua-named-caller')
    # A shared client's tab/frame change must not leave an invisible editor
    # consuming later keyboard shortcuts in another pane.
    d.keys('tap',18)
    d.tool('select_language_tab',generation=generation,tab='native')
    d.keys('tap',15)
    assert d.tool('get_language_tabs')['view']['selected']=='lua'
    d.keys('tap',18)
    d.tool('select_language_frame',generation=generation,tid=tid,language='lua',segment=0,frame=1)
    d.keys('tap',15)
    assert d.tool('get_language_tabs')['view']['selected']=='registers'
    assert d.session()['generation']==generation and d.tool('get_registers',tid=tid)==regs
    # Sixth probe has three unnamed arguments, including nil. Scroll the
    # independently paged locals area until its nameless summary is visible.
    for _ in range(5):
        d.tool('continue',generation=d.session()['generation']);assert d.stopped('breakpoint')
    generation=d.session()['generation'];regs=d.tool('get_registers',tid=tid)
    d.tool('select_language_frame',generation=generation,tid=tid,language='lua',segment=0,frame=1)
    varargs=d.tool('get_language_locals',generation=generation,tid=tid,language='lua',segment=0,frame=1)
    summary=next(row for row in varargs['rows'] if row['scope']=='vararg')
    assert summary['name']=='' and summary['address'] is None and summary['value']['count']==3,summary
    # Scrolling is bounded by the visible row count; walk canonical rows
    # so a one-row viewport reaches the vararg summary without skipping.
    for _ in range(varargs['rows'].index(summary)):
        d.keys('scroll',1150,530,1)
    deadline=time.monotonic()+20
    while True:
        screenshot=d.shot('lua-varargs');crop=screenshot+'.side.png'
        with Image.open(screenshot) as image:
            pane=ImageOps.invert(image.crop((1013,430,1272,578)).convert('L'))
            pane.resize((pane.width*3,pane.height*3)).save(crop)
        text=subprocess.run(['tesseract',crop,'stdout','--psm','6'],env=dict(d.env,OMP_THREAD_LIMIT='1'),capture_output=True,text=True,check=True,timeout=30).stdout
        Path(screenshot+'.side.txt').write_text(text)
        if 'vararg' in text and re.search(r'[×xX]\s*3',text):break
        assert time.monotonic()<deadline,text
        time.sleep(.1)
    assert d.session()['generation']==generation and d.tool('get_registers',tid=tid)==regs
    (w/'results.json').write_text(json.dumps({'status':'pass','native_values':native_values,'locals':locals_,'caller_expression':expression,'varargs':varargs,'generation_registers_unchanged':True,'display_dir':d.dir},indent=2)+'\n')
finally:
    if d:d.close()
print('Lua named-local pane, logical-frame selection and expression entry passed')
