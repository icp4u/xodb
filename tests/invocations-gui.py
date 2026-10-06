#!/usr/bin/env python3
"""Invocation/cohort browser on a private headless compositor.

Writes owned synthetic .xoi fixtures (no target, helper or uprobes), opens them
with --browse-observation and drives keys and clicks through a private Sway.
`--fixture PATH [--large]` only writes a fixture, e.g. for the documented demo.
XODB_BIN selects the application; XODB_TEST_TMPDIR shortens the work path.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace

MAGIC = b'XODBINVOC\x01\r\n'
UNREAD = {'record_limit', 'thread_limit', 'memory_limit', 'decode_error', 'identity', 'scope_changed', 'unread'}


class Store:
    """The pairing rules of src/observe/calls.zig, for expected citations."""
    def __init__(self):
        self.records, self.calls, self.lanes = [], [], {}
        self.first_gap, self.lost, self.finish_reason, self.unread = None, 0, None, False

    def gap(self, reason, ordinal):
        if self.first_gap is None:
            self.first_gap = {'reason': reason, 'record': ordinal}

    def boundary(self, lane, reason):
        for call in lane['stack']:
            self.calls[call]['reason'] = reason
        lane['stack'] = []

    def quarantine(self, lane, reason, ordinal):
        self.gap(reason, ordinal)
        self.boundary(lane, reason)
        lane['poison'] = lane['poison'] or reason

    def unpaired(self, event, ordinal, reason):
        sample = event['data']['sample']
        enter = sample['phase'] == 'enter'
        self.calls.append(dict(id=len(self.calls), thread_id=event['thread_id'], tid=event['tid'], function_id=sample['function_id'],
                               entry_record=ordinal if enter else None, return_record=None if enter else ordinal, parent_call=None, reason=reason))

    def feed(self, event):
        lane = self.lanes.setdefault(event['thread_id'], dict(stack=[], last=0, poison=None))
        ordinal = len(self.records)
        self.records.append({'ordinal': ordinal, 'event': event})
        kind, = event['data']
        if kind == 'lost':
            self.lost += event['data']['lost']
        assert event['time_ns'] >= lane['last'], 'fixture keeps per-thread time order'
        lane['last'] = event['time_ns']
        if kind == 'lost':
            return self.quarantine(lane, 'loss', ordinal)
        if kind in ('throttle', 'unthrottle'):
            return self.quarantine(lane, 'throttle', ordinal)
        assert kind == 'sample', kind
        sample = event['data']['sample']
        if lane['poison']:
            return self.unpaired(event, ordinal, lane['poison'])
        if sample['phase'] == 'enter':
            parent = lane['stack'][-1] if lane['stack'] else None
            if parent is not None and sample['stack_key'] >= self.records[self.calls[parent]['entry_record']]['event']['data']['sample']['stack_key']:
                self.quarantine(lane, 'stack_changed', ordinal)
                return self.unpaired(event, ordinal, 'stack_changed')
            self.calls.append(dict(id=len(self.calls), thread_id=event['thread_id'], tid=event['tid'], function_id=sample['function_id'],
                                   entry_record=ordinal, return_record=None, parent_call=parent, reason='pending'))
            lane['stack'].append(len(self.calls) - 1)
            return
        if not lane['stack']:
            self.quarantine(lane, 'missing_entry', ordinal)
            return self.unpaired(event, ordinal, 'missing_entry')
        call = self.calls[lane['stack'][-1]]
        entry = self.records[call['entry_record']]['event']['data']['sample']
        mismatch = 'function_mismatch' if entry['function_id'] != sample['function_id'] else 'stack_mismatch' if entry['stack_key'] != sample['stack_key'] else None
        if mismatch:
            self.quarantine(lane, mismatch, ordinal)
            return self.unpaired(event, ordinal, mismatch)
        call['return_record'], call['reason'] = ordinal, 'complete'
        lane['stack'].pop()

    def finish(self, reason):
        for lane in self.lanes.values():
            if lane['stack']:
                self.gap(reason, None)
            self.boundary(lane, reason)
        self.finish_reason = reason
        if reason in UNREAD:
            self.unread = True
            self.gap(reason, None)

    def duration(self, call):
        if call['reason'] != 'complete':
            return None
        return self.records[call['return_record']]['event']['time_ns'] - self.records[call['entry_record']]['event']['time_ns']


def sample(thread, tid, time_ns, phase, function, key, args=(), result=None, pcs=()):
    words = list(args) + [0] * (6 - len(args))
    return dict(thread_id=thread, tid=tid, time_ns=time_ns, data={'sample': dict(
        phase=phase, function_id=function, stack_key=key, ip=0x401000 + function * 0x100 + (0 if phase == 'enter' else 0x40),
        args=words, arg_count=len(args), result=result,
        stack=dict(pcs=list(pcs) + [0] * (32 - len(pcs)), len=len(pcs), truncated=False),
        raw_registers=None, stack_word=[0] * 8, stack_word_size=0, stack_word_valid=0)})


def demo_events(start):
    """Fast/slow calls, a nested call, a missing return, a missing entry and loss.
    Each uncertainty is on its own thread: quarantine keeps a lane's first reason."""
    events = []
    t = start + 1000
    key = 0x7ffd00001000
    for i in range(24):
        slow = i % 2 == 1
        events.append(sample(1, 4101, t, 'enter', 1, key, (0x4000 if slow else 0x10, 0x7f0000001000 + i * 0x40), None, (0x401234, 0x401890, 0x7f1100002345)))
        if i == 5:
            events.append(sample(1, 4101, t + 100_000, 'enter', 2, key - 0x80, (0x2a,), None, (0x401300, 0x401234)))
            events.append(sample(1, 4101, t + 1_100_000, 'leave', 2, key - 0x80, (), 0))
        t += 6_000_000 if slow else 300_000
        events.append(sample(1, 4101, t, 'leave', 1, key, (), 1 if slow else 0))
        t += 50_000
    t = start + 2000
    key = 0x7ffd00002000
    for i in range(6):
        events.append(sample(2, 4102, t, 'enter', 2, key, (0x30 + i,), None, (0x401300,)))
        t += 2_000_000
        events.append(sample(2, 4102, t, 'leave', 2, key, (), 0))
        t += 100_000
    events.append(sample(2, 4102, t, 'enter', 2, key, (0x99,), None, (0x401300,)))
    t = start + 3000
    key = 0x7ffd00003000
    events.append(sample(3, 4103, t, 'leave', 1, key, (), 5))
    t = start + 400_000
    key = 0x7ffd00004000
    for i in range(2):
        events.append(sample(4, 4104, t, 'enter', 1, key, (0x10,), None))
        t += 250_000
        events.append(sample(4, 4104, t, 'leave', 1, key, (), 0))
        t += 50_000
    events.append(dict(thread_id=4, tid=4104, time_ns=t, data={'lost': 3}))
    t += 10_000
    events.append(sample(4, 4104, t, 'enter', 1, key, (0x4000,), None))
    t += 7_000_000
    events.append(sample(4, 4104, t, 'leave', 1, key, (), 1))
    return events


def large_events(start, count):
    events, t, key = [], start + 1000, 0x7ffd00001000
    for i in range(count):
        events.append(sample(1, 4101, t, 'enter', 1, key, (i % 7,)))
        t += 9_000 if i % 3 else 30_000
        events.append(sample(1, 4101, t, 'leave', 1, key, (), i % 2))
        t += 1_000
    return events


def write_fixture(path, large=0):
    start = 1_000_000_000
    events = large_events(start, large) if large else demo_events(start)
    events.sort(key=lambda e: e['time_ns'])  # stable: per-thread order is preserved
    store = Store()
    for event in events:
        store.feed(event)
    store.finish('capture_end')
    threads = [dict(id=1, tid=4101)] if large else [dict(id=n, tid=4100 + n) for n in (1, 2, 3, 4)]
    def function(fid, name, offset):
        return dict(id=fid, name=name, path='/opt/xodb-demo/bin/demo-server', file_offset=offset, link_address=0x401000 + offset,
                    runtime_address=0x401000 + offset, identity=dict(device=1, inode=2, size=65536, mtime_sec=1, mtime_ns=0, ctime_sec=1, ctime_ns=0))
    metadata = dict(identity=dict(session_id=11, capture_id=1, process_id=1, pid=4100, image_epoch=1, generation=3), producer=None,
                    started_ns=start, ended_ns=events[-1]['time_ns'] + 1000, threads=threads,
                    functions=[function(1, 'parse_request', 0x100), function(2, 'render_page', 0x200)],
                    config=dict(duration_ms=10000, callstacks=True, record_limit=max(32768, len(events)), memory_limit=256 * 1024 * 1024),
                    stop_reason='duration', finish_reason='capture_end', abi='sysv_x86_64_raw_registers', recipe_json=None, comparison_selection=None)
    wire = dict(version=1, pairing_algorithm='xodb-invocation-pairing-v1', evidence=dict(
        metadata=metadata, records=store.records, calls=store.calls, first_gap=store.first_gap, unread_possible=store.unread, rejected=0))
    body = json.dumps(wire, separators=(',', ':')).encode()
    Path(path).write_bytes(MAGIC + hashlib.sha256(body).digest() + body)
    return store


def expected(store, threshold):
    complete = [c for c in store.calls if c['reason'] == 'complete']
    fast = sum(1 for c in complete if store.duration(c) < threshold)
    return dict(total=len(store.calls), complete=len(complete), incomplete=len(store.calls) - len(complete), fast=fast, slow=len(complete) - fast)


class Gui:
    """One xodb inside the private compositor, with traced view state on stderr."""
    def __init__(self, ctx, name, args):
        self.ctx, self.name = ctx, name
        self.log = ctx.work / f'{name}.log'
        with self.log.open('wb') as stream:
            self.proc = subprocess.Popen([str(ctx.binary), *args], cwd=ctx.work, env=dict(ctx.env, XODB_INPUT_TRACE='1'), stdin=subprocess.DEVNULL,
                                         stdout=subprocess.DEVNULL, stderr=stream)
        ctx.processes.append(self.proc)
        self.seen = 0

    def lines(self):
        return [line for line in self.log.read_text(errors='replace').splitlines() if line.startswith('observation-view ')]

    def wait(self, pattern, timeout=10):
        """Next view trace line at or after the cursor that matches pattern."""
        deadline = time.monotonic() + timeout
        while True:
            lines = self.lines()
            for index in range(self.seen, len(lines)):
                match = re.search(pattern, lines[index])
                if match:
                    self.seen = index + 1
                    return match
            assert self.proc.poll() is None, (self.name, self.log.read_text(errors='replace')[-2000:])
            assert time.monotonic() < deadline, (self.name, pattern, lines[self.seen:])
            time.sleep(.02)

    def state(self, line):
        return dict(re.findall(r'(\w+)=(\S+)', line.string if hasattr(line, 'string') else line))

    def quit(self):
        self.ctx.inject('tap', '16')
        assert self.proc.wait(timeout=10) == 0, self.log.read_text(errors='replace')[-2000:]


def comparison(gui, ident):
    match = gui.wait(rf'comparison id={ident} ')
    return {k: int(v) for k, v in gui.state(match).items()}


def main():
    os.umask(0o022)
    root = Path(__file__).resolve().parents[1]
    if len(sys.argv) >= 3 and sys.argv[1] == '--fixture':
        store = write_fixture(sys.argv[2], 15000 if '--large' in sys.argv[3:] else 0)
        print(json.dumps(dict(path=sys.argv[2], records=len(store.records), calls=len(store.calls), at_4ms=expected(store, 4_000_000))))
        return
    spec = importlib.util.spec_from_file_location('shared_clients', root / 'tests/shared-sessions.py')
    shared = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shared)
    # vinput requires a /.work/input- path; Sway's socket must fit sun_path.
    if os.environ.get('XODB_TEST_TMPDIR'):
        work = Path(tempfile.mkdtemp(prefix='xiv-', dir=os.environ['XODB_TEST_TMPDIR'])).resolve() / '.work/input-invocations'
        runtime = work / 'rt'
    else:
        work = root / '.work' / ('input-invocations-' + str(time.time_ns())[-10:])
        runtime = work / 'rt'
    assert len(os.fsencode(runtime)) <= 72, 'Use a shorter checkout or XODB_TEST_TMPDIR for Sway sockets'
    work.mkdir(mode=0o755, parents=True)
    work.chmod(0o755)
    runtime.mkdir(mode=0o700)
    for name in ('tmp', 'cache', 'shots'):
        (work / name).mkdir(mode=0o755)
    config = work / 'sway.conf'
    config.write_text('xwayland disable\noutput HEADLESS-1 mode 1280x800\noutput * bg #0b0f16 solid_color\n'
                      'default_border none\nfocus_follows_mouse no\nseat seat0 hide_cursor 100\n')
    env = dict(os.environ)
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK', 'DBUS_SESSION_BUS_ADDRESS'):
        env.pop(key, None)
    env.update(XDG_RUNTIME_DIR=str(runtime), TMPDIR=str(work / 'tmp'), XDG_CACHE_HOME=str(work / 'cache'),
               WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_LIBINPUT_NO_DEVICES='1', XODB_TEST_PRIVATE_DISPLAY='1')
    ctx = SimpleNamespace(work=work, env=env, processes=[], binary=Path(os.environ.get('XODB_BIN', root / 'zig-out/bin/xodb')).resolve())
    host = SimpleNamespace(path=runtime / 's', clients=[])
    results = []

    def check(name, ok, detail=''):
        results.append(dict(check=name, ok=bool(ok), detail=str(detail)))
        print(('ok   ' if ok else 'FAIL ') + name + (f': {detail}' if detail else ''), flush=True)
        assert ok, (name, detail)

    def shot(name):
        subprocess.run(['grim', '-o', 'HEADLESS-1', str(work / 'shots' / (name + '.png'))], env=env, check=True, timeout=10)

    try:
        with (work / 'sway.log').open('wb') as log:
            sway = subprocess.Popen(['sway', '--unsupported-gpu', '--config', str(config)], env=env, stdout=log, stderr=subprocess.STDOUT)
        ctx.processes.append(sway)
        deadline = time.monotonic() + 10
        while True:
            displays = [p for p in runtime.glob('wayland-*') if not p.name.endswith('.lock')]
            ipcs = list(runtime.glob('sway-ipc*.sock'))
            if displays and ipcs:
                break
            assert sway.poll() is None, (work / 'sway.log').read_text()
            assert time.monotonic() < deadline, 'Private compositor did not start'
            time.sleep(.03)
        env.update(WAYLAND_DISPLAY=displays[0].name, SWAYSOCK=str(ipcs[0]))
        protocols = (('/usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml', 'virtual-pointer'),
                     ('/usr/lib/wayland-debug/resources/protocols/wlroots/protocol/virtual-keyboard-unstable-v1.xml', 'virtual-keyboard'))
        for protocol, stem in protocols:
            for mode, suffix in (('client-header', '.h'), ('private-code', '.c')):
                subprocess.run(['wayland-scanner', mode, protocol, str(work / (stem + suffix))], check=True)
        vinput = work / 'vinput'
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), str(root / 'tests/helpers/vinput.c'), str(work / 'virtual-pointer.c'),
                        str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', str(vinput)], check=True, env=env)
        ctx.inject = lambda *events: subprocess.run([str(vinput), '1280', '800', 'layout', 'us', *events], env=env, check=True, timeout=10)

        demo = work / 'demo.xoi'
        store = write_fixture(demo)
        large = work / 'large.xoi'
        large_store = write_fixture(large, 15000)
        corrupt = work / 'corrupt.xoi'
        bytes_ = bytearray(demo.read_bytes())
        bytes_[-10] ^= 1
        corrupt.write_bytes(bytes_)

        # 1. Shared session: open, cohorts, rows, thresholds, citations, F8, close/reopen.
        gui = Gui(ctx, 'shared', ['--browse-observation', 'demo.xoi', '--session-socket', str(host.path), '--agent-scope', 'control'])
        ready = gui.state(gui.wait(r'^observation-view ready '))
        check('open selects the first call', ready['list'] == 'all' and ready['call'] == '0', ready)
        first = comparison(gui, 1)
        want = expected(store, 4_000_000)
        check('initial comparison denominators', all(first[k] == want[k] for k in want) and first['threshold'] == 4_000_000, (first, want))
        time.sleep(.3)
        shot('01-open-cohorts')
        observer = shared.Client(host, 'observer')
        status = observer.tool('get_observation')
        check('MCP observer sees the same immutable capture', status['state'] == 'completed' and status['offline'] and status['calls'] == len(store.calls), status['calls'])
        agent_view = observer.tool('get_observation_comparison', id=1)
        check('MCP comparison equals the GUI cohort', agent_view['result']['fast']['count'] == want['fast'] and agent_view['result']['slow']['count'] == want['slow'], agent_view['result']['summary'])

        ctx.inject('tap', '36', 'tap', '36', 'tap', '36')
        move = gui.state(gui.wait(r'^observation-view move .*call=3 '))
        check('J moves the selection by call id', move['call'] == '3', move)
        ctx.inject('click', '300', str(307 + 22 * 5))
        click = gui.state(gui.wait(r'^observation-view click '))
        check('clicking a row selects that call', click['call'] == '5', click)

        ctx.inject('tap', '27')  # ]
        gui.wait(r'^observation-view recompute ')
        doubled = comparison(gui, 2)
        want8 = expected(store, 8_000_000)
        check('] doubles the threshold through the shared model operation', doubled['threshold'] == 8_000_000 and all(doubled[k] == want8[k] for k in want8), (doubled, want8))
        ctx.inject('tap', '20', 'tap', '2', 'tap', '11', 'tap', '11', 'tap', '11', 'tap', '11', 'tap', '11', 'tap', '11', 'tap', '28')
        typed = comparison(gui, 3)
        want1 = expected(store, 1_000_000)
        check('T types an exact threshold', typed['threshold'] == 1_000_000 and all(typed[k] == want1[k] for k in want1), (typed, want1))
        time.sleep(.3)
        shot('02-threshold-1ms')

        ctx.inject('tap', '15', 'tap', '15', 'tap', '15')
        incomplete = [c for c in store.calls if c['reason'] != 'complete']
        listed = gui.state(gui.wait(r'^observation-view list list=incomplete '))
        check('Tab reaches incomplete calls', listed['call'] == str(incomplete[0]['id']), (listed, incomplete[0]))
        time.sleep(.3)
        shot('03-incomplete')
        missing = next(c for c in incomplete if c['reason'] == 'missing_entry')
        lost = [c for c in incomplete if c['reason'] == 'loss']
        open_end = next(c for c in incomplete if c['reason'] == 'capture_end')
        check('fixture has missing entry, missing return and loss evidence', missing and lost and open_end['return_record'] is None, incomplete)
        position = [c['id'] for c in incomplete].index(missing['id'])
        ctx.inject(*(['tap', '36'] * position))
        if position:
            gui.wait(rf'^observation-view move .*call={missing["id"]} ')
        ctx.inject('tap', '18')  # E
        gui.wait(r'^observation-view citation-missing ')
        ctx.inject('tap', '19')  # R
        cited = gui.state(gui.wait(r'^observation-view cite-return '))
        check('R follows the raw return citation', cited['list'] == 'records' and cited['record'] == str(missing['return_record']), (cited, missing))
        time.sleep(.3)
        shot('04-raw-return-record')
        ctx.inject('tap', '46')  # C
        back = gui.state(gui.wait(r'^observation-view cite-call '))
        check('C returns to the citing call', back['call'] == str(missing['id']) and back['list'] == 'incomplete', back)
        ctx.inject('tap', '15', 'tap', '15')  # records, then all calls
        gui.wait(r'^observation-view list list=all ')
        nested = next(c for c in store.calls if c['parent_call'] is not None)
        ctx.inject(*(['tap', '36'] * (nested['id'] - int(back['call']))) if nested['id'] > int(back['call']) else (['tap', '37'] * (int(back['call']) - nested['id'])))
        gui.wait(rf'^observation-view move .*call={nested["id"]} ')
        ctx.inject('tap', '25')  # P
        parent = gui.state(gui.wait(r'^observation-view cite-parent '))
        check('P follows the parent call citation', parent['call'] == str(nested['parent_call']), (parent, nested))
        ctx.inject('tap', '18')  # E on the parent
        entry = gui.state(gui.wait(r'^observation-view cite-entry '))
        check('E follows the raw entry citation', entry['record'] == str(store.calls[nested['parent_call']]['entry_record']), entry)
        ctx.inject('tap', '46')
        gui.wait(r'^observation-view cite-call ')

        # Agent recomputation: same lease rule as MCP, and the GUI keeps its call.
        shared.expect_error(observer.raw('compare_observation', session_id=11, capture_id=1, threshold_ns=2_000_000), 'ControlLeaseRequired')
        observer.claim()
        started = observer.tool('compare_observation', session_id=11, capture_id=1, threshold_ns=2_000_000)
        external = comparison(gui, started['id'])
        check('GUI adopts an agent comparison without losing selection', external['threshold'] == 2_000_000, external)
        ctx.inject('tap', '36')
        after = gui.state(gui.wait(r'^observation-view move '))
        check('selection pinned across external recomputation', after['call'] == str(nested['parent_call'] + 1), after)
        check('controller visible', observer.info()['controller_id'] is not None)
        time.sleep(.3)
        shot('05-agent-controller')
        ctx.inject('tap', '66')  # F8 in the browser
        shared.eventually(observer.info, lambda s: s['scope'] == 'observe' and s['controller_id'] is None, 'F8 revocation in browser')
        shared.expect_error(observer.raw('compare_observation', session_id=11, capture_id=1, threshold_ns=3_000_000), 'AgentScopeDenied')
        check('F8 revokes the lease from inside the browser', True)
        time.sleep(.3)
        shot('06-f8-revoked')

        ctx.inject('tap', '49')  # N closes
        gui.wait(r'^observation-view close ')
        time.sleep(.3)
        shot('07-closed-workspace')
        ctx.inject('tap', '49', 'w', '200', 'tap', '36')  # N reopens, J moves
        reopened = gui.state(gui.wait(r'^observation-view move '))
        check('close/reopen keeps the selected call', reopened['call'] == str(nested['parent_call'] + 2), reopened)
        observer.close()
        gui.quit()

        # 2. A new process reopens the same file with a startup threshold.
        gui = Gui(ctx, 'reopen', ['--browse-observation', 'demo.xoi', '--observation-threshold-ns', '1000000'])
        gui.wait(r'^observation-view ready ')
        again = comparison(gui, 1)
        check('reopened archive reproduces cohorts', all(again[k] == typed[k] for k in want1) and again['threshold'] == 1_000_000, (again, typed))
        gui.quit()

        # 3. Large capture: paging never rebuilds the projection.
        gui = Gui(ctx, 'large', ['--browse-observation', 'large.xoi', '--observation-threshold-ns', '20000'])
        gui.wait(r'^observation-view ready ', timeout=30)
        comparison(gui, 1)
        ctx.inject('tap', '15')
        slow = gui.state(gui.wait(r'^observation-view list list=slow '))
        builds = slow['builds']
        began = time.monotonic()
        ctx.inject('burst', '40', *(['109'] * 40))
        ctx.inject('w', '300')
        ctx.inject('tap', '36', 'w', '500')
        lines = [gui.state(line) for line in gui.lines() if ' move ' in line]
        paged = lines[-1]
        check('paging is passive: no projection rebuilds', all(state['builds'] == builds for state in lines) and int(paged['top']) > 0, (builds, paged))
        check('paging stays responsive', time.monotonic() - began < 10, time.monotonic() - began)
        time.sleep(.3)
        shot('08-large-slow-paged')
        gui.quit()

        # 4. Startup themes apply to the browser; no theme key exists.
        gui = Gui(ctx, 'light', ['--browse-observation', 'demo.xoi', '--theme', 'builtin:light'])
        gui.wait(r'^observation-view ready ')
        comparison(gui, 1)
        time.sleep(.4)
        shot('10-light-theme')
        gui.quit()

        # 5. A corrupt archive is reported and nothing is shown from it.
        gui = Gui(ctx, 'corrupt', ['--browse-observation', 'corrupt.xoi'])
        failed = gui.wait(r'^observation-view open-failed ')
        check('corrupt archive reports its checksum failure', 'ArchiveChecksum' in failed.string, failed.string)
        time.sleep(.4)
        shot('09-corrupt')
        gui.quit()

        summary = dict(status='passed', work=str(work), checks=results, demo=dict(records=len(store.records), calls=len(store.calls)),
                       large=dict(records=len(large_store.records), calls=len(large_store.calls)))
        (work / 'result.json').write_text(json.dumps(summary, indent=2) + '\n')
        print('Invocation browser private GUI passed:', work)
    finally:
        for client in host.clients:
            client.close()
        for proc in reversed(ctx.processes):
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)


if __name__ == '__main__':
    main()
