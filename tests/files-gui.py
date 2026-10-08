#!/usr/bin/env python3
"""Owned Files pane: cache sharing, freeze, explicit events, privacy and layout.

Only private headless Sway is used. Screenshots and live evidence stay in .work.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import time
import types
from PIL import Image

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-files-' + str(time.time_ns())[-8:])
work.mkdir(parents=True)
for name in ('tmp', 'cache', 'writer', 'deleted', 'events'):
    (work / name).mkdir()
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value
h = module('files_input', root / 'tests/helpers/input.py')
shared = module('files_shared', root / 'tests/shared-sessions.py')
h.WORK = str(work)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'), str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
results, fixtures, peers = [], [], []
d = None

def check(label, ok):
    results.append(dict(check=label, status='pass' if ok else 'fail'))
    print(('PASS ' if ok else 'FAIL ') + label, flush=True)
    assert ok, label

def until(fn, predicate, label, seconds=25):
    end = time.monotonic() + seconds
    while True:
        value = fn()
        if predicate(value): return value
        assert time.monotonic() < end, (label, value)
        time.sleep(.04)

def cached(peer, name='get_fd_activity', **args):
    end = time.monotonic() + 5
    while True:
        reply = peer.raw(name, **args)
        if not reply.get('error') and not reply['result'].get('isError'):
            return reply['result']['structuredContent']
        error = reply.get('result', {}).get('content', [{}])[0].get('text')
        assert error == 'FdCacheBusy' and time.monotonic() < end, reply
        time.sleep(.004)

def ticks(pid): return int(Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19])
def spawn(mode, *args):
    p = subprocess.Popen([str(root / 'zig-out/bin/xodb-fd-fixture'), mode, *map(str, args)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    fixtures.append(p)
    assert select.select([p.stdout], [], [], 5)[0] and p.stdout.readline().startswith('ready ')
    return p

def audit(): return Path(d.log).read_text(errors='replace')
def process_rows(): return re.findall(r'process selection query_pid=(\d+) query_row=(-?\d+) rows=(\d+) selected_pid=(\d+) start=(\d+)', audit())
def file_rows(): return re.findall(r'files collector opens=(\d+) sequence=(\d+) filter_pid=(\d+) start=(\d+) rows=(\d+) mode=(\w+)', audit())
def perf_fds():
    count = 0
    for fd in Path(f'/proc/{d.app.pid}/fd').iterdir():
        try: count += 'perf_event' in os.readlink(fd)
        except FileNotFoundError: pass
    return count

def screen(name): return h.ocr(d.shot(name))
def mode_size(width, height):
    subprocess.run(['swaymsg', 'output', 'HEADLESS-1', 'mode', f'{width}x{height}'], env=d.env, check=True, stdout=subprocess.DEVNULL, timeout=5)
    time.sleep(.4)

flat = False
def scope(pid):
    global flat
    d.keys('tap', 4)  # Processes
    if not flat: d.keys('tap', 47); flat = True
    d.keys('tap', 53, 'tap', 1, 'tap', 53) # clear the prior process query
    keys = [item for digit in str(pid) for item in ('tap', 11 if digit == '0' else int(digit) + 1)]
    d.keys(*keys, 'tap', 28)
    # A new fixture may miss the previous process snapshot; numeric search
    # also matches pid prefixes and command arguments. Wait for its exact row
    # and acknowledge the selected identity before requesting an action.
    until(process_rows, lambda rows: rows and rows[-1][0] == str(pid) and int(rows[-1][1]) >= 0, 'queried process present')
    birth = ticks(pid)
    def select_exact():
        rows = process_rows()
        if rows and rows[-1][0] == str(pid) and int(rows[-1][1]) >= 0:
            d.keys('tap', 102, *[item for _ in range(int(rows[-1][1])) for item in ('tap', 108)])
        return process_rows()
    until(select_exact, lambda rows: rows and rows[-1][3:5] == (str(pid), str(birth)), 'exact process selected')
    d.keys('tap', 38); time.sleep(.3); d.keys('tap', 28)
    birth = ticks(pid)
    until(file_rows, lambda rows: rows and rows[-1][2:4] == (str(pid), str(birth)) and int(rows[-1][4]) > 0, 'selected process fd rows')
    return birth

def confirm_events():
    d.keys('tap', 18); time.sleep(.3); d.keys('tap', 28)

os.environ['XODB_OVERVIEW_AUDIT'] = '1'
os.environ['XODB_OVERVIEW_LAYOUT'] = '1'
try:
    writer = spawn('write', work / 'writer', 65536)
    deleted = spawn('deleted', work / 'deleted', 8192)
    leaker = spawn('leak', 8, 1024)
    d = h.Display(str(root), ['--overview', '--files-pid', str(writer.pid), '--files-start-ticks', str(ticks(writer.pid)), '--interval-ms', '1000', '--session-socket', str(work / 's')], trace=False)
    mode_size(1280, 720)
    endpoint = types.SimpleNamespace(path=work / 's', clients=[])
    peer = shared.Client(endpoint, 'files-observer'); peers.append(peer)
    initial = until(lambda: cached(peer, pid=writer.pid), lambda value: value['rows'], 'owned writer cache')
    until(file_rows, lambda rows: rows and rows[-1][2] == str(writer.pid) and int(rows[-1][4]) > 0, 'writer shown')
    check('Files CLI pins the owned identity and shares one owner with MCP', initial['collector_instances'] == 1 and all(row[0] == '1' for row in file_rows()))
    text = screen('writer-1280')
    check('writer table and unknown progress are visible at 1280x720', 'written' in text and ('unmeasured' in text or 'first sample' in text))
    reads_started = time.monotonic()
    reads = [cached(peer, pid=writer.pid) for _ in range(10)]
    reads_elapsed = time.monotonic() - reads_started
    # Allow the initial publication and a boundary tick, plus the owner ticks
    # that fit in the actual observation window, including scheduler delays.
    cadence = min(value['interval_ms'] for value in reads) / 1000
    publications = len({value['sequence'] for value in reads})
    check('GUI and MCP reads do not request a sample per call', publications <= int(reads_elapsed / cadence) + 2)
    d.keys('tap', 25) # pause; metadata can still report capture stop
    frozen = file_rows()[-1][1]
    first = Image.open(d.shot('paused-first')).crop((208, 380, 1268, 640)).tobytes()
    advanced = until(lambda: cached(peer, pid=writer.pid, interval_ms=250), lambda value: value['sequence'] > int(frozen), 'MCP while GUI frozen')
    time.sleep(.3)
    second = Image.open(d.shot('paused-second')).crop((208, 380, 1268, 640)).tobytes()
    check('paused presentation is stable while a peer refreshes its shared cache', frozen == file_rows()[-1][1] and first == second and advanced['collector_instances'] == 1)
    d.keys('tap', 25)
    until(file_rows, lambda rows: int(rows[-1][1]) >= advanced['sequence'], 'resumed GUI')
    check('faster peer cadence is shown honestly', '250 ms shared polling' in screen('shared-250'))
    # The command-driven native fixture explicitly permits this GUI's perf reads.
    event = subprocess.Popen([str(root / 'zig-out/bin/xodb-fd-events'), str(d.app.pid)], cwd=work / 'events', stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    fixtures.append(event)
    assert select.select([event.stdout], [], [], 5)[0]
    ready = event.stdout.readline().split(); assert ready[0] == 'ready'
    fd = int(ready[2]); birth = scope(event.pid)
    event_args = dict(mode='events', pid=event.pid, start_ticks=birth)
    idle = cached(peer, **event_args)
    check('opening a Files view and observing events never enables capture', not idle['running'] and perf_fds() == 0)
    d.keys('tap', 18)
    text = screen('event-consent')
    check('exact-event prompt states host-wide syscall slowdown before capture', 'all syscalls' in text and 'roughly 10' in text and perf_fds() == 0)
    d.keys('tap', 1)
    check('cancel leaves exact capture off', not cached(peer, **event_args)['running'] and perf_fds() == 0)
    confirm_events()
    begun = until(lambda: cached(peer, **event_args), lambda value: value['running'], 'explicit UI capture')
    check('confirmed UI action starts one bounded capture without ptrace', begun['threads'] == 1 and perf_fds() == 2 and re.search(r'^TracerPid:\s*0$', Path(f'/proc/{event.pid}/status').read_text(), re.M))
    shared.expect_error(peer.raw('start_fd_events', pid=event.pid, start_ticks=birth, acknowledge_host_cost=True), 'AgentScopeDenied')
    check('UI consent does not grant observer peers control', True)
    event.stdin.write('g'); event.stdin.flush()
    assert select.select([event.stdout], [], [], 5)[0] and event.stdout.readline().strip() == 'done'
    measured = until(lambda: cached(peer, **event_args), lambda value: any(row['fd'] == fd and row['read_bytes'] == 13 and row['write_bytes'] == 9 for row in value['rows']), 'shared event oracle')
    text = screen('event-active')
    check('active capture warning and fd-number provenance stay visible', 'all syscalls' in text and ('FD-number' in text or 'spans reuse' in text) and measured['lost'] == 0)
    event.stdin.write('b'); event.stdin.flush()
    assert select.select([event.stdout], [], [], 5)[0] and event.stdout.readline().strip() == 'burst'
    loss = until(lambda: cached(peer, **event_args), lambda value: value['lost'] or value['possible_loss'], 'idle burst loss')
    text = until(lambda: screen('event-loss'), lambda value: 'incomplete' in value and 'all syscalls' in value, 'presented loss frame')
    check('active GUI keeps loss visible alongside the host-wide cost', 'incomplete' in text and 'all syscalls' in text and (loss['lost'] or loss['possible_loss']))
    d.keys('tap', 18)
    until(lambda: cached(peer, **event_args), lambda value: not value['running'], 'explicit UI stop')
    check('E stops capture and retains its pages', perf_fds() == 0 and cached(peer, **event_args)['rows'])
    confirm_events(); until(lambda: cached(peer, **event_args), lambda value: value['running'], 'restart for pause')
    d.keys('tap', 25)
    until(lambda: cached(peer, **event_args), lambda value: not value['running'], 'pause stops capture')
    d.keys('tap', 25)
    time.sleep(.5)
    check('pause cancels capture and resume does not silently restart it', not cached(peer, **event_args)['running'] and perf_fds() == 0)
    confirm_events(); until(lambda: cached(peer, **event_args), lambda value: value['running'], 'restart for navigation')
    d.keys('tap', 2) # Summary
    until(lambda: cached(peer, **event_args), lambda value: not value['running'], 'leaving stops capture')
    d.keys('tap', 38) # return to Files without a new consent action
    time.sleep(.5)
    check('leaving Files stops capture and reopening stays read-only', not cached(peer, **event_args)['running'] and perf_fds() == 0)
    scope(leaker.pid)
    d.keys('tap', 27, 'tap', 27) # Leak watch for this identity
    growth = until(lambda: cached(peer, 'get_fd_leaks', pid=leaker.pid, interval_ms=250), lambda value: value['rows'], 'growth fixture', seconds=35)
    text = screen('leak-history')
    check('Leak watch exposes owned sustained growth with history', growth['rows'][0]['growth_candidate'] and len(growth['rows'][0]['history']) >= 6 and 'Leak watch' in text)
    scope(deleted.pid)
    d.keys('tap', 27, 'tap', 27, 'tap', 27) # Files -> Processes -> Leaks -> Deleted
    held = until(lambda: cached(peer, 'get_deleted_open', pid=deleted.pid, interval_ms=250), lambda value: value['rows'], 'deleted fixture')
    text = screen('deleted-holder')
    check('deleted holder size is shown with an exact inode oracle', any(row['size_bytes'] == 8192 for row in held['rows']) and 'held' in text and '8.0' in text)
    d.keys('tap', 45) # one-way redaction
    mode_size(1920, 1080)
    d.keys('tap', 20, 'tap', 20) # existing phosphor theme cycle
    text = screen('redacted-1920')
    check('redaction hides owned paths at 1920x1080', 'redacted' in text and 'held (deleted)' not in text and str(work) not in text)
    layout = re.findall(r'overview layout (\d+)x(\d+) panel=files overlaps=(\d+)', audit())
    # The audit logs changes in overlap count or panel, so an unchanged clean
    # layout after resize need not emit another line. Verify sizes in the PNGs.
    sizes = {Image.open(path).size for name in ('writer-1280.png', 'redacted-1920.png') for path in work.glob('run-*/' + name)}
    check('Files layout has no text overlaps at both review sizes', layout and {(1280, 720), (1920, 1080)} <= sizes and all(n == '0' for _,_,n in layout))
    event.stdin.write('q'); event.stdin.flush(); assert event.wait(timeout=5) == 0
finally:
    for peer in peers: peer.close()
    if d: d.close()
    for p in fixtures:
        if p.poll() is None: p.terminate()
    for p in fixtures:
        try: p.wait(timeout=5)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
    (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print(f'Files GUI: {len(results)}/{len(results)} passed; {work}', flush=True)
