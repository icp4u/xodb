#!/usr/bin/env python3
"""Fast private GUI: request-only observer, human approval/refusal and global stop."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-sc' + str(time.time_ns())[-5:])
work.mkdir(parents=True)
for name in ('tmp', 'cache'):
    (work / name).mkdir()
spec = importlib.util.spec_from_file_location('private_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'),
                str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
fixture = work / 'fixture'
subprocess.run(['cc', '-g', '-O1', '-fno-omit-frame-pointer', 'tests/fixtures/profile.c', '-pthread', '-o', str(fixture)], check=True)
target = subprocess.Popen([str(fixture), '30'], stdout=subprocess.DEVNULL)
started = time.monotonic()
d = None
checks = []


def check(label, condition):
    if not condition:
        raise AssertionError(label + ': ' + d.tail())
    checks.append(label)
    print('PASS ' + label, flush=True)


def until(probe, predicate, seconds=8):
    end = time.monotonic() + seconds
    while True:
        value = probe()
        if predicate(value):
            return value
        if not d.alive() or time.monotonic() >= end:
            raise AssertionError((value, d.tail()))
        time.sleep(.01)


def tracer():
    return int(next(line.split()[1] for line in Path(f'/proc/{target.pid}/status').read_text().splitlines() if line.startswith('TracerPid:')))


def state():
    return d.tool('get_system_capture')


def request(**arguments):
    def submit():
        response = d.request('tools/call', dict(name='request_system_capture', arguments=arguments))
        if response.get('isError'):
            if response['content'][0]['text'] == 'CaptureRequestRateLimited':
                return None
            raise AssertionError(response)
        return response['structuredContent']
    return until(submit, bool)


try:
    ticks = int(Path(f'/proc/{target.pid}/stat').read_text().rsplit(')', 1)[1].split()[19])
    previous_user = os.environ.get('USER')
    try:
        os.environ['USER'] = 'deadline'
        d = h.Display(str(root), ['--overview', '--panel', 'processes', '--session-socket', str(work / 's')], trace=False)
    finally:
        if previous_user is None:
            os.environ.pop('USER', None)
        else:
            os.environ['USER'] = previous_user
    d.wait_focused()
    check('live redaction control contains synthetic identity', 'deadline' in state()['shutdown'])
    d.keys('tap', 45)  # X: existing live GUI redaction toggle.
    hidden = until(state, lambda s: 'deadline' not in s['shutdown'])
    check('live X uses owner-local redaction for capture replies', 'user' in hidden['shutdown'])
    cpu = dict(kind='cpu', pid=target.pid, start_ticks=ticks, duration_ms=10_000)
    pending = request(**cpu)
    until(lambda: d.tool('get_layout'), lambda s: not s['available'])
    check('observer request opens confirmation without attaching', state()['request']['phase'] == 'pending' and tracer() == 0)
    d.shot('cpu-consent')
    d.keys('tap', 1)
    until(state, lambda s: s['request']['phase'] == 'denied')
    check('Escape denies and removes the request', tracer() == 0)
    pending = request(**cpu)
    until(lambda: d.tool('get_layout'), lambda s: not s['available'])
    d.shot('cpu-consent-again')
    # Retry Enter until the existing anti-double-press guard has armed.
    def confirm():
        current = state()
        if current['request']['phase'] == 'pending':
            d.keys('tap', 28)
        return state()
    until(confirm, lambda s: s['request']['phase'] == 'running')
    check('human approval starts capture in the same overview owner', tracer() == d.app.pid)
    d.keys('tap', 15)  # Another pane: capture does not inherit pane demand.
    d.keys('down', h.KEY['ctrl'], 'tap', h.KEY['esc'], 'up', h.KEY['ctrl'])
    stopped = until(state, lambda s: s['request']['phase'] == 'revoked' and not s['cleanup_pending'])
    (work / 'audit.json').write_text(json.dumps(stopped, indent=2))
    check('Ctrl+Escape revokes from another pane and detaches', tracer() == 0 and target.poll() is None)
    check('audit identifies human approval and revocation', any(r['phase'] == 'approved' and 'human' in r['caller'] for r in stopped['audit']) and stopped['audit'][-1]['phase'] == 'revoked' and 'human' in stopped['audit'][-1]['caller'])
    request(kind='fd_flow', duration_ms=1000)
    until(lambda: d.tool('get_layout'), lambda s: not s['available'])
    d.shot('flow-consent')
    check('fd-flow request waits for consent', state()['request']['phase'] == 'pending' and not state()['cleanup_pending'])
    d.keys('tap', 1)
    until(state, lambda s: s['request']['phase'] == 'denied')
    check('fd-flow rejection does not start tracing', not state()['cleanup_pending'])
    # A shared-socket requester stays present while connected (owner clock after pumps).
    peer = socket.socket(socket.AF_UNIX)
    peer.settimeout(8)
    peer.connect(str(work / 's'))
    lines = peer.makefile('rb')
    for message in (dict(id=1, method='initialize', params=dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='capture-gui', version='1'))),
                    dict(method='notifications/initialized')):
        peer.sendall((json.dumps(dict(jsonrpc='2.0', **message)) + '\n').encode())
    lines.readline()
    def peer_request():
        peer.sendall((json.dumps(dict(jsonrpc='2.0', id=2, method='tools/call', params=dict(name='request_system_capture', arguments=dict(kind='fd_flow', duration_ms=1000)))) + '\n').encode())
        reply = json.loads(lines.readline())['result']
        return None if reply.get('isError') and reply['content'][0]['text'] == 'CaptureRequestRateLimited' else reply
    reply = until(peer_request, bool)
    check('shared peer request accepted', not reply.get('isError') and reply['structuredContent']['request']['caller']['agent']['client'] > 0)
    time.sleep(.5)
    check('connected shared requester is not revoked as disconnected', state()['request']['phase'] == 'pending')
    lines.close()
    peer.close()
    until(state, lambda s: s['request']['phase'] == 'revoked' and s['request']['reason'] == 'requester_disconnected')
    check('shared requester disconnect revokes its pending request', not state()['cleanup_pending'])
finally:
    if d:
        d.close()
    if target.poll() is None:
        target.terminate()
    target.wait(timeout=5)
report = dict(status='pass', checks=checks, seconds=time.monotonic() - started)
(work / 'results.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report))
