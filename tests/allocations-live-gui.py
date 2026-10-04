#!/usr/bin/env python3
"""Production allocation controls on a private compositor and owned fixture."""
import argparse,importlib.util,json,os,subprocess,time
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('--prefix',default='.work/allocation-demo/out')
parser.add_argument('--helper')
parser.add_argument('--expect-denial',action='store_true')
args=parser.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root)
spec=importlib.util.spec_from_file_location('input_repro',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
work=root/'.work'/('input-functional-'+str(time.time_ns())[-10:]);work.mkdir()
h.WORK=str(work)
for name in ('tmp','cache','cache/mesa','cache/nvidia'):(work/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(work),str(root/'tests/helpers/vinput.c'),str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,env=dict(os.environ,TMPDIR=str(work/'tmp')))
fixture=work/'fixture'
subprocess.run(['cc','-pthread','-g','-O0','-fno-builtin','tests/fixtures/allocations.c','-o',str(fixture)],check=True,env=dict(os.environ,TMPDIR=str(work/'tmp')))
tree=work/'tree';tree.mkdir();(tree/'zig-out').symlink_to(Path(args.prefix).resolve(),target_is_directory=True)
d=None
try:
    launch=['--agent-scope','control']
    if args.helper:launch+=['--allocation-helper',str(Path(args.helper).resolve())]
    d=h.Display(str(tree),[*launch,'--break','allocation_marker','--',str(fixture),'demo'])
    def action(name,**kw):
        return d.tool(name,generation=d.session()['generation'],**kw)
    d.keys('tap',57) # Same first Space as the published demo: stop at phase 0.
    assert d.stopped('breakpoint')
    d.keys('tap',30) # A
    d.shot('01-empty')
    d.keys('tap',25) # P
    deadline=time.monotonic()+8
    while True:
        cap=d.tool('get_allocation_capture')
        if not cap['preparing']:break
        assert time.monotonic()<deadline,cap
        time.sleep(.01)
    if args.expect_denial:
        assert cap['error']=='AllocationCollectorOpen' and cap['failure']['kind']=='permission',cap
        d.shot('02-permission')
    else:
        assert cap['collecting'] and cap['error'] is None,cap
        d.shot('02-collecting')
        d.keys('tap',57) # Space passes through inspector
        assert d.stopped('breakpoint')
        d.keys('click',1170,78) # Stop button
        deadline=time.monotonic()+8
        while True:
            cap=d.tool('get_allocation_capture')
            if cap['state']=='ready':break
            assert time.monotonic()<deadline,cap
            time.sleep(.01)
        assert cap['summary']['outstanding_bytes']==29,cap
        d.shot('03-calls')
        d.keys('tap',38);d.shot('04-lifetimes') # L
        d.keys('tap',24);d.shot('05-outstanding') # O
        d.keys('tap',18);d.shot('06-events') # E
        d.keys('tap',33);time.sleep(.2);d.shot('06a-flames') # F
        d.keys('tap',50);time.sleep(.2);d.shot('06b-outstanding-flames') # M
    subprocess.run(['swaymsg','output','HEADLESS-1','mode','720x480'],env=d.env,check=True,capture_output=True)
    time.sleep(.3);d.shot('07-small')
    d.keys('tap',1);d.shot('08-source')
    d.app.stdin.close();assert d.app.wait(timeout=5)==0,d.tail()
    (work/'status.json').write_text(json.dumps(cap,indent=2)+'\n')
    print('Private allocation GUI:',work.relative_to(root))
finally:
    if d:d.close()
