#!/usr/bin/env python3
"""Fast bounded fd-flow request on one owned pipe reader, then silence.

Permission refusal is checked, but reported separately as blocked live-capture
coverage. --privileged uses only a scoped owned fixture and changes no policy.
"""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time
from client import Client

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--privileged', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('capture-flow-' + str(time.time_ns())[-8:])
work.mkdir(parents=True)
started = time.monotonic()
# Explicit read/write, not a utility that may choose splice/copy_file_range.
fixture = subprocess.Popen([sys.executable, '-c', 'import os\nos.write(1,b"r")\nwhile data := os.read(0,4096):\n os.write(1,data)\n'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
if not select.select([fixture.stdout], [], [], 5)[0] or fixture.stdout.read(1) != b'r':
    raise AssertionError('owned reader did not become ready')
client = None
report = dict(status='failed', capture='not_started', checks=[], footprints=[])


def check(name, condition, value=None):
    if not condition:
        raise AssertionError((name, value))
    report['checks'].append(name)
    print('PASS ' + name, flush=True)


def until(probe, predicate):
    deadline = time.monotonic() + 8
    while True:
        value = probe()
        if predicate(value):
            return value
        if time.monotonic() >= deadline:
            raise AssertionError(('timeout', value))
        time.sleep(.005)


def footprint(phase):
    pending = [client.p.pid]
    owner = None
    while pending:
        pid = pending.pop()
        if Path(f'/proc/{pid}/comm').read_text().strip() == 'xodb':
            owner = pid
            break
        pending += [int(value) for value in Path(f'/proc/{pid}/task/{pid}/children').read_text().split()]
    if owner is None:
        raise AssertionError('owned xodb process not found for measurement')
    fields = Path(f'/proc/{owner}/stat').read_text().rsplit(')', 1)[1].split()
    report['footprints'].append(dict(phase=phase, at=time.monotonic(), cpu_ticks=int(fields[11])+int(fields[12]), rss_bytes=int(fields[21])*os.sysconf('SC_PAGE_SIZE')))


class Scoped(Client):
    def __init__(self):
        self.id = 0
        self.transcript = []
        self.runtime_agent = False
        command = [str(root / 'zig-out/bin/xodb'), '--overview', '--headless', '--mcp', '--agent-scope', 'control', '--graph-pid', str(fixture.pid)]
        self.p = subprocess.Popen((['sudo', '-n', '--'] if args.privileged else []) + command,
                                  bufsize=0, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.call('initialize', dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='capture-flow-test', version='1')))
        self.p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')


try:
    client = Scoped()
    footprint('before')
    request = client.inspect('request_system_capture', kind='fd_flow', duration_ms=1000, interval_ms=250)
    request_id = request['request']['id']
    def flow():
        response = client.tool('get_fd_activity', limit=1)
        if response['result']['isError']:
            check('publication busy is explicit', response['result']['content'][0]['text'] == 'FdCacheBusy', response)
            return None
        return response['result']['structuredContent']['system_flow']
    ready = until(flow, lambda value: value and (value['running'] or value['state'] not in ('ok', 'pending')))
    footprint('active_or_denied')
    if ready['running']:
        check('scoped trace really opened', ready['active_cpus'] > 0 and 'explicit process' in ready['scope'], ready)
        payload = b'x' * 4096
        fixture.stdin.write(payload)
        check('owned pipe burst returns', bool(select.select([fixture.stdout], [], [], 5)[0]))
        received = b''
        while len(received) < len(payload):
            received += os.read(fixture.stdout.fileno(), len(payload)-len(received))
        check('burst is exact before silence', received == payload)
    done = until(lambda: client.inspect('get_system_capture'), lambda value: value['request']['phase'] not in ('pending', 'approved', 'running') and not value['cleanup_pending'])
    result = client.inspect('get_system_capture_result', request_id=request_id, limit=128)
    footprint('after')
    report['result'] = result
    if ready['running']:
        check('deadline stops exact tracing', done['request']['phase'] == 'complete' and not flow()['running'], done)
        check('burst then silence retains byte evidence', result['read_bytes'] + result['write_bytes'] + result['unknown_read'] + result['unknown_write'] > 0, result)
        report['capture'] = 'passed'
    else:
        check('permission failure is explicit, not a completed capture', done['request']['phase'] == 'failed' and ready['state'] == 'needs privilege' and bool(result['failure']), (ready, done, result))
        report['capture'] = 'blocked'
        report['blocker'] = result['failure']
        if args.privileged:
            raise AssertionError(('privileged capture unavailable', result))
    check('owned target remains alive', fixture.poll() is None)
    report['status'] = 'pass'
finally:
    if client:
        (work / 'rpc.json').write_text(json.dumps(client.transcript, indent=2))
        client.close()
    fixture.stdin.close()
    fixture.wait(timeout=5)
    report.update(seconds=time.monotonic()-started, load=os.getloadavg(), cpus=len(os.sched_getaffinity(0)))
    (work / 'results.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report))
