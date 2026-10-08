#!/usr/bin/env python3
"""Owned CPython integration: readable PyObject values and the Python stack
at native stops, read from stopped memory only.
Run: python3 tests/python-language.py --python /path/to/python3 --work out/python-test
The caller supplies an empty work directory; real-run evidence stays there.
--python may be repeated (for example a DWARF build and a stripped final
release); value checks need DWARF types and are skipped, not failed, without.
"""
import argparse
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import struct
import sys
import time

from client import Client

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = Path('tests/fixtures/python/stopped.py')
FRAME_PREVIOUS, FRAME_EXECUTABLE, FRAME_OWNER = 8, 0, 74  # 3.14 and 3.16 GIL layouts


def marker(name):
    for number, text in enumerate(FIXTURE.read_text().splitlines(), 1):
        if text.rstrip().endswith('# @' + name):
            return number
    raise KeyError(name)


class Run:
    """One fixture process and one MCP session attached to it."""
    def __init__(self, python, mode, work, scope='control', symbol='getpid'):
        self.work, self.mode = work, mode
        self.p = subprocess.Popen([python, str(FIXTURE), mode], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.c = None
        assert select.select([self.p.stdout], [], [], 20)[0], 'fixture ready timeout'
        assert self.p.stdout.readline() == b'ready\n', self.p.stderr.read().decode()
        self.c = Client(scope, None, options=['--attach', str(self.p.pid)])
        self.c.action('set_breakpoint', symbol=symbol)
        self.c.action('continue')
        self.p.stdin.write(b'go\n')
        self.p.stdin.flush()
        self.stop()

    def stop(self):
        s = self.c.stopped('breakpoint')
        self.tid = next(t['tid'] for t in s['threads'] if t['reason'] == 'breakpoint')
        return s

    def resume(self):
        self.c.action('continue')
        return self.stop()

    def stack(self, tid=None, **kw):
        return self.c.inspect('get_language_stack', tid=tid or self.tid, language='python', **kw)

    def value(self, expression, frame=0):
        return self.c.inspect('evaluate_expression', tid=self.tid, frame=frame, expression=expression)['value']

    def close(self, tag):
        try:
            if self.c:
                (self.work/(tag+'-transcript.json')).write_text(json.dumps(self.c.transcript, indent=1)+'\n')
                self.c.close()
        finally:
            if self.p.poll() is None:
                self.p.terminate()
            try:
                self.p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait()
            (self.work/(tag+'-stderr.txt')).write_bytes(self.p.stderr.read())


def frames(segment):
    return [(f['name'], Path(f['file']).name if f['file'] else None, f['line']) for f in segment['frames']]


def check_segments(result, native):
    for s in result['segments']:
        if s['anchor']:
            assert native[s['anchor']['frame']]['pc'] == int(s['anchor']['pc'], 16), (s, native)
            entry = int(s['anchor']['entry_frame'], 16)
            frame = native[s['anchor']['frame']]
            assert frame['registers'][7] <= entry < frame['cfa'], (s['anchor'], frame['cfa'])
        assert s['runtime']['language'] == 'python' and s['runtime']['build_id']
        assert s['runtime_instance'] is None or s['runtime_instance']['kind'] == 'address'
    anchored = [s['anchor']['frame'] for s in result['segments'] if s['anchor']]
    assert anchored == sorted(anchored), result
    assert result['memory_reads'] <= 16384 and result['memory_bytes'] <= 2 * 1024 * 1024, result


EXPECTED = {
    'none': ('NoneType', 'None'),
    'true': ('bool', 'True'),
    'small': ('int', 'int 42'),
    'negative': ('int', 'int -7'),
    'big': ('int', 'int -1267650600228229401496703205381'),
    'float': ('float', 'float 3.25'),
    'ascii': ('str', "str 'hello'"),
    'latin1': ('str', "str 'héllo'"),
    'ucs2': ('str', "str 'λ x'"),
    'ucs4': ('str', "str '\U0001f600'"),
    'bytes': ('bytes', "bytes b'raw\\x00bytes'"),
    'list': ('list', 'list (4 items)'),
    'tuple': ('tuple', 'tuple (2 items)'),
    'dict': ('dict', 'dict (1 item)'),
    'empty': ('dict', 'dict (0 items)'),
    'cleared': ('dict', 'dict (0 items)'),
    'plain': ('Plain', '<Plain object>'),
    'type': ('type', "<class 'int'>"),
    'subclass': ('Text', "Text(str) 'sub'"),
}


def check_values(run, work, checks):
    """Walk every CASES store; each stop evaluates `key` and `value`."""
    seen = {}
    for index in range(20):
        if index:
            run.resume()
        key = run.value('key')
        name = re.fullmatch(r"str '([a-z0-9]+)' .*", key['display']).group(1)
        value = run.value('value')
        seen[name] = value
        native = run.c.inspect('get_stack', tid=run.tid)['frames']
        stack = run.stack()
        check_segments(stack, native)
        assert frames(stack['segments'][0])[:2] == [('store', 'stopped.py', marker('store')), ('values', 'stopped.py', marker('values'))], stack
    (work/'values.json').write_text(json.dumps(seen, indent=1, ensure_ascii=False)+'\n')
    for name, (kind, display) in EXPECTED.items():
        python = seen[name]['visualization']['python']
        assert python['type'] == kind and python['display'] == display, (name, seen[name])
        assert seen[name]['diagnostic'] is None, (name, seen[name])
    assert seen['none']['display'] == 'None (immortal)', seen['none']
    assert re.fullmatch(r'int 42 \(immortal\)', seen['small']['display']), seen['small']
    assert re.fullmatch(r'list \(4 items\) \(refcnt \d+\)', seen['list']['display']), seen['list']
    items = seen['list']['visualization']['python']['items']
    assert [i['display'] for i in items] == ['1', "'two'", '3.0', 'None'], items
    assert [(i['key'], i['display']) for i in seen['dict']['visualization']['python']['items']] == [("'answer'", '42')]
    longer = seen['long']['visualization']
    assert longer['truncated'] and longer['count'] == 300 and longer['python']['display'].endswith("'... (300 chars)"), longer
    checks.append('values: None/bool/int/big int/float/str kinds/bytes/list/tuple/dict/object/type/subclass')
    return seen


def corrupt_value(run, checks):
    """Freed and invalid heads via the owned stopped child, then restored."""
    value = run.value('value')
    address = value['bits']
    old = run.c.inspect('read_memory', address=hex(address), length=16)['hex']
    try:
        run.c.action('write_memory', address=hex(address), hex='00' * 8)
        freed = run.value('value')
        assert freed['visualization']['python']['type'] == 'freed' and freed['diagnostic'] == 'FreedObject', freed
        run.c.action('write_memory', address=hex(address), hex='9078563412' + '7f0000')
        invalid = run.value('value')
        assert invalid['diagnostic'] == 'ObjectHeaderInvalid', invalid
        run.c.action('write_memory', address=hex(address), hex=old[:16] + '1000000000000000')
        bad_type = run.value('value')
        assert bad_type['diagnostic'] in ('ObjectTypeInvalid', 'ObjectTypeUnreadable'), bad_type
        assert '(refcnt' not in bad_type['display'] and '(refcnt' not in invalid['display'], (bad_type, invalid)
    finally:
        run.c.action('write_memory', address=hex(address), hex=old)
    assert run.value('value')['diagnostic'] is None
    checks.append('freed / overwritten / invalid-type object heads marked, then restored')


def corrupt_frames(run, checks):
    """Corrupt the stopped thread's frame chain in place and restore it."""
    good = run.stack()
    top = int(good['segments'][0]['frames'][0]['frame_address'], 16)
    middle = int(good['segments'][0]['frames'][1]['frame_address'], 16)
    cases = [
        (top + FRAME_OWNER, '09', lambda s: s['segments'][0]['reason'] == 'FrameOwnerInvalid'),
        (middle + FRAME_EXECUTABLE, '1000000000000000', lambda s: s['segments'][0]['frames'][1]['reason'] in ('ExecutableNotCode', 'MemoryUnreadable')),
        (top + FRAME_PREVIOUS, struct.pack('<Q', top).hex(), lambda s: s['segments'][0]['reason'] == 'FrameCycle'),
        (top + FRAME_PREVIOUS, '1000000000000000', lambda s: s['segments'][0]['reason'] in ('MemoryUnreadable', 'InvalidAddress')),
    ]
    for address, data, ok in cases:
        old = run.c.inspect('read_memory', address=hex(address), length=len(data)//2)['hex']
        try:
            run.c.action('write_memory', address=hex(address), hex=data)
            result = run.stack()
            assert all(s['state'] == 'partial' for s in result['segments'][:1]) and ok(result), result
        finally:
            run.c.action('write_memory', address=hex(address), hex=old)
    after = run.stack()
    assert [frames(s) for s in after['segments']] == [frames(s) for s in good['segments']] and after['segments'][0]['state'] == 'complete'
    checks.append('corrupted owner / executable / cycle / unreadable previous are partial with reasons, then restored')


LOOP = '_PyEval_EvalFrameDefault'


def loop_frames(native):
    return [f['index'] for f in native if f['symbol'] and (f['symbol'] == LOOP or f['symbol'].startswith(LOOP + '.'))]


def skipped_entry(python, work, checks, skips):
    """A non-innermost interpreter loop whose entry frame is missing from the
    chain must leave the affected segments partial, for every `frame`."""
    run = Run(python, 'sorted3', work, scope='mutate')
    try:
        native = run.c.inspect('get_stack', tid=run.tid)['frames']
        loops = loop_frames(native)
        if len(loops) < 3:
            skips.append('V1 loop-frame rule: needs symbolized interpreter-loop frames (stripped build cannot detect a skipped entry)')
            return
        good = run.stack()
        (work/'sorted3.json').write_text(json.dumps(good, indent=1)+'\n')
        segments = good['segments']
        assert [s['anchor']['frame'] for s in segments] == loops and all(s['state'] == 'complete' for s in segments), good
        middle, outer = segments[1], segments[2]
        middle_frames = {f['frame_address'] for f in middle['frames']}

        def corrupt(address, data, label):
            old = run.c.inspect('read_memory', address=hex(address), length=8)['hex']
            run.c.action('write_memory', address=hex(address), hex=data)
            try:
                for n in sorted({0, 1, loops[1] - 1, loops[1], loops[1] + 1}):
                    result = run.stack(frame=n)
                    for s in result['segments']:
                        assert not (s['state'] == 'complete' and any(f['frame_address'] in middle_frames for f in s['frames'])), (label, n, result)
                    assert any(s['reason'] == 'InterpreterLoopWithoutEntryFrame' and s['state'] == 'partial' for s in result['segments']), (label, n, result)
                    (work/f'sorted3-{label}-frame{n}.json').write_text(json.dumps(result, indent=1)+'\n')
            finally:
                run.c.action('write_memory', address=hex(address), hex=old)
        last = int(middle['frames'][-1]['frame_address'], 16)
        corrupt(last + FRAME_PREVIOUS, struct.pack('<Q', int(outer['frames'][0]['frame_address'], 16)).hex(), 'skip-middle-entry')
        corrupt(int(segments[0]['anchor']['entry_frame'], 16) + FRAME_PREVIOUS, '00' * 8, 'entry-previous-null')
        runtime = int(run.c.inspect('find_symbol', name='_PyRuntime')['address'], 16)
        current = int.from_bytes(bytes.fromhex(run.c.inspect('read_memory', address=hex(runtime + 208), length=8)['hex']), 'little')  # thread_state.current_frame
        thread_state = int(segments[0]['runtime_instance']['thread_state'], 16)
        corrupt(thread_state + current, '00' * 8, 'current-frame-null')
        after = run.stack()
        assert after['segments'] == good['segments'], after
        checks.append('V1: skipped middle entry, entry.previous=NULL and current_frame=NULL leave reasoned partial segments for frame 0/1/N-1/N/N+1; restored complete')
    finally:
        run.close('sorted3')


def frame_budget(python, work, checks):
    """A deep inner activation must not starve the outer segment (N1)."""
    run = Run(python, 'deepinner', work)
    try:
        full = run.stack()
        outer = full['segments'][-1]
        assert outer['anchor'] and [f['name'] for f in outer['frames']] == ['deep_inner', '<module>'], full
        assert full['segments'][0]['reason'] == 'FrameLimit' and len(full['segments'][0]['frames']) == 128, full['segments'][0]['reason']
        selected = run.stack(frame=outer['anchor']['frame'])
        assert len(selected['segments']) == 1 and [f['name'] for f in selected['segments'][0]['frames']] == ['deep_inner', '<module>'], selected
        assert selected['segments'][0]['state'] == 'complete', selected
        (work/'deepinner.json').write_text(json.dumps({'full': full, 'selected': selected}, indent=1)+'\n')
        checks.append('N1: 200-deep inner activation keeps 128 frames; the outer segment keeps its own frames for frame=0 and frame=<outer>')
    finally:
        run.close('deepinner')


def identity_refusals(run, checks, with_values):
    """Alter and restore only this owned fixture's private stopped mappings."""
    regions = run.c.inspect('list_modules')['regions']
    symbol = run.c.inspect('find_symbol', name='_PyRuntime')
    runtime = int(symbol['address'], 16)

    def refused(address, reason):
        old = run.c.inspect('read_memory', address=hex(address), length=1)['hex']
        try:
            run.c.action('write_memory', address=hex(address), hex=f'{int(old, 16) ^ 1:02x}')
            result = run.c.tool('get_language_stack', tid=run.tid, language='python')
            assert result['result']['isError'] and result['result']['content'][0]['text'] == reason, result
            if with_values:
                value = run.value('value')
                assert value['visualization'] is None and value['diagnostic'] == reason, value
        finally:
            run.c.action('write_memory', address=hex(address), hex=old)
        assert run.stack()['segments']
    refused(runtime + 8, 'PythonDebugOffsetsMismatch')     # published version
    refused(runtime + 300, 'PythonDebugOffsetsMismatch')   # a published offset
    module = next(r for r in regions if r['start'] <= runtime < r['end'])
    path = Path(module['path'])
    data = path.read_bytes()
    shoff = struct.unpack_from('<Q', data, 40)[0]
    size, count, names = struct.unpack_from('<HHH', data, 58)
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * size) for i in range(count)]
    strings = data[sections[names][4]:sections[names][4] + sections[names][5]]
    note = next(s for s in sections if strings[s[0]:].split(b'\0', 1)[0] == b'.note.gnu.build-id')
    phoff = struct.unpack_from('<Q', data, 32)[0]
    psize, pcount = struct.unpack_from('<HH', data, 54)
    headers = [struct.unpack_from('<IIQQQQQQ', data, phoff + i * psize) for i in range(pcount)]
    load = next(p for p in headers if p[0] == 1 and p[2] == 0)
    base = next(r for r in regions if r['path'] == module['path'] and r['offset'] == 0)
    bias = base['start'] - load[3]
    refused(bias + note[3] + 16, 'PythonBuildIdMismatch')
    checks.append('live debug-offsets and build-id mismatch refusals, then restored')


def strace_audit(run, work, checks, expressions):
    """Observer reads use reads only: no writes, resumes or register sets."""
    if not shutil.which('strace'):
        return 'strace unavailable'
    log = work/'strace.txt'
    pid = run.p.pid

    def sched():
        return [Path(f'/proc/{pid}/task/{t}/schedstat').read_text().split()[0] for t in sorted(os.listdir(f'/proc/{pid}/task'))]
    regs0, gen0, s0 = run.c.inspect('get_registers', tid=run.tid), run.c.session()['generation'], sched()
    st = subprocess.Popen(['strace', '-f', '-qq', '-o', str(log), '-e', 'trace=ptrace,process_vm_readv,process_vm_writev,pwrite64,pwritev,pwritev2,pread64,kill,tgkill,tkill', '-p', str(run.c.p.pid)], stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 10
        while not log.exists() or not log.stat().st_size and time.monotonic() < deadline:
            run.c.inspect('get_session')
            time.sleep(0.2)
            if log.exists():
                break
        time.sleep(1)
        for _ in range(3):
            run.stack()
        for expression in expressions:
            run.value(expression)
        time.sleep(0.5)
    finally:
        st.send_signal(signal.SIGINT)
        st.wait(timeout=10)
    regs1, gen1, s1 = run.c.inspect('get_registers', tid=run.tid), run.c.session()['generation'], sched()
    calls = {}
    for line in log.read_text().splitlines():
        parts = line.split(None, 1)
        if len(parts) < 2 or '(' not in parts[1]:
            continue
        name = parts[1].split('(', 1)[0]
        if name == 'ptrace':
            name += ':' + parts[1].split('(', 1)[1].split(',', 1)[0]
        calls[name] = calls.get(name, 0) + 1
    audit = {'syscalls': calls, 'registers_unchanged': regs0 == regs1, 'generation_unchanged': gen0 == gen1, 'schedstat_unchanged': s0 == s1}
    (work/'strace-audit.json').write_text(json.dumps(audit, indent=1)+'\n')
    forbidden = [k for k in calls if k in ('process_vm_writev', 'pwrite64', 'pwritev', 'pwritev2', 'kill', 'tgkill', 'tkill') or
                 k.startswith('ptrace:PTRACE_POKE') or k.startswith('ptrace:PTRACE_SET') or k in ('ptrace:PTRACE_CONT', 'ptrace:PTRACE_SINGLESTEP', 'ptrace:PTRACE_SYSCALL')]
    assert not forbidden and audit['registers_unchanged'] and audit['generation_unchanged'] and audit['schedstat_unchanged'], audit
    assert any(k in calls for k in ('process_vm_readv', 'pread64', 'ptrace:PTRACE_PEEKDATA')), audit
    checks.append('strace: stack%s reads issue reads only; target registers, generation and schedstat unchanged' % (' and value' if expressions else ''))
    return None


def run_python(python, work, checks, skips):
    tag = re.sub(r'[^A-Za-z0-9]+', '-', python).strip('-')
    start = len(checks)
    try:
        run_modes(python, tag, work, checks, skips)
    finally:
        for i in range(start, len(checks)):
            if not checks[i].startswith(tag):
                checks[i] = tag + ': ' + checks[i]


def run_modes(python, tag, work, checks, skips):
    info = json.loads(subprocess.check_output([python, '-c', 'import json,sys,sysconfig;print(json.dumps({"version":sys.version,"hexversion":sys.hexversion,"gil_disabled":sysconfig.get_config_var("Py_GIL_DISABLED")}))']))
    (work/(tag+'-config.json')).write_text(json.dumps(info, indent=1)+'\n')
    has_dwarf = b'.debug_info' in subprocess.run(['readelf', '-S', '-W', os.path.realpath(python)], capture_output=True).stdout or \
        any(b'.debug_info' in subprocess.run(['readelf', '-S', '-W', lib], capture_output=True).stdout for lib in re.findall(r'=> (\S*libpython\S*)', subprocess.run(['ldd', python], capture_output=True, text=True).stdout))
    # The breakpoint symbol must fire on every store in this build.
    run = Run(python, 'nested', work)
    try:
        tools = run.c.call('tools/list')['result']['tools']
        definition = next(t for t in tools if t['name'] == 'get_language_stack')
        assert definition['annotations']['readOnlyHint'] and definition['annotations']['xodbSessionAccess'] == 'observer'
        assert 'python' in definition['inputSchema']['properties']['language']['enum']
        native = run.c.inspect('get_stack', tid=run.tid)['frames']
        result = run.stack()
        (work/(tag+'-nested.json')).write_text(json.dumps(result, indent=1)+'\n')
        check_segments(result, native)
        assert len(result['segments']) == 1 and result['segments'][0]['state'] == 'complete', result
        assert frames(result['segments'][0]) == [('store', 'stopped.py', marker('hit')), ('c', 'stopped.py', marker('c')),
                                                 ('b', 'stopped.py', marker('b')), ('a', 'stopped.py', marker('a')),
                                                 ('<module>', 'stopped.py', marker('module'))], result
        assert [f['code_kind'] for f in result['segments'][0]['frames']] == ['function'] * 4 + ['module']
        stale = run.c.tool('get_language_stack', tid=run.tid, language='python', generation=0)
        assert stale['result']['isError'], stale
        bad = run.c.tool('get_language_stack', tid=run.tid, language='ruby')
        assert 'error' in bad or bad['result']['isError'], bad
        registers = run.c.inspect('get_registers', tid=run.tid)
        generation = run.c.session()['generation']
        assert run.c.inspect('get_registers', tid=run.tid) == registers and run.c.session()['generation'] == generation
        checks.append(tag+': nested frames name/file/line exact, one complete anchored segment, stale/invalid refused')
    finally:
        run.close(tag+'-nested')
    # Values need DWARF types for `PyObject *` arguments.
    if has_dwarf:
        run = Run(python, 'values', work, scope='mutate', symbol='_PyDict_SetItem_Take2')
        try:
            check_values(run, work, checks)
            corrupt_value(run, checks)
            corrupt_frames(run, checks)
            identity_refusals(run, checks, True)
            why = strace_audit(run, work, checks, ('mp', 'key', 'value'))
            if why:
                skips.append(tag+': strace audit: '+why)
        finally:
            run.close(tag+'-values')
    else:
        skips.append(tag+': value previews need DWARF types (stripped image)')
        run = Run(python, 'nested', work, scope='mutate')
        try:
            corrupt_frames(run, checks)
            identity_refusals(run, checks, False)
            why = strace_audit(run, work, checks, ())
            if why:
                skips.append(tag+': strace audit: '+why)
        finally:
            run.close(tag+'-corrupt')
    skipped_entry(python, work, checks, skips)
    frame_budget(python, work, checks)
    # Generators: the first next() is a generic FOR_ITER (a nested native
    # activation); once specialized, FOR_ITER_GEN runs the generator inline.
    run = Run(python, 'generator', work)
    try:
        expected = [('store', marker('hit'), 'function', 'thread'), ('gen', marker('gen'), 'generator', 'generator'),
                    ('consume', marker('consume'), 'function', 'thread'), ('<module>', None, 'module', 'thread')]
        shapes = []
        for attempt in range(300):
            if attempt:
                run.resume()
            result = run.stack()
            check_segments(result, run.c.inspect('get_stack', tid=run.tid)['frames'])
            assert all(s['state'] == 'complete' and s['anchor'] for s in result['segments']), result
            got = [(f['name'], f['line'], f['code_kind'], f['owner']) for s in result['segments'] for f in s['frames']]
            assert [g if e[1] else g[:1] + (None,) + g[2:] for g, e in zip(got, expected)] == expected and len(got) == 4, got
            shapes.append([len(s['frames']) for s in result['segments']])
            if attempt == 0:
                (work/(tag+'-generator-first.json')).write_text(json.dumps(result, indent=1)+'\n')
            if len(result['segments']) == 1:
                (work/(tag+'-generator-inline.json')).write_text(json.dumps(result, indent=1)+'\n')
                break
        assert shapes[0] == [2, 2], shapes[0]
        checks.append(tag+': first generator resume is its own anchored activation (segments 2+2)')
        if shapes[-1] == [4]:
            checks.append(f'{tag}: after {len(shapes) - 1} resumes FOR_ITER_GEN runs the generator inline (one segment of 4)')
        else:
            skips.append(tag+': FOR_ITER_GEN specialization not observed within 300 stops')
    finally:
        run.close(tag+'-generator')
    # Coroutine.send() starts a second native activation: two proven segments.
    run = Run(python, 'coroutine', work)
    try:
        native = run.c.inspect('get_stack', tid=run.tid)['frames']
        result = run.stack()
        (work/(tag+'-coroutine.json')).write_text(json.dumps(result, indent=1)+'\n')
        check_segments(result, native)
        segments = result['segments']
        assert len(segments) == 2 and all(s['state'] == 'complete' and s['anchor'] for s in segments), result
        assert [(f['name'], f['code_kind']) for f in segments[0]['frames']] == [('store', 'function'), ('coro', 'coroutine')], segments[0]
        assert [f['name'] for f in segments[1]['frames']][:1] == ['drive'] and segments[1]['frames'][0]['line'] == marker('drive')
        assert segments[0]['runtime_instance'] == segments[1]['runtime_instance']
        inner = run.stack(frame=segments[1]['anchor']['frame'])
        assert len(inner['segments']) == 1 and frames(inner['segments'][0]) == frames(segments[1]), inner
        checks.append(tag+': coroutine.send() splits into two anchored segments of one interpreter; frame selection keeps the outer one')
    finally:
        run.close(tag+'-coroutine')
    for mode, depth in (('deep300', 300), ('deep5000', 5000)):
        run = Run(python, mode, work)
        try:
            result = run.stack()
            (work/(tag+'-'+mode+'.json')).write_text(json.dumps(result, indent=1)+'\n')
            assert len(result['segments']) == 1, result
            s = result['segments'][0]
            assert s['state'] == 'partial' and len(s['frames']) == 128, s['reason']
            if depth < 4096:
                assert s['reason'] == 'FrameLimit' and s['anchor'] and s['examined_frames'] == depth + 4, (s['reason'], s['examined_frames'])
            else:
                assert s['reason'] == 'FrameExaminedLimit' and s['examined_frames'] == 4096 and s['anchor'] is None, s['reason']
            assert result['memory_reads'] < 4096 + 600, result['memory_reads']
            assert [f['line'] for f in s['frames'][:3]] == [marker('hit'), marker('deepstore'), marker('deep')]
            checks.append(f'{tag}: recursion {depth} bounded ({s["reason"]}, {result["memory_reads"]} reads)')
        finally:
            run.close(tag+'-'+mode)
    # Threads: a second thread's stack is read from its own thread state.
    run = Run(python, 'threads', work)
    try:
        session = run.c.session()
        others = [t['tid'] for t in session['threads'] if t['tid'] != run.tid]
        assert run.tid != run.p.pid and run.p.pid in others, session
        worker = run.stack()
        check_segments(worker, run.c.inspect('get_stack', tid=run.tid)['frames'])
        assert all(s['state'] == 'complete' and s['anchor'] for s in worker['segments']), worker
        assert [f['name'] for s in worker['segments'] for f in s['frames']] == ['store', 'worker', 'Thread.run', 'Thread._bootstrap_inner', 'Thread._bootstrap'], worker
        main = run.stack(tid=run.p.pid)
        (work/(tag+'-threads.json')).write_text(json.dumps({'worker': worker, 'main': main}, indent=1)+'\n')
        check_segments(main, run.c.inspect('get_stack', tid=run.p.pid)['frames'])
        assert main['segments'][0]['state'] == 'complete' and [f['name'] for f in main['segments'][-1]['frames']][-1] == '<module>', main
        assert worker['segments'][0]['runtime_instance']['thread_state'] != main['segments'][0]['runtime_instance']['thread_state']
        checks.append(tag+': two threads, separate thread states, each anchored on its own native stack')
    finally:
        run.close(tag+'-threads')
    # A subinterpreter on the same native thread: separate instances, ordered.
    run = Run(python, 'subinterp', work)
    try:
        # Other dict stores may stop first (the subinterpreter's own setup).
        for attempt in range(500):
            if attempt:
                run.resume()
            result = run.stack()
            names = [f['name'] for s in result['segments'] for f in s['frames']]
            if names[:2] == ['store', 'run']:
                break
        native = run.c.inspect('get_stack', tid=run.tid)['frames']
        (work/(tag+'-subinterp.json')).write_text(json.dumps(result, indent=1)+'\n')
        check_segments(result, native)
        segments = result['segments']
        assert len(segments) == 2 and all(s['state'] == 'complete' for s in segments), result
        sub, main = segments
        assert sub['runtime_instance']['interpreter_id'] != 0 and main['runtime_instance']['interpreter_id'] == 0, result
        assert sub['runtime_instance']['address'] != main['runtime_instance']['address']
        assert [f['name'] for f in sub['frames']] == ['store', 'run', '<module>'], sub
        assert [f['name'] for f in main['frames']] == ['Interpreter.exec', 'subinterp', '<module>'] and main['frames'][1]['line'] == marker('subexec'), main
        checks.append(tag+': subinterpreter and main interpreter on one thread: two instances, anchored in native order')
    finally:
        run.close(tag+'-subinterp')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--python', required=True, action='append')
    parser.add_argument('--work', required=True, type=Path)
    args = parser.parse_args()
    os.chdir(ROOT)
    work = args.work.resolve()
    work.mkdir(mode=0o755, parents=True, exist_ok=True)
    assert not list(work.iterdir()), 'work directory must be empty'
    checks, skips = [], []
    # The reader's position tables against each version's installed headers.
    reader = work/'python-reader'
    subprocess.run(['cc', '-std=c11', '-O1', '-UNDEBUG', '-Wall', '-Wextra', '-Werror', 'src/language/python.c', 'src/language/python_layout.c',
                    'tests/python-reader.c', '-ldw', '-lm', '-o', str(reader)], check=True, timeout=120)
    tables = subprocess.check_output([str(reader), '--positions'], text=True)
    for python in args.python:
        includes = subprocess.run([python + '-config', '--includes'], capture_output=True, text=True)
        if tables and includes.returncode == 0:
            dirs = [d[2:] for d in includes.stdout.split() if d.startswith('-I')]
            probe = work/'positions-probe'
            names = re.findall(r' ([a-z_]+\.[a-z_]+)=', tables.splitlines()[0])
            source = '#define Py_BUILD_CORE 1\n#include <Python.h>\n#include <stddef.h>\n#include "internal/pycore_debug_offsets.h"\n#include "internal/pycore_dict.h"\n#include <stdio.h>\nint main(void){printf("%x", PY_VERSION_HEX >> 16);\n'
            source += ''.join(f'printf(" {n}=%zu", offsetof(_Py_DebugOffsets, {n}));\n' for n in names)
            source += 'printf("\\nunpublished PyCompactUnicodeObject=%zu PyCodeObject.co_flags=%zu PyDictObject.ma_used=%zu PyDictKeysObject.dk_log2_size=%zu PyDictKeysObject.dk_log2_index_bytes=%zu PyDictKeysObject.dk_kind=%zu PyDictKeysObject.dk_nentries=%zu PyDictKeysObject.dk_indices=%zu PyDictValues.values=%zu PyCellObject.ob_ref=%zu\\n", sizeof(PyCompactUnicodeObject), offsetof(PyCodeObject, co_flags), offsetof(PyDictObject, ma_used), offsetof(PyDictKeysObject, dk_log2_size), offsetof(PyDictKeysObject, dk_log2_index_bytes), offsetof(PyDictKeysObject, dk_kind), offsetof(PyDictKeysObject, dk_nentries), offsetof(PyDictKeysObject, dk_indices), offsetof(PyDictValues, values), offsetof(PyCellObject, ob_ref));}\n'
            (work/'positions-probe.c').write_text(source)
            subprocess.run(['cc', *[f'-I{d}' for d in dirs], *[f'-I{d}/internal' for d in dirs], str(work/'positions-probe.c'), '-o', str(probe)], check=True, timeout=60)
            got = subprocess.check_output([str(probe)], text=True).splitlines()
            row = next(line for line in tables.splitlines() if line.split()[0] == got[0].split()[0])
            assert row == got[0], (row, got[0])
            assert tables.splitlines()[-1] == got[1], (tables.splitlines()[-1], got[1])
            checks.append(f'{python}: reader position tables equal the installed headers ({got[0].split()[0]})')
        else:
            skips.append(f'{python}: no installed internal headers for a table cross-check')
        run_python(python, work, checks, skips)
    (work/'results.json').write_text(json.dumps({'pass': checks, 'fail': [], 'skip': skips}, indent=2)+'\n')
    print(f'{len(checks)} CPython integration checks passed, {len(skips)} skipped')


if __name__ == '__main__':
    main()
