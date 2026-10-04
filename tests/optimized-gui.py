#!/usr/bin/env python3
"""Inline scopes and caller expressions on the native GUI, on a private compositor."""
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
source=root/'tests/fixtures/optimized.c';fixture=work/'fixture'
subprocess.run(['gcc','-g','-O2','-fno-omit-frame-pointer',str(source),'-o',str(fixture)],check=True,env=dict(os.environ,TMPDIR=str(work/'tmp')))
tree=work/'tree';tree.mkdir()
prefix=Path(sys.argv[1] if len(sys.argv)>1 else '.work/optimized-safe').resolve()
(tree/'zig-out').symlink_to(prefix,target_is_directory=True)
d=None
try:
    d=h.Display(str(tree),['--agent-scope','control','--',str(fixture)])
    d.tool('set_breakpoint',generation=d.session()['generation'],symbol='inline_stop')
    d.keys('tap',63);snap=d.stopped('breakpoint');assert snap
    tid=snap['threads'][0]['tid']
    frame=d.tool('get_stack',tid=tid)['frames'][0]
    assert [v['name'] for v in frame['inline_frames']]==['inside','middle'],frame
    d.keys('tap',23);d.shot('01-innermost')
    d.keys('tap',108,'tap',18,'tap',23,'tap',49,'tap',25,'tap',22,'tap',20,'tap',28)
    d.shot('02-caller-evaluation')
    d.keys('tap',108);d.shot('03-physical-locals')
    subprocess.run(['swaymsg','output','HEADLESS-1','mode','720x480'],env=d.env,check=True,capture_output=True)
    time.sleep(.3);d.keys('tap',103);d.shot('04-small-caller')
    d.keys('tap',1);d.shot('05-small-source')
    d.app.stdin.close();assert d.app.wait(timeout=5)==0
    print('Private GUI: inline chain, caller locals, expression evaluation and narrow panel passed:',work)
finally:
    if d:d.close()
