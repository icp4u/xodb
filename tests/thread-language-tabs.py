#!/usr/bin/env python3
"""Cooperative twin interpreters: tab identity and locals follow the selected thread."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import threading
import time
from client import Client

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True)
p.add_argument('--perl',required=True)
p.add_argument('--python',default=sys.executable,help='shared-library Python')
p.add_argument('--agent',type=Path)
p.add_argument('--gui',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,exist_ok=True);w.chmod(0o755)
prefix,libdir,soname=json.loads(subprocess.check_output([a.python,'-c','import sys,sysconfig,json; print(json.dumps([sys.prefix,sysconfig.get_config_var("LIBDIR"),sysconfig.get_config_var("LDLIBRARY")]))'],text=True))
libraries={'python':Path(libdir)/soname,'perl':Path(subprocess.check_output([a.perl,'-MConfig','-e','print "$Config{archlibexp}/CORE/$Config{libperl}"'],text=True))}
exe=w/'embedder'
subprocess.run(['cc','-g','-O0','-fno-omit-frame-pointer','-Wl,--build-id','tests/fixtures/thread-interpreters.c','-ldl','-pthread','-o',str(exe)],check=True,timeout=30)
h=None
if a.gui:
    spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
    h.WORK=str(w/'.work/input-thread');Path(h.WORK).mkdir(parents=True)
    for name in ('tmp','cache/mesa','cache/nvidia'):Path(h.WORK,name).mkdir(parents=True,exist_ok=True)
    for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
        subprocess.run(['wayland-scanner','client-header',xml,str(Path(h.WORK,stem+'.h'))],check=True,timeout=10)
        subprocess.run(['wayland-scanner','private-code',xml,str(Path(h.WORK,stem+'.c'))],check=True,timeout=10)
    h.HELPER=str(Path(h.WORK,'vinput'))
    subprocess.run(['cc','-I',h.WORK,'tests/helpers/vinput.c',str(Path(h.WORK,'virtual-pointer.c')),str(Path(h.WORK,'virtual-keyboard.c')),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=30)
rows=[];began=time.monotonic()
for language,library in libraries.items():
    own=w/language;own.mkdir()
    copies=[own/'one.so',own/'two.so']
    for dest in copies:shutil.copyfile(library,dest);dest.chmod(0o755)
    target=subprocess.Popen([str(exe),language,*map(str,copies)],env=dict(os.environ,PYTHONHOME=prefix),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    messages=queue.Queue();notes=[]
    def consume(stream):
        for line in stream:messages.put(line)
    def consume_err(stream):
        for line in stream:
            if len(notes)<80:notes.append(line)
    threading.Thread(target=consume,args=(target.stdout,),daemon=True).start()
    threading.Thread(target=consume_err,args=(target.stderr,),daemon=True).start()
    client=None;display=None
    try:
        oracle={};ready=0
        while ready<2 or len(oracle)<2:
            try:line=messages.get(timeout=15)
            except queue.Empty:
                print('embedder silent',target.poll(),''.join(notes)[:2000],flush=True)
                if target.poll() is None:
                    for task in Path(f'/proc/{target.pid}/task').iterdir():
                        wchan=Path(f'/proc/{target.pid}/task/{task.name}/wchan')
                        print(task.name, wchan.read_text() if wchan.exists() else '', flush=True)
                raise
            if line=='ready\n':ready+=1
            elif line.startswith('{'):
                row=json.loads(line);oracle[row['name']]=row
        options=['--attach',str(target.pid),*(['--runtime-agent',str(a.agent.resolve())] if a.agent else [])]
        if a.gui:
            display=h.Display(str(root),['--agent-scope','control',*options]);tool=display.tool;session=display.session
            display.stopped()
        else:
            client=Client('control',None,options=options,reply_seconds=60);client.stopped(seconds=30);tool=client.inspect;session=client.session
        generation=session()['generation']
        def settled(tid):
            deadline=time.monotonic()+30
            while True:
                view=tool('get_language_tabs')['view'];entry=next(t for t in view['tabs'] if t['tab']==language)
                if view['complete'] and entry['thread']==tid:return view,entry
                assert time.monotonic()<deadline,(tid,view)
                time.sleep(.005)
        captures=[]
        for name in ('one','two','one'):
            tid=oracle[name]['tid']
            if a.gui:
                threads=session()['threads'];index=next(i for i,t in enumerate(threads) if t['tid']==tid)
                display.keys('click',100,628+25*index+8) # actual thread row, 1280x800
            else:tool('select_native_frame',generation=generation,tid=tid,frame=0)
            view,entry=settled(tid)
            assert entry['visible'] and entry['status']=='ready' and entry['identity']=='witnessed',entry
            tool('select_language_tab',generation=generation,tab=language)
            stack=tool('get_language_stack',language=language,tid=tid)
            selected=next((si,fi) for si,s in enumerate(stack['segments']) for fi,f in enumerate(s['frames']) if f['name'].split('::')[-1]==name)
            tool('select_language_frame',generation=generation,language=language,tid=tid,segment=selected[0],frame=selected[1])
            values=tool('get_language_locals',generation=generation,language=language,tid=tid,segment=selected[0],frame=selected[1])
            held=next(row for row in values['rows'] if row['name'].lstrip('$')=='held')
            assert str(oracle[name]['held']) in held['value']['display'],held
            assert entry['build_id']==stack['segments'][selected[0]]['runtime']['build_id'],entry
            if a.gui:
                from PIL import Image, ImageOps
                deadline=time.monotonic()+15
                while True:
                    shot=display.shot(language+'-'+name)
                    with Image.open(shot) as capture:
                        pane=ImageOps.invert(capture.crop((1013,91,1272,575)).convert('L'))
                        pane.resize((pane.width*3,pane.height*3)).save(shot+'.pane.png')
                    text=' '.join(h.ocr(shot+'.pane.png','--psm','6').lower().split())
                    if name in text and 'thread '+str(tid) in text and str(oracle[name]['held']) in text:break
                    assert time.monotonic()<deadline,text
                assert name in text and 'thread '+str(tid) in text and str(oracle[name]['held']) in text,text
            captures.append(dict(name=name,tid=tid,entry=entry,held=held))
        # The native main thread has neither interpreter's frames. Keep a
        # selectable tab with an honest reason, never the previous runtime ID.
        tool('select_native_frame',generation=generation,tid=target.pid,frame=0)
        _,empty=settled(target.pid)
        assert empty['visible'] and empty['identity'] is None and empty['reason']==language.title()+'InterpreterFrameUnavailable' and empty['build_id']=='',empty
        rows.append(dict(language=language,status='pass',captures=captures,native_thread=empty))
    finally:
        if display:display.close()
        if client:client.close()
        if target.poll() is None:target.kill()
        target.wait(timeout=10)
        (w/'results.json').write_text(json.dumps(dict(rows=rows,seconds=round(time.monotonic()-began,3)),indent=2)+'\n')
print('Selected-thread language tabs: both executing interpreters, locals, switching and native-only thread pass')
