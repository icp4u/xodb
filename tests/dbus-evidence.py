#!/usr/bin/env python3
"""D-Bus evidence from a test-owned daemon, monitor and scripted client."""
import atexit, hashlib, json, os, socket, struct, subprocess, tempfile, time
from pathlib import Path
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
work_parent = Path(os.environ.get('XODB_TEST_TMPDIR', '.work'))
work_parent.mkdir(parents=True, exist_ok=True)
work = Path(tempfile.mkdtemp(prefix='xodb-dbus-', dir=work_parent))
runtime = work / 'runtime'
runtime.mkdir(mode=0o700)
bus_socket = work / 'bus.sock'
capture = work / 'private-bus.pcap'
private = 'xquinellax-secret'
env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime))
owned = []

def cleanup():
    for process in reversed(owned):
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

atexit.register(cleanup)

daemon = subprocess.Popen(['dbus-daemon', '--session', '--nofork', '--print-address=1', '--print-pid=1',
                           f'--address=unix:path={bus_socket}'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
owned.append(daemon)
address = daemon.stdout.readline().decode().strip()
reported_pid = int(daemon.stdout.readline())
assert address.startswith(f'unix:path={bus_socket},guid=') and reported_pid == daemon.pid, address
capture_file = open(capture, 'wb')
monitor = subprocess.Popen(['dbus-monitor', '--address', address, '--pcap'], env=env,
                           stdout=capture_file, stderr=subprocess.PIPE)
owned.append(monitor)

def wait_monitor():
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        subprocess.run(['dbus-send', f'--bus={address}', '--print-reply', '--dest=org.freedesktop.DBus',
                        '/org/freedesktop/DBus', 'org.freedesktop.DBus.ListNames'],
                       env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        capture_file.flush()
        if capture.stat().st_size > 24:
            return
        time.sleep(.01)
    raise AssertionError('private dbus-monitor did not publish a packet')

wait_monitor()

def align(data, boundary):
    data.extend(b'\0' * (-len(data) % boundary))

def text32(value):
    raw = value.encode()
    return struct.pack('<I', len(raw)) + raw + b'\0'

def signature(value):
    raw = value.encode()
    return bytes([len(raw)]) + raw + b'\0'

def body_values(sig, values):
    out = bytearray()
    if sig == 'ay':
        raw = values[0]
        return struct.pack('<I', len(raw)) + raw
    for code, value in zip(sig, values):
        if code in 'so':
            align(out, 4); out += text32(value)
        elif code == 'u':
            align(out, 4); out += struct.pack('<I', value)
        else:
            raise AssertionError(code)
    return bytes(out)

def message(kind, serial, fields, sig='', values=(), flags=0):
    body = body_values(sig, values)
    encoded = bytearray()
    for code, value_sig, value in fields + ([(8, 'g', sig)] if sig else []):
        align(encoded, 8)
        encoded.append(code)
        encoded += signature(value_sig)
        if value_sig in 'so':
            align(encoded, 4); encoded += text32(value)
        elif value_sig == 'g':
            encoded += signature(value)
        elif value_sig == 'u':
            align(encoded, 4); encoded += struct.pack('<I', value)
        else:
            raise AssertionError(value_sig)
    fixed = struct.pack('<cBBBIII', b'l', kind, flags, 1, len(body), serial, len(encoded))
    packet = bytearray(fixed + encoded)
    align(packet, 8)
    packet += body
    return bytes(packet)

def call(serial, member, sig='', values=(), flags=0):
    return message(1, serial, [(1, 'o', '/org/freedesktop/DBus'),
                               (2, 's', 'org.freedesktop.DBus'),
                               (3, 's', member),
                               (6, 's', 'org.freedesktop.DBus')], sig, values, flags)

def receive_exact(sock, size):
    result = bytearray()
    while len(result) < size:
        part = sock.recv(size - len(result))
        assert part, 'private bus closed'
        result += part
    return bytes(result)

def read_fields(data):
    at, result = 0, {}
    while at < len(data):
        at = (at + 7) & ~7
        if at == len(data): break
        code = data[at]; at += 1
        n = data[at]; at += 1
        sig = data[at:at+n].decode(); at += n + 1
        if sig in 'so':
            at = (at + 3) & ~3
            size = struct.unpack_from('<I', data, at)[0]; at += 4
            value = data[at:at+size].decode(); at += size + 1
        elif sig == 'g':
            size = data[at]; at += 1
            value = data[at:at+size].decode(); at += size + 1
        elif sig == 'u':
            at = (at + 3) & ~3
            value = struct.unpack_from('<I', data, at)[0]; at += 4
        else:
            raise AssertionError(sig)
        result[code] = value
    return result

def receive(sock):
    fixed = receive_exact(sock, 16)
    assert fixed[0:1] == b'l' and fixed[3] == 1
    body_len, serial, fields_len = struct.unpack_from('<III', fixed, 4)
    tail = receive_exact(sock, ((16 + fields_len + 7) & ~7) - 16 + body_len)
    fields = read_fields(tail[:fields_len])
    body_at = ((16 + fields_len + 7) & ~7) - 16
    return fixed[1], serial, fields, tail[body_at:body_at+body_len]

def reply(sock, wanted):
    while True:
        kind, serial, fields, body = receive(sock)
        if fields.get(5) == wanted:
            return kind, fields, body

client = socket.socket(socket.AF_UNIX)
client.connect(str(bus_socket))
auth = str(os.getuid()).encode().hex().encode()
client.sendall(b'\0AUTH EXTERNAL ' + auth + b'\r\n')
line = b''
while not line.endswith(b'\r\n'): line += client.recv(1)
assert line.startswith(b'OK '), line
client.sendall(b'BEGIN\r\n')

client.sendall(call(1, 'Hello'))
kind, fields, body = reply(client, 1)
assert kind == 2 and fields[8] == 's'
size = struct.unpack_from('<I', body)[0]
unique = body[4:4+size].decode()
assert unique.startswith(':')

client.sendall(call(2, 'RequestName', 'su', ('com.example.xquinellax', 0)))
kind, fields, body = reply(client, 2)
assert kind == 2 and struct.unpack_from('<I', body)[0] in (1, 4)

client.sendall(call(3, 'GetConnectionUnixProcessID', 's', (unique,)))
kind, fields, body = reply(client, 3)
assert kind == 2 and struct.unpack_from('<I', body)[0] == os.getpid()

client.sendall(message(4, 4, [(1, 'o', '/com/example/xquinellax/private'),
                              (2, 's', 'com.example.Fixture'),
                              (3, 's', 'Ping')], 's', (private,)))
client.sendall(call(5, 'NoSuchFixtureMethod'))
kind, fields, body = reply(client, 5)
assert kind == 3 and fields[4].startswith('org.freedesktop.DBus.Error.')
client.sendall(call(6, 'ListNames'))
kind, fields, body = reply(client, 6)
assert kind == 2 and fields[8] == 'as'
# Prove six owned request/reply pairs; the monitor's own startup exchange
# may precede capture and must not supply the sixth pair by accident.
client.sendall(call(9, 'GetId'))
kind, fields, body = reply(client, 9)
assert kind == 2 and fields[8] == 's'
before_extra = capture.stat().st_size
large_bytes = bytes((index % 251 for index in range(5000)))
client.sendall(message(4, 7, [(1, 'o', '/com/example/xquinellax/private'),
                              (2, 's', 'com.example.Fixture'),
                              (3, 's', 'Bytes')], 'ay', (large_bytes,)))
client.sendall(call(8, 'ListNames', flags=1))
client.close()

deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    capture_file.flush()
    if capture.stat().st_size >= before_extra + len(large_bytes):
        break
    time.sleep(.01)
else:
    raise AssertionError('private dbus-monitor did not publish the byte array')
monitor.terminate()
assert monitor.wait(timeout=5) in (-15, 0)
capture_file.close()
daemon.terminate()
assert daemon.wait(timeout=5) in (-15, 0)

def close_clean(client_):
    client_.close()
    logs = client_.p.stderr.read()
    assert private.encode() not in logs and b'xquinellax' not in logs, 'private D-Bus text entered diagnostics'

observer = Client('observe', None, options=['--open-pcap', str(capture)])
try:
    streams = observer.inspect('list_streams')['streams']
    assert [row['kind'] for row in streams] == ['network', 'dbus'], streams
    network, stream = streams
    assert network['interfaces'][0]['link'] == 'dbus', network
    assert stream['stream_id'] == 5 and stream['records'] >= 12, stream
    assert stream['calls_paired'] >= 6 and stream['identities'] >= 1 and stream['malformed'] == 0, stream
    assert stream['no_reply_calls'] >= 1 and stream['pending_calls'] == 0, stream
    rows = observer.inspect('query_stream', stream_id=5, limit=256)['records']
    pid_call = next(row for row in rows if row['member'] == 'GetConnectionUnixProcessID')
    pid_reply = rows[pid_call['peer_record']]
    assert pid_call['latency_ns'] is not None and pid_reply['arguments'][0]['unsigned'] == os.getpid(), (pid_call, pid_reply)
    signal = next(row for row in rows if row['message_type'] == 'signal' and row['member'] == 'Ping')
    assert signal['path'] == '/com/example/xquinellax/private', signal
    assert signal['arguments'][0]['text'] == private, signal
    byte_signal = next(row for row in rows if row['message_type'] == 'signal' and row['member'] == 'Bytes')
    byte_argument = byte_signal['arguments'][0]
    assert byte_argument['byte_length'] == len(large_bytes) and byte_argument['children'] == [], byte_argument
    assert byte_argument['byte_sha256'] == hashlib.sha256(large_bytes).hexdigest(), byte_argument
    error = next(row for row in rows if row['message_type'] == 'error_reply' and row['peer_record'] is not None)
    assert error['error_name'].startswith('org.freedesktop.DBus.Error.'), error
    list_reply = next(rows[row['peer_record']] for row in rows if row['member'] == 'ListNames' and row['peer_record'] is not None)
    assert list_reply['arguments'][0]['kind'] == 'array' and list_reply['arguments'][0]['children'], list_reply
    correlated = observer.inspect('correlate', stream_id=5, record=signal['index'])
    assert correlated['basis'] == 'dbus_daemon' and correlated['process']['pid'] == os.getpid(), correlated
    assert correlated['bus_name'] == unique, correlated
finally:
    close_clean(observer)

controller = Client('control', None, options=['--open-pcap', str(capture)])
try:
    rows = controller.inspect('query_stream', stream_id=5, limit=256)['records']
    signal = next(row for row in rows if row['member'] == 'Ping')
    assert signal['sender'] is None and signal['path'] is None and signal['arguments'][0]['text'] is None, signal
    pid_call = next(row for row in rows if row['member'] == 'GetConnectionUnixProcessID')
    pid_reply = rows[pid_call['peer_record']]
    assert pid_reply['arguments'][0]['unsigned'] is None, pid_reply
    byte_signal = next(row for row in rows if row['member'] == 'Bytes')
    assert byte_signal['arguments'][0]['byte_sha256'] is None, byte_signal
    assert hashlib.sha256(large_bytes).hexdigest() not in json.dumps(rows), byte_signal
    assert next(row for row in rows if row['member'] == 'ListNames' and row['flags'] & 1)['peer_record'] is None
    denied = controller.tool('query_stream', stream_id=5, include_raw=True)
    assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'PrivateEvidenceUnavailable', denied
    denied = controller.tool('query_stream', stream_id=1, include_raw=True)
    assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'PrivateEvidenceUnavailable', denied
finally:
    close_clean(controller)

redacted = Client('observe', None, options=['--redact', '--open-pcap', str(capture)])
try:
    result = redacted.inspect('query_stream', stream_id=5, limit=256)
    encoded = json.dumps(result)
    assert private not in encoded and 'xquinellax' not in encoded, encoded
    assert hashlib.sha256(large_bytes).hexdigest() not in encoded, encoded
    byte_signal = next(row for row in result['records'] if row['member'] == 'Bytes')
    assert byte_signal['arguments'][0]['byte_sha256'] is None and byte_signal['arguments'][0]['byte_length'] == len(large_bytes), byte_signal
    denied = redacted.tool('query_stream', stream_id=5, include_raw=True)
    assert denied['result']['isError'] and denied['result']['content'][0]['text'] == 'RawPayloadRedacted', denied
finally:
    close_clean(redacted)

print('D-Bus evidence: private daemon/pcap, typed messages, pairing, PID join and privacy pass')
