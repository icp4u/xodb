#!/usr/bin/env python3
"""execute_call: inferior C/C++ calls on x86-64 SysV Linux, local or agent.

An oracle compares every supported call with gdb's `print` on the same owned
fixture stopped at the same point (a separate gdb run; pointers are compared
relative to locals). Each returned call is followed by a full dump of the
thread's general registers, x87/SSE/AVX state and the borrowed stack range,
which must match the dump taken before the call byte for byte. Failure cases
(timeout, SIGSEGV, a lock held by a stopped thread, a breakpoint inside the
callee, an escaping C++ exception) leave an explicit active call frame that
blocks continue until it is restored or abandoned. Typed refusals cover
scope, consent, overloads, templates, non-trivial copies, varargs without a
prototype, literals needing scratch memory and unresolved IFUNCs; the read-only
evaluator refuses calls with ExecutionRequired.

--agent runs the same script through --runtime-agent. --evidence writes the
gdb transcript, every xodb result and the register dumps.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from client import Client

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--binary', type=Path, default=Path(os.environ.get('XODB_BIN', 'zig-out/bin/xodb')))
p.add_argument('--agent', type=Path)
p.add_argument('--evidence', type=Path)
args = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = args.work.resolve()
work.mkdir(parents=True, exist_ok=True)
started = time.monotonic()
os.environ['XODB_BIN'] = str(args.binary.resolve())
lane = 'agent' if args.agent else 'local'
options = ['--runtime-agent', str(args.agent.resolve())] if args.agent else []
if args.agent:
    os.environ.pop('XODB_TEST_RUNTIME_AGENT', None)
    os.environ.pop('XODB_RUNTIME_AGENT', None)
failures = []
evidence = {'lane': lane, 'gdb': None, 'calls': [], 'restores': [], 'refusals': [], 'recovery': []}


def check(name, condition, detail=''):
    print(('PASS ' if condition else 'FAIL ') + name + ('' if condition else ' ' + str(detail)[:2000]), flush=True)
    if not condition:
        failures.append(name)


if os.uname().machine != 'x86_64':
    print('SKIP execute_call needs an x86-64 host')
    sys.exit(0)
fixture = work / 'execute-call-fixture'
subprocess.run(['c++', '-std=c++17', '-O0', '-g', '-fno-omit-frame-pointer', '-pthread',
                '-Wl,-z,now', '-o', str(fixture), str(root / 'tests/execute-call-fixture.cc')],
               check=True, timeout=120)

# ---------------------------------------------------------------- oracle
# (name, gdb expression, xodb request, kind)
CASES = [
    ('int', 'add_ints(x, 2)', {'callee': 'add_ints', 'arguments': ['x', '2']}, 'int'),
    ('narrow', 'add_small(small, -3, 7)', {'callee': 'add_small', 'arguments': ['small', '-3', '7']}, 'int'),
    ('unsigned_char', '(int)low_byte(0x1ff)', {'callee': 'low_byte', 'arguments': ['0x1ff']}, 'int'),
    ('bool_int', 'is_odd(x)', {'callee': 'is_odd', 'arguments': ['x']}, 'int'),
    ('double', 'scale(d, 3)', {'callee': 'scale', 'arguments': ['d', '3']}, 'float'),
    ('float', 'halve(f)', {'callee': 'halve', 'arguments': ['f']}, 'float'),
    ('mixed', 'mix(small, d, x, f)', {'callee': 'mix', 'arguments': ['small', 'd', 'x', 'f']}, 'float'),
    ('struct_int_sse', 'make_pair(x, d)', {'callee': 'make_pair', 'arguments': ['x', 'd']}, 'struct'),
    ('struct_arg', 'pair_sum(pr)', {'callee': 'pair_sum', 'arguments': ['pr']}, 'float'),
    ('struct_sse', 'swap_f(fp2)', {'callee': 'swap_f', 'arguments': ['fp2']}, 'struct'),
    ('struct_int', 'add_ipair(ip, 1)', {'callee': 'add_ipair', 'arguments': ['ip', '1']}, 'struct'),
    ('struct_memory_return', 'make_triple(x)', {'callee': 'make_triple', 'arguments': ['x']}, 'struct'),
    ('struct_memory_arg', 'triple_sum(tr)', {'callee': 'triple_sum', 'arguments': ['tr']}, 'int'),
    ('stack_ints', 'eight(1, 2, 3, 4, 5, 6, 7, 8)', {'callee': 'eight', 'arguments': [str(i) for i in range(1, 9)]}, 'int'),
    ('stack_doubles', 'ten(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0)', {'callee': 'ten', 'arguments': ['%d.0' % i for i in range(1, 11)]}, 'float'),
    ('alignment', 'stack_align()', {'callee': 'stack_align'}, 'int'),
    ('pointer', 'pick(buf, 7) - (char *)buf', {'callee': 'pick', 'arguments': ['buf', '7']}, 'offset_buf'),
    ('varargs_int', 'sum_ints(3, 10, 20, 30)', {'callee': 'sum_ints', 'arguments': ['3', '10', '20', '30'], 'prototype': 'long(int, ...)'}, 'int'),
    ('varargs_double', 'sum_doubles(2, d, 2.5)', {'callee': 'sum_doubles', 'arguments': ['2', 'd', '2.5'], 'prototype': 'double(int, ...)'}, 'float'),
    ('plt_ifunc_strlen', '(unsigned long)strlen(buf)', {'callee': 'strlen', 'arguments': ['buf'], 'prototype': 'size_t(const char *)'}, 'int'),
    ('plt_ifunc_memcpy', '(long)memcpy(dst, buf, 5) - (long)dst', {'callee': 'memcpy', 'arguments': ['dst', 'buf', '5'], 'prototype': 'void *(void *, const void *, size_t)'}, 'offset_dst'),
    ('memcpy_effect', 'dst', None, 'string'),
    ('function_pointer', 'fp(3, 4)', {'callee': 'fp', 'arguments': ['3', '4']}, 'int'),
    ('member', 'counter.add(5)', {'callee': 'Counter::add', 'this': '&counter', 'arguments': ['5']}, 'int'),
    ('const_member', 'counter.get()', {'callee': 'Counter::get', 'this': '&counter'}, 'int'),
    ('virtual', 'shape->area()', {'callee': 'Shape::area', 'this': 'shape'}, 'float'),
    ('virtual_derived', '((Shape *)&square)->area()', {'callee': 'Shape::area', 'this': '&square'}, 'float'),
    ('overload_selected', 'overloaded(d)', {'callee': 'overloaded(double)', 'arguments': ['d']}, 'int'),
    ('template_instance', 'maxof<int>(3, 9)', {'callee': 'maxof<int>', 'arguments': ['3', '9']}, 'int'),
    ('side_effect_1', 'bump(5)', {'callee': 'bump', 'arguments': ['5']}, 'int'),
    ('side_effect_2', 'bump(5)', {'callee': 'bump', 'arguments': ['5']}, 'int'),
]

gdb = shutil.which('gdb')
if not gdb:
    check('gdb oracle available', False, 'gdb not on PATH')
    sys.exit(1)
command = [gdb, '-batch', '-nx', '-ex', 'set debuginfod enabled off', '-ex', 'set confirm off',
           '-ex', 'set print pretty off', '-ex', 'set width 0', '-ex', 'break checkpoint', '-ex', 'run', '-ex', 'up']
for _, expression, _, _ in CASES:
    command += ['-ex', 'echo @@\\n', '-ex', 'print ' + expression]
command += ['-ex', 'kill']
oracle = subprocess.run(command + ['--args', str(fixture)], capture_output=True, text=True, timeout=120, cwd=work)
gdb_text = oracle.stdout
evidence['gdb'] = {'command': ' '.join(command[1:]) + ' --args execute-call-fixture', 'stdout': gdb_text, 'stderr': oracle.stderr[-4000:]}
blocks = gdb_text.split('@@\n')[1:]
gdb_values = []
for block in blocks:
    m = re.search(r'^\$\d+ = (.*)$', block, re.M)
    gdb_values.append(m.group(1).strip() if m else None)
check('gdb produced every oracle value', len(gdb_values) == len(CASES) and all(v is not None for v in gdb_values), gdb_text[-3000:] + oracle.stderr[-2000:])


def gdb_number(text):
    text = text.split(' ')[0]
    return float(text) if any(c in text for c in '.en') and not text.startswith('0x') else int(text, 0)


def gdb_struct(text):
    return {k: gdb_number(v.strip()) for k, v in re.findall(r'(\w+) = ([^,}]+)', text)}


def gdb_string(text):
    m = re.search(r'"(.*)"', text)
    return m.group(1).split('\\000')[0] if m else None


# ---------------------------------------------------------------- xodb
c = Client('execute', str(fixture), options=options, reply_seconds=40)


def gen():
    return c.session()['generation']


PENDING = ('DebugMetadataPending', 'SymbolDiscoveryPending')


def raw(name, **kw):
    """One tool call; image preparation (remote) is waited out. A pending
    refusal happens before any target write, so repeating it is safe."""
    deadline = time.monotonic() + 60
    while True:
        response = c.tool(name, **kw)
        assert 'error' not in response, response
        result = response['result']
        if not (result.get('isError') and result['content'][0]['text'] in PENDING) or time.monotonic() > deadline:
            return result
        if 'generation' in kw:
            kw['generation'] = c.session()['generation']
        time.sleep(.02)


def ok(name, **kw):
    result = raw(name, **kw)
    assert not result.get('isError'), (name, kw, result)
    return result['structuredContent']


def refused(name, **kw):
    result = raw(name, **kw)
    return result['content'][0]['text'] if result.get('isError') else None


def call(**request):
    request.setdefault('frame', 1)
    request.setdefault('tid', tid)
    return ok('execute_call', allow_execution=True, generation=gen(), **request)


ok('set_breakpoint', symbol='checkpoint', generation=gen())
c.continue_initial_stop()
state = c.stopped('breakpoint', seconds=20)
tid = next(t['tid'] for t in state['threads'] if t['reason'] == 'breakpoint')


def dump():
    regs = ok('get_registers', tid=tid)['registers']
    ext = ok('get_extended_registers', tid=tid)
    ext = {k: v for k, v in ext.items() if k != 'generation'}
    rsp = int(regs['rsp'], 0)
    low = rsp - 1024 - 128
    stack = ok('read_memory', address=hex(low), length=1024 + 128 + 256)['hex']
    return {'registers': regs, 'extended': ext, 'stack_low': hex(low), 'stack': stack}


def same(a, b, low=None, high=None):
    """Differences between two dumps. Stack bytes below `low` (the borrowed
    range's lowest address) are dead stack the callee's own frames used."""
    diffs = []
    for key in sorted(set(a['registers']) | set(b['registers'])):
        if a['registers'].get(key) != b['registers'].get(key):
            diffs.append(('register', key, a['registers'].get(key), b['registers'].get(key)))
    if a['extended'] != b['extended']:
        for key in sorted(set(a['extended']) | set(b['extended'])):
            if a['extended'].get(key) != b['extended'].get(key):
                diffs.append(('extended', key))
    base = int(a['stack_low'], 16)
    skip = 0 if low is None else max(0, low - base)
    end = None if high is None else max(skip, high - base)
    sa, sb = bytes.fromhex(a['stack'])[skip:end], bytes.fromhex(b['stack'])[skip:end]
    if sa != sb:
        first = next((i for i in range(min(len(sa), len(sb))) if sa[i] != sb[i]), 0)
        diffs.append(('stack', hex(base + skip + first)))
    return diffs


baseline = dump()
evidence['baseline'] = baseline
locals_ = {name: ok('evaluate_expression', tid=tid, frame=1, expression=name) for name in ('&buf', '&dst')}
buf_address = int(locals_['&buf']['bits'], 16)
dst_address = int(locals_['&dst']['bits'], 16)
vector_rows = baseline['extended'].get('vectors') or baseline['extended'].get('registers') or []
check('baseline holds the fixture vector pattern', '0102030405060708' in json.dumps(baseline['extended']), json.dumps(baseline['extended'])[:400])


def xodb_value(result, kind):
    if kind == 'int':
        v = result['value']
        return int(v['display'])
    if kind == 'float':
        return float(result['value']['display'])
    if kind == 'struct':
        return {f['name']: (float(f['value']['display']) if f['value']['kind'] == 'float' else int(f['value']['display'])) for f in result['fields']}
    if kind == 'offset_buf':
        return int(result['value']['display'], 16) - buf_address
    if kind == 'offset_dst':
        return int(result['value']['display'], 16) - dst_address
    raise AssertionError(kind)


def matches(kind, ours, theirs):
    if kind == 'struct':
        expected = gdb_struct(theirs)
        return set(ours) == set(expected) and all(math.isclose(ours[k], expected[k], rel_tol=0, abs_tol=0) for k in ours)
    expected = gdb_number(theirs)
    return ours == expected


# A planted wrong oracle value must be reported as a mismatch.
check('planted wrong oracle value is rejected', not matches('int', 43, '42') and not matches('struct', {'a': 40, 'b': 1.25}, '{a = 40, b = 1.5}') and not matches('float', 3.75, '3.7500000000000004'))

for (name, expression, request, kind), theirs in zip(CASES, gdb_values):
    if request is None:
        text = bytes.fromhex(ok('read_memory', address=hex(dst_address), length=16)['hex']).split(b'\0')[0].decode()
        check(f'oracle {name}: target memory after memcpy matches gdb', theirs is not None and text == gdb_string(theirs), (text, theirs))
        evidence['calls'].append({'case': name, 'xodb': text, 'gdb': theirs})
        continue
    before = gen()
    prior = dump()
    result = call(**request)
    ours = xodb_value(result, kind) if result['outcome'] == 'returned' else None
    good = result['outcome'] == 'returned' and result['restored'] and result['verified'] and theirs is not None and matches(kind, ours, theirs)
    check(f'oracle {name}: {expression} = {ours} (gdb {theirs})', good, result)
    check(f'{name}: generation advanced and the call is journaled', result['generation'] > before and result['journal_sequence'] > 0, (before, result['generation']))
    low = result['borrowed_stack']['low']
    after = dump()
    diffs = same(prior, after, low, result['borrowed_stack']['high']) + [d for d in same(baseline, after, low, low) if d[0] != 'stack']
    check(f'{name}: registers, vector state and borrowed stack restored bit for bit', not diffs, diffs[:8])
    check(f'{name}: the borrowed range is below the red zone and inside the dump', result['borrowed_stack']['high'] == int(baseline['registers']['rsp'], 0) and low >= int(baseline['stack_low'], 16), result['borrowed_stack'])
    evidence['calls'].append({'case': name, 'gdb_expression': expression, 'gdb': theirs, 'xodb': ours, 'result': result})
    evidence['restores'].append({'case': name, 'differences': diffs, 'compared': result.get('compared'), 'borrowed_stack': result['borrowed_stack'], 'dead_stack_changed_below_borrowed': same(baseline, after) != []})
    if name == 'plt_ifunc_strlen':
        check('strlen resolved through its bound GOT slot, not the IFUNC resolver', result['resolution'] == 'got', result['resolution'])
    if name == 'function_pointer':
        check('function pointer resolved from the frame', result['resolution'] == 'function_pointer', result['resolution'])
    if name == 'virtual':
        check('virtual call dispatched to the dynamic override', 'Circle::area' in (result.get('dispatched_to') or ''), result.get('dispatched_to'))
    if name == 'alignment':
        check('call frame is 16-byte aligned at entry', ours == 0, ours)

# ---------------------------------------------------------------- archive
# A capture running across a call records an `execution` marker, and the
# saved archive keeps it when reopened offline.
def archive_ready(client):
    deadline = time.monotonic() + 30
    while True:
        status = client.inspect('get_archive_status')
        if status['job'] and status['job']['done']:
            assert status['job']['error_name'] is None, status
            return status
        assert time.monotonic() < deadline, status
        time.sleep(.01)


ok('start_profile', generation=gen())
call(callee='add_ints', arguments=['x', '2'])
time.sleep(.1)
ok('stop_profile', generation=gen(), capture_id=c.inspect('get_profile')['capture']['id'])
capture = c.inspect('get_profile')['capture']
timeline = ok('get_profile_timeline', capture_id=capture['id'], revision=capture['revision'])
check('the live capture timeline carries an execution marker', any(m['kind'] == 'execution' for m in timeline['debugger_markers']), [m['kind'] for m in timeline['debugger_markers']])
archive = work / f'execute-{lane}.xoc'
ok('save_capture_archive', generation=gen(), capture_id=capture['id'], revision=capture['revision'], path=str(archive))
archive_ready(c)
offline = Client('observe', None, options=['--open-capture', str(archive)], reply_seconds=30)
try:
    archive_ready(offline)
    reopened = offline.inspect('get_profile')['capture']
    markers = offline.inspect('get_profile_timeline', capture_id=reopened['id'], revision=reopened['revision'])['debugger_markers']
    check('the reopened archive keeps the execution marker', any(m['kind'] == 'execution' for m in markers), [m['kind'] for m in markers])
finally:
    offline.close()

# ---------------------------------------------------------------- refusals
# Stack below the lowest borrowed byte so far is dead stack callee frames used.
refusal_base = dump()
REFUSALS = [
    ('overload ambiguity', {'callee': 'overloaded', 'arguments': ['d']}, 'OverloadAmbiguous'),
    ('template without instantiation', {'callee': 'maxof', 'arguments': ['1', '2']}, 'TemplateInstantiationRequired'),
    ('by-value class with a non-trivial copy', {'callee': 'take_tracked', 'arguments': ['tracked']}, 'NonTrivialCopyArgument'),
    ('member call without this', {'callee': 'Counter::add', 'arguments': ['1']}, 'ThisRequired'),
    ('this for a free function', {'callee': 'add_ints', 'this': '&counter', 'arguments': ['1', '2']}, 'ThisUnexpected'),
    ('varargs without a prototype', {'callee': 'sum_ints', 'arguments': ['1', '2']}, 'VariadicPrototypeRequired'),
    ('fixed prototype for a variadic callee', {'callee': 'sum_ints', 'arguments': ['1', '2'], 'prototype': 'long(int, int)'}, 'PrototypeMismatch'),
    ('string literal needs scratch', {'callee': 'strlen', 'arguments': ['"abc"'], 'prototype': 'size_t(const char *)'}, 'ScratchUnavailable'),
    ('unbound IFUNC', {'callee': 'rawmemchr', 'arguments': ['buf', '0'], 'prototype': 'void *(const void *, int)'}, 'UnresolvedIfunc'),
    ('argument count', {'callee': 'add_ints', 'arguments': ['1']}, 'ArgumentCountMismatch'),
    ('nested call', {'callee': 'add_ints', 'arguments': ['add_ints(1, 2)', '3']}, 'NestedCallUnsupported'),
    ('long double prototype', {'callee': 'add_ints', 'arguments': ['1', '2'], 'prototype': 'long double(long, long)'}, 'PrototypeTypeUnsupported'),
]
for name, request, want in REFUSALS:
    before = gen()
    got = refused('execute_call', tid=tid, frame=1, allow_execution=True, generation=before, **request)
    check(f'refusal {name}: {want}', got == want, got)
    check(f'refusal {name} wrote nothing', same(refusal_base, dump()) == [] and gen() == before, gen())
    evidence['refusals'].append({'case': name, 'request': request, 'error': got})
# A disabled user breakpoint at AT_ENTRY must not stand in for the return
# trap: the callee would return into the real entry code.
entry = ok('set_breakpoint', symbol='_start', generation=gen())['id']
ok('configure_breakpoint', id=entry, enabled=False, generation=gen())
result = call(callee='add_ints', arguments=['x', '2'])
check('a disabled breakpoint at the trap site refuses the call', result['outcome'] == 'refused' and result['reason'] == 'ReturnTrapUnavailable' and not result['call_frame_active'], result)
ok('remove_breakpoint', id=entry, generation=gen())
got = refused('evaluate_expression', tid=tid, frame=1, expression='add_ints(1, 2)')
check('evaluate_expression refuses a call: ExecutionRequired', got == 'ExecutionRequired', got)
got = refused('execute_call', tid=tid, frame=1, callee='add_ints', arguments=['1', '2'], generation=gen())
check('missing allow_execution: ExecutionConsentRequired', got == 'ExecutionConsentRequired', got)
got = refused('execute_call', tid=tid, frame=1, callee='add_ints', arguments=['1', '2'], allow_execution=False, generation=gen())
check('allow_execution=false: ExecutionConsentRequired', got == 'ExecutionConsentRequired', got)
got = refused('execute_call', tid=tid, frame=1, callee='add_ints', arguments=['1', '2'], allow_execution=True, generation=gen() - 1)
check('stale generation: StaleSnapshot', got == 'StaleSnapshot', got)
evidence['refusals'].append({'case': 'evaluate_expression', 'error': 'ExecutionRequired'})

# ---------------------------------------------------------------- recovery


def active_case(name, request, want, extra=None):
    prior = dump()
    result = call(**request)
    check(f'{name}: outcome {want} with an active call frame', result['outcome'] == want and result['call_frame_active'], result)
    if extra:
        extra(result)
    state = ok('get_execution_state')
    check(f'{name}: get_execution_state shows the active frame', state['call_frame_active'] and state['call_frame_active']['tid'] == tid, state['call_frame_active'])
    got = refused('continue', generation=gen())
    check(f'{name}: continue refused while the frame is active', got == 'CallFrameActive', got)
    got = refused('step_instruction', tid=tid, generation=gen())
    check(f'{name}: step refused while the frame is active', got == 'CallFrameActive', got)
    got = refused('execute_call', tid=tid, frame=1, callee='add_ints', arguments=['1', '2'], allow_execution=True, generation=gen())
    check(f'{name}: a second call is refused while the frame is active', got == 'CallFrameActive', got)
    inside = dump()
    resolved = ok('resolve_execution', action='restore', generation=gen())
    check(f'{name}: restore verified', resolved['outcome'] == 'restored' and resolved['verified'] and not resolved['call_frame_active'], resolved)
    diffs = same(prior, dump(), result['borrowed_stack']['low'], result['borrowed_stack']['high'])
    check(f'{name}: restored state equals the pre-call dump', not diffs, diffs[:8])
    evidence['recovery'].append({'case': name, 'result': result, 'resolved': resolved, 'differences_after_restore': diffs, 'inside_differences': same(baseline, inside)[:16]})
    return inside


active_case('timeout', {'callee': 'spin', 'timeout_ms': 300}, 'timeout')
active_case('SIGSEGV inside the call', {'callee': 'crash', 'arguments': ['nullp']}, 'signal',
            lambda r: check('SIGSEGV is typed with its fault address', r['signal'] == 'SIGSEGV' and r.get('fault_address') in (None, 0), r))
active_case('lock held by a stopped thread', {'callee': 'take_lock', 'timeout_ms': 500}, 'timeout',
            lambda r: check('the blocked syscall is futex', r.get('blocked_syscall') == 202, r.get('blocked_syscall')))
bp = ok('set_breakpoint', symbol='breakme', generation=gen())['id']
inside = active_case('breakpoint inside the callee', {'callee': 'clobber', 'arguments': ['1']}, 'breakpoint')
check('the stop inside the call shows the callee clobbered vector state', any(d[0] == 'extended' for d in same(baseline, inside)), same(baseline, inside)[:4])
ok('remove_breakpoint', id=bp, generation=gen())
active_case('escaping C++ exception', {'callee': 'thrower', 'arguments': ['1']}, 'exception')

# A call after the recovery cases still returns the right value.
again = call(callee='add_ints', arguments=['x', '2'])
check('calls work after every recovery', again['outcome'] == 'returned' and again['value']['display'] == '42', again)

journal = ok('get_execution_state')['journal']
check('journal records actor, scope, callee and outcome for each call',
      len(journal) >= len([c for c in CASES if c[2]]) and all(row['actor'] == 'agent' and row['scope'] == 'execute' and row['callee'] for row in journal), journal[-3:])
check('journal never stores argument text', 'hello' not in json.dumps(journal) and all('arguments' not in row for row in journal))
evidence['journal'] = journal

# Abandon: the thread stays inside the callee; continue then stops at the
# visible return trap instead of running the entry point.
bp = ok('set_breakpoint', symbol='breakme', generation=gen())['id']
result = call(callee='breakme', arguments=['1'])
check('abandon setup stops at the callee breakpoint', result['outcome'] == 'breakpoint', result)
abandoned = ok('resolve_execution', action='abandon', generation=gen())
check('abandon clears the active frame', abandoned['outcome'] == 'abandoned' and not abandoned['call_frame_active'], abandoned)
breakpoints = ok('get_breakpoints')['breakpoints']
check('the return trap is now a visible breakpoint', any(int(b['address'], 0) == result['trap_address'] for b in breakpoints if 'address' in b) if breakpoints and isinstance(breakpoints[0].get('address'), str) else any(b.get('address') == result['trap_address'] for b in breakpoints), breakpoints)
ok('remove_breakpoint', id=bp, generation=gen())
c.continue_initial_stop()
stop = c.stopped(seconds=10)
regs = ok('get_registers', tid=tid)['registers']
check('continuing an abandoned call stops at the return trap', int(regs['rip'], 0) == result['trap_address'], (regs['rip'], result['trap_address']))
# A callee that exits the process: the session sees the exit at once and
# closes (the exit stop the call consumed is not left parked).
result = call(callee='exit', arguments=['7'], prototype='void(int)', frame=0)
check('a callee calling exit reports exited', result['outcome'] == 'exited' and not result['call_frame_active'], result)
deadline = time.monotonic() + 10
while (state := c.session())['state'] != 'exited' and time.monotonic() < deadline:
    time.sleep(.01)
check('the session shows the exit status after exit inside a call', state['state'] == 'exited' and (state['exit'] or {}).get('status') == 7, {k: state.get(k) for k in ('state', 'exit')})
c.close()

# ---------------------------------------------------------------- scopes
for scope in ('observe', 'control', 'mutate'):
    other = Client(scope, str(fixture), options=options, reply_seconds=20)
    try:
        listed = {t['name'] for t in other.call('tools/list')['result']['tools']}
        check(f'{scope}: execute tools are not listed', not ({'execute_call', 'resolve_execution'} & listed), listed & {'execute_call', 'resolve_execution'})
        g = other.session()['generation']
        t = other.session()['threads'][0]['tid']
        for name, kw in (('execute_call', {'tid': t, 'callee': 'add_ints', 'arguments': ['1', '2'], 'allow_execution': True, 'generation': g}),
                         ('resolve_execution', {'action': 'restore', 'generation': g})):
            r = other.tool(name, **kw)['result']
            got = r['content'][0]['text'] if r.get('isError') else 'accepted'
            check(f'{scope}: {name} called directly is refused', got == 'AgentScopeDenied', got)
        state = other.inspect('get_execution_state')
        check(f'{scope}: get_execution_state stays readable', state['call_frame_active'] is None and state['executions'] == 0, state)
    finally:
        other.close()

# ---------------------------------------------------------------- attached process
# An attached process gets the same transaction and continues normally after
# detach: its own output proves the restored frame resumed correctly.
target = subprocess.Popen([str(fixture), 'attach'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    time.sleep(.2)
    c = Client('execute', None, options=[*options, '--attach', str(target.pid)], reply_seconds=40)
    ok('set_breakpoint', symbol='checkpoint', generation=gen())
    c.continue_initial_stop()
    state = c.stopped('breakpoint', seconds=20)
    tid = next(t['tid'] for t in state['threads'] if t['reason'] == 'breakpoint')
    prior = dump()
    result = call(callee='add_ints', arguments=['x', '2'])
    check('attached: the call returns and restores', result['outcome'] == 'returned' and result['value']['display'] == '42' and result['verified'], result)
    check('attached: registers, vector state and borrowed stack restored', not same(prior, dump(), result['borrowed_stack']['low'], result['borrowed_stack']['high']))
    result = call(callee='bump', arguments=['7'])
    check('attached: a side effect stays (callee effects are not rolled back)', result['value']['display'] == '7', result['value'])
    c.close()
    out, err = target.communicate(timeout=20)
    check('attached: the detached process finishes normally', target.returncode == 0 and out.startswith('hello, debugger'), (target.returncode, out[:200], err[-400:]))
finally:
    if target.poll() is None:
        target.kill()
        target.wait()

# ---------------------------------------------------------------- shared sessions
# Execution needs the controller lease and an execute ceiling: an observer
# is refused even under execute, and a lease holder is refused under mutate.
import importlib.util
spec = importlib.util.spec_from_file_location('shared_sessions', root / 'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
if args.agent:
    os.environ['XODB_RUNTIME_AGENT'] = str(args.agent.resolve())
for scope in ('execute', 'mutate'):
    server = shared.Server(root, work, args.binary.resolve(), fixture, scope, fixture_args=())
    try:
        observer, owner = shared.Client(server, 'observer'), shared.Client(server, 'owner')
        owner.claim()
        owner.action('set_breakpoint', symbol='checkpoint')
        owner.action('continue')
        state = shared.eventually(owner.session, lambda s: s['state'] == 'stopped' and any(t['reason'] == 'breakpoint' for t in s['threads']) and not s['continue_pending'], 'shared stop', timeout=20)
        t = next(x['tid'] for x in state['threads'] if x['reason'] == 'breakpoint')
        request = dict(tid=t, frame=1, callee='add_ints', arguments=['x', '2'], allow_execution=True)
        reply = observer.raw('execute_call', generation=state['generation'], **request)['result']
        why = reply['content'][0]['text'] if reply.get('isError') else 'accepted'
        check(f'shared {scope}: an observer calling execute_call directly is refused', why in ('ControlLeaseRequired', 'AgentScopeDenied'), why)
        deadline = time.monotonic() + 60
        while True:
            reply = owner.raw('execute_call', generation=owner.session()['generation'], **request)['result']
            if not (reply.get('isError') and reply['content'][0]['text'] in PENDING) or time.monotonic() > deadline:
                break
            time.sleep(.02)
        if scope == 'execute':
            check('shared execute: the lease holder runs the call', not reply.get('isError') and reply['structuredContent']['value']['display'] == '42', reply)
        else:
            why = reply['content'][0]['text'] if reply.get('isError') else 'accepted'
            check('shared mutate: the lease holder is refused without an execute ceiling', why == 'AgentScopeDenied', why)
        server.remember_target(state)
        observer.close()
        owner.close()
        server.stop_and_check()
    finally:
        server.close()

if args.evidence:
    args.evidence.mkdir(parents=True, exist_ok=True)
    (args.evidence / f'execute-call-{lane}.json').write_text(json.dumps(evidence, indent=1, sort_keys=True))
    (args.evidence / f'gdb-oracle-{lane}.txt').write_text(gdb_text)
elapsed = time.monotonic() - started
print(f'execute-call {lane}: {len(failures)} failure(s) in {elapsed:.1f}s')
sys.exit(1 if failures else 0)
