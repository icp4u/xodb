#!/usr/bin/env python3
"""Network evidence (X1): synthetic pcapng/pcap from owned loopback traffic,
opened beside a real capture archive, aligned and correlated to the process.

The harness is one peer; tests/fixtures/net-peer.py runs under xodb as the
other. Packets are written by a tiny pcapng writer here from the endpoints
both peers really used; no live capture, no privilege, loopback only.
--gui also opens the result on a private headless Sway and keeps a screenshot.
"""
import argparse, json, os, shutil, socket, struct, subprocess, sys, time
from datetime import datetime
from pathlib import Path
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
parser = argparse.ArgumentParser()
parser.add_argument('--work', default='.work/network-evidence-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
parser.add_argument('--gui', action='store_true')
options = parser.parse_args()
work = Path(options.work)
work.mkdir(parents=True, exist_ok=True)
AGENT = bool(os.environ.get('XODB_TEST_RUNTIME_AGENT'))

# ------------------------------------------------------------ pcapng writer

def block(kind, body):
    body += b'\0' * (-len(body) % 4)
    n = 12 + len(body)
    return struct.pack('<II', kind, n) + body + struct.pack('<I', n)

def option(code, value):
    return struct.pack('<HH', code, len(value)) + value + b'\0' * (-len(value) % 4)

def shb():
    return block(0x0a0d0d0a, struct.pack('<IHHq', 0x1a2b3c4d, 1, 0, -1))

def idb(link, name):
    return block(1, struct.pack('<HHI', link, 0, 65535) + option(2, name) + option(9, b'\x09') + option(0, b''))

def epb(iface, ns, data, orig=None):
    return block(6, struct.pack('<IIIII', iface, ns >> 32, ns & 0xffffffff, len(data), orig or len(data)) + data + b'\0' * (-len(data) % 4))

def isb(iface, ifdrop, osdrop):
    return block(5, struct.pack('<III', iface, 0, 0) + option(5, struct.pack('<Q', ifdrop)) + option(7, struct.pack('<Q', osdrop)) + option(0, b''))

def ipv4(proto, src, dst, payload):
    header = struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(payload), 0, 0x4000, 64, proto, 0, socket.inet_aton(src), socket.inet_aton(dst))
    return header + payload

def tcp(sport, dport, seq, ack, flags, data=b''):
    return struct.pack('!HHIIBBHHH', sport, dport, seq, ack, 5 << 4, flags, 65535, 0, 0) + data

def udp(sport, dport, data):
    return struct.pack('!HHHH', sport, dport, 8 + len(data), 0) + data

def ether(ip):
    return b'\0' * 12 + b'\x08\x00' + ip

def sll(ip):
    return struct.pack('!HHH8sH', 0, 772, 0, b'\0' * 8, 0x0800) + ip

# ------------------------------------------------------------ live capture of owned traffic

listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(1)
receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); receiver.bind(('127.0.0.1', 0))
tcp_port, udp_port = listener.getsockname()[1], receiver.getsockname()[1]
ready, go, stop = work / 'peer-ready.json', work / 'peer-go', work / 'peer-stop'
for path in (ready, go, stop):
    if path.exists(): path.unlink()
archive = work / 'peer.xoc'
if archive.exists(): archive.unlink()
python = shutil.which('python3')
c = Client('control', python, args=['-I', str(root / 'tests/fixtures/net-peer.py'), str(tcp_port), str(udp_port), str(ready), str(go), str(stop)], options=['--language-off', 'all'])
times = {}
try:
    state = c.session()
    assert state['state'] == 'stopped', state
    # First exchange before the capture: the start table holds both sockets.
    c.continue_initial_stop()
    conn, _ = listener.accept()
    times['accepted'] = time.time_ns()
    assert conn.recv(4) == b'ping'
    times['ping'] = time.time_ns()
    conn.sendall(b'pong')
    times['pong'] = time.time_ns()
    datagram, sender = receiver.recvfrom(64)
    times['udp'] = time.time_ns()
    assert datagram == b'datagram'
    deadline = time.monotonic() + 20
    while not ready.exists():
        assert time.monotonic() < deadline, 'peer did not report'
        time.sleep(.01)
    peer = json.loads(ready.read_text())
    assert sender[1] == peer['udp']
    c.action('interrupt'); c.stopped()
    cap = c.action('start_profile', frequency_hz=99, duration_ms=0)['capture']
    times['start'] = time.time_ns()
    c.action('continue')
    # Second exchange inside the capture, on the same sockets.
    go.touch()
    assert conn.recv(4) == b'ping'
    times['ping2'] = time.time_ns()
    conn.sendall(b'pong')
    times['pong2'] = time.time_ns()
    datagram, sender = receiver.recvfrom(64)
    times['udp2'] = time.time_ns()
    assert datagram == b'datagram' and sender[1] == peer['udp']
    cap = c.action('stop_profile', capture_id=cap['id'])['capture']
    times['stop'] = time.time_ns()
    result = c.action('save_capture_archive', capture_id=cap['id'], revision=cap['revision'], path=str(archive))
    deadline = time.monotonic() + 20
    while True:
        job = c.inspect('get_archive_status')['job']
        if job['done']: break
        assert time.monotonic() < deadline, job
        time.sleep(.01)
    assert job['error_name'] is None and job['publication']['state'] == 'published', job
    assert c.session()['pid'] == peer['pid']
finally:
    stop.touch()
    if 'conn' in globals(): conn.close()
    (work / 'live-rpc.json').write_text(json.dumps(c.transcript, indent=2) + '\n')
    c.close()
listener.close(); receiver.close()

# ECTX stays. The in-memory [vdso] image selects minor 12, above the evidence minor.
raw = archive.read_bytes()
assert raw[:8] == b'XODBCAPT' and struct.unpack_from('<H', raw, 10)[0] == 12, raw[:16]
tags = [struct.unpack_from('<I', raw, 64 + 24 * i)[0] for i in range(struct.unpack_from('<I', raw, 24)[0])]
assert 0x58544345 in tags, tags
assert 0x494d454d in tags, tags

# ------------------------------------------------------------ synthetic files

lo, P, H = '127.0.0.1', peer['tcp'], tcp_port
syn = ether(ipv4(6, lo, lo, tcp(P, H, 1000, 0, 0x02)))
synack = ether(ipv4(6, lo, lo, tcp(H, P, 5000, 1001, 0x12)))
ack = ether(ipv4(6, lo, lo, tcp(P, H, 1001, 5001, 0x10)))
ping = ether(ipv4(6, lo, lo, tcp(P, H, 1001, 5001, 0x18, b'ping')))
pong = ether(ipv4(6, lo, lo, tcp(H, P, 5001, 1005, 0x18, b'pong')))
dgram = ipv4(17, lo, lo, udp(peer['udp'], udp_port, b'datagram'))
stranger = ether(ipv4(6, lo, lo, tcp(9, 10, 1, 0, 0x02)))
t = times
# Records 0-5 are the second exchange (inside the capture, between tables that
# both hold the sockets: exact); 9-12 are the first exchange and handshake
# (before the start table: sampled, the tuple could have belonged to anyone then).
packets = [
    (0, t['ping2'] - 3000, ping), (0, t['ping2'] - 2000, pong), (0, t['ping2'] - 1000, ack),
    (0, t['ping2'] - 500, ping), (0, t['pong2'] + 500, pong), (1, t['udp2'] - 500, sll(dgram)),
    (2, t['udp2'] + 100, b'opaque-user-link-record'),
    (0, t['udp2'] + 200, stranger),
    (0, t['start'] - 10 * 10**9, ping),  # long before the capture: identity matches, time does not
    (0, t['accepted'] - 3000, syn), (0, t['accepted'] - 2000, synack), (0, t['ping'] - 500, ping),
    (1, t['udp'] - 500, sll(dgram)),
]
ng = shb() + idb(1, b'lo') + idb(113, b'any') + idb(147, b'user0')
for iface, ns, data in packets: ng += epb(iface, ns, data)
ng += isb(0, 2, 3)
pcapng = work / 'loopback.pcapng'
pcapng.write_bytes(ng)
classic = struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1)
for iface, ns, data in packets:
    if iface == 0: classic += struct.pack('<IIII', ns // 10**9, ns % 10**9 // 1000, len(data), len(data)) + data
pcap = work / 'loopback.pcap'
pcap.write_bytes(classic)
truncated = work / 'truncated.pcapng'
truncated.write_bytes(ng[:len(ng) - 30])

# ------------------------------------------------------------ offline queries

def opened(*paths):
    options_ = ['--open-pcap', str(paths[0])] + (['--open-capture', str(paths[1])] if len(paths) > 1 else [])
    return Client('observe', None, options=options_)

summary = {}
o = opened(pcapng, archive)
try:
    streams = o.inspect('list_streams')['streams']
    assert [stream['kind'] for stream in streams] == ['network', 'protocol'], streams
    s = streams[0]
    assert streams[1]['records'] == 0 and streams[1]['derived_from'] == s['stream_id'], streams[1]
    assert s['format'] == 'pcapng' and s['records'] == len(packets) and s['undecoded'] == 1, s
    assert s['file']['stop'] == 'complete' and len(s['interfaces']) == 3, s
    assert [i['link'] for i in s['interfaces']] == ['ethernet', 'linux_sll', 'unknown'], s['interfaces']
    assert s['loss']['isb_ifdrop'] == 2 and s['loss']['isb_osdrop'] == 3, s['loss']
    m = s['clock']['mapping']
    assert s['clock']['domain'] == 'realtime', s['clock']
    assert s['context']['present'] and s['context']['capture_pid'] == peer['pid'], s['context']
    if AGENT:
        assert m['state'] == 'unaligned' and m['pairs'] == 0, s['clock']
        assert s['context']['collection'] == 'not_collected' and s['context']['reason'] == 'not collected: remote', s['context']
        assert s['context']['tables'] == [], s['context']
    else:
        assert m['state'] == 'aligned' and m['pairs'] == 2, s['clock']
        assert s['context']['collection'] == 'collected' and s['context']['reason'] is None, s['context']
        assert [tb['when'] for tb in s['context']['tables']] == ['start', 'stop'], s['context']
        assert s['context']['tables'][1]['sockets'] >= 2, s['context']
    tcp_rows = o.inspect('query_stream', protocol='tcp', port=H, flows=True, limit=2)
    assert len(tcp_rows['records']) == 2 and tcp_rows['next'] is not None, tcp_rows
    rows = tcp_rows['records']
    while tcp_rows['next'] is not None:
        tcp_rows = o.inspect('query_stream', protocol='tcp', port=H, limit=2, start=tcp_rows['next'])
        rows += tcp_rows['records']
    assert [r['index'] for r in rows] == [0, 1, 2, 3, 4, 8, 9, 10, 11], rows
    assert rows[3]['decoded']['src_port'] == P and rows[3]['decoded']['payload_length'] == 4, rows[3]
    first = rows[0]['time']
    assert first['clock'] == 'realtime' and first['stream_ns'] == t['ping2'] - 3000, first
    if AGENT:
        assert all(row['time']['capture_ns'] is None and row['time']['uncertainty_ns'] is None for row in rows), rows
    else:
        assert first['capture_ns'] is not None and first['uncertainty_ns'] is not None and first['uncertainty_ns'] < 10**7, first
        assert rows[5]['time']['capture_ns'] is None, rows[5]
    joins = {}
    for index in range(len(packets)):
        j = o.inspect('correlate', record=index)
        joins[index] = j
        summary[index] = dict(basis=j['basis'], direction=j['direction'], pid=(j['process'] or {}).get('pid'))
    if AGENT:
        for index in (*range(0, 6), *range(7, len(packets))):
            assert joins[index]['basis'] == 'none' and joins[index]['reason'] == 'not collected: remote', joins[index]
            assert joins[index]['direction'] is None and joins[index]['process'] is None and joins[index]['socket'] is None, joins[index]
        assert joins[6]['basis'] == 'none' and joins[6]['record']['undecoded'] == 'unknown_link_type', joins[6]
        assert 'no 5-tuple' in joins[6]['reason'], joins[6]
    else:
        for index in (0, 2, 3):
            assert joins[index]['basis'] == 'exact' and joins[index]['direction'] == 'outbound', joins[index]
            assert joins[index]['process']['pid'] == peer['pid'] and joins[index]['socket']['local_port'] == P, joins[index]
        for index in (1, 4):
            assert joins[index]['basis'] == 'exact' and joins[index]['direction'] == 'inbound', joins[index]
        assert joins[5]['basis'] == 'exact' and joins[5]['socket']['protocol'] == 'udp' and joins[5]['socket']['local_port'] == peer['udp'], joins[5]
        assert joins[6]['basis'] == 'none' and joins[6]['record']['undecoded'] == 'unknown_link_type', joins[6]
        assert joins[7]['basis'] == 'none', joins[7]
        for index in (8, 9, 10, 11, 12):
            assert joins[index]['basis'] == 'sampled' and joins[index]['process']['pid'] == peer['pid'], joins[index]
    assert joins[0]['thread'] is None and joins[0]['thread_reason'], joins[0]
    if not AGENT: assert joins[0]['process']['comm'].startswith('python'), joins[0]
    undecoded = o.inspect('query_stream', undecoded=True, include_raw=True)['records']
    assert [r['index'] for r in undecoded] == [6] and undecoded[0]['raw_hex'] == b'opaque-user-link-record'.hex(), undecoded
    if not AGENT:
        window = o.inspect('query_stream', clock='capture', from_ns=rows[1]['time']['capture_ns'], to_ns=rows[3]['time']['capture_ns'])
        assert [r['index'] for r in window['records']] == [1, 2], window
    bad = o.tool('correlate', record=99)
    assert bad['result']['isError'] and bad['result']['content'][0]['text'] == 'UnknownRecord', bad
    (work / 'offline-rpc.json').write_text(json.dumps(o.transcript, indent=2) + '\n')
finally:
    o.close()

o = opened(pcap, archive)
try:
    s = o.inspect('list_streams')['streams'][0]
    assert s['format'] == 'pcap' and s['records'] == 10, s
    if AGENT:
        assert s['clock']['mapping']['state'] == 'unaligned', s
        j = o.inspect('correlate', record=0)
        assert j['basis'] == 'none' and j['reason'] == 'not collected: remote', j
    else:
        assert s['clock']['mapping']['state'] == 'aligned', s
        assert o.inspect('correlate', record=0)['basis'] == 'exact'
finally:
    o.close()

o = opened(pcapng)
try:
    s = o.inspect('list_streams')['streams'][0]
    assert s['clock']['mapping']['state'] == 'unaligned' and not s['context']['present'], s
    j = o.inspect('correlate', record=0)
    assert j['basis'] == 'none' and 'no capture context' in j['reason'], j
finally:
    o.close()

o = opened(truncated)
try:
    s = o.inspect('list_streams')['streams'][0]
    # The cut lands inside the trailing ISB: every packet stays, its counters do not.
    assert s['file']['stop'] == 'truncated' and s['file']['stop_offset'] > 0 and s['records'] == len(packets), s
    assert s['loss']['isb_ifdrop'] == 0, s['loss']
finally:
    o.close()

if options.gui:
    import importlib.util
    spec = importlib.util.spec_from_file_location('display', root / 'tests/helpers/display.py')
    h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
    h.WORK = str(work.resolve())
    d = h.Display('gui')
    try:
        for name, args in (('with-capture', ['--open-capture', str(archive)]), ('pcap-only', [])):
            log = open(work / ('gui-' + name + '.log'), 'wb')
            app = subprocess.Popen(['./zig-out/bin/xodb', '--mcp', '--agent-scope', 'observe', '--open-pcap', str(pcapng), *args], env=d.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, bufsize=0)
            try:
                app.stdin.write(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"net-gui","version":"1"}}}\n')
                assert json.loads(app.stdout.readline())['id'] == 1
                app.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
                app.stdin.write(b'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_streams","arguments":{}}}\n')
                reply = json.loads(app.stdout.readline())
                assert reply['result']['structuredContent']['streams'][0]['records'] == len(packets), reply
                time.sleep(2)
                d.shot('stream-lane-' + name)
                assert app.poll() is None, 'GUI exited'
                app.stdin.close()
                assert app.wait(15) == 0
            finally:
                if app.poll() is None: app.kill(); app.wait()
                log.close()
    finally:
        d.close()

(work / 'summary.json').write_text(json.dumps(dict(peer_comm='python3', joins=summary, records=len(packets)), indent=2) + '\n')
print('network evidence: pcapng/pcap/unaligned/truncated opened; correlation', {k: v['basis'] for k, v in summary.items()})
