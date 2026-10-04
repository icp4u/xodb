#!/usr/bin/env python3
"""Process selection, per-process control and common scope on a private compositor."""
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
tree=work/'tree';tree.mkdir()
prefix=Path(os.environ.get('XODB_BUILD_PREFIX', root/'.work/processes-ui')).resolve()
(tree/'zig-out').symlink_to(prefix,target_is_directory=True)
d=None
try:
    d=h.Display(str(tree),['--agent-scope','control','--break','tree_ready','--',str(prefix/'bin/xodb-process-fixture')])
    d.keys('tap',57)
    assert d.stopped('breakpoint')
    d.tool('set_breakpoint',generation=d.session()['generation'],symbol='tree_child')
    d.keys('tap',57)
    deadline=time.monotonic()+5
    while d.tool('get_processes')['processes'][0]['admission_error']!='ProcessFollowingDisabled':
        assert time.monotonic()<deadline
        time.sleep(.01)
    d.keys('tap',24);d.shot('00-following-off-held')
    d.keys('tap',33) # F adopts the held child; parent remains stopped.
    deadline=time.monotonic()+5
    while d.tool('get_processes')['total']<2:
        assert time.monotonic()<deadline
        time.sleep(.01)
    d.shot('01-processes-wide')
    d.keys('tap',108,'tap',28)
    assert d.tool('get_processes')['gui_process_id']==2
    assert d.session()['process_id']==1
    d.keys('tap',57)
    deadline=time.monotonic()+5
    while True:
        child=d.tool('get_session',process_id=2)
        if any(t['reason']=='breakpoint' for t in child['threads']):break
        assert time.monotonic()<deadline,child
        time.sleep(.01)
    d.shot('02-child-breakpoint')
    # Human scope revocation applies to all sessions, independent of selection.
    d.keys('tap',66)
    assert d.session()['agent_scope']=='observe'
    assert d.tool('get_session',process_id=2)['agent_scope']=='observe'
    result=d.request('tools/call',{'name':'continue','arguments':{'process_id':2,'generation':d.tool('get_session',process_id=2)['generation']}})
    assert result['isError'] and result['content'][0]['text']=='AgentScopeDenied',result
    d.keys('tap',24)
    subprocess.run(['swaymsg','output','HEADLESS-1','mode','720x480'],env=d.env,check=True,capture_output=True)
    time.sleep(.3);d.shot('03-processes-small')
    # Click parent row selects root without resuming it.
    d.keys('click',320,367)
    assert d.tool('get_processes')['gui_process_id']==1
    d.shot('04-parent-small')
    d.keys('tap',24,'tap',108,'tap',28)
    assert d.tool('get_processes')['gui_process_id']==2
    d.shot('05-child-small')
    d.app.stdin.close();assert d.app.wait(timeout=5)==0
    print('Private GUI: process selection, independent control, root-default MCP and global scope, both sizes:',work.relative_to(root))
finally:
    if d:d.close()
