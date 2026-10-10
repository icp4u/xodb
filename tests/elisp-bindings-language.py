#!/usr/bin/env python3
"""Fast component lane: paged Elisp bindings through local/agent/shared MCP."""
import argparse, importlib.util, json, os, re, resource, signal, subprocess, time
from pathlib import Path
from types import SimpleNamespace
from client import Client
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--emacs',type=Path,required=True);p.add_argument('--work',type=Path,required=True)
p.add_argument('--agent',type=Path);p.add_argument('--shared',action='store_true');p.add_argument('--strace',action='store_true');p.add_argument('--wrong-oracle',action='store_true')
a=p.parse_args();os.umask(0o022);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
root=Path(__file__).resolve().parents[1];w=a.work.resolve();w.mkdir(mode=0o755,parents=True,exist_ok=False)
os.environ.update(XODB_ELISP_ORACLE=str(w/'oracle.json'),XDG_CACHE_HOME=str(w/'cache'))
options=['--break','Fdebugger_trap']+(['--runtime-agent',str(a.agent.resolve())] if a.agent else [])
server=None;c=None;out={};log=None
try:
    if a.shared:
        spec=importlib.util.spec_from_file_location('shared_elisp',root/'tests/shared-sessions.py');shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)
        (w/'run').mkdir(mode=0o700);server=SimpleNamespace(path=w/'run/s',clients=[],proc=None)
        log=(w/'server.log').open('wb');server.proc=subprocess.Popen([str(root/'zig-out/bin/xodb'),'--headless','--session-socket',str(server.path),'--agent-scope','control',*options,'--',str(a.emacs.resolve()),'-Q','--batch','-l',str(root/'tests/fixtures/elisp/bindings.el')],stdout=log,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL)
        owner=shared.Client(server,'owner');c=shared.Client(server,'observer');owner.claim(ttl_ms=60000)
        raw=c.raw;advance=lambda:owner.action('continue');pid_host=server.proc.pid
    else:
        c=Client('control',str(a.emacs.resolve()),args=('-Q','--batch','-l',str(root/'tests/fixtures/elisp/bindings.el')),options=options)
        raw=c.tool;advance=c.continue_initial_stop;pid_host=c.p.pid
    def inspect(name,**fields):
        deadline=time.monotonic()+180
        while True:
            reply=raw(name,**fields)['result']
            if not reply.get('isError'):return reply['structuredContent']
            assert reply['content'][0]['text']=='DebugMetadataPending' and time.monotonic()<deadline,reply
            time.sleep(.002)
    def error(expected,name,**fields):
        reply=raw(name,**fields)
        if 'error' in reply:
            assert expected=='InvalidArguments' and reply['error']=={'code':-32602,'message':expected},reply
        else:
            reply=reply['result'];assert reply.get('isError') and reply['content'][0]['text']==expected,reply
    advance();deadline=time.monotonic()+180
    while True:
        state=c.session()
        if state['state']=='stopped' and not state['continue_pending'] and not state['symbol_discovery_pending'] and any(t['reason']=='breakpoint' for t in state['threads']):break
        assert time.monotonic()<deadline and state['state']!='exited',state;time.sleep(.002)
    pid=state['pid'];generation=state['generation'];registers=inspect('get_registers',tid=pid)
    stack=inspect('get_language_stack',language='elisp',tid=pid)['segments'][0]['frames']
    first=next(i for i,f in enumerate(stack) if f['name']=='xodb-binding-mark')
    oracle=json.loads((w/'oracle.json').read_text())
    if a.wrong_oracle:oracle[0]['bindings'][0][1]='24'
    cases=[]
    def usage():
        stat=Path(f'/proc/{pid_host}/stat').read_text().rsplit(')',1)[1].split()
        return dict(cpu_seconds=(int(stat[11])+int(stat[12]))/os.sysconf('SC_CLK_TCK'),rss_kib=int(re.search(r'^VmRSS:\s*(\d+)',Path(f'/proc/{pid_host}/status').read_text(),re.M)[1]))
    before=usage()
    for item in oracle:
        frame=first+item['level'];assert stack[frame]['name']==item['name']
        fields=dict(generation=generation,language='elisp',tid=pid,segment=0,frame=frame)
        value=inspect('get_language_locals',**fields)
        actual=[[r['name'],r['value']['display']] for r in value['rows'] if r['name'].startswith('xodb-')]
        assert sorted(actual)==sorted(item['bindings']),('bindings oracle mismatch',item,actual)
        budgets=2+len(value['rows']) # stack, bindings, then one per preview
        assert value['memory_reads']<=budgets*8192 and value['memory_bytes']<=budgets*2*1024*1024
        assert 'bytecode/native' in value['lexical_visibility']
        paged=[]
        for index in range(value['total']):paged+=inspect('get_language_locals',**fields,start=index,limit=1)['rows']
        assert paged==value['rows'],('pagination',value,paged)
        assert inspect('get_language_locals',**fields,start=value['total'],limit=1)['rows']==[]
        cases.append(value)
    after=usage();fields=dict(generation=generation,language='elisp',tid=pid,segment=0,frame=first+1)
    error('InvalidArguments','get_language_locals',**fields,limit=33)
    error('InvalidLanguageSegment','get_language_locals',**dict(fields,segment=1))
    error('InvalidLanguageFrame','get_language_locals',**dict(fields,frame=63))
    error('ElispThreadAssociationUnproved','get_language_locals',**dict(fields,tid=pid+1000000))
    error('ElispExpressionsUnavailable','evaluate_language_expression',**fields,expression='xodb-dynamic')
    if a.shared:
        error('ControlLeaseRequired','select_language_tab',generation=generation,tab='elisp')
        error('ControlLeaseRequired','select_language_frame',**fields)
    audit={}
    if a.strace:
        observer=pid_host
        if a.agent:
            children=Path(f'/proc/{observer}/task/{observer}/children').read_text().split();assert len(children)==1;observer=int(children[0])
        def ticks():return {q.name:(q/'schedstat').read_text().split()[0] for q in Path(f'/proc/{pid}/task').iterdir()}
        before_ticks=ticks();trace=w/'readonly.strace'
        tracer=subprocess.Popen(['strace','-f','-qq','-o',str(trace),'-e','trace=ptrace,process_vm_readv,process_vm_writev,pread64,pwrite64,pwritev,pwritev2,kill,tgkill,tkill','-p',str(observer)],stderr=subprocess.PIPE)
        try:
            deadline=time.monotonic()+10
            while not re.search(r'^TracerPid:\s*'+str(tracer.pid)+r'\s*$',Path(f'/proc/{observer}/status').read_text(),re.M):
                assert tracer.poll() is None and time.monotonic()<deadline;time.sleep(.002)
            assert inspect('get_language_locals',**fields)==cases[0]
        finally:
            if tracer.poll() is None:tracer.send_signal(signal.SIGINT)
            tracer.wait(timeout=10);(w/'strace.stderr').write_bytes(tracer.stderr.read())
        text=trace.read_text();assert re.search(r'process_vm_readv|pread64|PTRACE_PEEKDATA',text)
        assert not re.search(r'process_vm_writev\(|pwrite64\(|pwritev2?\(|(?:kill|tgkill|tkill)\(|PTRACE_(?:POKE\w*|SET\w*|CONT|SINGLESTEP|SYSCALL)\b',text)
        assert ticks()==before_ticks;audit=dict(target_reads_observed=True,target_mutations=0,target_runs=0)
    assert inspect('get_registers',tid=pid)==registers and c.session()['generation']==generation
    advance();deadline=time.monotonic()+15
    while c.session()['state']!='exited':assert time.monotonic()<deadline;time.sleep(.002)
    error('StaleSnapshot','get_language_locals',**fields)
    out=dict(status='pass',cases=cases,cpu_rss_before=before,cpu_rss_after=after,readonly_audit=audit,shared=a.shared,agent=bool(a.agent))
    print('elisp bindings MCP: exact per-frame values, pagination, retained stop and read-only audit PASS')
finally:
    (w/'results.json').write_text(json.dumps(out,indent=2)+'\n')
    if server:
        for client in server.clients:
            (w/(client.label+'-rpc.json')).write_text(json.dumps(client.transcript,indent=2)+'\n');client.close()
        if server.proc:
            server.proc.terminate()
            try:server.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:server.proc.kill();server.proc.wait(timeout=10)
        if log:log.close()
    elif c:
        c.close();(w/'rpc.json').write_text(json.dumps(c.transcript,indent=2)+'\n');(w/'stderr.log').write_bytes(c.p.stderr.read())
