#!/usr/bin/env python3
"""X2: owned live child, bounded ring, HTTP/1 and DNS over loopback."""
import errno
import importlib.util
import json
import os
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path

from client import Client, runtime_agent_args
from helpers.tasks import children as task_children


root = Path(__file__).resolve().parents[1]
os.chdir(root)
tool = root / 'tests/fixtures/capture-tool.py'
work = Path(tempfile.mkdtemp(prefix='xodb-live-evidence-', dir=os.environ.get('TMPDIR')))
pid_file = work / 'capture.pid'
os.environ['XODB_FAKE_CAPTURE_PID_FILE'] = str(pid_file)
options = ['--live-capture', 'lo', '--capture-tool', str(tool), '--capture-ring-bytes', '65536']
private_fields = 'available only to the direct observer that opened this stream'
private_error = 'PrivateEvidenceUnavailable'
secrets = (b'/owned', b'unit.test')


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


def wait_streams_call(call):
    deadline = time.monotonic() + 10
    while True:
        streams = call('list_streams')['streams']
        if len(streams) == 2 and streams[0]['records'] >= 7:
            return streams
        assert time.monotonic() < deadline, streams
        time.sleep(0.01)


def wait_streams(client):
    return wait_streams_call(client.inspect)


def assert_private_withheld(call):
    http = call('query_stream', stream_id=2, kind='http_request')['records']
    assert len(http) == 1 and http[0]['method'] is None and http[0]['target'] is None, http
    assert http[0]['private_fields'] == private_fields, http
    dns = call('query_stream', stream_id=2, kind='dns_query')['records']
    assert len(dns) == 1 and dns[0]['dns_name'] is None, dns
    assert dns[0]['private_fields'] == private_fields, dns


def assert_private_refused(reply):
    result = reply.get('result', {})
    assert result.get('isError') and result['content'][0]['text'] == private_error, reply


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
    raw = client.inspect('query_stream', stream_id=1, include_raw=True, limit=1)['records']
    assert len(raw) == 1 and raw[0]['raw_hex'], raw
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

# The runtime agent assigns private evidence to the stdio observe connection
# that opened the capture. Controllers and every transport peer stay outside
# that ownership boundary, even when they request observe scope.
agent_args = runtime_agent_args()
if agent_args:
    controller = Client('control', None, options=options)
    try:
        wait_streams(controller)
        assert_private_withheld(controller.inspect)
        assert_private_refused(controller.tool('query_stream', stream_id=1, include_raw=True))
    finally:
        controller.close()
    controller_stderr = controller.p.stderr.read()
    assert not any(secret in controller_stderr for secret in secrets), controller_stderr

    listen_socket = socket.socket()
    listen_socket.bind(('127.0.0.1', 0))
    listen_port = listen_socket.getsockname()[1]
    listen_socket.close()
    listener = subprocess.Popen(
        [os.environ.get('XODB_BIN', './zig-out/bin/xodb'), '--headless', '--mcp',
         '--agent-scope', 'observe', '--listen', f'127.0.0.1:{listen_port}',
         *agent_args, *options],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    remote = None
    try:
        deadline = time.monotonic() + 5
        while True:
            assert listener.poll() is None, listener.stderr.read().decode()
            try:
                remote = socket.create_connection(('127.0.0.1', listen_port), timeout=.2)
                break
            except OSError:
                assert time.monotonic() < deadline, 'listen endpoint did not accept'
                time.sleep(.01)
        remote.settimeout(5)
        with remote, remote.makefile('rwb') as wire:
            serial = [0]

            def remote_call(method, params=None):
                serial[0] += 1
                message = {'jsonrpc': '2.0', 'id': serial[0], 'method': method,
                           'params': params or {}}
                wire.write((json.dumps(message, separators=(',', ':')) + '\n').encode())
                wire.flush()
                while True:
                    line = wire.readline()
                    assert line, 'listen endpoint closed before replying'
                    reply = json.loads(line)
                    if reply.get('id') == serial[0]:
                        return reply

            def remote_raw(name, **args):
                return remote_call('tools/call', {'name': name, 'arguments': args})

            def remote_tool(name, **args):
                reply = remote_raw(name, **args)
                assert 'error' not in reply and not reply['result']['isError'], reply
                return reply['result']['structuredContent']

            initialized = remote_call('initialize', {
                'protocolVersion': '2025-06-18', 'capabilities': {},
                'clientInfo': {'name': 'live-evidence-listen', 'version': '1'},
            })
            assert initialized.get('result', {}).get('protocolVersion') == '2025-06-18', initialized
            wire.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            wire.flush()
            wait_streams_call(remote_tool)
            assert_private_withheld(remote_tool)
            assert_private_refused(remote_raw('query_stream', stream_id=1, include_raw=True))
    finally:
        if remote is not None:
            remote.close()
        if listener.poll() is None:
            listener.send_signal(signal.SIGINT)
        assert listener.wait(timeout=10) == 0, listener.stderr.read().decode()
    listen_stderr = listener.stderr.read()
    assert not any(secret in listen_stderr for secret in secrets), listen_stderr

    spec = importlib.util.spec_from_file_location('live_shared', root / 'tests/shared-sessions.py')
    assert spec is not None and spec.loader is not None
    shared = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shared)
    shared_dir = work / 'shared'
    shared_dir.mkdir(mode=0o700)
    host = type('SharedHost', (), {'path': (shared_dir / 's').resolve(), 'clients': []})()
    shared_log = shared_dir / 'server.log'
    peers = []
    with shared_log.open('wb') as log:
        host.proc = subprocess.Popen(
            [os.environ.get('XODB_BIN', './zig-out/bin/xodb'), '--headless',
             '--session-socket', str(host.path), '--agent-scope', 'observe',
             *agent_args, *options],
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
        )
        try:
            for label in ('live-evidence-peer-1', 'live-evidence-peer-2'):
                peer = shared.Client(host, label)
                peers.append(peer)
                wait_streams_call(peer.tool)
                assert_private_withheld(peer.tool)
                assert_private_refused(peer.raw('query_stream', stream_id=1, include_raw=True))
        finally:
            for peer in reversed(peers):
                peer.close()
            if host.proc.poll() is None:
                host.proc.send_signal(signal.SIGINT)
            assert host.proc.wait(timeout=10) == 0
    shared_output = shared_log.read_bytes()
    assert not any(secret in shared_output for secret in secrets), shared_output

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
