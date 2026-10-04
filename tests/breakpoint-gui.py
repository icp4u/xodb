#!/usr/bin/env python3
"""Breakpoint editing and finish on the native GUI, on a private compositor."""
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
source=root/'tests/fixtures/breakpoint-policy.c';fixture=work/'fixture'
subprocess.run(['gcc','-pthread','-g','-O0',str(source),'-o',str(fixture)],env=dict(os.environ,TMPDIR=str(work/'tmp')),check=True)
tree=work/'tree';tree.mkdir()
prefix=Path(sys.argv[1] if len(sys.argv)>1 else '.work/functional-gui').resolve()
(tree/'zig-out').symlink_to(prefix,target_is_directory=True)
d=None
try:
    d=h.Display(str(tree),['--agent-scope','control','--source',str(source),'--',str(fixture)])
    line=next(i for i,s in enumerate(source.read_text().splitlines(),1) if 'POLICY_STOP' in s)
    ids=d.tool('set_breakpoint',generation=d.session()['generation'],file=str(source),line=line)['ids']
    b=ids[0]
    for extra in ids[1:]:d.tool('remove_breakpoint',generation=d.session()['generation'],id=extra)
    d.keys('tap',48,'tap',46,'tap',49,'tap',13,'tap',13,'tap',6,'tap',28)
    p=next(p for p in d.tool('get_breakpoints')['policies'] if p['id']==b)
    assert p['condition']=='n==5',p
    d.shot('01-policy')
    d.keys('tap',63)
    snap=d.stopped('breakpoint');assert snap,snap
    tid=snap['threads'][0]['tid']
    assert d.tool('evaluate_expression',tid=tid,expression='n')['value']['display']=='5'
    d.keys('tap',88)
    snap=d.stopped();assert snap and snap['running_to'] is None,snap
    assert d.tool('get_stack',tid=tid)['frames'][0]['symbol']=='main'
    d.shot('02-finish')
    # A narrow window still supports the policy editor and control keys.
    subprocess.run(['swaymsg','output','HEADLESS-1','mode','720x480'],env=d.env,check=True,capture_output=True)
    time.sleep(.3)
    d.keys('tap',57)
    assert not d.tool('get_breakpoints')['breakpoints'][0]['enabled']
    d.shot('03-small-disabled')
    d.keys('tap',57)
    assert d.tool('get_breakpoints')['breakpoints'][0]['enabled']
    d.app.stdin.close();assert d.app.wait(timeout=5)==0
    print('Private GUI: condition editing, native/MCP parity, finish, narrow-window toggle passed:',work)
finally:
    if d:d.close()
