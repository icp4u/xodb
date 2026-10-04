#!/usr/bin/env python3
"""Pending symbol entry and restart on the native GUI, on a private compositor."""
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
source=root/'tests/fixtures/pending.c';fixture=work/'fixture'
subprocess.run(['gcc','-pthread','-g','-O0',str(source),'-o',str(fixture)],env=dict(os.environ,TMPDIR=str(work/'tmp')),check=True)
lib=work/'late.so'
subprocess.run(['gcc','-shared','-fPIC','-g','-O0',str(root/'tests/fixtures/pending-lib.c'),'-o',str(lib)],env=dict(os.environ,TMPDIR=str(work/'tmp')),check=True)
tree=work/'tree';tree.mkdir()
prefix=Path(sys.argv[1] if len(sys.argv)>1 else '.work/restart-dev').resolve()
(tree/'zig-out').symlink_to(prefix,target_is_directory=True)
d=None
try:
    d=h.Display(str(tree),['--agent-scope','control','--source',str(source),'--',str(fixture),str(lib)])
    # B, N, late_function: pending at the loader's initial exec stop.
    d.keys('tap',48,'tap',49,'tap',38,'tap',30,'tap',20,'tap',18,'down',42,'tap',12,'up',42,'tap',33,'tap',22,'tap',49,'tap',46,'tap',20,'tap',23,'tap',24,'tap',49,'tap',28)
    pending=next(x for x in d.tool('get_breakpoints')['definitions'] if x['symbol']=='late_function')
    ident=pending['id'];assert next(x for x in d.tool('get_breakpoints')['breakpoints'] if x['id']==ident)['pending']
    d.shot('01-pending-symbol')
    d.keys('tap',63);snap=d.stopped('breakpoint');assert snap
    tid=snap['threads'][0]['tid'];pid=snap['pid']
    assert d.tool('get_stack',tid=tid)['frames'][0]['symbol']=='late_function'
    d.shot('02-library-hit')
    d.keys('tap',62)
    snap=d.session();assert snap['pid']!=pid and snap['state']=='stopped',snap
    assert not Path('/proc',str(pid)).exists()
    assert next(x for x in d.tool('get_breakpoints')['breakpoints'] if x['id']==ident)['pending']
    subprocess.run(['swaymsg','output','HEADLESS-1','mode','720x480'],env=d.env,check=True,capture_output=True)
    time.sleep(.3);d.shot('03-small-restarted')
    d.keys('tap',63);snap=d.stopped('breakpoint');assert snap
    assert d.tool('get_stack',tid=snap['threads'][0]['tid'])['frames'][0]['symbol']=='late_function'
    d.app.stdin.close();assert d.app.wait(timeout=5)==0
    print('Private GUI: pending symbol editor, library hit and F4 restart at both sizes passed:',work)
finally:
    if d:d.close()
