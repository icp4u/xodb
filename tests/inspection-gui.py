#!/usr/bin/env python3
"""Memory snapshots, search and vector lanes on the native GUI, on a private compositor."""
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
source=root/'tests/fixtures/inspection.c';fixture=work/'fixture'
subprocess.run(['gcc','-pthread','-g','-O0',str(source),'-o',str(fixture)],env=dict(os.environ,TMPDIR=str(work/'tmp')),check=True)
tree=work/'tree';tree.mkdir()
prefix=Path(sys.argv[1] if len(sys.argv)>1 else '.work/inspect-gui').resolve()
(tree/'zig-out').symlink_to(prefix,target_is_directory=True)
d=None
try:
    d=h.Display(str(tree),['--agent-scope','control','--source',str(source),'--',str(fixture)])
    ready=d.request('tools/call',{'name':'find_symbol','arguments':{'name':'inspect_ready'}})['structuredContent']['address']
    d.tool('set_breakpoint',generation=d.session()['generation'],address=ready)
    d.tool('continue',generation=d.session()['generation']); snap=d.stopped('breakpoint'); assert snap
    tid=snap['threads'][0]['tid']
    # M, G, &values, Enter; pin, and inspect actual changed bytes after continuing.
    d.keys('tap',50,'tap',34,'down',42,'tap',8,'up',42,'tap',47,'tap',30,'tap',38,'tap',22,'tap',18,'tap',31,'tap',28,'tap',25)
    d.shot('01-memory-baseline')
    changed=d.request('tools/call',{'name':'find_symbol','arguments':{'name':'inspect_changed'}})['structuredContent']['address']
    d.tool('set_breakpoint',generation=d.session()['generation'],address=changed)
    d.keys('tap',63); assert d.stopped('breakpoint')
    d.shot('02-memory-changes')
    # / hex:1199, Enter; job completion and expected hit via shared MCP.
    d.keys('tap',53,'tap',35,'tap',18,'tap',45,'down',42,'tap',39,'up',42,'tap',2,'tap',2,'tap',10,'tap',10,'tap',28)
    time.sleep(.2)
    # UI uses the same job sequence as retained snapshots; inspect latest model job.
    search=None
    for ident in range(1,20):
        response=d.request('tools/call',{'name':'get_memory_search','arguments':{'id':ident}})
        if not response.get('isError',True):search=response['structuredContent'];break
    assert search and search['total_hits']>=1,search
    d.keys('tap',49);d.shot('03-search-result')
    # W: the same search over every writable private mapping, as one job.
    single=search
    d.keys('tap',17,'tap',53,'tap',35,'tap',18,'tap',45,'down',42,'tap',39,'up',42,'tap',2,'tap',2,'tap',10,'tap',10,'tap',28)
    deadline=time.monotonic()+10;search=None
    while time.monotonic()<deadline:
        for ident in range(1,40):
            response=d.request('tools/call',{'name':'get_memory_search','arguments':{'id':ident}})
            if not response.get('isError',True):search=response['structuredContent'];break
        if search and search['id']!=single['id'] and search['state']!='running':break
        time.sleep(.02)
    assert search and search['id']!=single['id'] and search['state']=='complete' and search['range_count']>1,search
    assert search['total_hits']>=single['total_hits'] and search['length']>single['length'],(search,single)
    d.shot('03b-search-writable')
    d.keys('tap',1,'tap',19);d.shot('04-vectors')
    d.keys('tap',47,'tap',17);d.shot('05-vector-formats')
    subprocess.run(['swaymsg','output','HEADLESS-1','mode','720x480'],env=d.env,check=True,capture_output=True)
    time.sleep(.3)
    d.keys('tap',108,'tap',108);d.shot('06-small-vectors')
    d.keys('tap',1,'tap',50);d.shot('07-small-memory')
    d.app.stdin.close();assert d.app.wait(timeout=5)==0
    print('Private GUI: memory baseline/diff/search, typed vector lanes, narrow panels passed:',work)
finally:
    if d:d.close()
