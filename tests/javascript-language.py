#!/usr/bin/env python3
"""Owned Node native-stop values and physical language stacks; no inferior calls."""
import argparse
import json
import os
from pathlib import Path
import queue
import re
import signal
import shutil
import subprocess
import tempfile
import threading
import time
from client import Client

parser = argparse.ArgumentParser()
parser.add_argument('--node', default=os.environ.get('XODB_NODE', 'node'))
parser.add_argument('--include', default=os.environ.get('XODB_NODE_INCLUDE', '/usr/include/node'))
parser.add_argument('--output')
parser.add_argument('--strace', action='store_true', help='Audit only observer reads on the owned stopped fixture')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
os.chdir(root)
node = shutil.which(args.node)
assert node, 'Selected Node executable is unavailable'
version = subprocess.check_output([node, '-p', 'process.versions.v8'], text=True, timeout=10).strip()
(root/'.work').mkdir(exist_ok=True)
work = Path(tempfile.mkdtemp(prefix='javascript-', dir=root/'.work'))
work.chmod(0o755)
(work/'cache').mkdir(mode=0o700)
os.environ['XDG_CACHE_HOME'] = str(work/'cache')
addon = work/'probe.node'
subprocess.run([os.environ.get('CXX', 'c++'), '-std=c++20', '-g', '-O0', '-fno-omit-frame-pointer',
                '-fPIC', '-shared', '-I'+args.include, '-DNODE_GYP_MODULE_NAME=xodb_probe',
                'tests/fixtures/javascript/probe.cc', '-o', str(addon)], check=True, timeout=90)
checks, evidence = [], []
# Force the oracle producer to encounter a full nonblocking pipe. A missing
# or truncated record must fail here, before any debugger comparisons run.
producer = subprocess.Popen([node, '--allow-natives-syntax',
    'tests/fixtures/javascript/scenarios.js', 'optimized'],
    env=dict(os.environ, XODB_NODE_PROBE=str(addon)), stdin=subprocess.PIPE,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, pipesize=4096)
try:
    assert producer.stdout.readline() == b'ready\n'
    producer.stdin.write(b'go\n'); producer.stdin.flush()
    time.sleep(.1)
    output, errors = producer.communicate(timeout=15)
    assert producer.returncode == 0, errors
    records = [json.loads(line) for line in output.splitlines()]
    assert [r['label'] for r in records if 'frames' in r] == [
        'nested', 'closure', 'class', 'async', 'promise', 'generator',
        'deep', 'optimized', 'inlined'], records
    checks.append('fixture: all ground-truth records survive pipe backpressure')
finally:
    if producer.poll() is None:
        producer.kill(); producer.communicate(timeout=5)
large_library = work/'large.so'
subprocess.run(['cc', '-shared', '-fPIC', '-x', 'c', '-', '-o', str(large_library)],
    input='int owned_large_library(void) { return 7; }\n', text=True, check=True, timeout=30)
# Sparse padding outside PT_LOAD: this is a real loaded ELF library whose
# total file size exceeds the snapshot cap, without a large physical file.
with large_library.open('r+b') as large:
    large.truncate(300 * 1024 * 1024)


def audit(client, target, name):
    log = work/(name+'-strace.txt')
    def scheduled():
        tasks = Path(f'/proc/{target.pid}/task')
        return {p.name:(p/'schedstat').read_text().split()[0] for p in tasks.iterdir()}
    registers = client.inspect('get_registers', tid=target.pid)
    generation = client.session()['generation']
    before = scheduled()
    tracer = subprocess.Popen(['strace','-f','-qq','-o',str(log),'-e',
        'trace=ptrace,process_vm_readv,process_vm_writev,pread64,pwrite64,pwritev,pwritev2,kill,tgkill,tkill',
        '-p',str(client.p.pid)], stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 10
        while True:
            assert tracer.poll() is None, tracer.stderr.read().decode()
            status = Path(f'/proc/{client.p.pid}/status').read_text()
            attached = next(int(line.split()[1]) for line in status.splitlines() if line.startswith('TracerPid:'))
            if attached == tracer.pid: break
            assert time.monotonic() < deadline, 'strace did not attach before the audit deadline'
            time.sleep(.01)
        for _ in range(2):
            client.inspect('get_language_stack',tid=target.pid,language='javascript')
            client.inspect('evaluate_expression',tid=target.pid,frame=0,expression='value')
    finally:
        if tracer.poll() is None: tracer.send_signal(signal.SIGINT)
        tracer.wait(timeout=10)
    calls = {}
    for line in log.read_text().splitlines():
        match = re.search(r'\b(ptrace|process_vm_readv|process_vm_writev|pread64|pwrite64|pwritev|pwritev2|kill|tgkill|tkill)\(([^,)]*)',line)
        if not match: continue
        call = match[1] + (':'+match[2] if match[1]=='ptrace' else '')
        calls[call] = calls.get(call,0)+1
    forbidden = [k for k in calls if k in ('process_vm_writev','pwrite64','pwritev','pwritev2','kill','tgkill','tkill') or
        k.startswith(('ptrace:PTRACE_POKE','ptrace:PTRACE_SET')) or k in ('ptrace:PTRACE_CONT','ptrace:PTRACE_SINGLESTEP','ptrace:PTRACE_SYSCALL')]
    assert not forbidden, calls
    assert any(k in calls for k in ('process_vm_readv','pread64','ptrace:PTRACE_PEEKDATA')), calls
    assert scheduled() == before
    assert client.inspect('get_registers',tid=target.pid)==registers and client.session()['generation']==generation
    if args.output:
        Path(str(args.output)+'.'+name+'.strace').write_bytes(log.read_bytes())
    evidence.append({'readonly_audit':name,'syscalls':calls,'registers_generation_schedstat_unchanged':True})
    checks.append(name+': strace confirms reads only; target registers, generation and scheduled time unchanged')


def run(script, count, flags=(), script_args=()):
    lines = queue.Queue()
    target = subprocess.Popen([node, *flags, 'tests/fixtures/javascript/'+script, *script_args],
        env=dict(os.environ, XODB_NODE_PROBE=str(addon)), stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    def drain():
        for line in target.stdout:
            lines.put(line)
    thread = threading.Thread(target=drain, daemon=True)
    thread.start()
    client = None
    rows = []
    try:
        assert lines.get(timeout=10) == 'ready\n'
        client = Client('control', None, options=['--attach', str(target.pid)])
        definition = next(t for t in client.call('tools/list')['result']['tools'] if t['name']=='get_language_stack')
        assert definition['annotations']['readOnlyHint'] and definition['annotations']['xodbSessionAccess']=='observer'
        assert 'javascript' in definition['inputSchema']['properties']['language']['enum']
        client.action('set_breakpoint', symbol='xodb_node_stop')
        client.continue_initial_stop()
        target.stdin.write('go\n'); target.stdin.flush()
        for i in range(count):
            state = client.stopped('breakpoint')
            ground = json.loads(lines.get(timeout=10))
            before = client.inspect('get_registers', tid=target.pid)
            # Metadata is a separate bounded background job. Wait for its
            # verified profile before comparing previews or timing reads.
            stack = client.inspect('get_language_stack', tid=target.pid, language='javascript')
            started = time.time()
            locals_ = client.inspect('list_locals', tid=target.pid, frame=0)
            value = client.inspect('evaluate_expression', tid=target.pid, frame=0, expression='value')['value']
            ended = time.time()
            assert client.inspect('get_registers', tid=target.pid) == before
            assert client.session()['generation'] == state['generation']
            segment = stack['segments'][0]
            assert segment['runtime']['version'] == version and segment['anchor'] is not None
            assert segment['memory_reads'] <= 8192 and segment['memory_bytes'] <= 2*1024*1024
            assert 0 < len(segment['frames']) <= 64
            assert all(f['line'] is None and f['column'] is None or f['line'] > 0 and f['column'] > 0 for f in segment['frames'])
            assert any(v['name']=='value' and v['value']['display']==value['display'] for v in locals_['locals'])
            # V8 captures at the native call site, including frame zero.
            # Match physical frames monotonically by name; inlined ground
            # frames may be absent, but proved positions cannot float between
            # unrelated frames as they could with a set-membership check.
            ground_index = 0
            proved = 0
            for frame in segment['frames']:
                if frame['file'] is None and frame['line'] is None:
                    assert frame['reason'], frame
                    continue
                while ground_index < len(ground['frames']) and (ground['frames'][ground_index]['name'] or '(anonymous)') != frame['name']:
                    ground_index += 1
                assert ground_index < len(ground['frames']), (frame, ground)
                expected_frame = ground['frames'][ground_index]
                if frame['line'] is not None:
                    assert (frame['file'], frame['line'], frame['column']) == (expected_frame['file'] or None, expected_frame['line'], expected_frame['column']), (frame, expected_frame)
                    proved += 1
                else:
                    assert frame['reason'], frame
                ground_index += 1
            assert proved or ground.get('label') == 'inlined', segment
            rows.append({'index':i,'ground':ground,'value':value,'stack':stack,'readonly_window':[started,ended]})
            if args.strace and script=='stopped.js' and i in (0,11): audit(client,target,'scalar' if i==0 else 'array')
            client.action('continue')
        target.wait(timeout=10)
        assert target.returncode == 0, target.stderr.read()
    finally:
        if client: client.close()
        if target.poll() is None: target.kill(); target.wait()
        thread.join(timeout=5)
        target.stdout.close(); target.stderr.close(); target.stdin.close()
    evidence.append({'script':script,'flags':flags,'rows':rows})
    return rows

try:
    rows = run('stopped.js',35,script_args=[str(large_library)])
    expected = ['smi 42','smi -7','number 3.25','undefined','null','true','false',
                'string "hi"','string "héllo"','string "λ 😀"',None,
                'Array(3) [smi 1, string "two", true]','Object {a: smi 1, b: string "two"}',
                'function named','Point {x: smi 4, y: smi 5}','function closure']
    for row, display in zip(rows, expected):
        if display is None: assert row['value']['visualization']['truncated']
        else: assert row['value']['display']==display, (display,row['value'])
    for row in rows[16:19]:
        value = row['value']
        assert value['display'].startswith('Object {'), value
        assert value['visualization']['diagnostic'] == 'JavaScriptConstructorNameUnproved', value
    for row in rows[19:22]:
        value = row['value']; js = value['visualization']['javascript']
        assert js['type'] in ('Array', 'Object') and js['items'], value
        assert any(item['diagnostic'] for item in js['items']), value
    assert [row['value']['display'] for row in rows[22:25]] == ['number NaN', 'number Infinity', 'number -Infinity']
    assert rows[25]['value']['display'] == 'Array(2) [number NaN, number 1.5]'
    assert rows[26]['value']['display'] == 'Array(3) [number 1.5, <hole>, number 3.5]'
    assert rows[12]['value']['visualization']['diagnostic'] is None, rows[12]['value']
    for i, char in ((27, 'x'), (28, 'λ')):
        value = rows[i]['value']
        assert value['display'].startswith('string "' + char * 10), value
        assert value['visualization']['truncated'], value
    for row in rows[29:33]:
        value = row['value']
        assert value['display'].startswith('Object {'), value
        assert value['visualization']['diagnostic'] == 'JavaScriptConstructorNameUnproved', value
    assert rows[33]['value']['display'] == 'string "fresh"', rows[33]['value']
    assert rows[34]['value']['display'] == 'smi 42', rows[34]['value']
    checks.append('35 live values: primitives, UTF-16, large and fresh strings, arrays, object literals, changed prototypes, proved and unproved classes, item-local failures, NaN, holes and a loaded 300 MiB library')
    rows = run('scenarios.js',9,flags=['--allow-natives-syntax'],script_args=['optimized'])
    for row in rows:
        label = row['ground']['label']; segment = row['stack']['segments'][0]
        names = [f['name'] for f in segment['frames']]
        required = {'nested':'inner','closure':'closure','class':'inspect','async':'asynchronous',
                    'promise':'promised','generator':'generate','deep':'recurse','optimized':'optimized','inlined':'inlineHot'}[label]
        assert required in names, (label,segment)
        if label=='deep': assert segment['state']=='partial' and segment['reason'] in ('JavaScriptFrameLimit','JavaScriptReadBudget')
        if label=='optimized':
            frame=next(f for f in segment['frames'] if f['name']=='optimized')
            assert frame['kind'] == 'turbofan' and frame['line'] is not None, frame
        if label=='inlined':
            frame=next(f for f in segment['frames'] if f['name']=='inlineHot')
            assert frame['kind']=='turbofan' and frame['line'] is None, frame
            assert frame['reason']=='JavaScriptInlinedSourcePositionUnresolved', frame
            assert 'inlineLeaf' not in names, names
        checks.append(label+': physical frame and proved caller positions; unchanged registers/generation')
    result = {'status':'pass','v8':version,'checks':checks,'evidence':evidence}
except BaseException:
    if args.output: Path(args.output).write_text(json.dumps({'status':'fail','checks':checks,'evidence':evidence},indent=2)+'\n')
    raise
else:
    if args.output: Path(args.output).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'status':'pass','v8':version,'checks':checks},indent=2))
finally:
    shutil.rmtree(work)
