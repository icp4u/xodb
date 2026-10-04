#!/usr/bin/env python3
"""Owned GCC/Clang captures, MCP inspection, and offline raw-state archives.
Pass a build path to test before installing; no user processes or visible GUI.
"""
from datetime import datetime
from pathlib import Path
import hashlib, json, os, subprocess, sys, time
from client import Client
root = Path(__file__).resolve().parents[1]
os.chdir(root)
binary = str(Path(sys.argv[1] if len(sys.argv)>1 else 'zig-out/bin/xodb').resolve())
run = root / '.work' / ('m2-sampled-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir()
print(run, flush=True)
class TestClient(Client):
    def __init__(self, name, args, trace=False):
        self.transcript, self.id = [], 0
        self.log = (run / (name + '.stderr')).open('x')
        cmd = [binary, '--headless', '--mcp', '--agent-scope', 'control', *args]
        if trace: cmd = ['strace','-f','-e','trace=ptrace,perf_event_open,process_vm_readv,fsync,fdatasync,syncfs','-o',str(run/(name+'.trace')),*cmd]
        self.p = subprocess.Popen(cmd, bufsize=0, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        self.call('initialize', {'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'sampled-test','version':'1'}})
        self.p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n'); self.p.stdin.flush()
        self.name = name
    def close(self):
        try:
            self.p.stdin.close()
            assert self.p.wait(10)==0
        finally:
            if self.p.poll() is None: self.p.kill(); self.p.wait()
            self.log.close()
            (run/(self.name+'.json')).write_text(json.dumps(self.transcript, indent=2)+'\n')
def ready(c):
    end = time.monotonic()+15
    while True:
        job = c.inspect('get_archive_status')['job']
        if job['done']:
            assert job['error_name'] is None, job
            return job
        assert time.monotonic()<end, job
        time.sleep(.005)
def stack(c, cap, ordinal):
    end = time.monotonic()+15
    while True:
        result = c.inspect('get_profile_stack', capture_id=cap['id'], revision=cap['revision'], sample=ordinal)
        if not result['pending']:
            assert result['job']['error_name'] is None, result
            assert result['derived'] is not None, result
            return result
        assert time.monotonic()<end, result
        # Event loop continues responding while the worker runs.
        assert c.call('ping')['result']=={}
        time.sleep(.005)
results=[]
for compiler, fp, stack_bytes, budget in [('gcc',False,4096,1048576),('gcc',True,4096,1048576),('clang',False,4096,1048576),('clang',True,4096,1048576),('gcc',False,64,1048576),('gcc',False,4096,32768),('gcc',False,4096,0)]:
    name=f'{compiler}-{fp}-{stack_bytes}-{budget}'
    fixture=run/name
    subprocess.run([compiler,'-g','-O2','-fno-optimize-sibling-calls','-fno-omit-frame-pointer' if fp else '-fomit-frame-pointer',str(root/'tests/fixtures/sampled-recur.c'),'-o',str(fixture)],check=True)
    c=TestClient(name,['--',str(fixture)])
    try:
        tools={t['name'] for t in c.call('tools/list')['result']['tools']}
        assert {'get_profile_stack','get_profile_stack_coverage'} <= tools
        bp=c.action('set_breakpoint',symbol='sampled_ready')['id']
        c.action('continue');c.stopped('breakpoint');c.action('remove_breakpoint',id=bp)
        defaults=c.inspect('get_profile')['defaults']
        assert defaults['user_stack_bytes']==0 and defaults['user_stack_budget_bytes']==33554432
        cap=c.action('start_profile',frequency_hz=199,duration_ms=0,user_stack_bytes=stack_bytes,user_stack_budget_bytes=budget)['capture']
        c.action('continue');time.sleep(.55)
        cap=c.action('stop_profile',capture_id=cap['id'])['capture']
        assert cap['stored_samples']>30 and cap['status']=='manual',cap
        assert c.inspect('get_profile')['defaults']==defaults
        kw={'capture_id':cap['id'],'revision':cap['revision']}
        coverage=c.inspect('get_profile_stack_coverage',**kw)
        assert coverage['totals']['samples']==cap['stored_samples'] and coverage['total_threads']==1,coverage
        first=stack(c,cap,0)
        if budget==0:
            assert first['derived']['terminal_reason']=='retention_budget'
            assert coverage['totals']['budget_missing']==cap['stored_samples']
        elif stack_bytes==64:
            assert first['derived']['terminal_reason']=='stack_window',first
            assert len(first['derived']['frames'])<10,first
        else:
            assert sum('sampled_recur'==f['name'] for f in first['derived']['frames'])>=10,first
        if budget==32768:
            assert coverage['totals']['budget_missing']>0 and coverage['totals']['retained_stacks']>0,coverage
            tail=stack(c,cap,cap['stored_samples']-1)
            assert tail['derived']['terminal_reason']=='retention_budget',tail
            assert tail['state']['regs_present'] and tail['state']['retained_bytes']==0
        # Range counts must compose exactly, even with the retention gap.
        midpoint=(cap['ended_ns']-cap['started_ns'])//2
        early=c.inspect('get_profile_stack_coverage',**kw,from_ns=0,to_ns=midpoint)
        late=c.inspect('get_profile_stack_coverage',**kw,from_ns=midpoint)
        for key in coverage['totals']: assert early['totals'][key]+late['totals'][key]==coverage['totals'][key]
        artifact=run/(name+'.xcap')
        c.action('save_capture_archive',**kw,path=str(artifact));assert ready(c)['publication']['state']=='published'
        results.append({'case':name,'capture':cap,'coverage':coverage,'stack':first})
    finally:c.close()
    if budget==32768:
        assert (run/(name+'.stderr')).read_text().count('stack retention budget reached')==1
    # Default offline opening loads no asset, but exposes identical raw bytes.
    offline=TestClient(name+'-offline',['--open-capture',str(artifact)],trace=compiler=='gcc' and not fp and budget==1048576 and stack_bytes==4096)
    try:
        ready(offline); ocap=offline.inspect('get_profile')['capture']; raw=stack(offline,ocap,0)
        assert raw['raw']==first['raw'] and raw['state']==first['state'],raw
        assert raw['derived']['terminal_reason']==('retention_budget' if budget==0 else 'asset_missing'),raw
        copy=run/(name+'-copy.xcap')
        offline.action('save_capture_archive',capture_id=ocap['id'],revision=ocap['revision'],path=str(copy));ready(offline)
        assert copy.read_bytes()==artifact.read_bytes()
    finally:offline.close()
    resolved=TestClient(name+'-resolved',['--open-capture',str(copy),'--resolve-capture-symbols'])
    try:
        ready(resolved); rcap=resolved.inspect('get_profile')['capture']; derived=stack(resolved,rcap,0)
        assert derived['derived']==first['derived'],(derived,first)
    finally:resolved.close()
    print('PASS',name,'samples',cap['stored_samples'],'frames',len(first['derived']['frames']),'reason',first['derived']['terminal_reason'],flush=True)
for trace in run.glob('*.trace'):
    text=trace.read_text()
    assert all(word not in text for word in ('ptrace(','perf_event_open(','process_vm_readv(','fsync(','fdatasync(','syncfs(')),text
(run/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print('PASS: raw state, optimized recursion, budget/short stacks, per-range coverage, archive copy/reopen, matching assets, offline syscall isolation')
