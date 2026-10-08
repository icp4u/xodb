#!/usr/bin/env python3
"""Owned fd activity, explicit capture control, cached observers and pagination."""
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import types

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)  # Reap only this test's descendants.
work = root / '.work' / ('fda-' + str(time.time_ns())[-8:])
work.mkdir(parents=True, mode=0o755)
run = work / 'run'; run.mkdir(mode=0o700)
results, fixtures, peers, descriptors = [], [], [], []
server = None
spec = importlib.util.spec_from_file_location('fd_shared_test', root / 'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(spec); spec.loader.exec_module(shared)

def check(label, condition):
    results.append({'check': label, 'status': 'pass' if condition else 'fail'})
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)
    assert condition, label

def until(fn, predicate, label, seconds=20):
    deadline = time.monotonic() + seconds
    while True:
        value = fn()
        if predicate(value): return value
        assert time.monotonic() < deadline, (label, value)
        time.sleep(.04)

def cache(peer, name, **args):
    deadline = time.monotonic() + 5
    while True:
        reply = peer.raw(name, **args)
        if not reply.get('error') and not reply['result'].get('isError'):
            return reply['result']['structuredContent']
        message = reply.get('result', {}).get('content', [{}])[0].get('text')
        assert message == 'FdCacheBusy' and time.monotonic() < deadline, reply
        time.sleep(.003)

def spawn(mode, *args):
    p = subprocess.Popen([str(root / 'zig-out/bin/xodb-fd-fixture'), mode, *map(str, args)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    fixtures.append(p)
    assert select.select([p.stdout], [], [], 5)[0]
    assert p.stdout.readline().startswith('ready ')
    return p

def ticks(pid): return int(Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19])
def traced(pid): return int(next(x.split(':')[1] for x in Path(f'/proc/{pid}/status').read_text().splitlines() if x.startswith('TracerPid:')))

try:
    for mode in ('direct', 'shared'):
        done = subprocess.run([str(root / 'zig-out/bin/xodb-fdactivity-live'), str(work / ('oracle-' + mode)), mode], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=15)
        (work / ('oracle-' + mode + '.log')).write_text(done.stdout)
        check('C ' + mode + ' exact bytes, identity and lifetime', done.returncode == 0 and 'PASS live exact bytes' in done.stdout)
    scope = subprocess.run([str(root / 'zig-out/bin/xodb-fdactivity-scope')], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=15)
    (work / 'scope.log').write_text(scope.stdout)
    check('C oversized scope and permission refusals close handles', scope.returncode == 0 and scope.stdout.count('PASS ') == 2)
    log = (work / 'server.log').open('wb')
    env = dict(os.environ)
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK'): env.pop(key, None)
    server = subprocess.Popen([str(root / 'zig-out/bin/xodb'), '--headless', '--session-socket', str(run / 's'), '--agent-scope', 'control'], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=env)
    until(lambda: (server.poll(), (run / 's').exists()), lambda r: r[0] is None and r[1], 'listener', 5)
    socket_owner = types.SimpleNamespace(path=run / 's', clients=[])
    first = shared.Client(socket_owner, 'fd-observer-one'); peers.append(first)
    second = shared.Client(socket_owner, 'fd-observer-two'); peers.append(second)
    names = {x['name']: x for x in first.call('tools/list')['result']['tools']}
    expected = ('get_fd_activity', 'who_has_open', 'get_fd_leaks', 'get_deleted_open')
    check('four tools available without a control lease', all(n in names and names[n]['annotations']['readOnlyHint'] for n in expected) and first.info()['controller_id'] is None)
    initial = until(lambda: cache(first, 'get_fd_activity', redact=True, interval_ms=1000), lambda r: r['state'] == 'ok' and r['rows'], 'initial shared poll')
    versions = [cache(second, 'get_fd_activity', redact=True, interval_ms=1000)['sequence'] for _ in range(15)]
    check('MCP reads do not add a sample per call', len(set(versions)) <= 2 and versions[-1] - versions[0] <= 1)
    check('two peers share one collector', initial['collector_instances'] == 1 and cache(second, 'get_fd_activity', redact=True)['collector_instances'] == 1)
    for label in ('writer', 'deleted'): (work / label).mkdir(mode=0o755)
    writer = spawn('write', work / 'writer', 65536)
    deleted = spawn('deleted', work / 'deleted', 8192)
    leaker = spawn('leak', 32, 1000)
    writer_rows = until(lambda: cache(first, 'get_fd_activity', pid=writer.pid, interval_ms=250), lambda r: any(x['kind'] == 'file' or x['kind'] == 'regular' for x in r['rows']), 'writer fd page')
    regular = next(x for x in writer_rows['rows'] if x['kind'] in ('file', 'regular'))
    st = os.stat(f'/proc/{writer.pid}/fd/{regular["fd"]}')
    check('poll device/inode matches owned proc descriptor', regular['device'] == str(st.st_dev) and regular['inode'] == str(st.st_ino))
    lookup = cache(second, 'who_has_open', device=str(st.st_dev), inode=str(st.st_ino), pid=writer.pid, interval_ms=250)
    check('reverse inode lookup finds the owned holder', any(x['fd'] == regular['fd'] and x['pid'] == writer.pid for x in lookup['rows']))
    by_path = cache(first, 'who_has_open', path=regular['path'], pid=writer.pid, interval_ms=250)
    check('reverse path lookup uses cached exact path text', any(x['fd'] == regular['fd'] for x in by_path['rows']))
    shared.expect_error(first.raw('who_has_open', path=regular['path'], redact=True), 'FdPathLookupRedacted')
    check('redacted path guesses are refused before cache lookup', True)
    hidden = cache(second, 'get_fd_activity' , pid=writer.pid, redact=True, interval_ms=250)
    check('redaction hides every descriptor path', hidden['redacted'] and hidden['rows'] and all(x['path'] == 'redacted' for x in hidden['rows']))
    unusual = os.open(os.fsencode(work) + b'/bytes-\xff', os.O_RDWR | os.O_CREAT, 0o600)
    descriptors.append(unusual)
    os.write(unusual, b'fixture'); os.lseek(unusual, 2, os.SEEK_SET)
    unusual_stat = os.fstat(unusual)
    unusual_page = until(lambda: cache(first, 'who_has_open', pid=os.getpid(), device=str(unusual_stat.st_dev), inode=str(unusual_stat.st_ino), interval_ms=250), lambda r: bool(r['rows']), 'non-UTF-8 inode')
    unusual_row = next(x for x in unusual_page['rows'] if x['fd'] == unusual)
    check('non-UTF-8 path remains queryable by inode with valid JSON', unusual_row['path'] is None and unusual_row['path_state'] == 'non-UTF-8; query by device and inode')
    check('fdinfo offset and per-pid coverage match the owned descriptor', unusual_row['offset'] == 2 and unusual_page['scope']['state'] in ('sampled', 'stale') and unusual_page['scope']['start_ticks'] == ticks(os.getpid()))
    hidden_unusual = cache(second, 'who_has_open', pid=os.getpid(), device=str(unusual_stat.st_dev), inode=str(unusual_stat.st_ino), interval_ms=250, redact=True)
    check('redaction also hides non-UTF-8 path evidence', hidden_unusual['rows'] and all(x['path'] == 'redacted' and x['path_state'] == 'redacted' for x in hidden_unusual['rows']))
    denied = subprocess.Popen([sys.executable, '-u', '-c', 'import ctypes,sys; assert ctypes.CDLL(None).prctl(4,0,0,0,0)==0; print("ready"); sys.stdin.read(1)'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    fixtures.append(denied)
    assert select.select([denied.stdout], [], [], 5)[0] and denied.stdout.readline().strip() == 'ready'
    denied_page = until(lambda: cache(first, 'get_fd_activity', pid=denied.pid, interval_ms=250), lambda r: r.get('scope', {}).get('state') == 'fd table unavailable', 'permission scope')
    check('denied fd table is explicit rather than a fabricated empty table', not denied_page['rows'] and denied_page['coverage']['hidden'] > 0)
    held = until(lambda: cache(second, 'get_deleted_open', pid=deleted.pid, interval_ms=250), lambda r: bool(r['rows']), 'deleted holder')
    check('deleted-open size agrees with owned fixture', any(x['deleted'] and x['size_bytes'] == 8192 for x in held['rows']))
    growth = until(lambda: cache(first, 'get_fd_leaks', pid=leaker.pid, interval_ms=250), lambda r: bool(r['rows']), 'growth history', 30)
    check('sustained growth is reported with a history', growth['rows'][0]['growth_candidate'] and len(growth['rows'][0]['history']) >= 6 and growth['rows'][0]['growth_above_window_low'] >= 8)
    shared.expect_invalid(first.raw('get_fd_activity', mode='events', pid=writer.pid))
    shared.expect_invalid(first.raw('who_has_open', path=regular['path'], inode='1', device='2'))
    shared.expect_invalid(first.raw('get_fd_activity', pid=writer.pid, offset=1))
    check('invalid identities and ambiguous queries refused', True)
    shared.expect_error(first.raw('get_fd_activity', pid=writer.pid, sequence=1), 'FdSnapshotChanged')
    check('pagination refuses a changed cache sequence', True)
    event_dir = work / 'events'; event_dir.mkdir(mode=0o755)
    event = subprocess.Popen([str(root / 'zig-out/bin/xodb-fd-events'), str(server.pid)], cwd=event_dir, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    fixtures.append(event)
    assert select.select([event.stdout], [], [], 5)[0]
    ready = event.stdout.readline().split(); assert ready[0] == 'ready'
    fd = int(ready[2]); start = ticks(event.pid)
    event_args = dict(mode='events', pid=event.pid, start_ticks=start, interval_ms=250)
    start_args = dict(pid=event.pid, start_ticks=start, acknowledge_host_cost=True)
    def perf_fds():
        result = []
        for item in Path(f'/proc/{server.pid}/fd').iterdir():
            try:
                if 'perf_event' in os.readlink(item): result.append(item.name)
            except FileNotFoundError: pass
        return result
    for _ in range(5):
        idle = cache(first, 'get_fd_activity', **event_args)
        assert not idle['running'] and not idle['exact_mode_active']
        time.sleep(.04)
    shared.expect_error(first.raw('start_fd_events', **start_args), 'ControlLeaseRequired')
    check('unleased observers cannot start capture and reads open no perf fds', not perf_fds() and 'start_fd_events' not in names)
    first.claim()
    advertised = {x['name']: x for x in first.call('tools/list')['result']['tools']}
    check('capture controls appear only to the controller with a host-wide cost warning', all(advertised[n]['annotations']['xodbSessionAccess'] == 'controller' and not advertised[n]['annotations']['readOnlyHint'] for n in ('start_fd_events', 'stop_fd_events')) and 'roughly 10 %' in advertised['start_fd_events']['description'])
    shared.expect_error(first.raw('start_fd_events', pid=event.pid, start_ticks=start), 'FdHostCostAcknowledgementRequired')
    cache(first, 'start_fd_events', **start_args)
    begun = until(lambda: cache(first, 'get_fd_activity', **event_args), lambda r: r['state'] == 'ok' and r['running'], 'event enrollment', 10)
    check('event mode opens one explicit identity without ptrace', begun['collector_instances'] == 1 and begun['threads'] == 1 and traced(event.pid) == 0)
    conflict = first.raw('start_fd_events', pid=writer.pid, start_ticks=ticks(writer.pid), acknowledge_host_cost=True)
    shared.expect_error(conflict, 'FdEventScopeBusy')
    check('a peer cannot replace another active event identity', True)
    event.stdin.write('g'); event.stdin.flush()
    assert select.select([event.stdout], [], [], 5)[0] and event.stdout.readline().strip() == 'done'
    measured = until(lambda: cache(second, 'get_fd_activity', **event_args), lambda r: any(x['fd'] == fd and x['read_bytes'] == 13 and x['write_bytes'] == 9 for x in r['rows']), 'MCP exact syscall bytes', 10)
    row = next(x for x in measured['rows'] if x['fd'] == fd)
    check('MCP event bytes equal the oracle across fd reuse', row['read_bytes'] == 13 and row['write_bytes'] == 9 and row['open_returns'] == 1 and row['close_successes'] == 1)
    check('event evidence has no loss, malformed data or current-path attribution', measured['lost'] == 0 and measured['invalid'] == 0 and 'path' not in row and measured['unpaired'] >= 1)
    cache(first, 'start_fd_events', **start_args)
    event.stdin.write('p'); event.stdin.flush()
    assert select.select([event.stdout], [], [], 5)[0] and event.stdout.readline().strip() == 'paged'
    paged = until(lambda: cache(second, 'get_fd_activity', **dict(event_args, limit=500)), lambda r: r['matches_in_cache'] >= 603 and not r['drain_pending'], 'more than 500 event rows')
    shared.expect_error(second.raw('get_fd_activity', **dict(event_args, sequence=measured['sequence'], offset=1)), 'FdSnapshotChanged')
    check('new event records invalidate earlier pagination sequences', paged['sequence'] != measured['sequence'])
    cache(first, 'start_fd_events', **start_args)
    stable = None
    for _ in range(20):
        page1 = cache(second, 'get_fd_activity', **dict(event_args, limit=500))
        time.sleep(.015)  # crosses at least one idle owner drain
        page2 = cache(second, 'get_fd_activity', **dict(event_args, limit=500, offset=page1['next_offset'], sequence=page1['sequence']))
        combined = page1['rows'] + page2['rows']
        assert len(combined) == page1['matches_in_cache'] and page2['next_offset'] is None
        assert len({r['fd'] for r in combined}) == len(combined)
        assert all(next(r for r in combined if r['fd'] == n)['write_bytes'] == 1 for n in range(1000, 1600))
        stable = page1['sequence']
    check('20/20 idle captures paginate beyond 500 rows with exact bytes', stable is not None and paged['lost'] == 0 and not paged['possible_loss'] and paged['loss_accounting_available'])
    # Observer reads cannot refresh the 3s authorization window.
    expired = until(lambda: cache(second, 'get_fd_activity', **event_args), lambda r: not r['running'], 'event demand expiry despite observer reads', 5)
    print('expiry evidence', dict(first_generation=measured['capture_generation'], expired_generation=expired['capture_generation'], perf_fds=perf_fds()), flush=True)
    until(perf_fds, lambda fds: not fds, 'expired perf handle cleanup', 2)
    check('observer reads allow demand expiry and retain counts', expired['capture_generation'] == paged['capture_generation'] and not perf_fds())
    shared.expect_error(second.raw('start_fd_events', **start_args), 'ControlLeaseRequired')
    cache(first, 'start_fd_events', **start_args)
    resumed = until(lambda: cache(second, 'get_fd_activity', **event_args), lambda r: r['running'], 'explicit restart')
    check('explicit restart advances generation and content sequence', resumed['capture_generation'] > expired['capture_generation'] and resumed['sequence'] != stable)
    shared.expect_error(second.raw('get_fd_activity', **dict(event_args, sequence=stable, offset=500)), 'FdSnapshotChanged')
    # After a large burst the fixture blocks in read(0), producing no more IO.
    # Loss must be visible without waiting for a later PERF_RECORD_LOST record.
    event.stdin.write('b'); event.stdin.flush()
    assert select.select([event.stdout], [], [], 5)[0] and event.stdout.readline().strip() == 'burst'
    burst_idle = time.monotonic()
    loss = until(lambda: cache(second, 'get_fd_activity', **dict(event_args, limit=1)),
                 lambda r: r.get('lost', 0) > 0 or r.get('possible_loss', False), 'idle burst loss visibility', 5)
    observed_ms = 1000 * (time.monotonic() - burst_idle)
    cpus, load = len(os.sched_getaffinity(0)), os.getloadavg()
    print('burst loss evidence', dict(milliseconds=round(observed_ms, 3) if load[0] <= cpus else 'not measurable', load_average=load, cpu_count=cpus, lost=loss['lost'], flags=loss['flags'], state=loss['loss_state']), flush=True)
    check('unpaced burst exposes loss before further target IO', loss['lost'] > 0 or loss['possible_loss'])
    time.sleep(.05)
    retained_loss = cache(second, 'get_fd_activity', **dict(event_args, limit=1))
    check('idle loss remains visible without further target IO', retained_loss['lost'] >= loss['lost'] and (retained_loss['lost'] > 0 or retained_loss['possible_loss']))
    cache(first, 'stop_fd_events')
    until(lambda: cache(second, 'get_fd_activity', **event_args), lambda r: not r['running'], 'explicit stop')
    until(perf_fds, lambda fds: not fds, 'stopped perf handle cleanup', 2)
    check('explicit stop closes perf handles', not perf_fds())
    cache(first, 'start_fd_events', **start_args)
    until(lambda: cache(second, 'get_fd_activity', **event_args), lambda r: r['running'], 'restart for release')
    first.tool('release_session_control')
    until(lambda: cache(second, 'get_fd_activity', **event_args), lambda r: not r['running'], 'control release stops capture', 2)
    until(perf_fds, lambda fds: not fds, 'revoked perf handle cleanup', 2)
    check('lease release stops capture without observer renewal', not perf_fds())
    first.claim(ttl_ms=1000)
    cache(first, 'start_fd_events', **start_args)
    until(lambda: cache(second, 'get_fd_activity', **event_args), lambda r: r['running'], 'restart for lease expiry')
    until(lambda: cache(second, 'get_fd_activity', **event_args), lambda r: not r['running'], 'lease expiry stops capture', 2)
    until(perf_fds, lambda fds: not fds, 'revoked perf handle cleanup', 2)
    check('lease expiry stops capture before the demand deadline', not perf_fds())
    first.claim()
    cache(first, 'start_fd_events', **start_args)
    until(lambda: cache(second, 'get_fd_activity', **event_args), lambda r: r['running'], 'restart for disconnect')
    first.close(); peers.remove(first)
    until(lambda: cache(second, 'get_fd_activity', **event_args), lambda r: not r['running'], 'controller disconnect stops capture', 2)
    until(perf_fds, lambda fds: not fds, 'revoked perf handle cleanup', 2)
    check('controller disconnect stops capture and retains shared owner', not perf_fds() and cache(second, 'get_fd_activity')['collector_instances'] == 1)
    second.claim()
    cache(second, 'start_fd_events', **start_args)
    until(lambda: cache(second, 'get_fd_activity', **event_args), lambda r: r['running'], 'restart for target exit')
    event.stdin.write('q'); event.stdin.flush(); assert event.wait(timeout=5) == 0
    ended = until(lambda: cache(second, 'get_fd_activity', **event_args), lambda r: r['state'] == 'ok' and not r['running'], 'ended event scope', 5)
    check('event scope ends on task exit with retained counts', ended['invalid'] == 0 and not ended['exact_mode_active'])
    (work / 'observations.json').write_text(json.dumps(dict(initial=initial, writer=writer_rows, deleted=held, growth=growth, event=measured, ended=ended), indent=2) + '\n')
finally:
    for fd in descriptors: os.close(fd)
    for peer in peers: peer.close()
    if server and server.poll() is None:
        server.send_signal(signal.SIGINT)
        try: server.wait(timeout=5)
        except subprocess.TimeoutExpired: server.kill(); server.wait()
    for p in fixtures:
        if p.poll() is None: p.terminate()
    for p in fixtures:
        try: p.wait(timeout=5)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
    deadline = time.monotonic() + 2
    while True:
        try: pid, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError: break
        assert time.monotonic() < deadline, 'owned child cleanup deadline'
        if not pid: time.sleep(.01)
    (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print(f'fd activity: {len(results)}/{len(results)} passed; {work}', flush=True)
