#!/usr/bin/env python3
"""Observe-scope direct calls preserve a human's snapshots and shared GUI jobs."""
import argparse,importlib.util,json,os,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True);p.add_argument('--binary',type=Path);p.add_argument('--agent',type=Path)
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve()
if '/.work/input-' not in str(w):p.error('--work must be a private .work/input-* path')
w.mkdir(parents=True,mode=0o755)
spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(w)
for name in ('tmp','cache/mesa','cache/nvidia'):(w/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    for mode,suffix in (('client-header','.h'),('private-code','.c')):subprocess.run(['wayland-scanner',mode,xml,str(w/(stem+suffix))],check=True,timeout=30)
h.HELPER=str(w/'vinput');subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(w),'tests/helpers/vinput.c',str(w/'virtual-pointer.c'),str(w/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=60)
tree=w/'tree';(tree/'zig-out/bin').mkdir(parents=True)
(tree/'zig-out/bin/xodb').symlink_to((a.binary or root/'zig-out/bin/xodb').resolve())
def error(reply):
    if reply is None:return 'JsonRpcErrorWithoutToolResult'
    return reply['content'][0]['text'] if reply.get('isError') else None
def call(name,**arguments):
    reply=d.request('tools/call',{'name':name,'arguments':arguments});report['calls'].append({'name':name,'arguments':arguments,'reply':reply});return reply
def resources():
    fields=Path(f'/proc/{d.app.pid}/stat').read_text().rsplit(')',1)[1].split()
    return {'cpu_seconds':(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'), 'rss_kib':int(fields[21])*os.sysconf('SC_PAGE_SIZE')//1024,'load':os.getloadavg(),'allowed_cpus':len(os.sched_getaffinity(0))}
report={'status':'running','calls':[]};d=None
try:
    d=h.Display(str(tree),['--agent-scope','observe',*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--',str(root/'zig-out/bin/xodb-m1-fixture'),'w'])
    state=d.wait(lambda s:s['state']=='stopped' and not s.get('symbol_discovery_pending'));assert state
    d.keys('tap',50)  # Human opens Memory; the GUI captures its own stack page.
    deadline=time.monotonic()+20;baseline=None
    while time.monotonic()<deadline:
        reply=call('read_memory_snapshot',id=1,start=0,limit=64)
        if not error(reply):baseline=reply['structuredContent'];break
        time.sleep(.03)
    assert baseline is not None,'human Memory snapshot was not observed'
    report['human_baseline']=baseline
    report['startup_observe']=call('capture_memory',generation=d.session()['generation'],address=baseline['address'],length=64)
    assert error(report['startup_observe'])=='AgentScopeDenied'
    d.keys('tap',66);assert d.wait(lambda s:s['agent_scope']=='control')
    defs=d.request('tools/list')['tools'];restricted=[x['name'] for x in defs if x['annotations']['readOnlyHint'] and x['annotations']['xodbSessionAccess']=='controller']
    # Positive controller workflow, then the same valid capture is refused.
    control=call('capture_memory',generation=d.session()['generation'],address=baseline['address'],length=64)
    assert not error(control),control
    # Revoke before starting the human search: F8 itself changes the target
    # generation and would make an already-running search stale.
    d.keys('tap',66);state=d.wait(lambda s:s['agent_scope']=='observe');assert state
    before=d.tool('get_registers',tid=state['pid']);generation=state['generation']
    # Maximum bounded range and an unlikely multi-byte pattern keep the job
    # running across the actual cancellation attempt; no sample-rate guess.
    d.keys('tap',38,'tap',7,'tap',8,'tap',2,'tap',11,'tap',9,'tap',9,'tap',7,'tap',5,'tap',28) # L 67108864 Return
    pattern_keys=[part for _ in range(16) for part in ('tap',30,'tap',48)]
    d.keys('tap',53,*pattern_keys,'tap',28) # / ababab... Return
    search=None
    for ident in range(1,9):
        reply=call('get_memory_search',id=ident)
        if not error(reply):search=reply['structuredContent'];break
    assert search is not None,'human GUI search was not observed'
    report['human_search']=search
    assert search['state']=='running' and search['length']==67108864,search
    cancellation=call('cancel_memory_search',id=search['id']);report['cancel_reply']=cancellation
    report['search_after']=call('get_memory_search',id=search['id'])
    # Both sides must observe this same job running. A completed or stale
    # search cannot satisfy the preservation assertion vacuously.
    assert error(cancellation)=='AgentScopeDenied',cancellation
    assert not error(report['search_after']),report['search_after']
    after_search=report['search_after']['structuredContent']
    assert after_search['id']==search['id'] and after_search['state']=='running',after_search
    assert search['scanned'] <= after_search['scanned'] < after_search['length'],after_search
    report['listed_after_revoke']=[x['name'] for x in d.request('tools/list')['tools']]
    report['resources_before']=resources()
    captures=[]
    for _ in range(9):captures.append(call('capture_memory',generation=generation,address=baseline['address'],length=64))
    retained=call('read_memory_snapshot',id=baseline['id'],start=0,limit=64)
    report['baseline_after_nine']=retained
    direct={}
    for name in restricted:
        direct[name]=error(call(name))
    report['restricted_direct_calls']=direct
    report['target_unchanged']=d.session()['generation']==generation and d.tool('get_registers',tid=state['pid'])==before
    report['resources_after']=resources()
    d.shot('observe-jobs-preserved')
    assert all(error(reply)=='AgentScopeDenied' for reply in captures),captures
    assert not error(retained) and retained['structuredContent']==baseline,retained
    assert all(why=='AgentScopeDenied' for why in direct.values()),direct
    assert not set(restricted)&set(report['listed_after_revoke'])
    assert report['target_unchanged']
    report['status']='pass'
finally:
    if d:d.close()
    if report['status']!='pass':report['status']='failed'
    (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print('GUI shared jobs: human snapshot and running search preserved; nine valid observe captures and all retained-job tools refused after F8; snapshot, registers and generation preserved')
