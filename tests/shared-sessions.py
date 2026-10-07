#!/usr/bin/env python3
"""Real Unix-socket MCP clients share a session, retained jobs and a control lease.

XODB_BIN selects the application; XODB_RUNTIME_AGENT selects its optional local
C agent. Artifacts use XODB_TEST_TMPDIR, otherwise Python's TMPDIR-aware default.
No inherited graphical session, privilege change or unrelated process is used.
"""
import json
import os
from pathlib import Path
import select
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time


TIMEOUT = 5
DERIVED_READS = {'get_flamegraph', 'get_profile_frame', 'get_profile_stack',
                 'get_allocation_lifetimes', 'get_allocation_flamegraph'}


def eventually(probe, predicate, label, timeout=TIMEOUT):
    deadline = time.monotonic() + timeout
    while True:
        result = probe()
        if predicate(result):
            return result
        assert time.monotonic() < deadline, (label, result)
        time.sleep(.01)


def expect_error(reply, name):
    assert reply.get('result', {}).get('isError'), reply
    assert reply['result']['content'][0]['text'] == name, reply


def expect_invalid(reply):
    assert reply.get('error', {}).get('code') == -32602 or reply.get('result', {}).get('isError'), reply


def process_identity(pid):
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        return fields[19], fields[0]  # Linux starttime and state; PID reuse is distinct.
    except FileNotFoundError:
        return None


class Client:
    """A framed socket reader: recv boundaries need not match JSON lines."""
    def __init__(self, server, label, handshake=True):
        self.server, self.label = server, label
        self.serial = 0
        self.pending = bytearray()
        self.transcript = []
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(TIMEOUT)
        self.closed = False
        server.clients.append(self)
        try:
            self.sock.connect(str(server.path))
            if handshake:
                reply = self.call('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                                  'clientInfo': {'name': label, 'version': '1'}})
                assert reply.get('result', {}).get('protocolVersion') == '2025-06-18', reply
                self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        except BaseException:
            self.close()
            raise

    def send(self, message):
        self.sock.sendall((json.dumps(message, separators=(',', ':')) + '\n').encode())

    def receive(self, ident, timeout=TIMEOUT):
        deadline = time.monotonic() + timeout
        while True:
            while b'\n' in self.pending:
                line, _, remainder = self.pending.partition(b'\n')
                self.pending = bytearray(remainder)
                reply = json.loads(line)
                if 'id' not in reply:
                    self.transcript.append({'notification': reply})
                    continue
                assert reply['id'] == ident, (ident, reply)
                return reply
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([self.sock], [], [], remaining)[0], f'{self.label}: response timeout'
            data = self.sock.recv(65536)
            if not data:
                raise ConnectionError(f'{self.label}: server closed connection')
            self.pending.extend(data)
            assert len(self.pending) <= 2 * 1024 * 1024, 'unbounded MCP reply'

    def call(self, method, params=None):
        self.serial += 1
        message = {'jsonrpc': '2.0', 'id': self.serial, 'method': method, 'params': params or {}}
        self.send(message)
        reply = self.receive(self.serial)
        self.transcript.append({'request': message, 'response': reply})
        return reply

    def raw(self, name, **args):
        return self.call('tools/call', {'name': name, 'arguments': args})

    def tool(self, name, **args):
        reply = self.raw(name, **args)
        assert 'error' not in reply and not reply['result']['isError'], reply
        return reply['result']['structuredContent']

    def session(self):
        return self.tool('get_session')

    def info(self):
        return self.tool('get_session_clients')

    def claim(self, ttl_ms=30000):
        return self.tool('claim_session_control', generation=self.session()['generation'], ttl_ms=ttl_ms)

    def action(self, name, **args):
        return self.tool(name, generation=self.session()['generation'], **args)

    def close(self):
        if not self.closed:
            self.closed = True
            self.sock.close()


class Server:
    def __init__(self, root, work, binary, fixture, scope, options=(), fixture_args=('w',)):
        self.root, self.binary, self.scope = root, binary, scope
        self.work = work / scope
        self.work.mkdir(mode=0o755)
        self.runtime = self.work / 'run'
        self.runtime.mkdir(mode=0o700)
        self.path = self.runtime / 's'
        assert len(os.fsencode(self.path)) < 108, 'Select a shorter XODB_TEST_TMPDIR for Unix sockets'
        self.clients = []
        self.target_pid = None
        self.target_identity = None
        self.log = (self.work / 'server.log').open('wb')
        args = [str(binary), '--headless', '--session-socket', str(self.path), '--agent-scope', scope]
        agent = os.environ.get('XODB_RUNTIME_AGENT')
        if agent:
            args += ['--runtime-agent', str(Path(agent).resolve())]
        args += [*options, '--', str(fixture), *fixture_args]
        env = dict(os.environ)
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK'):
            env.pop(key, None)
        self.proc = subprocess.Popen(args, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                     stdout=self.log, stderr=subprocess.STDOUT)
        try:
            def ready():
                assert self.proc.poll() is None, (args, (self.work / 'server.log').read_text())
                return self.path.exists()
            eventually(ready, bool, 'socket listener readiness', timeout=10)
            assert stat.S_ISSOCK(self.path.stat().st_mode)
        except BaseException:
            self.close()
            raise

    def remember_target(self, snapshot):
        self.target_pid = snapshot['pid']
        self.target_identity = process_identity(self.target_pid)
        assert self.target_identity and self.target_identity[1] != 'Z', snapshot

    def target_alive(self):
        identity = process_identity(self.target_pid)
        return identity is not None and identity[0] == self.target_identity[0] and identity[1] != 'Z'

    def stop_and_check(self):
        self.proc.send_signal(signal.SIGINT)
        assert self.proc.wait(timeout=TIMEOUT) == 0, (self.work / 'server.log').read_text()
        eventually(self.path.exists, lambda exists: not exists, 'owned socket unlink')
        eventually(self.target_alive, lambda alive: not alive, 'owned launched target cleanup')

    def close(self):
        for client in self.clients:
            client.close()
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        # Failure cleanup is restricted to this launched PID and its birth identity.
        if self.target_pid and self.target_alive():
            os.kill(self.target_pid, signal.SIGKILL)
        self.log.close()
        (self.work / 'transcript.json').write_text(json.dumps(
            [{'client': c.label, 'messages': c.transcript} for c in self.clients], indent=2) + '\n')


def no_controller(client):
    return eventually(client.info, lambda value: value['controller_id'] is None, 'lease released/expired')


def job_done(client, ident):
    return eventually(lambda: client.tool('get_inspection', id=ident, limit=2),
                      lambda value: value['state'] not in ('pending', 'running'), 'retained job', timeout=10)


def attributed_action(observer, action, client_id):
    audit = observer.tool('get_audit')['actions'][-1]
    assert audit['actor'] == 'agent' and audit['action'] == action, audit
    assert audit['client_id'] == client_id, audit
    assert observer.session()['last_action'] == audit
    # These observer reads must neither append an action nor change its owner.
    assert observer.tool('get_audit')['actions'][-1] == audit
    return audit


def listed_tools(client):
    reply = client.call('tools/list')
    assert 'error' not in reply, reply
    return {tool['name'] for tool in reply['result']['tools']}


def derived_view_guards(observer, error='ControlLeaseRequired'):
    # These read-like tools can create or replace retained analysis jobs. They
    # require ownership before resource lookup, even with no capture available.
    names = listed_tools(observer)
    assert not names.intersection(DERIVED_READS), names.intersection(DERIVED_READS)
    assert {'get_function_graph', 'get_profile_stack_coverage', 'get_profile_comparison'} <= names
    assert 'start_inspection' not in names
    for name in sorted(DERIVED_READS):
        expect_error(observer.raw(name), error)
    assert 'get_imported_flamegraph' not in names
    unknown = observer.raw('get_imported_flamegraph')
    assert unknown.get('error') == {'code': -32602, 'message': 'UnknownTool'}, unknown


def duplicate_listener(server, client):
    before = server.path.stat()
    args = [str(server.binary), '--headless', '--session-socket', str(server.path), '--agent-scope', 'control']
    result = subprocess.run(args, cwd=server.root, stdin=subprocess.DEVNULL, capture_output=True, timeout=TIMEOUT)
    (server.work / 'duplicate-listener.log').write_bytes(result.stdout + result.stderr)
    assert result.returncode != 0, result
    after = server.path.stat()
    assert (before.st_dev, before.st_ino) == (after.st_dev, after.st_ino), 'second server replaced first socket'
    assert client.session()['pid'] == server.target_pid


def isolated_bad_clients(server, observer):
    malformed = Client(server, 'partial-json', handshake=False)
    try:
        malformed.sock.sendall(b'{"jsonrpc":')
        assert observer.session()['pid'] == server.target_pid
        malformed.sock.sendall(b'nope}\n')
        # Either a protocol error or local disconnect is acceptable. Neither may
        # affect other clients, the target, or the retained session.
        try:
            malformed.sock.settimeout(1)
            malformed.sock.recv(4096)
        except (ConnectionError, socket.timeout):
            pass
        assert observer.session()['pid'] == server.target_pid
    finally:
        malformed.close()
    oversized = Client(server, 'oversized-json', handshake=False)
    try:
        try:
            oversized.sock.sendall(b'x' * 131072)
        except (BrokenPipeError, ConnectionResetError):
            pass
        assert observer.session()['pid'] == server.target_pid
    finally:
        oversized.close()
    slow = Client(server, 'slow-reader')
    timings = []
    try:
        slow.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
        # Large tools/list replies exceed the receive window; this client never
        # drains them. Other clients must continue to receive timely replies.
        messages = []
        for _ in range(256):
            slow.serial += 1
            messages.append(json.dumps({'jsonrpc': '2.0', 'id': slow.serial, 'method': 'tools/list', 'params': {}}))
        try:
            slow.sock.sendall(('\n'.join(messages) + '\n').encode())
        except (BrokenPipeError, ConnectionResetError):
            pass
        for _ in range(8):
            started = time.monotonic()
            assert observer.session()['pid'] == server.target_pid
            timings.append(time.monotonic() - started)
            time.sleep(.025)
        assert max(timings) < 2, timings
    finally:
        slow.close()
    return round(max(timings) * 1000, 3)


def client_limit(server, observer):
    original = {row['id'] for row in observer.info()['clients']}
    added = []
    try:
        for index in range(8 - len(original)):
            added.append(Client(server, f'capacity-{index}'))
        info = eventually(observer.info, lambda value: len(value['clients']) == 8, 'eight accepted clients')
        assert len({row['id'] for row in info['clients']}) == 8, info
        rejected = False
        try:
            extra = Client(server, 'ninth-client')
        except (ConnectionError, OSError, AssertionError):
            rejected = True
        else:
            extra.close()
        assert rejected, 'ninth client completed a successful handshake'
        assert len(observer.info()['clients']) == 8
        assert observer.session()['pid'] == server.target_pid
    finally:
        for client in added:
            client.close()
    eventually(observer.info, lambda value: {row['id'] for row in value['clients']} == original, 'capacity reclaimed')


def journal(client):
    client.claim()
    for _ in range(70):
        client.tool('release_session_control')
        client.claim()
    status = client.info()
    assert status['oldest_event_sequence'] > 1, status
    first = client.tool('get_session_events', after=0, limit=17)
    assert first['gap'] is True and len(first['events']) == 17, first
    assert first['next'] == first['events'][-1]['sequence'], first
    assert first['oldest_available'] == status['oldest_event_sequence'], (first, status)
    assert first['latest_sequence'] == status['event_sequence'], (first, status)
    events = list(first['events'])
    cursor = events[-1]['sequence']
    while cursor < first['latest_sequence']:
        page = client.tool('get_session_events', after=cursor, limit=17)
        assert not page['gap'] and page['events'], page
        assert all(item['sequence'] > cursor for item in page['events']), page
        assert page['next'] == page['events'][-1]['sequence'], page
        events.extend(page['events'])
        cursor = events[-1]['sequence']
    sequences = [event['sequence'] for event in events]
    assert len(events) == 128 and sequences == sorted(set(sequences)), events
    assert sequences[0] == first['oldest_available'] and sequences[-1] == first['latest_sequence']
    kinds = {'connected', 'disconnected', 'acquired', 'released', 'expired', 'scope_changed'}
    assert all(event['kind'] in kinds for event in events)
    assert all('time_ns' in event and 'client_id' in event for event in events)
    assert [event['time_ns'] for event in events] == sorted(event['time_ns'] for event in events)
    empty = client.tool('get_session_events', after=cursor, limit=128)
    assert empty['events'] == [] and not empty['gap'] and empty['next'] == cursor, empty
    expect_invalid(client.raw('get_session_events', after=cursor + 1))
    for limit in (0, 129):
        expect_invalid(client.raw('get_session_events', limit=limit))
    return {'retained_events': len(events), 'oldest': sequences[0], 'latest': sequences[-1]}


def control_checks(server):
    controller, one, two = [Client(server, label) for label in ('controller', 'observer-1', 'observer-2')]
    initial = eventually(controller.session, lambda value: value['state'] == 'stopped', 'initial target stop')
    server.remember_target(initial)
    tid = initial['threads'][0]['tid']
    ids = [client.info()['client_id'] for client in (controller, one, two)]
    assert len(set(ids)) == 3
    assert {row['id'] for row in one.info()['clients']} == set(ids)
    assert one.info()['controller_id'] is None
    derived_view_guards(one)
    for name, args in [('continue', {}), ('set_breakpoint', {'symbol': 'change_value'}),
                       ('start_inspection', {'tid': tid, 'registers': True, 'stack': False})]:
        expect_error(one.raw(name, generation=one.session()['generation'], **args), 'ControlLeaseRequired')
    # Acquiring a lease is independent of the running target's snapshot.
    one.tool('claim_session_control', generation=initial['generation'] + 1)
    one.tool('release_session_control')
    one.tool('claim_session_control')
    one.tool('release_session_control')
    for ttl in (0, 99, 60001):
        expect_invalid(controller.raw('claim_session_control', generation=controller.session()['generation'], ttl_ms=ttl))
    controller.claim(ttl_ms=1000)
    assert one.info()['controller_id'] == ids[0]
    assert DERIVED_READS <= listed_tools(controller)
    derived_view_guards(two)
    expect_error(one.raw('claim_session_control', generation=one.session()['generation']), 'ControllerBusy')
    expect_error(one.raw('release_session_control'), 'ControlLeaseRequired')
    time.sleep(.05)
    controller.claim(ttl_ms=1500)
    renewed = two.info()
    assert renewed['controller_id'] == ids[0] and 1000 < renewed['lease_remaining_ms'] <= 1500, renewed
    controller.tool('release_session_control')
    no_controller(one)
    one.claim(ttl_ms=100)
    no_controller(two)
    expect_error(one.raw('continue', generation=one.session()['generation']), 'ControlLeaseRequired')
    controller.claim()

    # A real mutation changes generation; a stale request cannot execute after it.
    before = controller.session()['generation']
    breakpoint = controller.action('set_breakpoint', symbol='change_value')['id']
    assert controller.session()['generation'] > before
    audit = attributed_action(one, 'set_breakpoint', ids[0])
    expect_error(two.raw('remove_breakpoint', generation=two.session()['generation'], id=breakpoint), 'ControlLeaseRequired')
    expect_error(controller.raw('continue', generation=before), 'StaleSnapshot')
    assert attributed_action(two, 'set_breakpoint', ids[0]) == audit
    registers = one.tool('get_registers', tid=tid)['registers']
    pc = registers['rip']
    expect_error(controller.raw('write_memory', generation=controller.session()['generation'], address=pc, hex='90'), 'AgentScopeDenied')
    assert one.tool('get_registers', tid=tid)['registers'] == registers
    controller.action('remove_breakpoint', id=breakpoint)
    started = controller.action('start_inspection', tid=tid, registers=True, stack=False)
    saved = job_done(two, started['id'])
    assert saved['state'] == 'completed' and saved['items'], saved
    for name in ('cancel_inspection', 'release_inspection'):
        expect_error(one.raw(name, id=started['id']), 'ControlLeaseRequired')
    controller.claim(ttl_ms=100)
    no_controller(two)
    expired = two.tool('get_inspection', id=started['id'])
    assert expired['state'] == 'completed' and expired['identity'] == saved['identity']
    assert expired['items'] == saved['items'], expired
    controller.claim()
    replay_after = two.info()['event_sequence']
    controller.action('continue')
    eventually(one.session, lambda value: value['state'] == 'running', 'fixture running')
    controller.close()
    no_controller(one)
    assert server.target_alive() and one.session()['state'] == 'running'
    assert job_done(two, started['id'])['items'] == saved['items']
    assert two.tool('get_inspection', id=started['id'])['identity'] == saved['identity']
    reconnect = Client(server, 'controller-reconnected')
    reconnect_id = reconnect.info()['client_id']
    assert reconnect_id not in ids
    replay = reconnect.tool('get_session_events', after=replay_after, limit=128)
    assert not replay['gap'] and any(e['client_id'] == ids[0] for e in replay['events']), replay
    assert reconnect.tool('get_inspection', id=started['id'])['items'] == saved['items']
    duplicate_listener(server, one)
    client_limit(server, one)
    max_reply_ms = isolated_bad_clients(server, one)

    # A session with zero attached clients owns both the running target and job.
    for client in server.clients:
        client.close()
    time.sleep(.15)
    assert server.proc.poll() is None and server.target_alive()
    last = Client(server, 'after-zero-clients')
    info = last.info()
    assert info['client_id'] not in ids + [reconnect_id] and len(info['clients']) == 1, info
    assert info['controller_id'] is None
    retained = last.tool('get_inspection', id=started['id'])
    assert retained['identity'] == saved['identity'] and retained['items'] == saved['items']
    report = journal(last)
    last.tool('release_inspection', id=started['id'])
    expect_error(last.raw('get_inspection', id=started['id']), 'UnknownInspection')
    report.update(client_ids=ids + [reconnect_id, info['client_id']], slow_reader_peer_max_ms=max_reply_ms,
                  retained_items=len(saved['items']), target_pid=server.target_pid)
    server.stop_and_check()
    return report


def bridge_smoke(server):
    script = server.root / 'scripts/session-client'
    assert script.is_file(), script
    transcript = []
    with (server.work / 'bridge.log').open('wb') as log:
        proc = subprocess.Popen([sys.executable, str(script), str(server.path)], cwd=server.root,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, bufsize=0)
        pending = bytearray()
        try:
            for ident, method, params in (
                (1, 'initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                                   'clientInfo': {'name': 'bridge-smoke', 'version': '1'}}),
                (2, 'tools/call', {'name': 'get_session', 'arguments': {}}),
            ):
                message = {'jsonrpc': '2.0', 'id': ident, 'method': method, 'params': params}
                proc.stdin.write((json.dumps(message) + '\n').encode())
                deadline = time.monotonic() + TIMEOUT
                while True:
                    if b'\n' in pending:
                        line, _, rest = pending.partition(b'\n')
                        pending = bytearray(rest)
                        reply = json.loads(line)
                        if 'id' not in reply:
                            continue
                        assert reply['id'] == ident and 'error' not in reply, reply
                        transcript.append({'request': message, 'response': reply})
                        break
                    left = deadline - time.monotonic()
                    assert left > 0 and select.select([proc.stdout], [], [], left)[0], 'bridge response timeout'
                    chunk = os.read(proc.stdout.fileno(), 65536)
                    assert chunk, 'bridge closed before reply'
                    pending.extend(chunk)
                if ident == 1:
                    assert reply['result']['protocolVersion'] == '2025-06-18'
                    proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
                else:
                    assert not reply['result']['isError']
                    assert reply['result']['structuredContent']['pid'] == server.target_pid
            proc.stdin.close()
            assert proc.wait(timeout=TIMEOUT) == 0, 'bridge failed on stdin EOF'
            assert server.target_alive()
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            if not proc.stdin.closed:
                proc.stdin.close()
            proc.stdout.close()
            (server.work / 'bridge-transcript.json').write_text(json.dumps(transcript, indent=2) + '\n')


def observe_checks(server):
    client = Client(server, 'configured-observe')
    state = client.session()
    server.remember_target(state)
    expect_error(client.raw('claim_session_control', generation=state['generation']), 'ScopeDenied')
    expect_error(client.raw('start_inspection', generation=state['generation'],
                            tid=state['threads'][0]['tid'], registers=True, stack=False), 'AgentScopeDenied')
    assert client.info()['controller_id'] is None
    assert client.tool('list_threads')
    derived_view_guards(client, error='AgentScopeDenied')
    bridge_smoke(server)
    server.stop_and_check()


def mutate_checks(server):
    owner = Client(server, 'mutation-owner')
    observer = Client(server, 'mutation-observer')
    state = eventually(owner.session, lambda value: value['state'] == 'stopped', 'mutation fixture stop')
    server.remember_target(state)
    tid = state['threads'][0]['tid']
    pc = observer.tool('get_registers', tid=tid)['registers']['rip']
    original = observer.tool('read_memory', address=pc, length=1)['hex']
    expect_error(observer.raw('write_memory', generation=state['generation'], address=pc, hex=original), 'ControlLeaseRequired')
    owner.claim()
    expect_error(observer.raw('write_memory', generation=observer.session()['generation'], address=pc, hex=original), 'ControlLeaseRequired')
    # Write exactly the byte already present: exercise the mutation gate without
    # changing the fixture's instruction stream.
    owner.action('write_memory', address=pc, hex=original)
    assert observer.tool('read_memory', address=pc, length=1)['hex'] == original
    first = attributed_action(observer, 'write_memory', owner.info()['client_id'])
    # Transfer ownership and perform another real action. Request-scoped client
    # attribution must follow the new controller, including after failed writes.
    owner.tool('release_session_control')
    observer.claim()
    expect_error(owner.raw('write_memory', generation=owner.session()['generation'], address=pc, hex=original), 'ControlLeaseRequired')
    observer.action('write_memory', address=pc, hex=original)
    second = attributed_action(owner, 'write_memory', observer.info()['client_id'])
    assert second['sequence'] > first['sequence'] and second['client_id'] != first['client_id']
    server.stop_and_check()


def argument_conflicts(root, work, binary):
    results = []
    for index, flags in enumerate((['--mcp'], ['--listen', '127.0.0.1:1'], ['--connect', '127.0.0.1:1'])):
        path = work / f'conflict-{index}.sock'
        result = subprocess.run([str(binary), '--headless', '--session-socket', str(path), *flags], cwd=root,
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=TIMEOUT)
        (work / f'conflict-{index}.log').write_bytes(result.stdout + result.stderr)
        assert result.returncode != 0 and not path.exists(), (flags, result)
        results.append(flags)
    return results


def main():
    os.umask(0o022)
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    work = Path(tempfile.mkdtemp(prefix='xodb-shared-', dir=os.environ.get('XODB_TEST_TMPDIR')))
    work.chmod(0o755)
    binary = Path(os.environ.get('XODB_BIN', 'zig-out/bin/xodb')).resolve()
    fixture = root / 'zig-out/bin/xodb-m1-fixture'
    if not fixture.exists():
        fixture = work / 'fixture'
        subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-Wall', '-Wextra', '-Werror',
                        str(root / 'tests/fixtures/m1.c'), '-o', str(fixture)], check=True,
                       env=dict(os.environ, TMPDIR=str(work)))
    report = {'artifact': str(work), 'runtime_agent': bool(os.environ.get('XODB_RUNTIME_AGENT'))}
    try:
        report['argument_conflicts'] = argument_conflicts(root, work, binary)
        for scope in ('control', 'observe', 'mutate'):
            server = Server(root, work, binary, fixture, scope)
            try:
                if scope == 'control':
                    report.update(control_checks(server))
                elif scope == 'observe':
                    observe_checks(server)
                else:
                    mutate_checks(server)
            finally:
                server.close()
        report['checks'] = ['exclusive renewable expiring control lease', 'scope and generation guards',
                            'derived-view allocation gate and observer tool visibility',
                            'client attribution in audit and last action',
                            'retained job across lease expiry, reconnect and zero clients', 'eight-client cap',
                            'malformed and slow-peer isolation', 'journal replay and ring gap',
                            'duplicate listener preserves socket', 'SIGINT target and socket cleanup']
        report['passed'] = True
        print(json.dumps(report))
    finally:
        (work / 'result.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
