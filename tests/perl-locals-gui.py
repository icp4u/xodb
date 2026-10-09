#!/usr/bin/env python3
"""Perl named locals, native objects and expression entry on a private display."""
import argparse
import csv
import io
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import shlex
import subprocess
import time
from PIL import Image, ImageOps
from helpers.language_selection import check_native_values
from helpers.language_editor import check as check_editor
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--perl',required=True);p.add_argument('--padwalker',required=True,type=Path)
p.add_argument('--work',required=True,type=Path);a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=(a.work/'.work/input-named').resolve();w.mkdir(parents=True,mode=0o755)
cfg=json.loads(subprocess.check_output([a.perl,'-MConfig','-MJSON::PP','-e','print JSON::PP::encode_json({map {$_=>$Config{$_}} qw(archlib cc ccflags)})'],timeout=30))
source=root/'tests/fixtures/perl/named.c';shared=w/'named.so'
subprocess.run([*shlex.split(cfg['cc']),*shlex.split(cfg['ccflags']),'-U_FORTIFY_SOURCE','-shared','-fPIC','-g3','-O0','-fno-omit-frame-pointer','-I'+cfg['archlib']+'/CORE',str(source),'-o',str(shared)],check=True,timeout=90)
spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(w)
for name in ('tmp','cache/mesa','cache/nvidia'):(w/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(w/(stem+'.h'))],check=True,timeout=10)
    subprocess.run(['wayland-scanner','private-code',xml,str(w/(stem+'.c'))],check=True,timeout=10)
h.HELPER=str(w/'vinput');subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(w),'tests/helpers/vinput.c',str(w/'virtual-pointer.c'),str(w/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=60)
env=dict(os.environ,PERL5LIB=str(a.padwalker.resolve()/'blib/lib')+':'+str(a.padwalker.resolve()/'blib/arch'),XODB_PERL_NAMED_READY='1');env.pop('XODB_PERL_NAMED_EXPORT',None)
target=subprocess.Popen([a.perl,str(root/'tests/fixtures/perl/named.pl'),str(shared)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
d=None
try:
    assert select.select([target.stdout],[],[],10)[0] and target.stdout.readline()==b'ready\n'
    d=h.Display(str(root),['--agent-scope','control','--attach',str(target.pid)])
    line=next(i for i,text in enumerate(source.read_text().splitlines(),1) if 'NAMED_STOP' in text)
    d.tool('set_breakpoint',generation=d.session()['generation'],file=str(source),line=line)
    d.tool('continue',generation=d.session()['generation']);target.stdin.write(b'go\n');target.stdin.flush();assert d.stopped('breakpoint')
    generation=d.session()['generation'];tid=target.pid;regs=d.tool('get_registers',tid=tid)
    deadline=time.monotonic()+30
    while not any(t['tab']=='perl' and t['visible'] for t in d.tool('get_language_tabs')['view']['tabs']):
        assert time.monotonic()<deadline;time.sleep(.02)
    native_values=check_native_values(d,tid,'perl','perl-named')
    d.tool('select_language_frame',generation=generation,tid=tid,language='perl',segment=0,frame=0)
    args=dict(generation=generation,tid=tid,language='perl',segment=0,frame=0)
    locals_=d.tool('get_language_locals',**args);assert next(row for row in locals_['rows'] if row['name']=='$shadow')['value']['display']=='IV 100',locals_
    expression=d.tool('evaluate_language_expression',**args,expression='$shadow');assert expression['rows'][0]['value']['display']=='IV 100',expression
    d.keys('tap',18,'down',42,'tap',5,'up',42,'tap',31,'tap',35,'tap',30,'tap',32,'tap',24,'tap',17,'tap',28)
    deadline=time.monotonic()+20
    while True:
        screenshot=d.shot('perl-named-shadow');crop=screenshot+'.side.png'
        with Image.open(screenshot) as image:
            pane=ImageOps.invert(image.crop((1013,130,1272,578)).convert('L'));pane.resize((pane.width*3,pane.height*3)).save(crop)
        text=subprocess.run(['tesseract',crop,'stdout','--psm','6'],env=dict(d.env,OMP_THREAD_LIMIT='1'),capture_output=True,text=True,check=True,timeout=30).stdout
        Path(screenshot+'.side.txt').write_text(text)
        normalize=lambda s:re.sub(r'[^a-z0-9]','',s.lower())
        if 'mainrecurse' in normalize(text) and 'shadowiv100' in normalize(text) and 'NAMED LOCALS' in text:break
        assert time.monotonic()<deadline,text
        time.sleep(.1)
    # Collapsing native objects must give the logical stack another visible row,
    # and expanding restores it without changing the frame or expression.
    def geometry(label):
        shot=d.shot(label)
        tsv=subprocess.run(['tesseract',shot,'stdout','--psm','11','tsv'],env=dict(d.env,OMP_THREAD_LIMIT='1'),capture_output=True,text=True,check=True,timeout=30).stdout
        groups={}
        for word in csv.DictReader(io.StringIO(tsv),delimiter='\t'):
            if int(word['left'])<1013 or not word['text'].strip():continue
            key=tuple(word[k] for k in ('page_num','block_num','par_num','line_num'))
            groups.setdefault(key,[]).append(word)
        header=None;rows=[]
        for words in groups.values():
            words.sort(key=lambda word:int(word['left']))
            text=''.join(word['text'] for word in words)
            top=min(int(word['top']) for word in words)
            if 'Nativeframe' in text:header=(1050,top+8)
            if 'mainrecurse' in normalize(text):rows.append(top)
        assert header,(label,tsv)
        return header,len([top for top in rows if top<header[1]-8])
    first,first_rows=geometry('perl-native-first')
    d.keys('click',*first)
    second,second_rows=geometry('perl-native-toggled')
    # Automatic layout may start collapsed. In either direction, moving the
    # native header down must expose more logical rows, never fewer.
    assert second[1]!=first[1] and second_rows!=first_rows,(first,second,first_rows,second_rows)
    assert (second[1]>first[1])==(second_rows>first_rows),(first,second,first_rows,second_rows)
    d.keys('click',*second)
    restored,restored_rows=geometry('perl-native-restored')
    assert restored_rows==first_rows and restored==first,(first,restored,first_rows,restored_rows)
    assert d.session()['generation']==generation and d.tool('get_registers',tid=tid)==regs
    d.tool('select_language_frame',generation=generation,tid=tid,language='perl',segment=0,frame=1)
    expression=d.tool('evaluate_language_expression',**(args|{'frame':1}),expression='$shadow');assert expression['rows'][0]['value']['display']=='IV 101',expression
    d.shot('perl-named-caller')
    editor=check_editor(d,tid,'perl',1,0,
                       ['down',42,'tap',5,'up',42,*[v for key in (31,35,30,32,24,17) for v in ('tap',key)]],
                       '$shadow = IV 100')
    assert d.session()['generation']==generation and d.tool('get_registers',tid=tid)==regs
    (w/'results.json').write_text(json.dumps({'status':'pass','editor':editor,'toggle_rows':[first_rows,second_rows,restored_rows],'native_values':native_values,'locals':locals_,'caller_expression':expression,'generation_registers_unchanged':True,'display_dir':d.dir},indent=2)+'\n')
finally:
    if d:d.close()
    if target.poll() is None:target.kill();target.wait()
# Exercise the exact workload and expression advertised by scripts/demo-perl.
target=subprocess.Popen([a.perl,str(root/'examples/perl-demo.pl')],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
d=None
try:
    assert select.select([target.stdout],[],[],10)[0]
    assert target.stdout.readline()==f'{target.pid}\n'.encode()
    d=h.Display(str(root),['--agent-scope','control','--attach',str(target.pid),'--break','Perl_av_store'])
    d.tool('continue',generation=d.session()['generation']);assert d.stopped('breakpoint')
    generation=d.session()['generation'];regs=d.tool('get_registers',tid=target.pid)
    stack=d.tool('get_language_stack',tid=target.pid,language='perl')
    segment,frame=next((s,f) for s,item in enumerate(stack['segments']) for f,row in enumerate(item['frames']) if row['name']=='main::store_answer')
    args=dict(generation=generation,tid=target.pid,language='perl',segment=segment,frame=frame)
    d.tool('select_language_frame',**args)
    value=d.tool('evaluate_language_expression',**args,expression='$value')
    assert value['rows'][0]['value']['display']=='IV 42',value
    d.keys('tap',18,'down',42,'tap',5,'up',42,'tap',47,'tap',30,'tap',38,'tap',22,'tap',18,'tap',28)
    deadline=time.monotonic()+20
    while True:
        screenshot=d.shot('perl-demo-value');crop=screenshot+'.side.png'
        with Image.open(screenshot) as image:
            pane=ImageOps.invert(image.crop((1013,130,1272,578)).convert('L'));pane.resize((pane.width*3,pane.height*3)).save(crop)
        text=subprocess.run(['tesseract',crop,'stdout','--psm','6'],env=dict(d.env,OMP_THREAD_LIMIT='1'),capture_output=True,text=True,check=True,timeout=30).stdout
        Path(screenshot+'.side.txt').write_text(text)
        if 'valueiv42' in re.sub(r'[^a-z0-9]','',text.lower()):break
        assert time.monotonic()<deadline,text
        time.sleep(.1)
    assert d.session()['generation']==generation and d.tool('get_registers',tid=target.pid)==regs
    (w/'demo-results.json').write_text(json.dumps({'status':'pass','expression':value,'display_dir':d.dir,'generation_registers_unchanged':True},indent=2)+'\n')
finally:
    if d:d.close()
    if target.poll() is None:target.kill();target.wait()
print('Perl named-local pane, sigil expression, native values, frame/editor isolation and demo passed')
