#!/usr/bin/env python3
"""F12 finish and F9 run-to-line must survive a seven-second function."""
import importlib.util
import os
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
spec = importlib.util.spec_from_file_location('input_repro', root/'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
work = root/'.work'/('input-rl-'+str(time.time_ns())[-10:])
work.mkdir(mode=0o755)
h.WORK = str(work)
for name in ('tmp','cache','cache/mesa','cache/nvidia'):
    (work/name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True)
h.HELPER = str(work/'vinput')
subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(work),str(root/'tests/helpers/vinput.c'),
                str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),
                '-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True)
source = work/'fixture.c'
source.write_text('#include <unistd.h>\nvolatile int done;\n'
                  '__attribute__((noinline)) void wait_seven(void) { sleep(7); }\n'
                  'int main(void) { wait_seven();\n    done=1; return 0; }\n')
fixture = work/'fixture'
subprocess.run(['cc','-g','-O0','-fno-omit-frame-pointer',str(source),'-o',str(fixture)],check=True)
tree = work/'tree';tree.mkdir()
(tree/'zig-out').symlink_to(root/'zig-out',target_is_directory=True)
for action in ('finish','line'):
    d = None
    try:
        d=h.Display(str(tree),['--agent-scope','control','--runtime-agent',str(root/'zig-out/bin/xodb-agent'),
                              '--source',str(source),'--break','wait_seven','--',str(fixture)])
        d.keys('tap',57)
        state=d.stopped('breakpoint');assert state
        tid=state['pid']
        assert d.tool('get_stack',tid=tid)['frames'][0]['symbol']=='wait_seven'
        probe=next(p for p in d.tool('get_breakpoints')['breakpoints'] if not p['internal'])
        d.tool('remove_breakpoint',generation=d.session()['generation'],id=probe['id'])
        start=time.monotonic()
        if action=='finish':d.keys('tap',88)
        else:d.keys('click',220,239,'tap',67)
        state=d.wait(lambda s:s['state']=='stopped' and s['running_to'] is None,seconds=15)
        assert state and state['step_diagnostic'] is None,state
        assert 6.5<time.monotonic()-start<15,(action,state)
        assert d.tool('get_stack',tid=tid)['frames'][0]['symbol']=='main'
        d.shot(action+'-returned')
    finally:
        if d:d.close()
print('Private GUI F12 finish and F9 run-to-line returned after seven seconds:',work)
