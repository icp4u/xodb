#!/usr/bin/env python3
"""Static slice panel (S) on the native GUI, on a private compositor.

usage: static-analysis-gui.py [PREFIX]   (PREFIX holds bin/xodb; default zig-out)
XODB_STATIC_ANALYSIS=DIR names a built native Ghidra worker (tools/ghx). Without
it only the worker-absent panel is checked and the slice steps report "skip".

Owned fixture: tests/fixtures/semq/qx.c built with gcc -O2. Checks: the panel
opens with its static banner and a typed "unavailable" result without a worker;
with one, S on the stopped PC starts the shared analysis job, a click on the
`call malloc` row then S, Return answers "what feeds malloc's size": count and
size direct, flag irrelevant; Tab + Return lists the count guard; Return on a
row browses the assembly to the cited instruction. With
tests/fixtures/semq/lines.c: S on a source line holding two functions lists
both and picks neither; S on a line that exists only as code inlined into one
caller offers that caller's ops and answers.
"""
import importlib.util, json, os, subprocess, sys, time
from pathlib import Path
root = Path(__file__).resolve().parents[1]; os.chdir(root)
spec = importlib.util.spec_from_file_location('input_repro', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
work = root / '.work' / ('input-static-' + str(time.time_ns())[-10:]); work.mkdir(parents=True)
h.WORK = str(work)
for name in ('tmp', 'cache', 'cache/mesa', 'cache/nvidia'): (work / name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), str(root / 'tests/helpers/vinput.c'), str(work / 'virtual-pointer.c'), str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
source = root / 'tests/fixtures/semq/qx.c'; fixture = work / 'qx-gcc-O2'
subprocess.run(['gcc', '-O2', '-g', '-no-pie', '-Wl,--build-id=sha1', f'-ffile-prefix-map={source.parent}=fixtures', str(source), '-o', str(fixture)], env=dict(os.environ, TMPDIR=str(work / 'tmp')), check=True)
tree = work / 'tree'; tree.mkdir()
prefix = Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out').resolve()
(tree / 'zig-out').symlink_to(prefix, target_is_directory=True)
toolchain = os.environ.get('XODB_STATIC_ANALYSIS')
results = []

def record(name, outcome, detail=''):
    results.append({'check': name, 'outcome': outcome, 'detail': str(detail)})
    print(f'{outcome:5} {name}' + (f': {detail}' if detail else ''), flush=True)
    return outcome == 'pass'

def check(name, ok, detail=''):
    return record(name, 'pass' if ok else 'fail', detail)

def answers(d):
    out = []
    for line in open(d.log, errors='replace'):
        if line.startswith('static answer: '): out.append(line[len('static answer: '):].strip())
    return out

def stopped_at(d, symbol):
    address = d.request('tools/call', {'name': 'find_symbol', 'arguments': {'name': symbol}})['structuredContent']['address']
    d.tool('set_breakpoint', generation=d.session()['generation'], address=address)
    d.tool('continue', generation=d.session()['generation'])
    snap = d.stopped('breakpoint')
    assert snap, d.tail()
    return int(address, 16)

def wait_job(d, address, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        r = d.tool('analyze_function', address=hex(address))
        if r['status'] != 'running': return r
        time.sleep(.2)
    return r

failures = 0
d = None
env_saved = os.environ.pop('XODB_STATIC_ANALYSIS', None)
try:
    # 1. No worker: the panel is typed "unavailable" and says how to build it.
    d = h.Display(str(tree), ['--agent-scope', 'control', '--source', str(source), '--', str(fixture)])
    entry = stopped_at(d, 'qx_alloc')
    before = d.shot('01-absent-stopped')
    d.keys('tap', 31); time.sleep(.4)
    shot = d.shot('02-absent-panel')
    check('S opens the static panel without a worker', h.differs(before, shot, '1240x640+20+96'))
    r = d.tool('analyze_function', address=hex(entry))
    check('worker absent is a typed unavailable result', r['status'] == 'unavailable' and r['static_analysis']['reason'] == 'not_configured' and 'build_ghidra.sh' in r['static_analysis']['how_to_build'], r)
    d.keys('tap', 1); time.sleep(.2)
    check('Esc closes the panel and xodb stays alive', d.alive())
    d.app.stdin.close(); d.app.wait(timeout=10); d.close(); d = None
    if not toolchain:
        record('GUI slice with the native worker', 'skip', 'XODB_STATIC_ANALYSIS not set')
    else:
        os.environ['XODB_STATIC_ANALYSIS'] = toolchain
        d = h.Display(str(tree), ['--agent-scope', 'control', '--source', str(source), '--', str(fixture)])
        entry = stopped_at(d, 'qx_alloc')
        # 2. S on the stopped PC starts the shared job; MCP sees the same job.
        d.keys('tap', 31); time.sleep(.3)
        d.shot('03-running-or-ready')
        r = wait_job(d, entry)
        check('S started the analysis job shared with MCP', r['status'] == 'completed' and d.tool('cancel_static_analysis', job_id=1)['job']['state'] == 'completed', r.get('status'))
        time.sleep(.3); d.shot('04-pc-questions')
        d.keys('tap', 1); time.sleep(.2)
        # 3. Click the `call malloc` row, S, Return: what feeds malloc's size?
        listing = d.tool('disassemble', address=hex(entry))['instructions']
        index = next(i for i, x in enumerate(listing) if x['mnemonic'].startswith('call'))
        call_pc = int(listing[index]['address'], 16)
        d.keys('click', 820, 136 + 23 * index + 10); time.sleep(.3)
        d.shot('05-call-selected')
        d.keys('tap', 31); time.sleep(.5)
        d.shot('06-call-questions')
        d.keys('tap', 28); time.sleep(.5)
        d.shot('07-malloc-size-slice')
        got = answers(d)
        last = got[-1] if got else ''
        check('the slice answers CALL malloc argument 0', 'CALL malloc input 1' in last, last)
        check('count and size feed malloc, flag does not', 'param 0 EDI: direct' in last and 'param 1 ESI: direct' in last and 'param 2 EDX: irrelevant' in last, last)
        check('the answer keeps qualification and exhaustiveness', 'graph_qualified' in last and 'exhaustive yes' in last, last)
        mcp = d.tool('slice_value', pc=hex(call_pc), opcode='CALL', input=1)
        check('GUI and MCP give the same parameter relevance', [p['relevance'] for p in mcp['slice']['parameters']] == ['direct', 'direct', 'irrelevant'], mcp['slice']['parameters'])
        # 4. Tab: control questions for the same instruction; Return answers.
        d.keys('tap', 15, 'tap', 28); time.sleep(.5)
        d.shot('08-controls')
        got = answers(d)
        last = got[-1] if got else ''
        check('control dependences of the malloc call name the count guard only', 'What controls CALL malloc' in last and '1 control dependences' in last, last)
        guard = [l for l in open(d.log, errors='replace') if l.startswith('static row: ')][-1]
        check('the guard condition is fed by count (param 0) alone', 'param 0 EDI (direct)' in guard and 'param 1' not in guard and 'param 2' not in guard, guard.strip())
        # 5. Back to the slice; Return on its first row browses the assembly there.
        d.keys('tap', 15, 'tap', 28); time.sleep(.5)
        rows = [l for l in open(d.log, errors='replace') if l.startswith('static row: ')]
        count = int(answers(d)[-1].rsplit('rows=', 1)[1])
        first = int(rows[-count].split()[3], 16)
        before = d.shot('09-slice-again')
        d.keys('tap', 28); time.sleep(.5)
        after = d.shot('10-browsed-citation')
        moved = [l.split()[2] for l in open(d.log, errors='replace') if l.startswith('static navigate: ')]
        check('Return browses the assembly to the cited instruction', moved and int(moved[-1], 16) == first and h.differs(before, after, '400x500+614+120'), (moved[-1:] , hex(first)))
        d.keys('tap', 1); time.sleep(.2)
        d.app.stdin.close(); check('xodb exits cleanly', d.app.wait(timeout=10) == 0)
        d.close(); d = None
        # 6. Source lines: two functions on one line; a line that is only inlined code.
        lines_src = root / 'tests/fixtures/semq/lines.c'; lines_exe = work / 'lines'
        subprocess.run(['gcc', '-O2', '-g', '-no-pie', '-Wl,--build-id=sha1', str(lines_src), '-o', str(lines_exe)], env=dict(os.environ, TMPDIR=str(work / 'tmp')), check=True)
        text = lines_src.read_text().splitlines()
        mark = lambda m: next(i + 1 for i, l in enumerate(text) if '/* ' + m in l)
        d = h.Display(str(tree), ['--agent-scope', 'control', '--source', str(lines_src), '--', str(lines_exe)])
        stopped_at(d, 'two_a')
        tid = d.session()['threads'][0]['tid']
        current = d.tool('get_stack', tid=tid)['frames'][0]['source']['line']
        top = max(0, current - 6)
        row_y = lambda line: 135 + (line - top - 1) * 23 + 10
        d.keys('click', 300, row_y(mark('TWO'))); time.sleep(.3)
        d.keys('tap', 31); time.sleep(.5)
        d.shot('11-two-functions-choice')
        offered = [l.split()[2:] for l in open(d.log, errors='replace') if l.startswith('static functions:')]
        check('a line with two functions offers both and picks neither', offered and sorted(offered[-1]) == ['two_a', 'two_b'], offered[-1:])
        before = len(answers(d))
        d.keys('tap', 28); time.sleep(.3)  # choose the first function
        wait_job(d, int(d.request('tools/call', {'name': 'find_symbol', 'arguments': {'name': 'two_a'}})['structuredContent']['address'], 16))
        time.sleep(.4); d.shot('12-two-a-questions')
        d.keys('tap', 28); time.sleep(.5)
        got = answers(d)
        check('after choosing, the line answers within that function', len(got) > before, got[-1:])
        d.keys('tap', 1); time.sleep(.2)
        d.keys('click', 300, row_y(mark('WIDEN'))); time.sleep(.3)
        d.keys('tap', 31); time.sleep(.3)
        wait_job(d, int(d.request('tools/call', {'name': 'find_symbol', 'arguments': {'name': 'inl_c'}})['structuredContent']['address'], 16))
        time.sleep(.5); d.shot('13-inlined-line-questions')
        before = len(answers(d))
        d.keys('tap', 28); time.sleep(.5)
        d.shot('14-inlined-line-answer')
        got = answers(d)
        check('a line that is only inlined code offers its caller ops and answers', len(got) > before and ('INT_MULT' in got[-1] or 'INT_ADD' in got[-1]), got[-1:])
        d.keys('tap', 1); time.sleep(.2)
        d.app.stdin.close(); check('xodb exits cleanly after the line checks', d.app.wait(timeout=10) == 0)
finally:
    if d: d.close()
    if env_saved is not None: os.environ['XODB_STATIC_ANALYSIS'] = env_saved
(work / 'results.json').write_text(json.dumps(results, indent=1) + '\n')
failed = [r for r in results if r['outcome'] == 'fail']
print(f"static GUI: {sum(r['outcome'] == 'pass' for r in results)} pass, {len(failed)} fail, {sum(r['outcome'] == 'skip' for r in results)} skip; screenshots in {work}")
sys.exit(1 if failed else 0)
