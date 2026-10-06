#!/usr/bin/env python3
"""Static analysis inside the debugger over MCP (headless).

usage: static-analysis.py [--toolchain DIR] [--out RESULTS.json]
DIR (or XODB_STATIC_ANALYSIS) is a built native Ghidra worker directory
(tools/ghx/build_ghidra.sh + make -C tools/ghx into the same DIR). Without it
the worker-dependent cases are reported as "skip"; everything else still runs.

Owned fixtures only: tests/fixtures/semq/qx.c and tools/ghx/fixtures/fx.c,
built here. Cases:
  absent    no worker: every tool is a typed "unavailable" with how to build;
            incomplete directories name the missing piece; tools are observer reads
  lifecycle a real ghx_supervise with fake workers: a hung worker hits its
            deadline, a crashing one is worker_died, cancel stops a running job;
            each failure is bounded and leaves no child process behind; failures
            are not retried implicitly; one job at a time
  demo      qx_alloc in gcc/clang x O0/O2: count and size feed malloc's size,
            flag does not; the guard's condition is fed by count only;
            ambiguous PCs return candidates; PC, line and op selection agree
  lines     tests/fixtures/semq/lines.c: a line holding two functions and a
            helper inlined into two callers are "ambiguous" with both functions;
            a helper inlined into one caller selects that caller's ops through
            the line table (never "no_selection")
  deathsig  SIGKILL of xodb mid-job takes the supervisor and worker down at
            once; the next xodb sweeps the dead process's scratch directory
  ownership in a shared session an observer cannot cancel another client's
            job; its own, or any while holding the controller lease
  stripped  a stripped image with its debug file keeps the worker's
            stripped_without_function_starts qualification; the O2 PIC
            call-to-branch case stays an adapter refusal; no symbols at all is a
            typed bounds refusal
"""
import argparse, importlib.util, json, os, signal, subprocess, sys, tempfile, time
from pathlib import Path
root = Path(__file__).resolve().parents[1]; os.chdir(root)
sys.path.insert(0, str(root / 'tests'))
from client import Client

ap = argparse.ArgumentParser()
ap.add_argument('--toolchain', default=os.environ.get('XODB_STATIC_ANALYSIS'))
ap.add_argument('--out')
A = ap.parse_args()
os.environ.pop('XODB_STATIC_ANALYSIS', None)
os.umask(0o022)
work = Path(tempfile.mkdtemp(prefix='xodb-static-', dir=os.environ.get('XODB_TEST_TMPDIR')))
work.chmod(0o755)
results = []

def record(case, outcome, detail=''):
    results.append({'case': case, 'outcome': outcome, 'detail': detail if isinstance(detail, (str, dict, list)) else str(detail)})
    print(f'{outcome:5} {case}' + (f': {str(detail)[:400]}' if detail and outcome != 'pass' else ''), flush=True)

def check(case, ok, detail=''):
    record(case, 'pass' if ok else 'fail', detail)
    return ok

def run(case, fn):
    try:
        fn()
    except Exception as e:  # a crash in a case is a failure, never a skip
        record(case, 'fail', f'{type(e).__name__}: {e}')

def tool(c, tool_name, **args):
    r = c.call('tools/call', {'name': tool_name, 'arguments': args})
    if 'error' in r: return {'_protocol_error': r['error']['message']}
    if r['result'].get('isError'): return {'_error': r['result']['content'][0]['text']}
    return r['result']['structuredContent']

def stopped(c):
    for _ in range(100):
        s = tool(c, 'get_session')
        if s['state'] == 'stopped': return s
        time.sleep(.05)
    raise AssertionError('target did not stop')

def symbol(c, name):
    return int(tool(c, 'find_symbol', name=name)['address'], 16)

def poll(c, tool_name, seconds=90, **args):
    deadline = time.monotonic() + seconds
    while True:
        r = tool(c, tool_name, **args)
        if r.get('status') not in ('running',) or time.monotonic() > deadline: return r
        time.sleep(.1)

def children(pid):
    out = set()
    for task in Path(f'/proc/{pid}/task').iterdir():
        try: out |= {int(x) for x in (task / 'children').read_text().split()}
        except FileNotFoundError: pass
    return out

def alive(pid):
    try:
        state = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()[0]
        return state != 'Z'
    except FileNotFoundError:
        return False

def client(fixture, *options):
    c = Client('observe', str(fixture), options=list(options))
    s = stopped(c)
    return c, s['pid']

def close(c):
    c.p.stdin.close()
    return c.p.wait(timeout=20)

# ---- fixtures -------------------------------------------------------------------------
qx = work / 'qx'; fx = work / 'fx'
subprocess.run(['sh', 'tests/fixtures/semq/build_fixtures.sh', str(qx)], check=True, timeout=600, env=dict(os.environ, TMPDIR=str(work)))
subprocess.run(['sh', 'tools/ghx/fixtures/build_fixtures.sh', str(fx)], check=True, timeout=600, env=dict(os.environ, TMPDIR=str(work)))
for b in ('qx-gcc-O2',):
    subprocess.run(['strip', '-o', str(qx / (b + '.stripped')), str(qx / b)], check=True)
O2 = qx / 'qx-gcc-O2'

# ---- absent ---------------------------------------------------------------------------
def absent():
    c, pid = client(O2)
    try:
        entry = symbol(c, 'qx_alloc')
        listed = {t['name']: t for t in c.call('tools/list')['result']['tools']}
        names = ('analyze_function', 'slice_value', 'control_dependencies', 'cancel_static_analysis')
        check('absent: tools listed to an observe-scope client as observer reads', all(n in listed and listed[n]['annotations']['xodbSessionAccess'] == 'observer' and listed[n]['annotations']['readOnlyHint'] for n in names), sorted(listed)[:5])
        for name, args in (('analyze_function', {'address': hex(entry)}), ('slice_value', {'pc': hex(entry), 'input': 0}), ('control_dependencies', {'pc': hex(entry)}), ('slice_value', {'file': 'qx.c', 'line': 14})):
            r = tool(c, name, **args)
            check(f'absent: {name} {sorted(args)} is typed unavailable', r.get('status') == 'unavailable' and r['static_analysis']['reason'] == 'not_configured' and 'build_ghidra.sh' in r['static_analysis']['how_to_build'], r)
        r = tool(c, 'cancel_static_analysis', job_id=1)
        check('absent: cancel without a job is a typed error', r.get('_error') == 'NoStaticAnalysisJob', r)
        r = tool(c, 'slice_value', pc=hex(entry), file='qx.c', line=3)
        check('absent: two selectors at once are invalid arguments', r.get('_protocol_error') == 'InvalidArguments', r)
    finally:
        check('absent: xodb exits cleanly', close(c) == 0)
    sup = work / 'ghx_supervise'
    subprocess.run(['cc', '-std=c11', '-O2', '-D_GNU_SOURCE', '-o', str(sup), 'tools/ghx/ghx_supervise.c'], check=True)
    for name, content in (('empty', ()), ('no-worker', ('ghx_supervise',)), ('no-sleigh', ('ghx_supervise', 'ghx_worker'))):
        d = work / ('partial-' + name); d.mkdir()
        for f in content:
            (d / f).write_bytes(sup.read_bytes()); (d / f).chmod(0o755)
        c, pid = client(O2, '--static-analysis', str(d))
        try:
            r = tool(c, 'analyze_function', symbol='qx_alloc')
            want = {'empty': 'supervisor_missing', 'no-worker': 'worker_missing', 'no-sleigh': 'sleigh_missing'}[name]
            check(f'absent: {name} directory reports {want}', r.get('status') == 'unavailable' and r['static_analysis']['reason'] == want, r)
        finally:
            close(c)

# ---- lifecycle with fake workers --------------------------------------------------------
def fake_toolchain(name, script):
    d = work / ('fake-' + name)
    (d / 'ghidra-src/Ghidra/Processors/x86/data/languages').mkdir(parents=True)
    (d / 'ghidra-src/Ghidra/Processors/x86/data/languages/x86-64.sla').write_text('placeholder\n')
    (d / 'ghx_supervise').write_bytes((work / 'ghx_supervise').read_bytes()); (d / 'ghx_supervise').chmod(0o755)
    (d / 'ghx_worker').write_text('#!/bin/sh\n' + script + '\n'); (d / 'ghx_worker').chmod(0o755)
    return d

def bounded(case, c, xodb_pid, target_pid, r, code, limit_ms):
    job = r.get('job', {})
    failure = job.get('failure') or {}
    worker = failure.get('worker_pid')
    ok = r.get('status') in ('failed', 'cancelled') and failure.get('code') == code and job.get('elapsed_ms', 1e9) <= limit_ms
    check(f'{case}: {code} within {limit_ms} ms', ok, r)
    check(f'{case}: worker process gone', worker is not None and not alive(worker), worker)
    extra = children(xodb_pid) - {target_pid}
    check(f'{case}: no leaked child of xodb', not extra, sorted(extra))

def lifecycle():
    hang = fake_toolchain('hang', 'exec sleep 600')
    c, target = client(O2, '--static-analysis', str(hang))
    try:
        t0 = time.monotonic()
        r = tool(c, 'analyze_function', symbol='qx_alloc', deadline_ms=1500)
        check('lifecycle: a new analysis starts as a running job', r.get('status') == 'running' and r['job']['id'] == 1, r)
        busy = tool(c, 'analyze_function', symbol='main')
        check('lifecycle: a second function while one runs is StaticAnalysisBusy', busy.get('_error') == 'StaticAnalysisBusy', busy)
        r = poll(c, 'analyze_function', symbol='qx_alloc')
        bounded('timeout', c, c.p.pid, target, r, 'worker_timeout', 1500 + 4000)
        again = tool(c, 'analyze_function', symbol='qx_alloc')
        check('lifecycle: a failure is reported again, not retried implicitly', again.get('status') == 'failed' and again['job']['id'] == 1, again)
        r = tool(c, 'slice_value', pc=hex(symbol(c, 'qx_alloc')), input=0)
        check('lifecycle: slice_value reports the failed analysis', r.get('status') == 'failed' and r['job']['failure']['code'] == 'worker_timeout', r)
        r = tool(c, 'analyze_function', symbol='qx_alloc', retry=True, deadline_ms=60000)
        check('lifecycle: retry starts job 2', r.get('status') == 'running' and r['job']['id'] == 2, r)
        time.sleep(.5)
        r = tool(c, 'cancel_static_analysis', job_id=2)
        check('lifecycle: cancel is accepted', r.get('status') in ('cancelling', 'cancelled'), r)
        r = poll(c, 'analyze_function', symbol='qx_alloc', seconds=10)
        bounded('cancel', c, c.p.pid, target, r, 'cancelled', 3000 + 500)
        stale = tool(c, 'cancel_static_analysis', job_id=1)
        check('lifecycle: cancelling an older job id is StaleStaticAnalysisJob', stale.get('_error') == 'StaleStaticAnalysisJob', stale)
    finally:
        check('lifecycle: xodb exits cleanly after worker failures', close(c) == 0)
    crash = fake_toolchain('crash', 'kill -SEGV $$')
    c, target = client(O2, '--static-analysis', str(crash))
    try:
        tool(c, 'analyze_function', symbol='qx_alloc')
        r = poll(c, 'analyze_function', symbol='qx_alloc')
        bounded('crash', c, c.p.pid, target, r, 'worker_died', 3000)
        check('crash: the cause is reported', 'worker' in r['job']['failure']['detail'], r['job']['failure'])
    finally:
        close(c)
    # The host bound applies even while the debugger is torn down mid-job.
    c, target = client(O2, '--static-analysis', str(hang))
    tool(c, 'analyze_function', symbol='qx_alloc', deadline_ms=600000)
    time.sleep(.5)
    workers = [p for p in children(c.p.pid) if p != target]
    t0 = time.monotonic(); code = close(c)
    grandchildren = set()
    for p in workers:
        try: grandchildren |= children(p)
        except FileNotFoundError: pass
    check('teardown: closing xodb mid-job exits promptly', code == 0 and time.monotonic() - t0 < 5, (code, time.monotonic() - t0))
    time.sleep(.3)
    check('teardown: the supervisor is gone', all(not alive(p) for p in workers), workers)

# ---- demo with the real worker ----------------------------------------------------------
DATA = ('direct', 'possible')

def rel(params, i):
    for p in params:
        if p['index'] == i: return p['relevance']
    return 'absent'

def demo():
    for build in ('qx-gcc-O2', 'qx-gcc-O0', 'qx-clang-O2', 'qx-clang-O0'):
        c, _ = client(qx / build, '--static-analysis', A.toolchain)
        try:
            entry = symbol(c, 'qx_alloc')
            r = poll(c, 'analyze_function', address=hex(entry))
            if not check(f'{build}: analysis completes', r.get('status') == 'completed', r): continue
            an = r['analysis']
            check(f'{build}: identity is the session image and trust is never upgraded', an['trust']['verified_semantics'] is False and an['trust']['result_trust'] == 'graph_' + an['qualification']['level'] and len(an['image']['sha256']) == 64 and an['function'] == 'qx_alloc', an['trust'])
            again = tool(c, 'analyze_function', address=hex(entry + 1))
            check(f'{build}: cached by artifact_id', again.get('status') == 'completed' and again['analysis']['artifact_id'] == an['artifact_id'])
            malloc = [x for x in an['calls'] if x['name'] == 'malloc']
            if not check(f'{build}: the export names the malloc call', len(malloc) == 1, an['calls']): continue
            pc = malloc[0]['address']
            s = tool(c, 'slice_value', pc=pc, opcode='CALL', input=1, data_only=True)
            p = s['slice']['parameters']
            check(f'{build}: count and size feed malloc, flag does not', rel(p, 0) in DATA and rel(p, 1) in DATA and rel(p, 2) not in DATA, p)
            record(f'{build}: flag proven irrelevant (exhaustive slice)', 'pass' if rel(p, 2) == 'irrelevant' else 'note', {'flag': rel(p, 2), 'exhaustive': s['slice']['exhaustive']})
            check(f'{build}: answer carries the static label and citations', s['slice']['trust']['note'] == 'static possibilities, not an observed execution' and s['slice']['instructions'] and all(i['source'] for i in s['slice']['instructions']), s['slice']['instructions'][:2])
            k = tool(c, 'control_dependencies', pc=pc, opcode='CALL')
            direct = [x for x in k['controls']['controls'] if x['relation'] == 'direct']
            check(f'{build}: the malloc call is guarded by a condition on count only', any(rel(x['condition_parameters'], 0) in DATA and rel(x['condition_parameters'], 1) not in DATA and rel(x['condition_parameters'], 2) not in DATA for x in direct), direct)
            guard = direct[0]['branch']['address'] if direct else None
            amb = tool(c, 'control_dependencies', pc=guard) if guard else {}
            ops = {x['op']['opcode'] for x in amb.get('candidates', [])}
            if amb.get('status') == 'ambiguous':
                check(f'{build}: an ambiguous PC returns candidates, not a guess', len(amb['candidates']) >= 2 and 'slice' not in amb and 'controls' not in amb, ops)
            else:
                record(f'{build}: guard PC carries a single op', 'note', amb.get('status'))
            by_op = tool(c, 'slice_value', symbol='qx_alloc', op=s['candidate']['op']['op'], input=1, data_only=True)
            by_line = tool(c, 'slice_value', file='qx.c', line=14, opcode='CALL', input=1, data_only=True)
            check(f'{build}: op, PC and source-line selection agree', by_op.get('slice', {}).get('parameters') == p and by_line.get('slice', {}).get('parameters') == p, (by_line.get('status'), by_line.get('reason')))
            bad = tool(c, 'slice_value', pc=pc, opcode='CALL', input=99)
            check(f'{build}: an input past the op is a typed error', bad.get('_error') == 'InputOutOfRange', bad)
        finally:
            close(c)
    # Observed now is separate from the static answer.
    c = Client('control', str(O2), options=['--static-analysis', A.toolchain])
    try:
        stopped(c)
        entry = symbol(c, 'qx_alloc')
        tool(c, 'set_breakpoint', generation=tool(c, 'get_session')['generation'], address=hex(entry))
        tool(c, 'continue', generation=tool(c, 'get_session')['generation'])
        for _ in range(100):
            s = tool(c, 'get_session')
            if s['state'] == 'stopped' and any(t['reason'] == 'breakpoint' for t in s['threads']): break
            time.sleep(.05)
        tid = s['threads'][0]['tid']
        an = poll(c, 'analyze_function', address=hex(entry))['analysis']
        pc = [x for x in an['calls'] if x['name'] == 'malloc'][0]['address']
        r = tool(c, 'slice_value', pc=pc, opcode='CALL', input=1, tid=tid)
        seen = r.get('observed_now') or {}
        names = [p['name'] for p in seen.get('parameters', [])]
        check('observed_now: DWARF parameters at the stop, outside the static answer', seen.get('kind') == 'observed_now' and names[:3] == ['count', 'size', 'flag'] and 'observed_now' not in r['slice'], seen)
    finally:
        close(c)

def stripped():
    c, _ = client(qx / 'qx-gcc-O2.stripped', '--static-analysis', A.toolchain)
    try:
        r = tool(c, 'analyze_function', address=hex(int([l.split()[1] for l in open(qx / 'qx-gcc-O2.oracle') if l.startswith('qx_alloc ')][0], 16)))
        check('stripped: no symbols at all is a typed bounds refusal', r.get('_error') == 'FunctionBoundsUnavailable', r)
    finally:
        close(c)
    c, _ = client(qx / 'qx-gcc-O2.stripped', '--static-analysis', A.toolchain, '--debug-file', str(O2))
    try:
        r = poll(c, 'analyze_function', symbol='qx_alloc')
        codes = [x['code'] for x in r.get('analysis', {}).get('qualification', {}).get('reasons', [])]
        check('stripped+debug file: the worker qualification stays stripped_without_function_starts', r.get('status') == 'completed' and 'stripped_without_function_starts' in codes and r['analysis']['qualification']['level'] != 'complete', codes)
        pc = [x for x in r['analysis']['calls'] if x['name'] == 'malloc'][0]['address']
        s = tool(c, 'slice_value', pc=pc, opcode='CALL', input=1, data_only=True)
        check('stripped+debug file: the slice keeps the qualified trust', s['slice']['trust']['result_trust'] == 'graph_' + r['analysis']['qualification']['level'] and 'stripped_without_function_starts' in s['slice']['trust']['reasons'], s['slice']['trust'])
    finally:
        close(c)
    c, _ = client(fx / 'fx-gcc-O2.stripped', '--static-analysis', A.toolchain, '--debug-file', str(fx / 'fx-gcc-O2'))
    try:
        r = poll(c, 'analyze_function', symbol='fx_calls')
        f = r.get('job', {}).get('failure') or {}
        if r.get('status') == 'failed':
            check('stripped O2 fx_calls: the PIC call-to-branch case stays a refusal', f.get('code') == 'adapter_refused' and 'no block starts at function entry' in f.get('detail', ''), f)
        else:
            codes = [x['code'] for x in r.get('analysis', {}).get('qualification', {}).get('reasons', [])]
            check('stripped O2 fx_calls: answered only with its qualification', r.get('status') == 'completed' and r['analysis']['qualification']['level'] in ('qualified', 'unreliable'), codes)
    finally:
        close(c)


# ---- source lines: several functions, inlined code --------------------------------------
def marker(path, name):
    return next(i + 1 for i, l in enumerate(open(path).read().splitlines()) if '/* ' + name in l)

def lines():
    src = root / 'tests/fixtures/semq/lines.c'
    exe = work / 'lines'
    subprocess.run(['gcc', '-O2', '-g', '-no-pie', '-Wl,--build-id=sha1', '-o', str(exe), str(src)], check=True, env=dict(os.environ, TMPDIR=str(work)))
    c, _ = client(exe, '--static-analysis', A.toolchain)
    try:
        two = poll(c, 'slice_value', file='lines.c', line=marker(src, 'TWO'))
        check('lines: a line with two functions returns both, never a guess', two.get('status') == 'ambiguous' and sorted(f['function'] for f in two.get('functions', [])) == ['two_a', 'two_b'], two)
        grow = poll(c, 'slice_value', file='lines.c', line=marker(src, 'GROW'))
        check('lines: a helper inlined into two callers is ambiguous between them', grow.get('status') == 'ambiguous' and sorted(f['function'] for f in grow.get('functions', [])) == ['inl_a', 'inl_b'], grow)
        widen = poll(c, 'slice_value', file='lines.c', line=marker(src, 'WIDEN'))
        ops = {x['op']['opcode'] for x in widen.get('candidates', [])}
        check('lines: an inlined-only line selects the caller ops through the line table', widen.get('status') in ('ambiguous', 'completed') and widen.get('analysis', {}).get('function') == 'inl_c' and ops & {'INT_MULT', 'INT_ADD'}, widen)
        one = poll(c, 'slice_value', file='lines.c', line=marker(src, 'WIDEN'), opcode='INT_MULT', input=0, data_only=True)
        check('lines: the inlined line answers a slice in its caller', one.get('status') == 'completed' and one['slice']['trust']['note'] == 'static possibilities, not an observed execution' and rel(one['slice']['parameters'], 0) in DATA, one.get('slice', {}).get('parameters'))
    finally:
        close(c)

# ---- xodb killed mid-job ----------------------------------------------------------------
def deathsig():
    # Orphans of the killed xodb (its target, supervisor and worker) are
    # re-parented here, so this test reaps them instead of leaking zombies.
    import ctypes
    ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER
    hang = fake_toolchain('death', 'exec sleep 600')
    scratch = work / 'death-tmp'; scratch.mkdir()
    env = dict(os.environ, TMPDIR=str(scratch))
    xodb = os.environ.get('XODB_BIN', './zig-out/bin/xodb')
    p = subprocess.Popen([xodb, '--headless', '--mcp', '--static-analysis', str(hang), '--', str(O2)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, bufsize=0)
    def call(ident, method, params):
        p.stdin.write((json.dumps({'jsonrpc': '2.0', 'id': ident, 'method': method, 'params': params}) + '\n').encode())
        while True:
            line = p.stdout.readline()
            reply = json.loads(line)
            if reply.get('id') == ident: return reply
    call(1, 'initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'death', 'version': '1'}})
    p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    target = None
    for i in range(100):
        s = call(10 + i, 'tools/call', {'name': 'get_session', 'arguments': {}})['result']['structuredContent']
        if s['state'] == 'stopped': target = s['pid']; break
        time.sleep(.05)
    r = call(200, 'tools/call', {'name': 'analyze_function', 'arguments': {'symbol': 'qx_alloc', 'deadline_ms': 600000}})['result']['structuredContent']
    supervisor = worker = None
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and worker is None:
        sups = children(p.pid) - {target}
        if sups:
            supervisor = min(sups)
            kids = children(supervisor)
            worker = min(kids) if kids else None
        time.sleep(.05)
    dirs = [d.name for d in scratch.iterdir() if d.name.startswith('xodb-static-')]
    check('deathsig: a running job has a supervisor, a worker and a pid-named scratch directory', r.get('status') == 'running' and supervisor and worker and len(dirs) == 1 and dirs[0].startswith(f'xodb-static-{p.pid}-'), (r.get('status'), supervisor, worker, dirs))
    p.kill(); p.wait()
    t0 = time.monotonic()
    while time.monotonic() - t0 < 3 and (alive(supervisor or -1) or alive(worker or -1)): time.sleep(.05)
    gone = time.monotonic() - t0
    check('deathsig: SIGKILL of xodb takes the supervisor and the worker down at once', supervisor and worker and not alive(supervisor) and not alive(worker) and gone < 2, (supervisor, worker, round(gone, 2)))
    for pid in (supervisor, worker, target):
        if not pid: continue
        if alive(pid): os.kill(pid, signal.SIGKILL)
        try: os.waitpid(pid, 0)
        except ChildProcessError: pass
    check('deathsig: the killed xodb left its scratch directory', len([d for d in scratch.iterdir() if d.name.startswith('xodb-static-')]) == 1)
    foreign = scratch / 'xodb-static-1-keepme'; foreign.mkdir()  # pid 1 is alive: never swept
    q = subprocess.Popen([xodb, '--headless', '--mcp', '--static-analysis', str(hang), '--', str(O2)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    time.sleep(1.0)
    left = sorted(d.name for d in scratch.iterdir())
    q.stdin.close(); q.wait(timeout=20)
    check('deathsig: the next xodb sweeps only dead processes\' scratch', left == ['xodb-static-1-keepme'], left)

# ---- cancel ownership in a shared session -----------------------------------------------
def ownership():
    spec = importlib.util.spec_from_file_location('shared_sessions', root / 'tests/shared-sessions.py')
    shared = importlib.util.module_from_spec(spec); spec.loader.exec_module(shared)
    hang = fake_toolchain('own', 'exec sleep 600')
    xodb = Path(os.environ.get('XODB_BIN', './zig-out/bin/xodb')).resolve()
    server = shared.Server(root, work, xodb, O2, 'control', options=['--static-analysis', str(hang)], fixture_args=())
    try:
        a = shared.Client(server, 'owner'); b = shared.Client(server, 'other')
        job = a.tool('analyze_function', symbol='qx_alloc', deadline_ms=600000)['job']['id']
        denied = b.raw('cancel_static_analysis', job_id=job)
        check('ownership: an observer cannot cancel another client\'s job', denied.get('result', {}).get('isError') and denied['result']['content'][0]['text'] == 'StaticAnalysisJobNotOwned', denied)
        b.claim()
        ok = b.tool('cancel_static_analysis', job_id=job)
        check('ownership: the controller may cancel any job', ok.get('status') in ('cancelling', 'cancelled'), ok)
        b.tool('release_session_control')
        r = shared.eventually(lambda: a.tool('analyze_function', symbol='qx_alloc'), lambda v: v.get('status') != 'running', 'cancelled', timeout=10)
        mine = a.tool('analyze_function', symbol='qx_alloc', retry=True, deadline_ms=600000)['job']['id']
        own = a.tool('cancel_static_analysis', job_id=mine)
        check('ownership: a client may cancel its own job without control', r.get('status') == 'cancelled' and own.get('status') in ('cancelling', 'cancelled'), (r.get('status'), own.get('status')))
    finally:
        server.close()

run('absent', absent)
run('lifecycle', lifecycle)
run('deathsig', deathsig)
run('ownership', ownership)
if A.toolchain:
    run('demo', demo)
    run('stripped', stripped)
    run('lines', lines)
else:
    record('demo', 'skip', 'no --toolchain / XODB_STATIC_ANALYSIS: native worker not built')
    record('stripped', 'skip', 'no --toolchain / XODB_STATIC_ANALYSIS: native worker not built')
    record('lines', 'skip', 'no --toolchain / XODB_STATIC_ANALYSIS: native worker not built')
counts = {k: sum(r['outcome'] == k for r in results) for k in ('pass', 'fail', 'skip', 'note')}
if A.out: Path(A.out).write_text(json.dumps({'counts': counts, 'results': results}, indent=1) + '\n')
print(f"static analysis: {counts['pass']} pass, {counts['fail']} fail, {counts['skip']} skip, {counts['note']} note ({work})")
sys.exit(1 if counts['fail'] else 0)
