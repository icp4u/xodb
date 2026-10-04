#!/usr/bin/env python3
"""Allocation inspector component on a private compositor, using labeled fixture data.

Builds a scratch app with fixture-only injection; production Session/tool routing
is unchanged. This does not test perf collection or collection permissions.
"""
import importlib.util,json,os,shutil,subprocess,sys,time
from pathlib import Path
from datetime import datetime
from PIL import Image
root=Path(__file__).resolve().parents[1];os.chdir(root)
spec=importlib.util.spec_from_file_location('input_repro',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
work=root/'.work'/('input-functional-'+str(time.time_ns())[-10:]);work.mkdir()
h.WORK=str(work)
for name in ('tmp','cache','cache/mesa','cache/nvidia'):(work/name).mkdir(parents=True,exist_ok=True)
tree=work/'tree';tree.mkdir()
shutil.copytree(root/'src',tree/'src')
shutil.copy2(root/'build.zig',tree/'build.zig')
shutil.copy2(root/'tests/fixtures/allocations-preview.zig',tree/'src/allocation_preview.zig')
def edit(path,changes):
    text=path.read_text()
    # Every existing file is backed up before fixture-only edits.
    backup=work/'backups'/path.relative_to(tree);backup.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(path,backup)
    for before,after in changes:
        assert text.count(before)==1,(path,before,text.count(before))
        text=text.replace(before,after)
    path.write_text(text)
edit(tree/'src/main.zig',[
    ('const Server = @import("mcp/server.zig").Server;', 'const Server = @import("mcp/server.zig").Server;\nconst preview = @import("allocation_preview.zig");'),
    ('    const startup_started = linux.now();','    const startup_started = linux.now();\n    try preview.scenario("complete");\n    defer preview.deinit();'),
    ('            workspace.input(&window, active);','            preview.input(&window);'),
    ('    reportSlow("workspace draw/inspection", started);','    try preview.draw(renderer, font, @floatFromInt(window.width), @floatFromInt(window.height));\n    reportSlow("workspace draw/inspection", started);'),
])
edit(tree/'src/mcp/server.zig',[
    ('        const processes = @import("processes.zig");','        if (std.mem.startsWith(u8, name, "allocation_preview_") or std.mem.startsWith(u8, name, "get_allocation_")) return @import("../allocation_preview.zig").call(a, name, args);\n        const processes = @import("processes.zig");'),
])
env=dict(os.environ,TMPDIR=str(work/'tmp'),ZIG_GLOBAL_CACHE_DIR=str(root/'.cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(work/'zig-cache'))
with (work/'build.log').open('wb') as output:
    build=subprocess.run(['zig','build','app','-Doptimize=ReleaseSafe','--summary','all'],cwd=tree,env=env,stdout=output,stderr=subprocess.STDOUT)
if build.returncode:
    print((work/'build.log').read_text()[-6000:]);raise SystemExit(build.returncode)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(work),str(root/'tests/helpers/vinput.c'),str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True)
d=None;checks=[]
try:
    d=h.Display(str(tree),[])
    def status():return d.tool('allocation_preview_status')
    def load(name):return d.request('tools/call',{'name':'allocation_preview_scenario','arguments':{'name':name}})['structuredContent']
    def until(check,seconds=5):
        deadline=time.monotonic()+seconds
        while True:
            value=status()
            if check(value) and (value["key"] is None or value["display_key"]==value["key"]):return value
            assert time.monotonic()<deadline,value
            time.sleep(.02)
    def ok(name,condition):
        checks.append({'check':name,'ok':bool(condition)})
        assert condition,name
    s=until(lambda v:v['state']=='ready' and v['count']>0)
    d.shot('01-calls-wide')
    d.keys('tap',38) # L
    s=until(lambda v:v['mode']=='lifetimes' and v['count']>0)
    info=d.tool('get_allocation_capture');key=info['key']
    args=dict(session_id=key['identity']['session_id'],capture_id=key['identity']['capture_id'],revision=key['revision'])
    page=d.tool('get_allocation_lifetimes',**args,limit=64)
    ok('complete fixture has 80 lifetimes',page['total_unfiltered']==80)
    ok('same common summary shown to MCP',page['summary']['outstanding_count']==53)
    d.shot('02-lifetimes-wide')
    # Same capture, three metrics, exact stack citations and archive publication.
    totals = {'allocated_bytes': sum(24+i*8 for i in range(80)),
              'outstanding_bytes': sum(24+i*8 for i in range(80) if i%3),
              'allocations':80}
    for metric, expected in totals.items():
        deadline=time.monotonic()+8
        while True:
            graph=d.tool('get_allocation_flamegraph',**args,metric=metric,limit=256)
            if not graph.get('pending'):break
            assert time.monotonic()<deadline,graph
            time.sleep(.02)
        ok(metric+' counts known fixture evidence',graph['total_weight']==expected)
        ok(metric+' contains caller attribution',any(n['name']=='retain_block' for n in graph['nodes']))
    stack=d.tool('get_allocation_stack',**args,allocation_span=0)
    ok('entry stack retains its exact caller',stack['frames'][1]['pc']=='0x402004' and not stack['complete'])
    archive=work/'allocation.xoa'
    saved=d.tool('allocation_preview_save',path=str(archive))
    ok('fixture archive published',saved['state']=='published')
    d.keys('tap',33) # F
    until(lambda v:v['mode']=='heap' and v['heap_hits']>0)
    d.shot('02b-heap-bytes')
    d.keys('tap',50) # M
    until(lambda v:v['metric']=='outstanding_bytes' and v['heap_hits']>0)
    d.shot('02c-heap-outstanding')
    d.keys('tap',38) # L
    s=until(lambda v:v['mode']=='lifetimes' and v['count']>0)
    d.keys('tap',111) # Delete is deliberately not a panel action.
    ok('unknown key leaves selection intact',status()['selected']==s['selected'])
    d.keys('tap',109) # PgDn
    s=until(lambda v:v['start']>0)
    ok('next page retains back cursor',s['history']==1)
    d.keys('tap',104) # PgUp
    ok('previous page restores origin',until(lambda v:v['start']==0)['history']==0)
    d.keys('tap',24) # O
    s=until(lambda v:v['mode']=='outstanding')
    d.shot('03-outstanding-wide')
    d.keys('tap',20) # T, allocation origin thread 11
    until(lambda v:v['thread_id']==11)
    d.keys('tap',20) # release-only thread 22
    s=until(lambda v:v['thread_id']==22)
    ok('lifetime filter uses allocation origin',s['count']==0)
    d.keys('tap',46) # C: release calls exist on thread 22
    s=until(lambda v:v['mode']=='calls' and v['count']>0)
    d.keys('click',180,280)
    ok('row click selects actual displayed evidence',status()['selected'] is not None)
    d.shot('04-filtered-calls-wide')
    # An empty bounded scan must still offer Next.
    load('many')
    until(lambda v:v['state']=='ready')
    d.keys('tap',18,'tap',20,'tap',20) # E, second thread
    s=until(lambda v:v['mode']=='events' and v['thread_id']==22)
    ok('sparse event page advances bounded scan',s['count']==0 and s['next']==4096)
    d.keys('tap',109)
    ok('empty page navigation advances',until(lambda v:v['start']==4096)['next'] is None)
    # Replace the capture with reused OS TIDs; clear old filter/navigation IDs.
    old=s['key']
    load('complete')
    s=until(lambda v:v['state']=='ready' and v['key']['identity']['session_id']!=old['identity']['session_id'])
    ok('replacement clears thread filter and cursor',s['start']==0 and s['thread_id'] is None)
    d.keys('tap',46)
    subprocess.run(['swaymsg','output','HEADLESS-1','mode','720x480'],env=d.env,check=True,capture_output=True)
    time.sleep(.35);d.shot('05-calls-small')
    d.keys('click',729,242) # 410,145 at 720x480, in the helper's 1280x800 coordinates.
    s=until(lambda v:v['mode']=='outstanding')
    ok('small panel retains visible rows',s['count']>0)
    d.shot('06-outstanding-small')
    for scenario in ('loss','stopping','collecting','memory'):
        load(scenario)
        d.keys('tap',46)
        s=until(lambda v:v['state']==({'loss':'unavailable','memory':'unavailable'}.get(scenario,scenario)))
        d.shot('07-'+scenario+'-small')
        ok(scenario+' retains inspectable calls',s['count']>0)
        if scenario in ('loss','memory'):
            d.keys('tap',38)
            s=until(lambda v:v['mode']=='lifetimes' and v['count']==0)
            ok(scenario+' shows explicit analysis refusal',s['message'] in ('AllocationEvidenceGap','AllocationMemoryLimit'))
    d.keys('tap',1)
    ok('Escape closes the panel',status()['open'] is False)
    d.keys('tap',30)
    ok('fixture A reopens panel',until(lambda v:v['open'])['open'])
    load('empty')
    time.sleep(.15);d.shot('08-empty-small')
    ok('empty capture clears stale rows',status()['count']==0)
    d.app.stdin.close();ok('fixture shuts down cleanly',d.app.wait(timeout=5)==0)
    d.close();d=None
    # Production executable: no fixture injection, target, or host symbol files.
    d=h.Display(str(root),['--open-capture',str(archive),'--agent-scope','control'])
    deadline=time.monotonic()+8
    while True:
        info=d.tool('get_allocation_capture')
        if info.get('state')=='ready':break
        assert time.monotonic()<deadline,info
        time.sleep(.02)
    ok('production reopen restores lifetime totals',info['archived'] and info['summary']['outstanding_count']==53)
    key=info['key'];args=dict(session_id=key['identity']['session_id'],capture_id=key['identity']['capture_id'],revision=key['revision'])
    deadline=time.monotonic()+8
    while True:
        graph=d.tool('get_allocation_flamegraph',**args,metric='outstanding_bytes',limit=256)
        if not graph.get('pending'):break
        assert time.monotonic()<deadline,graph
        time.sleep(.02)
    ok('production archive flames retain byte weights and labels',graph['total_weight']==totals['outstanding_bytes'] and any(n['name']=='retain_block' for n in graph['nodes']))
    time.sleep(1.1)
    shot=d.shot('09-production-reopened-heap')
    with Image.open(shot) as pixels:
        ok('GUI renders its own heap metric while MCP queries another',max(abs(a-b) for a,b in zip(pixels.convert('RGB').getpixel((40,300)),(56,87,117)))<=2)
    copy=work/'allocation-copy.xoa'
    saved=d.tool('save_allocation_archive',generation=d.session()['generation'],capture_id=key['identity']['capture_id'],revision=key['revision'],path=str(copy))
    deadline=time.monotonic()+8
    while True:
        job=d.tool('get_archive_status')['job']
        if job['done']:break
        assert time.monotonic()<deadline,job
        time.sleep(.02)
    ok('production save publishes asynchronously',job['publication']['state']=='published' and copy.exists())
    print('Private allocation GUI component and production archive checks:',work.relative_to(root),flush=True)
finally:
    (work/'checks.json').write_text(json.dumps({'fixture_only':True,'live_collection_tested':False,'checks':checks},indent=2)+'\n')
    if d:d.close()
