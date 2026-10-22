#!/usr/bin/env python3
"""--redact in debugger modes: live MCP, saved archives, --open-capture,
--open-pcap, the log file and (--gui) the drawn window.

The private names are read from this machine at run time and never printed:
host name, user name, home path, and a non-loopback address and a MAC of this
machine when it has them. A failed check names only the kind that leaked.
Each surface is first run without --redact as a control, so a check that
could not see the names fails instead of passing.

Fixtures are synthetic: the profile fixture (built under this checkout, so
its paths lie under the home directory), a Python peer holding UDP sockets
connected to loopback and to this machine's own address (connect sends
nothing), and a pcapng written here. --gui OCRs a private headless Sway.
"""
import argparse, ipaddress, json, os, pwd, re, shutil, socket, struct, subprocess, sys, time
from datetime import datetime
from pathlib import Path
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
parser = argparse.ArgumentParser()
parser.add_argument('--work', default='.work/redact-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
parser.add_argument('--gui', action='store_true')
options = parser.parse_args()
work = Path(options.work).resolve()
work.mkdir(parents=True, exist_ok=True)

# ------------------------------------------------------------ this machine's names (never printed)

def machine():
    names = {'host': set(), 'user': set(), 'home': set()}
    host = socket.gethostname()
    names['host'] |= {host, host.split('.')[0]}
    pw = pwd.getpwuid(os.getuid())
    names['user'] |= {pw.pw_name, os.environ.get('USER', ''), os.path.basename(os.path.expanduser('~').rstrip('/'))}
    names['home'] |= {os.path.expanduser('~').rstrip('/'), pw.pw_dir.rstrip('/')}
    short = {kind: {v for v in values if len(v) == 2} for kind, values in names.items()}
    for kind in names:
        names[kind] = {v for v in names[kind] if len(v) >= 3 and v.lower() not in ('localhost', 'root')}
    addresses = []
    try:
        lines = Path('/proc/net/fib_trie').read_text().splitlines()
        for i, line in enumerate(lines[1:], 1):
            if '/32 host LOCAL' in line:
                addresses.append(ipaddress.ip_address(lines[i - 1].split()[-1]))
    except OSError: pass
    try:
        for line in Path('/proc/net/if_inet6').read_text().splitlines():
            addresses.append(ipaddress.ip_address(bytes.fromhex(line.split()[0])))
    except OSError: pass
    def private(a):
        if a.is_loopback or a.is_unspecified: return False
        docs = ('192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24', '2001:db8::/32')
        return not any(a in ipaddress.ip_network(n) for n in docs)
    addresses = sorted({a for a in addresses if private(a)}, key=lambda a: (a.version, str(a)))
    macs = set()
    for path in Path('/sys/class/net').glob('*/address'):
        try: value = path.read_text().strip().lower()
        except OSError: continue
        if re.fullmatch(r'([0-9a-f]{2}:){5}[0-9a-f]{2}', value) and value not in ('00:00:00:00:00:00', 'ff:ff:ff:ff:ff:ff'): macs.add(value)
    return names, short, addresses, macs

# The rule of src/redact.zig: names of 8+ characters are searched anywhere,
# shorter ones as tokens (between non-letters, or at a camelCase step), and
# 2-character names between bytes that are not letters, digits or '_' (not in
# OCR text).
NAMES, SHORT, ADDRESSES, MACS = machine()
V4 = next((a for a in ADDRESSES if a.version == 4), None)
AGENT = bool(os.environ.get('XODB_TEST_RUNTIME_AGENT'))

def token(text, name):
    """name in text as src/redact.zig matches it (3+ characters)."""
    for m in re.finditer(re.escape(name), text, re.I):
        if len(name) >= 8: return True
        at, end = m.span()
        letter = lambda ch: ch.isascii() and ch.isalpha()
        start = at == 0 or not letter(text[at - 1]) or (text[at - 1].islower() and text[at].isupper())
        stop = end == len(text) or not letter(text[end]) or (text[end - 1].islower() and text[end].isupper())
        if start and stop: return True
    return False

def leaks(text, words=True):
    """Kinds of private names found in text (str, or bytes read as Latin-1)."""
    if isinstance(text, bytes): text = text.decode('latin-1')
    low = text.lower()
    found = {kind for kind, values in NAMES.items() for v in values if token(text, v)}
    if words: found |= {kind for kind, values in SHORT.items() for v in values if re.search(r'(?<![a-z0-9_])' + re.escape(v.lower()) + r'(?![a-z0-9_])', low)}
    for a in ADDRESSES:
        if re.search(r'(?<![0-9a-f:.])' + re.escape(a.compressed.lower()) + r'(?![0-9a-f:.])', low): found.add('address')
    if any(m in low or m.replace(':', '-') in low for m in MACS): found.add('mac')
    return sorted(found)

def strings(data, n=8):
    """Printable runs, as `strings -n 8`: random bytes rarely spell a name."""
    return '\n'.join(m.decode('latin-1') for m in re.findall(rb'[\x20-\x7e]{%d,}' % n, data))

def check(label, text, want_leak, words=True):
    found = leaks(text, words)
    if want_leak: assert found, f'{label}: control run shows none of the machine names; the check cannot see them'
    else: assert not found, f'{label}: leaked {found}'
    return found

def replies(c):
    """What xodb sent: the requests carry this harness's own paths."""
    return json.dumps([t.get('response', t.get('notification')) for t in c.transcript])

def error(response, name):
    assert response['result']['isError'] and response['result']['content'][0]['text'] == name, response['result']['content'][0]['text']

def archive_done(c):
    deadline = time.monotonic() + 30
    while True:
        job = c.inspect('get_archive_status')['job']
        if job['done']: return job
        assert time.monotonic() < deadline, 'archive job did not finish'
        time.sleep(.01)

def section(raw, tag):
    count = struct.unpack_from('<I', raw, 24)[0]
    for i in range(count):
        kind, _, offset, size = struct.unpack_from('<IIQI', raw, 64 + 24 * i)
        if kind == tag: return raw[offset:offset + size]
    return None

summary = dict(names={k: len(v) + len(SHORT[k]) for k, v in NAMES.items()}, addresses=len(ADDRESSES), ipv4=V4 is not None, macs=len(MACS))

fixture = root / 'zig-out/bin/xodb-profile-fixture'

# ------------------------------------------------------------ GUI: OCR of a private headless Sway

def gui():
    import importlib.util
    from PIL import Image, ImageOps
    spec = importlib.util.spec_from_file_location('display', root / 'tests/helpers/display.py')
    h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
    h.WORK = str(work)
    d = h.Display('gui')
    try:
        for redact in (False, True):
            name = 'gui-redact' if redact else 'gui-control'
            log = open(work / (name + '.log'), 'wb')
            stop_file = work / (name + '-stop')
            # The source and stack panes name the source file: build the
            # profile fixture from a copy named after the user.
            named = work / (sorted(NAMES['user'])[0] + '-profile.c')
            built = work / 'gui-profile-fixture'
            if not built.exists():
                shutil.copy2(root / 'tests/fixtures/profile.c', named)
                subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-pthread', str(named), '-o', str(built)], check=True, timeout=60)
            app = subprocess.Popen(['./zig-out/bin/xodb', '--mcp', '--agent-scope', 'control', *(['--redact'] if redact else []), '--language-off', 'all', '--break', 'profile_ready', '--', str(built), '60', 'threads', str(stop_file)], env=d.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, bufsize=0)
            try:
                def call(i, method, params):
                    app.stdin.write((json.dumps(dict(jsonrpc='2.0', id=i, method=method, params=params)) + '\n').encode())
                    while True:
                        line = json.loads(app.stdout.readline())
                        if line.get('id') == i: return line
                call(1, 'initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'redact-gui', 'version': '1'}})
                app.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
                deadline = time.monotonic() + 30
                n = 2
                while True:
                    state = call(n, 'tools/call', {'name': 'get_session', 'arguments': {}})['result']['structuredContent']; n += 1
                    if state['state'] == 'stopped' and not state['symbol_discovery_pending']:
                        if any(t['reason'] == 'breakpoint' for t in state['threads']): break
                        if state['threads'][0]['reason'] in ('exec', 'initial'):
                            call(n, 'tools/call', {'name': 'continue', 'arguments': {'generation': state['generation']}}); n += 1
                    assert time.monotonic() < deadline, 'GUI target did not stop at profile_ready'
                    time.sleep(.05)
                time.sleep(1.5)
                shot = d.shot(name)
                ocr = ''
                with Image.open(shot) as image:
                    big = ImageOps.invert(image.convert('L'))
                    big = big.resize((big.width * 2, big.height * 2))
                    crop = shot.replace('.png', '-ocr.png')
                    big.save(crop)
                for psm in ('3', '11'):
                    ocr += subprocess.run(['tesseract', crop, 'stdout', '--psm', psm], env=dict(d.env, OMP_THREAD_LIMIT='1'), capture_output=True, text=True, check=True, timeout=60).stdout
                Path(shot + '.txt').write_text(ocr)
                summary[name] = check(name + ' OCR', ocr, not redact, words=False)
                assert app.poll() is None, 'GUI exited'
            finally:
                stop_file.touch()
                if app.poll() is None:
                    app.stdin.close()
                    try: app.wait(15)
                    except subprocess.TimeoutExpired: app.kill(); app.wait()
                log.close()
    finally:
        d.close()


if options.gui:
    gui()
    (work / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f"redact: the drawn window holds none of this machine's names (OCR; names {summary['names']})")
    sys.exit(0)

# ------------------------------------------------------------ A: live debugger + capture archive (profile fixture)

def live_capture(redact, name):
    stop_file = work / (name + '-stop')
    archive = work / (name + '.xoc')
    log_file = work / (name + '.log')
    for p in (stop_file, archive, log_file):
        if p.exists(): p.unlink()
    flags = (['--redact'] if redact else []) + ['--language-off', 'all', '-v', '--log-file', str(log_file)]
    c = Client('control', str(fixture), args=['60', 'threads', str(stop_file)], options=flags)
    try:
        bp = c.action('set_breakpoint', symbol='profile_ready')['id']
        c.action('continue'); c.stopped('breakpoint'); c.action('remove_breakpoint', id=bp)
        tid = c.session()['threads'][0]['id']
        for tool, args in (('list_modules', {}), ('get_stack', dict(tid=tid)), ('get_source_location', {}), ('find_symbol', dict(name='hot_hash')), ('get_stop_info', {})):
            c.tool(tool, **args)
        # The system tools take the overview's own rules too (other accounts,
        # command lines): a path lookup is refused, as with --overview --redact.
        lookup = c.tool('who_has_open', path=str(log_file))['result']
        assert lookup['isError'] == redact and (not redact or lookup['content'][0]['text'] == 'FdPathLookupRedacted'), 'who_has_open under --redact'
        c.tool('get_process', pid=c.p.pid)
        cap = c.action('start_profile', frequency_hz=199, duration_ms=0)['capture']
        c.action('continue')
        time.sleep(.4)
        c.action('interrupt'); c.stopped()
        cap = c.action('stop_profile', capture_id=cap['id'])['capture']
        c.tool('get_profile_mappings', capture_id=cap['id'], revision=cap['revision'])
        c.action('save_capture_archive', capture_id=cap['id'], revision=cap['revision'], path=str(archive))
        job = archive_done(c)
        assert job['error_name'] is None and job['publication']['state'] == 'published', job['error_name']
        stop_file.touch()
    finally:
        stop_file.touch()
        transcript = replies(c)
        c.close()
    return transcript, archive, log_file

for redact in (False, True):
    name = 'live-redact' if redact else 'live-control'
    transcript, archive, log_file = live_capture(redact, name)
    raw = archive.read_bytes()
    flags = struct.unpack_from('<Q', raw, 48)[0]
    assert (flags & 1 != 0) == redact, flags
    summary[name] = dict(mcp=check(name + ' MCP replies', transcript, not redact), archive=check(name + ' archive', strings(raw), not redact), archive_bytes=len(raw))
    log_text = log_file.read_text(errors='replace')
    assert log_text.strip(), 'empty log'
    summary[name]['log'] = check(name + ' log file', log_text, False) if redact else leaks(log_text)
    if redact: (work / 'live-mcp.json').write_text(transcript)
redacted_archive, control_archive = work / 'live-redact.xoc', work / 'live-control.xoc'

# A redacted archive opened anywhere, with or without --redact, holds no names;
# its copy under --redact is allowed, an unredacted archive's copy is refused.
for flags in ([], ['--redact']):
    # A relative path: without --redact, xodb echoes the path it was given.
    o = Client('observe', None, options=['--open-capture', os.path.relpath(redacted_archive), *flags])
    try:
        status = o.inspect('get_archive_status')
        assert status['recorded_origin']['redacted'], 'redacted flag not reported'
        cap = o.inspect('get_profile')['capture']
        o.tool('get_profile_mappings', capture_id=cap['id'], revision=cap['revision'])
        o.tool('get_flamegraph', capture_id=cap['id'], revision=cap['revision'])
        check('reopened redacted archive' + (' --redact' if flags else ''), replies(o), False)
    finally: o.close()
for source, allowed in ((redacted_archive, True), (control_archive, False)):
    copy = work / ('copy-of-' + source.name)
    if copy.exists(): copy.unlink()
    o = Client('control', None, options=['--open-capture', str(source), '--redact'])
    try:
        cap = o.inspect('get_profile')['capture']
        o.tool('save_capture_archive', generation=o.session()['generation'], capture_id=cap['id'], revision=cap['revision'], path=str(copy))
        job = archive_done(o)
        assert (job['error_name'] is None) == allowed, job['error_name']
        if not allowed: assert job['error_name'] == 'ArchiveNotRedacted', job['error_name']
    finally: o.close()
    assert copy.exists() == allowed
summary['copy'] = 'redacted copy kept, unredacted copy refused (ArchiveNotRedacted)'

# ------------------------------------------------------------ B: socket tables (ECTX) and --open-pcap

PEER = r'''
import json, os, socket, sys, time
ready, stop, address = sys.argv[1], sys.argv[2], sys.argv[3]
lo = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); lo.connect(('127.0.0.1', 9))
own = None
if address:
    own = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); own.bind((address, 0)); own.connect((address, 9))
info = dict(pid=os.getpid(), lo=lo.getsockname()[1], own=own.getsockname()[1] if own else None)
with open(ready + '.tmp', 'w') as f: json.dump(info, f)
os.rename(ready + '.tmp', ready)
deadline = time.monotonic() + 60
while not os.path.exists(stop) and time.monotonic() < deadline: time.sleep(.01)
'''

def block(kind, body):
    body += b'\0' * (-len(body) % 4)
    return struct.pack('<II', kind, 12 + len(body)) + body + struct.pack('<I', 12 + len(body))
def ipv4(proto, src, dst, payload):
    return struct.pack('!BBHHHBBH4s4s', 0x45, 0, 20 + len(payload), 0, 0x4000, 64, proto, 0, socket.inet_aton(src), socket.inet_aton(dst)) + payload
def udp(sport, dport, data):
    return struct.pack('!HHHH', sport, dport, 8 + len(data), 0) + data
def epb(ns, data):
    data = b'\0' * 12 + b'\x08\x00' + data
    return block(6, struct.pack('<IIIII', 0, ns >> 32, ns & 0xffffffff, len(data), len(data)) + data)

def peer_capture(redact, name):
    ready, stop, archive = work / (name + '-ready'), work / (name + '-stop'), work / (name + '.xoc')
    for p in (ready, stop, archive):
        if p.exists(): p.unlink()
    c = Client('control', shutil.which('python3'), args=['-I', '-c', PEER, str(ready), str(stop), str(V4) if V4 else ''], options=(['--redact'] if redact else []) + ['--language-off', 'all'])
    try:
        c.continue_initial_stop()
        deadline = time.monotonic() + 20
        while not ready.exists():
            assert time.monotonic() < deadline, 'peer did not report'
            time.sleep(.01)
        peer = json.loads(ready.read_text())
        c.action('interrupt'); c.stopped()
        cap = c.action('start_profile', frequency_hz=99, duration_ms=0)['capture']
        c.action('continue')
        time.sleep(.1)
        middle = time.time_ns()
        time.sleep(.1)
        cap = c.action('stop_profile', capture_id=cap['id'])['capture']
        c.action('save_capture_archive', capture_id=cap['id'], revision=cap['revision'], path=str(archive))
        job = archive_done(c)
        assert job['error_name'] is None, job['error_name']
    finally:
        stop.touch()
        c.close()
    return peer, middle, archive

for redact in (False, True):
    name = 'peer-redact' if redact else 'peer-control'
    peer, middle, archive = peer_capture(redact, name)
    ectx = section(archive.read_bytes(), 0x58544345)
    assert ectx is not None and ectx[0] == (2 if redact else 1), 'ECTX schema'
    if AGENT:
        assert len(ectx) == 15 and ectx[13:] == b'\0\0', f'{name}: remote ECTX is not empty'
    elif V4:
        raw_address = V4.packed
        assert (raw_address in ectx) != redact, f'{name}: raw address bytes in socket tables: {raw_address in ectx}'
    summary[name] = dict(ectx_bytes=len(ectx), schema=ectx[0])

# A pcapng with this machine's address (when it has one), a synthetic private
# peer, a documentation peer (kept) and loopback (kept, still correlates).
own = str(V4) if V4 else '10.11.12.13'
packets = [
    epb(middle, ipv4(17, '127.0.0.1', '127.0.0.1', udp(peer['lo'], 9, b'loop'))),
    epb(middle + 1000, ipv4(17, own, '172.16.31.7', udp(5353, 5353, b'private-payload'))),
    epb(middle + 2000, ipv4(17, own, '203.0.113.9', udp(4000, 53, b'doc'))),
]
pcap = work / 'redact.pcapng'
pcap.write_bytes(block(0x0a0d0d0a, struct.pack('<IHHq', 0x1a2b3c4d, 1, 0, -1)) + block(1, struct.pack('<HHI', 1, 0, 65535)) + b''.join(packets))

def pcap_session(redact):
    o = Client('observe', None, options=['--open-pcap', str(pcap), '--open-capture', str(archive)] + (['--redact'] if redact else []))
    try:
        stream = o.inspect('list_streams')['streams'][0]
        assert stream['context']['redacted'], 'archive socket tables not marked redacted'
        rows = o.inspect('query_stream', flows=True)
        joins = [o.inspect('correlate', record=i) for i in range(len(packets))]
        raw = o.tool('query_stream', include_raw=True)
        return replies(o), rows, joins, raw
    finally: o.close()

text, rows, joins, raw = pcap_session(False)
assert '172.16.31.7' in text and '203.0.113.9' in text, 'control: pcap addresses not shown'
if not V4: check('pcap control', text, False)
text, rows, joins, raw = pcap_session(True)
check('--open-pcap --redact replies', text, False)
assert '172.16.31.7' not in text and own not in text and '203.0.113.9' in text and '127.0.0.1' in text, 'pcap address rule'
srcs = [r['decoded']['src'] for r in rows['records']]
assert srcs[1].startswith('ip-') and srcs[1] == srcs[2], 'one peer, one tag'
if AGENT:
    assert joins[0]['basis'] == 'none' and joins[0]['process'] is None, joins[0]
else:
    assert joins[0]['basis'] in ('exact', 'sampled') and joins[0]['process']['pid'] == peer['pid'], joins[0]['basis']
error(raw, 'RawPayloadRedacted')
(work / 'pcap-redact.json').write_text(text)
summary['pcap'] = dict(records=len(rows['records']), loopback_basis=joins[0]['basis'], include_raw='RawPayloadRedacted')

(work / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(f"redact: MCP, archives, copies, socket tables, pcap and log hold none of this machine's names (names {summary['names']}, addresses {summary['addresses']}, macs {summary['macs']})")
