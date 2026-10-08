#!/usr/bin/env python3
"""Owned V8 context storage, with a separate cooperating inspector oracle."""
import argparse
import json
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import threading
import time
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--node', default='node')
p.add_argument('--include', default='/usr/include/node')
p.add_argument('--agent')
p.add_argument('--work', required=True, type=Path)
p.add_argument('--strace', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root); os.umask(0o022)
w = a.work.resolve(); w.mkdir(parents=True, exist_ok=True); w.chmod(0o755)
os.environ['XDG_CACHE_HOME'] = str(w/'cache')
addon = w/'probe.node'
subprocess.run(['c++','-std=c++20','-g','-O0','-fno-omit-frame-pointer','-fPIC','-shared',
                '-I'+a.include,'-DNODE_GYP_MODULE_NAME=xodb_probe',
                'tests/fixtures/javascript/probe.cc','-o',str(addon)],check=True,timeout=60)
labels = ['context-shadow','two-contexts','closure','recursive-0','recursive-1','recursive-2',
          'generator-0','generator-1','async','cell-double','cell-integer']
expected = {'two-contexts':[('twoContexts',{'p':7,'captured':99})], 'context-shadow':[('sample',{'p':7,'captured':41})],
            'closure':[('contextInner',{'v':5,'captured':13,'outerSeed':37})],
            'generator-0':[('generate',{'seed':11,'phase':0})],
            'generator-1':[('generate',{'seed':11,'phase':1})],
            'async':[('asynchronous',{'seed':3,'captured':29})],
            'cell-double':[('mutating',{'mutable':3.5})],
            'cell-integer':[('mutating',{'mutable':-104})]}
for depth in range(3):
    expected['recursive-'+str(depth)] = [('recursive',{'depth':n,'own':n*10}) for n in range(depth,3)]
evidence = []
resources = []

def usage(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
    status = Path(f'/proc/{pid}/status').read_text()
    return {'cpu_seconds':(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),
            'rss_kib':int(re.search(r'^VmRSS:\s*(\d+)',status,re.M)[1])}


def numeric(row):
    value = row['value']; assert value['diagnostic'] is None, row
    match = re.fullmatch(r'(?:smi|number) (-?[0-9]+(?:\.[0-9]+)?)', value['display'])
    assert match, row
    return float(match[1])

def audit(client, target, args):
    def scheduled():
        return {p.name:(p/'schedstat').read_text().split()[0] for p in Path(f'/proc/{target.pid}/task').iterdir()}
    regs = client.inspect('get_registers',tid=target.pid); generation = client.session()['generation']; before = scheduled()
    path = w/'readonly.strace'
    observer = client.collector_pid() if a.agent else client.p.pid
    tracer = subprocess.Popen(['strace','-f','-qq','-o',str(path),'-e',
        'trace=ptrace,process_vm_readv,process_vm_writev,pread64,pwrite64,pwritev,pwritev2,kill,tgkill,tkill',
        '-p',str(observer)],stderr=subprocess.PIPE)
    try:
        # Read the observer's TracerPid rather than assuming strace is ready.
        deadline = time.monotonic()+10
        while True:
            status = Path(f'/proc/{observer}/status').read_text()
            if re.search(r'^TracerPid:\s*'+str(tracer.pid)+r'\s*$',status,re.M): break
            assert tracer.poll() is None and time.monotonic()<deadline, status
            time.sleep(.01)
        for _ in range(2):
            client.inspect('get_language_locals',**args)
            refusal = client.tool('evaluate_language_expression',**args,expression='captured')
            assert refusal['result']['isError'] and refusal['result']['content'][0]['text']=='JavaScriptLexicalUnproved'
    finally:
        if tracer.poll() is None: tracer.send_signal(signal.SIGINT)
        tracer.wait(timeout=10)
    text = path.read_text()
    assert re.search(r'process_vm_readv|pread64|PTRACE_PEEKDATA',text), text
    assert not re.search(r'process_vm_writev\(|pwrite64\(|pwritev2?\(|(?:kill|tgkill|tkill)\(|PTRACE_(?:POKE\w*|SET\w*|CONT|SINGLESTEP|SYSCALL)\b',text), text
    assert scheduled()==before and client.session()['generation']==generation and client.inspect('get_registers',tid=target.pid)==regs

for mode in ('plain','inspector'):
    target = subprocess.Popen([a.node,'--no-opt','--no-sparkplug','--no-maglev','--expose-gc',
        'tests/fixtures/javascript/context.js',mode],env=dict(os.environ,XODB_NODE_PROBE=str(addon)),
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
    lines = queue.Queue()
    def drain():
        for line in target.stdout: lines.put(line)
    thread = threading.Thread(target=drain,daemon=True); thread.start(); client = None
    try:
        assert lines.get(timeout=10)=='ready\n'
        options = ['--attach',str(target.pid)] + (['--runtime-agent',a.agent] if a.agent else [])
        client = Client('control',None,options=options)
        tool = next(t for t in client.call('tools/list')['result']['tools'] if t['name']=='get_language_locals')
        assert tool['annotations']['readOnlyHint'] and tool['annotations']['xodbSessionAccess']=='observer'
        observer = client.collector_pid() if a.agent else client.p.pid
        measured = {'frontend':client.p.pid}
        if a.agent: measured['runtime_agent'] = observer
        before = {name:usage(pid) for name,pid in measured.items()}; started = time.monotonic()
        client.action('set_breakpoint',symbol='xodb_node_stop'); client.continue_initial_stop()
        target.stdin.write('go\n'); target.stdin.flush(); previous = None
        for label in labels:
            state = client.stopped('breakpoint',seconds=15); oracle = None
            record = json.loads(lines.get(timeout=10))
            if 'oracle' in record: oracle = record['oracle']; record = json.loads(lines.get(timeout=10))
            assert record['label']==label and (oracle is not None)==(mode=='inspector'), record
            stack = client.inspect('get_language_stack',tid=target.pid,language='javascript')
            generation = client.session()['generation']; regs = client.inspect('get_registers',tid=target.pid)
            wanted = expected[label]; found = 0; reads = []
            for segment,part in enumerate(stack['segments']):
                for frame,f in enumerate(part['frames']):
                    if found==len(wanted) or f['name']!=wanted[found][0]: continue
                    assert f['kind']=='interpreted' and f['bytecode'], f
                    args = dict(generation=generation,tid=target.pid,language='javascript',segment=segment,frame=frame)
                    read_before = {name:usage(pid) for name,pid in measured.items()}
                    read_started = time.monotonic()
                    data = client.inspect('get_language_locals',**args)
                    resources.append({'mode':mode,'label':label,'frame':frame,'phase':'context_read',
                        'before':read_before,'after':{name:usage(pid) for name,pid in measured.items()},
                        'elapsed_seconds':time.monotonic()-read_started})
                    assert data['view_kind']=='context_storage' and data['diagnostic']=='JavaScriptLexicalUnproved',data
                    assert 'unproved' in data['lexical_visibility'] and 'not shown' in data['lexical_visibility']
                    assert data['memory_reads']<=8192 and data['memory_bytes']<=2*1024*1024
                    assert all(row['scope']=='context' and row['context_depth'] is not None and 'lexical visibility unproved' in row['provenance'] for row in data['rows'])
                    assert [row['context_depth'] for row in data['rows']]==sorted(row['context_depth'] for row in data['rows'])
                    if label=='two-contexts':
                        captures=[row for row in data['rows'] if row['name']=='captured']
                        assert [numeric(row) for row in captures]==[99,41] and [row['context_depth'] for row in captures]==[0,1],captures
                    for name,value in wanted[found][1].items():
                        matches = [row for row in data['rows'] if row['name']==name]
                        assert matches and numeric(matches[0])==value,(label,name,value,matches,data)
                        if oracle is not None:
                            local = oracle[found]
                            if label=='context-shadow' and name=='captured':
                                assert local['values'][name]==99
                                assert any(s['type']=='local' and {'name':'captured','value':41} in s['values'] for s in local['scopes']),local
                            else: assert local['values'][name]==value,(label,local)
                    if label=='context-shadow':
                        assert not any(row['name']=='stackOnly' for row in data['rows'])
                        assert next(row for row in data['rows'] if row['name']=='p')['context_parameter']
                        page = client.inspect('get_language_locals',**args,start=1,limit=2)
                        assert page['rows']==data['rows'][1:3] and page['total']==data['total'],page
                        if a.strace and mode=='plain': audit(client,target,args)
                    refusal = client.tool('evaluate_language_expression',**args,expression=next(iter(wanted[found][1])))
                    assert refusal['result']['isError'] and refusal['result']['content'][0]['text']=='JavaScriptLexicalUnproved',refusal
                    if previous is not None:
                        stale = client.tool('get_language_locals',**(args|{'generation':previous}))
                        assert stale['result']['isError'] and stale['result']['content'][0]['text']=='StaleSnapshot',stale
                    reads.append(data); found += 1
            assert found==len(wanted),(label,found,stack)
            assert client.inspect('get_registers',tid=target.pid)==regs and client.session()['generation']==generation
            evidence.append({'mode':mode,'label':label,'oracle':oracle,'reads':reads,'generation_registers_unchanged':True})
            (w/'results.json').write_text(json.dumps({'status':'running','stops':evidence},indent=2)+'\n')
            previous = generation; client.action('continue')
        after = {name:usage(pid) for name,pid in measured.items()}
        resources.append({'mode':mode,'phase':'whole_fixture','before':before,'after':after,
                          'elapsed_seconds':time.monotonic()-started,
                          'load':os.getloadavg(),'allowed_cpus':len(os.sched_getaffinity(0))})
        target.wait(timeout=15); assert target.returncode==0,target.stderr.read()
    finally:
        if client: client.close()
        if target.poll() is None: target.kill(); target.wait()
        thread.join(timeout=2)
(w/'results.json').write_text(json.dumps({'status':'pass','stops':evidence,'resources':resources},indent=2)+'\n')
print('Context storage: 22 plain/inspector stops, recursion, closures, generator resume, async, cells, GC, pages, stale generations and lexical refusals passed')
