#!/usr/bin/env python3
"""X3: runtime-only TLS/key-log and mitmproxy evidence fixtures.

Two owned TLS clients reach owned servers through a loopback byte-forwarder.
The forwarder records only those sessions and writes a temporary pcapng; keys,
plaintext, certificates and flow dumps stay in the caller's work directory.
No transcript or payload is printed or written as test evidence.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import select
import shutil
import signal
import socket
import ssl
import struct
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

from client import Client
from helpers.listen import listen_and_report

root = Path(__file__).resolve().parents[1]
os.chdir(root)
parser = argparse.ArgumentParser()
parser.add_argument('--work', default='.work/private-network-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
options = parser.parse_args()
work = Path(options.work)
work.mkdir(parents=True, exist_ok=True)


def block(kind, body):
    body += b'\0' * (-len(body) % 4)
    n = 12 + len(body)
    return struct.pack('<II', kind, n) + body + struct.pack('<I', n)


def option(code, value):
    return struct.pack('<HH', code, len(value)) + value + b'\0' * (-len(value) % 4)


def ethernet_tcp(sport, dport, seq, ack, flags, payload=b''):
    tcp = struct.pack('!HHIIBBHHH', sport, dport, seq, ack, 5 << 4, flags, 65535, 0, 0) + payload
    ip = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(tcp), 0, 0x4000, 64, 6, 0,
                     socket.inet_aton('127.0.0.1'), socket.inet_aton('127.0.0.1')) + tcp
    return b'\0' * 12 + b'\x08\x00' + ip


def read_exact(sock, size):
    out = bytearray()
    while len(out) < size:
        part = sock.recv(size - len(out))
        if not part:
            raise EOFError('owned TLS peer closed')
        out += part
    return bytes(out)


def tls_context(server, version, cert, key, keylog):
    purpose = ssl.PROTOCOL_TLS_SERVER if server else ssl.PROTOCOL_TLS_CLIENT
    ctx = ssl.SSLContext(purpose)
    if server:
        ctx.load_cert_chain(cert, key)
    else:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        ctx.keylog_filename = str(keylog)
    selected = ssl.TLSVersion.TLSv1_3 if version == 'tls13' else ssl.TLSVersion.TLSv1_2
    ctx.minimum_version = selected
    ctx.maximum_version = selected
    if version == 'tls12':
        ctx.set_ciphers('ECDHE-RSA-AES128-GCM-SHA256')
    return ctx


def exchange(version, cert, key, keylog):
    request = os.urandom(4093 if version == 'tls13' else 2051)
    response = hashlib.sha256(request).digest() + os.urandom(3079)
    backend = socket.socket()
    backend.bind(('127.0.0.1', 0))
    backend.listen(1)
    proxy = socket.socket()
    proxy.bind(('127.0.0.1', 0))
    proxy.listen(1)
    result = {'chunks': [], 'errors': []}

    def serve():
        try:
            raw, _ = backend.accept()
            with raw, tls_context(True, version, cert, key, keylog).wrap_socket(raw, server_side=True) as peer:
                size = struct.unpack('!I', read_exact(peer, 4))[0]
                got = read_exact(peer, size)
                if got != request:
                    raise AssertionError('owned TLS request mismatch')
                peer.sendall(struct.pack('!I', len(response)) + response)
        except BaseException as exc:
            result['errors'].append(exc)

    def forward():
        try:
            client, client_address = proxy.accept()
            upstream = socket.create_connection(backend.getsockname())
            result['client_port'] = client_address[1]
            result['server_port'] = proxy.getsockname()[1]
            peers = {client: (upstream, 'client_to_server'), upstream: (client, 'server_to_client')}
            live = set(peers)
            while live:
                readable, _, _ = select.select(list(live), [], [], 5)
                if not readable:
                    raise TimeoutError('owned TLS forwarder stalled')
                for source in readable:
                    data = source.recv(65536)
                    destination, direction = peers[source]
                    if data:
                        result['chunks'].append((time.time_ns(), direction, data))
                        destination.sendall(data)
                    else:
                        live.remove(source)
                        try:
                            destination.shutdown(socket.SHUT_WR)
                        except OSError:
                            pass
            client.close()
            upstream.close()
        except BaseException as exc:
            result['errors'].append(exc)

    server_thread = threading.Thread(target=serve)
    proxy_thread = threading.Thread(target=forward)
    server_thread.start()
    proxy_thread.start()
    try:
        raw = socket.create_connection(proxy.getsockname())
        with raw, tls_context(False, version, cert, key, keylog).wrap_socket(raw, server_hostname='localhost') as client:
            client.sendall(struct.pack('!I', len(request)) + request)
            size = struct.unpack('!I', read_exact(client, 4))[0]
            if read_exact(client, size) != response:
                raise AssertionError('owned TLS response mismatch')
    finally:
        server_thread.join(10)
        proxy_thread.join(10)
        backend.close()
        proxy.close()
    assert not server_thread.is_alive() and not proxy_thread.is_alive(), 'owned TLS threads did not stop'
    if result['errors']:
        raise result['errors'][0]
    result['request'] = struct.pack('!I', len(request)) + request
    result['response'] = struct.pack('!I', len(response)) + response
    result['version'] = version
    return result


openssl = shutil.which('openssl')
assert openssl, 'openssl is required to generate the owned test certificate'
cert, key, keylog = work / 'cert.pem', work / 'key.pem', work / 'ssl.keys'
subprocess.run([openssl, 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                '-subj', '/CN=localhost', '-keyout', key, '-out', cert],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
sessions = [exchange('tls13', cert, key, keylog), exchange('tls12', cert, key, keylog)]

packets = []
for ordinal, session in enumerate(sessions):
    first = min(row[0] for row in session['chunks'])
    client_seq, server_seq = 1000 + ordinal * 100000, 5000 + ordinal * 100000
    cp, sp = session['client_port'], session['server_port']
    packets.extend([
        (first - 3000, ethernet_tcp(cp, sp, client_seq, 0, 0x02)),
        (first - 2000, ethernet_tcp(sp, cp, server_seq, client_seq + 1, 0x12)),
        (first - 1000, ethernet_tcp(cp, sp, client_seq + 1, server_seq + 1, 0x10)),
    ])
    client_seq += 1
    server_seq += 1
    for when, direction, data in session['chunks']:
        # Each chunk is captured as two segments, second half first, so
        # reassembly must order by sequence (including the first server data).
        half = len(data) // 2
        for order, (offset, part) in enumerate(((half, data[half:]), (0, data[:half]))):
            if not part:
                continue
            if direction == 'client_to_server':
                packets.append((when + order, ethernet_tcp(cp, sp, client_seq + offset, server_seq, 0x18, part)))
            else:
                packets.append((when + order, ethernet_tcp(sp, cp, server_seq + offset, client_seq, 0x18, part)))
        if direction == 'client_to_server':
            client_seq += len(data)
        else:
            server_seq += len(data)
    session['client_final_seq'] = client_seq
    session['server_final_seq'] = server_seq
packets.sort(key=lambda row: row[0])


def write_capture(path, rows):
    pcapng = [block(0x0a0d0d0a, struct.pack('<IHHq', 0x1a2b3c4d, 1, 0, -1)),
              block(1, struct.pack('<HHI', 1, 0, 65535) + option(2, b'lo') + option(9, b'\x09') + option(0, b''))]
    for when, packet in sorted(rows, key=lambda row: row[0]):
        pcapng.append(block(6, struct.pack('<IIIII', 0, when >> 32, when & 0xffffffff, len(packet), len(packet)) + packet))
    path.write_bytes(b''.join(pcapng))


capture = work / 'owned-tls.pcapng'
write_capture(capture, packets)
partial_capture = work / 'owned-tls-partial.pcapng'
partial_packets = list(packets)
partial = sessions[0]
partial_packets.append((max(row[0] for row in packets) + 1000,
                        ethernet_tcp(partial['server_port'], partial['client_port'],
                                     partial['server_final_seq'], partial['client_final_seq'], 0x18, b'\x16')))
write_capture(partial_capture, partial_packets)
# Both directions malformed: malformed_directions must count to 2 (a u1 sum
# once aborted ReleaseSafe here).
both_capture = work / 'owned-tls-both-malformed.pcapng'
write_capture(both_capture, partial_packets + [
    (max(row[0] for row in packets) + 2000,
     ethernet_tcp(partial['client_port'], partial['server_port'],
                  partial['client_final_seq'], partial['server_final_seq'] + 1, 0x18, b'\x17\x03\x03\xff\xff'))])

# Enough small, invalid application records to reach the production cap. The
# packet stream must still open and the affected TLS session must be partial.
tls_derived_limit = 256 * 1024
failure_record = b'\x17\x03\x03\x00\x10' + b'\0' * 16
cap_packets = list(packets)
cap_session = sessions[0]
cap_seq = cap_session['client_final_seq']
cap_when = max(row[0] for row in packets) + 10_000
remaining = tls_derived_limit + 32
while remaining:
    count = min(2500, remaining)
    payload = failure_record * count
    cap_packets.append((cap_when, ethernet_tcp(cap_session['client_port'], cap_session['server_port'],
                                               cap_seq, cap_session['server_final_seq'], 0x18, payload)))
    cap_seq += len(payload)
    cap_when += 1
    remaining -= count
cap_capture = work / 'owned-tls-record-cap.pcapng'
write_capture(cap_capture, cap_packets)


def close_and_check(client, private_values):
    client.close()
    logs = client.p.stderr.read()
    for private in private_values:
        assert private not in logs, 'private TLS/mitmproxy bytes entered stderr'


observer = Client('observe', None, options=['--open-pcap', str(capture), '--tls-key-log', str(keylog)])
try:
    streams = observer.inspect('list_streams')['streams']
    assert [stream['kind'] for stream in streams] == ['network', 'tls', 'protocol'], streams
    tls_stream = streams[1]
    assert {session['tls_version'] for session in tls_stream['sessions']} == {'tls12', 'tls13'}, tls_stream
    assert all(session['state'] == 'decrypted' for session in tls_stream['sessions']), tls_stream
    rows = observer.inspect('query_stream', stream_id=tls_stream['stream_id'], state='decrypted', include_raw=True, limit=256)['records']
    assert rows and all(row['plaintext']['sha256'] is not None for row in rows), rows
    by_flow = {}
    for row in rows:
        if row['content_type'] != 'application_data':
            continue
        by_flow.setdefault((row['flow_id'], row['direction']), bytearray()).extend(bytes.fromhex(row['plaintext_hex']))
    client_streams = [bytes(data) for (flow, direction), data in by_flow.items() if direction == 'client_to_server']
    server_streams = [bytes(data) for (flow, direction), data in by_flow.items() if direction == 'server_to_client']
    assert all(any(session['request'] in data for data in client_streams) for session in sessions)
    assert all(any(session['response'] in data for data in server_streams) for session in sessions)
    packets_with_bytes = observer.inspect('query_stream', stream_id=1, include_raw=True, limit=1)['records']
    assert packets_with_bytes and packets_with_bytes[0]['raw_hex'], packets_with_bytes
finally:
    close_and_check(observer, [session['request'] for session in sessions] + [session['response'] for session in sessions])

partial_client = Client('observe', None, options=['--open-pcap', str(partial_capture), '--tls-key-log', str(keylog)])
try:
    tls_stream = partial_client.inspect('list_streams')['streams'][1]
    affected = [session for session in tls_stream['sessions'] if session['tls_version'] == 'tls13']
    assert len(affected) == 1 and affected[0]['state'] == 'partial' and affected[0]['malformed_directions'] == 1, tls_stream
finally:
    close_and_check(partial_client, [session['request'] for session in sessions] + [session['response'] for session in sessions])

both_client = Client('observe', None, options=['--open-pcap', str(both_capture), '--tls-key-log', str(keylog)])
try:
    tls_stream = both_client.inspect('list_streams')['streams'][1]
    affected = [session for session in tls_stream['sessions'] if session['tls_version'] == 'tls13']
    assert len(affected) == 1 and affected[0]['state'] == 'partial' and affected[0]['malformed_directions'] == 2, tls_stream
finally:
    close_and_check(both_client, [session['request'] for session in sessions] + [session['response'] for session in sessions])

cap_client = Client('observe', None, options=['--open-pcap', str(cap_capture), '--tls-key-log', str(keylog)])
try:
    streams = cap_client.inspect('list_streams')['streams']
    assert [stream['kind'] for stream in streams] == ['network', 'tls', 'protocol'], streams
    tls_stream = streams[1]
    assert tls_stream['records'] == tls_derived_limit and tls_stream['derived_record_limit_hit'], tls_stream
    assert any(session['state'] == 'partial' for session in tls_stream['sessions']), tls_stream
    counted = sum(session['records'] + session['authentication_failures'] for session in tls_stream['sessions'])
    assert counted == tls_derived_limit, (counted, tls_stream['sessions'])
    status =Path(f'/proc/{cap_client.p.pid}/status').read_text()
    peak_kib = int(next(line.split()[1] for line in status.splitlines() if line.startswith('VmHWM:')))
    assert peak_kib < 512 * 1024, peak_kib
finally:
    close_and_check(cap_client, [session['request'] for session in sessions] + [session['response'] for session in sessions])

# One TCP flow with a gap in both directions: the protocol stream counts two
# gaps instead of overflowing a u1 sum (a large flow hits the same path
# through the per-direction byte limit).
gaps_capture = work / 'owned-two-gaps.pcapng'
write_capture(gaps_capture, [(1, ethernet_tcp(40000, 8080, 100, 200, 0x18, b'GET ')),
                             (2, ethernet_tcp(8080, 40000, 200, 104, 0x18, b'HTTP')),
                             (3, ethernet_tcp(40000, 8080, 120, 204, 0x18, b'x')),
                             (4, ethernet_tcp(8080, 40000, 220, 121, 0x18, b'y'))])
gaps_client = Client('observe', None, options=['--open-pcap', str(gaps_capture)])
try:
    protocol_stream = gaps_client.inspect('list_streams')['streams'][1]
    assert protocol_stream['kind'] == 'protocol' and protocol_stream['reassembly_gaps'] == 2, protocol_stream
finally:
    close_and_check(gaps_client, [])

controller = Client('control', None, options=['--open-pcap', str(capture), '--tls-key-log', str(keylog)])
try:
    denied = controller.tool('query_stream', stream_id=2, include_raw=True)
    assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'PrivateEvidenceUnavailable', denied
    denied = controller.tool('query_stream', stream_id=1, include_raw=True)
    assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'PrivateEvidenceUnavailable', denied
    metadata = controller.inspect('query_stream', stream_id=2)['records']
    assert metadata and all(row['plaintext']['sha256'] is None for row in metadata), metadata
finally:
    close_and_check(controller, [session['request'] for session in sessions] + [session['response'] for session in sessions])

# A --listen TCP client is remote, not the process-local opener.
listener = subprocess.Popen([os.environ.get('XODB_BIN', str(root / 'zig-out/bin/xodb')), '--headless', '--mcp', '--agent-scope', 'observe',
                             '--listen', '127.0.0.1:0', '--open-pcap', str(capture), '--tls-key-log', str(keylog)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
remote = None
listener_startup = b''
try:
    listen_port, listener_startup = listen_and_report(listener)
    remote = socket.create_connection(('127.0.0.1', listen_port), timeout=5)
    with remote, remote.makefile('rwb') as wire:
        def remote_call(ident, method, params):
            wire.write((json.dumps({'jsonrpc': '2.0', 'id': ident, 'method': method, 'params': params}) + '\n').encode())
            wire.flush()
            while True:
                reply = json.loads(wire.readline())
                if reply.get('id') == ident:
                    return reply
        remote_call(1, 'initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'x3-listen', 'version': '1'}})
        wire.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        wire.flush()
        denied = remote_call(2, 'tools/call', {'name': 'query_stream', 'arguments': {'stream_id': 2, 'include_raw': True}})
        assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'PrivateEvidenceUnavailable', denied
        denied = remote_call(4, 'tools/call', {'name': 'query_stream', 'arguments': {'stream_id': 1, 'include_raw': True}})
        assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'PrivateEvidenceUnavailable', denied
        metadata = remote_call(3, 'tools/call', {'name': 'query_stream', 'arguments': {'stream_id': 2}})
        rows = metadata['result']['structuredContent']['records']
        assert rows and all(row['plaintext']['sha256'] is None for row in rows), metadata
finally:
    if listener.poll() is None:
        listener.send_signal(signal.SIGINT)
    listener.wait(timeout=5)
    listener_logs = listener_startup + listener.stderr.read()
    listener.stderr.close()
    for session in sessions:
        assert session['request'] not in listener_logs and session['response'] not in listener_logs

# A socket peer is never the process-local opener, even when the server itself
# has observe scope. It can inspect authenticated metadata but not plaintext.
shared_spec = importlib.util.spec_from_file_location('x3_shared', root / 'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(shared_spec)
shared_spec.loader.exec_module(shared)
shared_run = work / 'shared-tls'
shared_run.mkdir(mode=0o700)
shared_path = (shared_run / 's').resolve()
shared_log_path = shared_run / 'server.log'
shared_log = shared_log_path.open('wb')
shared_host = type('SharedHost', (), {'path': shared_path, 'clients': []})()
shared_host.proc = subprocess.Popen([
    os.environ.get('XODB_BIN', str(root / 'zig-out/bin/xodb')), '--headless',
    '--session-socket', str(shared_path), '--agent-scope', 'observe',
    '--open-pcap', str(capture), '--tls-key-log', str(keylog),
], stdin=subprocess.DEVNULL, stdout=shared_log, stderr=subprocess.STDOUT)
shared_peer = None
try:
    shared_peer = shared.Client(shared_host, 'x3-shared-observer')
    shared_streams = shared_peer.tool('list_streams')['streams']
    assert [stream['kind'] for stream in shared_streams] == ['network', 'tls', 'protocol'], shared_streams
    denied = shared_peer.raw('query_stream', stream_id=2, include_raw=True)
    shared.expect_error(denied, 'PrivateEvidenceUnavailable')
    denied = shared_peer.raw('query_stream', stream_id=1, include_raw=True)
    shared.expect_error(denied, 'PrivateEvidenceUnavailable')
    metadata = shared_peer.tool('query_stream', stream_id=2, state='decrypted')['records']
    assert metadata and all('plaintext_hex' not in row and row['plaintext']['sha256'] is None for row in metadata)
finally:
    if shared_peer is not None:
        shared_peer.close()
    if shared_host.proc.poll() is None:
        shared_host.proc.send_signal(signal.SIGINT)
    assert shared_host.proc.wait(timeout=5) == 0
    shared_log.close()
    logs = shared_log_path.read_bytes()
    for session in sessions:
        assert session['request'] not in logs and session['response'] not in logs, 'private TLS bytes entered shared-server logs'

redacted = Client('observe', None, options=['--redact', '--open-pcap', str(capture), '--tls-key-log', str(keylog)])
try:
    denied = redacted.tool('query_stream', stream_id=2, include_raw=True)
    assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'RawPayloadRedacted', denied
    denied = redacted.tool('query_stream', stream_id=1, include_raw=True)
    assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'RawPayloadRedacted', denied
    metadata = redacted.inspect('query_stream', stream_id=2, state='decrypted')['records']
    assert metadata and all('plaintext_hex' not in row and row['plaintext']['sha256'] is None for row in metadata)
finally:
    close_and_check(redacted, [session['request'] for session in sessions] + [session['response'] for session in sessions])


def tnet(value):
    if value is None:
        return b'0:~'
    if value is True:
        return b'4:true!'
    if value is False:
        return b'5:false!'
    if isinstance(value, int):
        payload, tag = str(value).encode(), b'#'
    elif isinstance(value, float):
        payload, tag = repr(value).encode(), b'^'
    elif isinstance(value, bytes):
        payload, tag = value, b','
    elif isinstance(value, str):
        payload, tag = value.encode(), b';'
    elif isinstance(value, (list, tuple)):
        payload, tag = b''.join(tnet(item) for item in value), b']'
    elif isinstance(value, dict):
        payload, tag = b''.join(tnet(k) + tnet(v) for k, v in value.items()), b'}'
    else:
        raise TypeError(type(value))
    return str(len(payload)).encode() + b':' + payload + tag


request_body, response_body = os.urandom(701), os.urandom(907)
now = time.time()
message = dict(http_version=b'HTTP/1.1', headers=[[b'content-type', b'application/octet-stream']],
               content=request_body, trailers=None, timestamp_start=now, timestamp_end=now + .001)
flow = dict(version=21, type='http', timestamp_created=now,
            request=dict(message, host='localhost', port=443, method=b'POST', scheme=b'https', authority=b'', path=os.urandom(9)),
            response=dict(message, content=response_body, status_code=201, reason=b'Created'))
flow_file = work / 'owned-flow.mitm'
flow_file.write_bytes(tnet(flow) + tnet(dict(version=21, type='tcp', timestamp_created=now + 1)))

mitm_client = Client('observe', None, options=['--open-mitmproxy', str(flow_file)])
try:
    streams = mitm_client.inspect('list_streams')['streams']
    assert len(streams) == 1 and streams[0]['kind'] == 'mitmproxy' and streams[0]['records'] == 2, streams
    rows = mitm_client.inspect('query_stream', method='post', include_raw=True)['records']
    assert len(rows) == 1 and bytes.fromhex(rows[0]['request']['message']['content_hex']) == request_body
    assert bytes.fromhex(rows[0]['response']['message']['content_hex']) == response_body
    assert rows[0]['response']['status_code'] == 201
    assert rows[0]['request']['message']['content']['sha256'] is not None
    assert rows[0]['response']['message']['content']['sha256'] is not None
finally:
    close_and_check(mitm_client, [request_body, response_body])

mitm_controller = Client('control', None, options=['--open-mitmproxy', str(flow_file)])
try:
    # The method is withheld from non-openers, so it cannot be a filter either.
    denied = mitm_controller.tool('query_stream', method='post')
    assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'PrivateEvidenceUnavailable', denied
    row = mitm_controller.inspect('query_stream')['records'][0]
    assert row['request']['method'] is None and 'content_hex' not in row['request']['message']
    assert row['request']['message']['content']['sha256'] is None
    assert row['response']['message']['content']['sha256'] is None
finally:
    close_and_check(mitm_controller, [request_body, response_body])

mitm_redacted = Client('observe', None, options=['--redact', '--open-mitmproxy', str(flow_file)])
try:
    denied = mitm_redacted.tool('query_stream', include_raw=True)
    assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'RawPayloadRedacted', denied
    row = mitm_redacted.inspect('query_stream')['records'][0]
    assert row['request']['host'] is None and row['request']['path'] is None
    assert row['request']['message']['headers'] == [] and 'content_hex' not in row['request']['message']
    assert row['request']['message']['content']['sha256'] is None
    assert row['response']['message']['content']['sha256'] is None
finally:
    close_and_check(mitm_redacted, [request_body, response_body])

print('private network evidence: TLS 1.2/1.3 authenticated; mitmproxy imported; payload ownership enforced')
