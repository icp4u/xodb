#!/usr/bin/env python3
"""X2: owned live child, bounded ring, HTTP/1 and DNS over loopback."""
import errno
import os
import subprocess
import tempfile
import time
from pathlib import Path

from client import Client
from helpers.tasks import children as task_children


root = Path(__file__).resolve().parents[1]
os.chdir(root)
tool = root / 'tests/fixtures/capture-tool.py'
work = Path(tempfile.mkdtemp(prefix='xodb-live-evidence-', dir=os.environ.get('TMPDIR')))
pid_file = work / 'capture.pid'
os.environ['XODB_FAKE_CAPTURE_PID_FILE'] = str(pid_file)
options = ['--live-capture', 'lo', '--capture-tool', str(tool), '--capture-ring-bytes', '65536']


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError as error:
        if error.errno == errno.ESRCH:
            return False
        raise


def parent_of(pid):
    stat = Path(f'/proc/{pid}/stat').read_text()
    return int(stat[stat.rindex(')') + 2:].split()[1])


def running(pid):
    # An exited process may stay a zombie until its (sandbox) reaper runs.
    try:
        stat = Path(f'/proc/{pid}/stat').read_text()
    except FileNotFoundError:
        return False
    return stat[stat.rindex(')') + 2] != 'Z'


def wait_gone(pid, seconds=5):
    deadline = time.monotonic() + seconds
    while running(pid) and time.monotonic() < deadline:
        time.sleep(0.01)
    return not running(pid)


def wait_streams(client):
    deadline = time.monotonic() + 10
    while True:
        streams = client.inspect('list_streams')['streams']
        if len(streams) == 2 and streams[0]['records'] >= 7:
            return streams
        assert time.monotonic() < deadline, streams
        time.sleep(0.01)


client = Client('observe', None, options=options)
try:
    streams = wait_streams(client)
    network, derived = streams
    live = network['live_capture']
    assert network['kind'] == 'network' and network['label'] == 'live capture', network
    assert live['state'] == 'capturing' and live['producer'] == 'tcpdump', live
    assert live['version_major'] == 4 and live['version_minor'] == 99, live
    assert live['ring_limit_bytes'] == 65536 and live['ring_bytes'] <= 65536, live
    assert live['captured_records'] == 327 and live['ring_dropped_records'] > 0, live
    assert live['retained_records'] < live['captured_records'], live
    assert derived['kind'] == 'protocol' and derived['derived_from'] == 1, derived
    assert derived['http_records'] == 2 and derived['dns_records'] == 2, derived

    http = client.inspect('query_stream', stream_id=2, kind='http_request')['records']
    assert len(http) == 1 and http[0]['method'] == 'GET' and http[0]['target'] == '/owned', http
    response = client.inspect('query_stream', stream_id=2, kind='http_response')['records']
    assert len(response) == 1 and response[0]['status'] == 204, response
    assert response[0]['request'] == http[0]['index'] and response[0]['latency_ns'] == 40000, response
    query = client.inspect('query_stream', stream_id=2, kind='dns_query', dns_name='unit.test')['records']
    answer = client.inspect('query_stream', stream_id=2, kind='dns_response', rcode=0)['records']
    assert len(query) == 1 and query[0]['dns_name'] == 'unit.test' and query[0]['dns_type'] == 1, query
    assert len(answer) == 1 and answer[0]['request'] == query[0]['index'], answer
    assert answer[0]['latency_ns'] == 25000 and answer[0]['dns_rcode'] == 0, answer
    joined = client.inspect('correlate', stream_id=2, record=http[0]['index'])
    assert joined['source_record'] == http[0]['source_record'] and joined['basis'] == 'none', joined

    deadline = time.monotonic() + 2
    while not pid_file.exists():
        assert time.monotonic() < deadline
        time.sleep(0.01)
    child_pid = int(pid_file.read_text())
    assert parent_of(child_pid) == live['pid'] and alive(child_pid), (child_pid, live)
finally:
    client.close()

assert wait_gone(child_pid), f'owned capture child {child_pid} survived its session'

# SIGKILL of xodb: the tool must not outlive it even when its parent-death
# signal was cleared (capability exec). The supervisor sees its life pipe close.
pid_file.unlink()
# Adopt the orphaned supervisor so this test, not the runner, reaps it.
import ctypes
ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER
os.environ['XODB_FAKE_CAPTURE_NO_PDEATHSIG'] = '1'
killed = Client('observe', None, options=options)
try:
    wait_streams(killed)
    deadline = time.monotonic() + 2
    while not pid_file.exists():
        assert time.monotonic() < deadline
        time.sleep(0.01)
    orphan_pid = int(pid_file.read_text())
    supervisor_pid = parent_of(orphan_pid)
    # The agent lane gives xodb a second owned child. SIGKILL reparents both
    # it and the capture supervisor to this subreaper, so retain every direct
    # child now and reap each one after checking the capture exit rule.
    adopted_pids = set(task_children(killed.p.pid))
    assert supervisor_pid in adopted_pids, (supervisor_pid, adopted_pids)
    os.kill(killed.p.pid, 9)
    killed.p.wait(timeout=5)
    assert wait_gone(orphan_pid), f'capture tool {orphan_pid} outlived a SIGKILLed xodb'
    assert wait_gone(supervisor_pid), f'capture supervisor {supervisor_pid} outlived a SIGKILLed xodb'
    for pid in sorted(adopted_pids):
        assert wait_gone(pid), f'owned child {pid} outlived a SIGKILLed xodb'
        os.waitpid(pid, 0)
finally:
    del os.environ['XODB_FAKE_CAPTURE_NO_PDEATHSIG']
    if killed.p.poll() is None:
        killed.close()

# A tool below the explicit tcpdump version floor is refused before capture.
old_env = os.environ.copy()
old_env['XODB_FAKE_CAPTURE_OLD'] = '1'
old_env.pop('XODB_FAKE_CAPTURE_PID_FILE', None)
rejected = subprocess.run(
    [os.environ.get('XODB_BIN', './zig-out/bin/xodb'), '--headless', '--mcp',
     '--agent-scope', 'observe', '--live-capture', 'lo', '--capture-tool', str(tool)],
    input=b'', stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=old_env, timeout=10,
)
assert rejected.returncode != 0 and b'UnsupportedCaptureToolVersion' in rejected.stderr, rejected.stderr

# A tool that exits at once (no capture permission) is refused with a hint.
denied_env = os.environ.copy()
denied_env['XODB_FAKE_CAPTURE_DENIED'] = '1'
denied_env.pop('XODB_FAKE_CAPTURE_PID_FILE', None)
denied = subprocess.run(
    [os.environ.get('XODB_BIN', './zig-out/bin/xodb'), '--headless', '--mcp',
     '--agent-scope', 'observe', '--live-capture', 'lo', '--capture-tool', str(tool)],
    input=b'', stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=denied_env, timeout=10,
)
assert denied.returncode != 0 and b'LiveCaptureStartFailed' in denied.stderr, denied.stderr
assert b'capture permission' in denied.stderr and b'status 1' in denied.stderr, denied.stderr

# Redaction withholds private protocol text and refuses private-text filters.
redacted = Client('observe', None, options=[*options, '--redact'])
try:
    wait_streams(redacted)
    rows = redacted.inspect('query_stream', stream_id=2, kind='http_request')['records']
    assert len(rows) == 1 and rows[0]['method'] is None and rows[0]['target'] is None, rows
    assert rows[0]['private_fields'] == 'redacted', rows
    refused = redacted.tool('query_stream', stream_id=2, dns_name='unit.test')
    assert refused['result']['isError'] and refused['result']['content'][0]['text'] == 'RawPayloadRedacted', refused
finally:
    redacted.close()

print('live network evidence: owned child, bounded ring, HTTP/1, DNS, privacy and exit verified')
