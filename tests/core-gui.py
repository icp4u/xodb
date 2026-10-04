#!/usr/bin/env python3
"""Core/crash inspection on the native GUI, on a private compositor."""
from datetime import datetime
import importlib.util,json,os,subprocess,sys,time
from pathlib import Path
root=Path(__file__).resolve().parents[1];os.chdir(root)
spec=importlib.util.spec_from_file_location('input_repro',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
work=root/'.work'/('input-functional-'+str(time.time_ns())[-10:]);work.mkdir()
h.WORK=str(work)
for name in ('tmp','cache','cache/mesa','cache/nvidia'): (work/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(work),str(root/'tests/helpers/vinput.c'),str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True)
core=Path(sys.argv[2]).resolve() if len(sys.argv)>2 else sorted((root/'.work').glob('core-debugging-*/fixture.core'))[-1]
tree=work/'tree';tree.mkdir()
prefix=Path(sys.argv[1] if len(sys.argv)>1 else '.work/core-safe').resolve()
(tree/'zig-out').symlink_to(prefix,target_is_directory=True)
d=None
try:
    d=h.Display(str(tree),['--agent-scope','mutate','--core',str(core)])
    snap=d.session();assert snap['mode']=='core',snap
    tid=snap['threads'][0]['tid']
    assert d.tool('evaluate_expression',tid=tid,expression='held')['value']['display']=='71'
    d.shot('01-core-source')
    d.keys('tap',46);d.shot('02-crash-details')
    d.keys('tap',63,'tap',87) # execution/step rejected while details remain visible
    assert d.session()['generation']==snap['generation']
    subprocess.run(['swaymsg','output','HEADLESS-1','mode','720x480'],env=d.env,check=True,capture_output=True)
    time.sleep(.3);d.shot('03-small-crash')
    d.keys('tap',1,'tap',50);d.shot('04-core-memory')
    d.keys('tap',1,'tap',19);d.shot('05-core-fp')
    d.app.stdin.close();assert d.app.wait(timeout=5)==0
    print('Private GUI: read-only core source/locals, crash details, memory, FP/XMM and rejected execution passed:',work)
finally:
    if d:d.close()
