#!/usr/bin/env python3
"""Syscall timeline/detail/setup on the native GUI, on a private compositor."""
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
capture=Path(sys.argv[2]).resolve() if len(sys.argv)>2 else sorted((root/'.work').glob('syscall-timing-*/wait.xcap'))[-1]
tree=work/'tree';tree.mkdir()
prefix=Path(sys.argv[1] if len(sys.argv)>1 else '.work/syscalls-safe').resolve()
(tree/'zig-out').symlink_to(prefix,target_is_directory=True)
d=None
try:
    d=h.Display(str(tree),['--open-capture',str(capture)])
    deadline=time.monotonic()+20
    while True:
        state=d.tool('get_profile')
        if state['capture'] is not None: break
        assert time.monotonic()<deadline,state
        time.sleep(.02)
    cap=state['capture']
    assert cap['syscalls']['retained']>0,cap
    d.shot('01-syscall-timeline')
    d.keys('tap',45);d.shot('02-syscall-detail')
    d.keys('tap',109);d.shot('03-syscall-paging')
    subprocess.run(['swaymsg','output','HEADLESS-1','mode','720x480'],env=d.env,check=True,capture_output=True)
    time.sleep(.3);d.shot('04-small-syscalls')
    d.keys('tap',1);d.shot('05-small-timeline')
    d.app.stdin.close();assert d.app.wait(timeout=5)==0
    d.close();d=None
    fixture=sorted((root/'.work').glob('syscall-timing-*/fixture'))[-1]
    d=h.Display(str(tree),['--agent-scope','control','--',str(fixture),'wait'])
    d.keys('tap',33,'tap',31,'tap',21) # F profile, S setup, Y syscall toggle
    assert d.tool('get_profile')['defaults']['syscall_timing']
    d.shot('06-live-setup')
    subprocess.run(['swaymsg','output','HEADLESS-1','mode','720x480'],env=d.env,check=True,capture_output=True)
    time.sleep(.3);d.shot('07-small-setup')
    d.app.stdin.close();assert d.app.wait(timeout=5)==0
    print('Private GUI: syscall timeline, detail, paging and setup at both sizes:',work)
finally:
    if d:d.close()
