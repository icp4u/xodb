#!/usr/bin/env python3
"""Discovered debug symbols and source prefix substitution on the native GUI, on a private compositor."""
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
source=root/'tests/fixtures/m1.c'
fixture=Path(sys.argv[2]).resolve() if len(sys.argv)>2 else sorted((root/'.work').glob('debug-discovery-*/debuglink/fixture'))[-1]
tree=work/'tree';tree.mkdir()
prefix=Path(sys.argv[1] if len(sys.argv)>1 else '.work/symbols-safe').resolve()
(tree/'zig-out').symlink_to(prefix,target_is_directory=True)
d=None
try:
    d=h.Display(str(tree),['--agent-scope','control','--source-map','/xodb-build='+str(root),'--debug-dir',str(fixture.parent/'roots'),'--',str(fixture)])
    d.tool('set_breakpoint',generation=d.session()['generation'],file=str(source),line=10)
    d.keys('tap',63);snap=d.stopped('breakpoint');assert snap
    frame=d.tool('get_stack',tid=snap['threads'][0]['tid'])['frames'][0]
    assert frame['source']['path']==str(source),frame
    assert frame['source']['original_path']=='/xodb-build/tests/fixtures/m1.c',frame
    d.shot('01-remapped-source')
    subprocess.run(['swaymsg','output','HEADLESS-1','mode','720x480'],env=d.env,check=True,capture_output=True)
    time.sleep(.3);d.shot('02-small-source')
    d.app.stdin.close();assert d.app.wait(timeout=5)==0
    print('Private GUI: stripped companion symbols and remapped source/locals passed:',work)
finally:
    if d:d.close()
