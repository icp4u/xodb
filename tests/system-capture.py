#!/usr/bin/env python3
"""Fast owned-fixture capture consent, owner deadline, shared cancellation and EOF.

No host policy changes. Output artifacts stay in .work. Sampling permission
failure is a real capture failure, never a silent successful/skip result.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
started = time.monotonic()
work = root / '.work' / ('capture-' + str(time.time_ns())[-9:])
work.mkdir(parents=True)
fixture = work / 'fixture'
subprocess.run(['cc', '-g', '-O1', '-fno-omit-frame-pointer', '-fno-optimize-sibling-calls',
                'tests/fixtures/profile.c', '-pthread', '-o', str(fixture)], check=True, timeout=30)
target = subprocess.Popen([str(fixture), '30'], stdout=subprocess.DEVNULL)
clients, peers, checks, footprints = [], [], [], []


def check(label, condition, detail=None):
    if not condition:
        raise AssertionError((label, detail))
    checks.append(label)
    print('PASS ' + label, flush=True)


def eventually(probe, predicate, seconds=8):
    end = time.monotonic() + seconds
    while True:
        value = probe()
        if predicate(value):
            return value
        if time.monotonic() >= end:
            raise AssertionError(('condition timeout', value))
        time.sleep(.005)


def tracer():
    return int(next(line.split()[1] for line in Path(f'/proc/{target.pid}/status').read_text().splitlines() if line.startswith('TracerPid:')))


def stats(client, phase):
    fields = Path(f'/proc/{client.p.pid}/stat').read_text().rsplit(')', 1)[1].split()
    footprints.append(dict(phase=phase, cpu_ticks=int(fields[11]) + int(fields[12]),
                           rss_bytes=int(fields[21]) * os.sysconf('SC_PAGE_SIZE'), at=time.monotonic()))


def client(scope='control', options=()):
    result = Client(scope, executable=None, options=('--overview', *options))
    clients.append(result)
    return result


def refused(reply, reason):
    check('refuses ' + reason, reply.get('result', {}).get('isError') and
          reply['result']['content'][0]['text'] == reason, reply)


def terminal(c):
    return eventually(lambda: c.inspect('get_system_capture'),
                      lambda s: s['request'] and s['request']['phase'] not in ('pending', 'approved', 'running') and not s['cleanup_pending'])


class Peer(Client):
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(8)
        self.sock.connect(str(path))
        self.pending = b''
        self.id = 0
        self.transcript = []
        self.call('initialize', dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='capture-test', version='1')))
        self.sock.sendall(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        peers.append(self)

    def call(self, method, params=None):
        self.id += 1
        self.sock.sendall((json.dumps(dict(jsonrpc='2.0', id=self.id, method=method, params=params or {})) + '\n').encode())
        while True:
            while b'\n' not in self.pending:
                data = self.sock.recv(65536)
                if not data:
                    raise AssertionError('shared peer closed')
                self.pending += data
            line, self.pending = self.pending.split(b'\n', 1)
            reply = json.loads(line)
            if reply.get('id') == self.id:
                self.transcript.append(reply)
                return reply

    def close(self):
        self.sock.close()


try:
    ticks = int(Path(f'/proc/{target.pid}/stat').read_text().rsplit(')', 1)[1].split()[19])
    request = dict(kind='cpu', pid=target.pid, start_ticks=ticks, duration_ms=500)
    observer = client('observe')
    for spec in (request, dict(kind='fd_flow', duration_ms=100)):
        refused(observer.tool('request_system_capture', **spec), 'AgentScopeDenied')
    check('observe refusal does not attach or audit acceptance', tracer() == 0 and not observer.inspect('get_system_capture')['audit'])
    listed = observer.call('tools/list')['result']['tools']
    special = {t['name'] for t in listed if t['annotations']['xodbSessionAccess'] == 'requester'}
    check('request-only tools are visible, not labelled read-only', special == {'request_system_capture', 'cancel_system_capture'} and
          all(not t['annotations']['readOnlyHint'] for t in listed if t['name'] in special))
    check('redaction control actually contains synthetic token', 'deadline' in observer.inspect('get_system_capture')['shutdown'])
    previous_user = os.environ.get('USER')
    try:
        os.environ['USER'] = 'deadline'  # Synthetic identity, never a real host name in source.
        redacted = client('observe', options=('--redact',))
    finally:
        if previous_user is None:
            os.environ.pop('USER', None)
        else:
            os.environ['USER'] = previous_user
    hidden = redacted.inspect('get_system_capture')
    check('new overview replies pass shared redaction policy', 'deadline' not in hidden['shutdown'] and 'user' in hidden['shutdown'], hidden)

    stale = client()
    stale.inspect('request_system_capture', **{**request, 'start_ticks': ticks + 1})
    failure = terminal(stale)
    check('identity checked before attachment', failure['request']['phase'] == 'failed' and failure['request']['reason'] == 'ProcessIdentityChanged' and tracer() == 0, failure)

    bounded = client()
    stats(bounded, 'before')
    bounded.inspect('request_system_capture', **request)
    eventually(tracer, lambda pid: pid == bounded.p.pid)
    stats(bounded, 'active')
    # No MCP calls while waiting: a reader must not be the deadline clock.
    eventually(tracer, lambda pid: pid == 0)
    done = terminal(bounded)
    stats(bounded, 'after')
    check('owner enforces deadline without MCP polling', done['request']['phase'] == 'complete', done)
    profile = bounded.inspect('get_system_capture_result', request_id=done['result_id'])['capture']
    check('completed CPU evidence is readable and bounded', profile['stored_samples'] > 0 and profile['sample_limit'] == 16384 and profile['duration_ms'] == 500, profile)
    samples = bounded.inspect('get_system_capture_result', request_id=done['result_id'], view='samples', capture_id=profile['id'], revision=profile['revision'], limit=1)
    check('sample evidence survives detach', len(samples['samples']) == 1 and target.poll() is None)

    owner = client(options=('--session-socket', str(work / 's')))
    first, second = Peer(work / 's'), Peer(work / 's')
    accepted = first.inspect('request_system_capture', **{**request, 'duration_ms': 10_000})
    request_id = accepted['request']['id']
    eventually(tracer, lambda pid: pid == owner.p.pid)
    refused(second.tool('cancel_system_capture', request_id=request_id), 'CaptureRequesterRequired')
    refused(second.tool('get_system_capture_result', request_id=request_id), 'CaptureRequesterRequired')
    refused(owner.tool('get_system_capture_result', request_id=request_id), 'CaptureRequesterRequired')
    first.close()
    revoked = terminal(owner)
    check('shared requester disconnect revokes and detaches', revoked['request']['phase'] == 'revoked' and revoked['request']['reason'] == 'requester_disconnected' and tracer() == 0, revoked)
    check('audit retains requester identity, scope and transitions', any(row['phase'] == 'running' and row['spec']['pid'] == target.pid and row['spec']['kind'] == 'cpu' for row in revoked['audit']) and accepted['request']['caller']['agent']['client'] > 0)

    eof = client()
    eof.inspect('request_system_capture', **{**request, 'duration_ms': 10_000})
    eventually(tracer, lambda pid: pid == eof.p.pid)
    eof.close()
    clients.remove(eof)
    eventually(tracer, lambda pid: pid == 0)
    check('EOF stops capture and leaves owned target alive', target.poll() is None)
finally:
    for peer in peers:
        peer.close()
    for index, c in enumerate(clients):
        (work / f'client-{index}.json').write_text(json.dumps(c.transcript, indent=2))
        c.close()
    if target.poll() is None:
        target.terminate()
    target.wait(timeout=5)
    (work / 'footprints.json').write_text(json.dumps(dict(load=os.getloadavg(), cpus=len(os.sched_getaffinity(0)), phases=footprints), indent=2))
report = dict(status='pass', checks=checks, seconds=time.monotonic() - started)
(work / 'results.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report))
