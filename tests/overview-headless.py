#!/usr/bin/env python3
"""Headless overview: collector and observer MCP with no window, Vulkan or
compositor. Exercises process sort/filter/paging, history, the per-application
rollup, socket holders and owner hints, the RSS bound and stdin EOF exit.

Only an owned synthetic process group (tests/fixtures/overview-tree.c) is
asserted on by identity; other rows are checked for shape only.
"""
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('overview-headless-' + str(time.time_ns())[-8:])
work.mkdir(parents=True)
xodb = str(root / 'zig-out/bin/xodb')
CHILDREN = 3
# Measured 23 MiB idle, ~57 MiB once NVML (GPU sensors) is loaded; the window is ~500 MiB.
RSS_BOUND_MIB = 96
results = []


def check(name, condition, detail=''):
    results.append(dict(check=name, status='pass' if condition else 'fail'))
    # Details can hold host rows: print them only for a failure.
    print(('PASS ' + name) if condition else (f'FAIL {name} ({detail})'), flush=True)
    assert condition, f'{name} {detail}'


def eventually(probe, predicate, timeout=10):
    end = time.monotonic() + timeout
    while True:
        value = probe()
        if predicate(value):
            return value
        assert time.monotonic() < end, f'did not reach expected state: {json.dumps(value)[:400]}'
        time.sleep(.1)


class Stdio:
    def __init__(self, proc):
        self.proc = proc
        self.serial = 0
        self.pending = b''
        self.call('initialize', dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='overview-headless', version='1')))
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})

    def send(self, value):
        self.proc.stdin.write((json.dumps(value) + '\n').encode())
        self.proc.stdin.flush()

    def call(self, method, params=None):
        self.serial += 1
        self.send(dict(jsonrpc='2.0', id=self.serial, method=method, params=params or {}))
        end = time.monotonic() + 10
        fd = self.proc.stdout.fileno()
        while True:
            while b'\n' not in self.pending:
                assert select.select([fd], [], [], max(0, end - time.monotonic()))[0], 'reply timed out'
                data = os.read(fd, 1 << 20)
                assert data, 'server closed stdout'
                self.pending += data
            line, self.pending = self.pending.split(b'\n', 1)
            value = json.loads(line)
            if value.get('id') == self.serial:
                return value

    def raw(self, name, **arguments):
        return self.call('tools/call', dict(name=name, arguments=arguments))

    def tool(self, name, **arguments):
        r = self.raw(name, **arguments)
        assert not r.get('error') and not r['result']['isError'], r
        return r['result']['structuredContent']


class Peer(Stdio):
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(5)
        self.sock.connect(str(path))
        self.serial = 0
        self.pending = b''
        self.call('initialize', dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='overview-headless', version='1')))
        self.sock.sendall(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')

    def call(self, method, params=None):
        self.serial += 1
        self.sock.sendall((json.dumps(dict(jsonrpc='2.0', id=self.serial, method=method, params=params or {})) + '\n').encode())
        while True:
            while b'\n' not in self.pending:
                data = self.sock.recv(1 << 20)
                assert data, 'peer closed'
                self.pending += data
            line, self.pending = self.pending.split(b'\n', 1)
            value = json.loads(line)
            if value.get('id') == self.serial:
                return value


def headless_env():
    env = dict(os.environ)
    # No compositor or X server is reachable: the headless overview must not need one.
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'SWAYSOCK'):
        env.pop(key, None)
    runtime = work / 'runtime'
    runtime.mkdir(mode=0o700, exist_ok=True)
    env['XDG_RUNTIME_DIR'] = str(runtime)
    return env


def rss_kib(pid):
    for line in Path(f'/proc/{pid}/status').read_text().splitlines():
        if line.startswith('VmRSS:'):
            return int(line.split()[1])
    raise AssertionError('no VmRSS')


def graphics_mappings(pid):
    hits = set()
    for line in Path(f'/proc/{pid}/maps').read_text().splitlines():
        parts = line.split()
        path = parts[5] if len(parts) > 5 else ''
        name = os.path.basename(path)
        # NVML (power sensors) may map /dev/nvidiactl; drivers and WSI may not load.
        if name.startswith(('libvulkan_', 'libnvidia-glcore', 'libnvidia-eglcore', 'libnvidia-gpucomp', 'libEGL', 'libgallium', 'libwayland-cursor', 'libdecor')):
            hits.add(name or path)
    return hits


fixture_bin = work / 'overview-tree'
subprocess.run(['cc', '-O1', '-Wall', '-Wextra', '-Werror', 'tests/fixtures/overview-tree.c', '-o', str(fixture_bin)], check=True)
fixture = subprocess.Popen([str(fixture_bin), str(CHILDREN)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
server = None
socket_server = None
try:
    line = fixture.stdout.readline().decode().split()
    assert line[:1] == ['ready'], line
    group = int(line[1])
    children = [int(x) for x in Path(f'/proc/{group}/task/{group}/children').read_text().split()]
    check('owned fixture forms one process group', len(children) == CHILDREN and all(os.getpgid(p) == group for p in children))
    family = set(children) | {group}

    log = open(work / 'xodb.log', 'wb')
    server = subprocess.Popen([xodb, '--overview', '--headless', '--mcp', '--interval-ms', '250'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, env=headless_env())
    mcp = Stdio(server)
    names = {x['name'] for x in mcp.call('tools/list')['result']['tools']}
    check('headless lists the overview tools', {'list_processes', 'get_overview', 'get_history', 'get_process_groups', 'get_connections'} <= names and 'attach' not in names)
    denied = mcp.raw('attach', pid=group)
    check('headless overview cannot attach', bool(denied.get('error')) or denied['result']['isError'])

    # Burrito mode, passive: cards are listed with roles and reasons; the verdict never takes a card.
    radios = mcp.tool('list_radios')
    check('list_radios names every card with a role and a reason', isinstance(radios.get('cards'), list) and bool(radios.get('needs')) and all(c['role'] in ('in_use', 'spare', 'blocked', 'absent') and c['why'] for c in radios['cards']))
    verdict = mcp.tool('radio_interference', window_ms=1000, redact=True)
    check('radio_interference is passive and honest without a chosen card', verdict['kind'] == 'no_spectrum' and verdict['spectral']['on'] is False and verdict['tx'] is None and 'no spectrum' in verdict['words'])
    chans = mcp.tool('radio_channels', window_ms=1000)
    check('radio_channels lists 14 channels, unwatched and honest without a card', len(chans['channels']) == 14 and all(c['impact'] == 'unseen' and c['traffic'] is None for c in chans['channels']) and chans['blast'] is None and chans['traffic']['on'] is False and 'no spectrum' in chans['words'] and chans['tx'] == [])
    check('radio_interference rejects a bad window', bool(mcp.raw('radio_interference', window_ms=5).get('error')) or mcp.raw('radio_interference', window_ms=5)['result']['isError'])

    # Sort, filter and paging on the canonical process table.
    def mine(**extra):
        return mcp.tool('list_processes', filter={'match': 'overview-tree'}, **extra)
    rows = eventually(lambda: mine(sort='cpu', limit=10), lambda r: r['processes']['matched'] == CHILDREN + 1 and isinstance(r['processes']['rows'][0]['cpu_pct'], float) and r['processes']['rows'][0]['cpu_pct'] > 5)
    procs = rows['processes']
    check('filter matches exactly the owned group', {r['pid'] for r in procs['rows']} == family and procs['count'] >= procs['matched'], f"matched={procs['matched']}")
    check('cpu sort puts the burner first', procs['rows'][0]['pid'] in children and procs['rows'][0]['cpu_pct'] > 5)
    check('process rows carry process group and session', all(r.get('pgid') == group for r in procs['rows']))
    page = mine(sort='age', limit=2)['processes']
    check('age sort is oldest first, paged', page['rows'][0]['pid'] == group and page['shown'] == 2 and page['next_offset'] == 2)
    rest = mine(sort='age', limit=2, offset=2)['processes']
    check('the next page completes the group', rest['shown'] == CHILDREN + 1 - 2 and rest['next_offset'] is None and {r['pid'] for r in page['rows'] + rest['rows']} == family)
    by_uid = mcp.tool('list_processes', filter={'match': 'overview-tree', 'user': str(os.getuid()), 'state': 'R'}, limit=10)['processes']
    check('user and state filters compose', [r['pid'] for r in by_uid['rows']] == [procs['rows'][0]['pid']], json.dumps(by_uid['rows'])[:200])
    for sort in ('rss', 'io', 'fds', 'threads', 'start', 'pid'):
        mine(sort=sort, limit=1)
    bad = mcp.raw('list_processes', filter={'state': 'Q'})
    check('a bad filter is refused', bool(bad.get('error')) or bad['result']['isError'])
    overview = mcp.tool('get_overview', limit=2, filter={'match': 'overview-tree'}, sort='cpu')
    check('get_overview shares the process arguments', overview['processes']['matched'] == CHILDREN + 1 and overview['processes']['shown'] == 2)

    # Per-application rollup: the owned group is one row with every member.
    def owned_group():
        r = mcp.tool('get_process_groups', by='tree', sort='cpu', limit=200)
        return r, next((g for g in r['groups'] if g['root']['pid'] == group), None)
    rollup, row = eventually(owned_group, lambda x: x[1] is not None and x[1]['members'] == CHILDREN + 1 and isinstance(x[1]['fds'], (int, float)))
    check('tree rollup makes the owned app one row', row['members'] == CHILDREN + 1 and row['root']['pgid'] == group and row['busiest']['pid'] in children, json.dumps(row)[:300])
    check('rollup sums threads and fds of members', row['threads'] == CHILDREN + 1 and row['fds'] >= 3 * (CHILDREN + 1) and row['cpu_pct'] > 5)
    check('rollup reports total and paging', rollup['total'] >= 1 and rollup['shown'] <= 200)
    cg = mcp.tool('get_process_groups', by='cgroup', sort='members', limit=3)
    hidden = mcp.tool('get_process_groups', by='cgroup', redact=True, limit=5)
    hidden_tree = mcp.tool('get_process_groups', by='tree', redact=True, limit=200)
    check('redacted rollups hide names', all(g['cgroup'] == 'unavailable' for g in hidden['groups']) and all(g['root']['comm'] in ('process', 'kthreadd') or g['root'].get('pgid') == 0 for g in hidden_tree['groups'] if g['root']['pid'] == group))
    check('cgroup rollup answers', cg['by'] == 'cgroup' and cg['shown'] >= 1 and all('cgroup' in g for g in cg['groups']))

    # Socket holders: every member holds both ends of the owned socketpair.
    def shared_socket():
        r = mcp.tool('get_connections', pid=group, limit=50)
        return [x for x in r['connections']['rows'] if x['proto'] == 'unix' and set(x.get('holders', [])) == family]
    holders = eventually(shared_socket, lambda x: len(x) >= 2)
    check('own-uid sockets name every holder', all(x['holder_count'] == CHILDREN + 1 and x['pid'] == group for x in holders))
    conns = mcp.tool('get_connections', limit=300)['connections']['rows']
    hinted = [x for x in conns if isinstance(x['pid'], dict) and x['pid'].get('why') == 'needs privilege']
    check('every privileged owner carries an owner hint', all(isinstance(x.get('owner_hint', {}).get('uid'), int) and 'explain' in x['owner_hint'] for x in hinted), f'{len(hinted)} privileged sockets')
    # A stuck socket of our own uid: loopback, the peer never reads.
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    sender = socket.socket()
    sender.connect(listener.getsockname())
    receiver, _ = listener.accept()
    sender.setblocking(False)
    try:
        while True:
            sender.send(b'x' * 65536)
    except BlockingIOError:
        pass
    port = sender.getsockname()[1]
    def stuck():
        r = mcp.tool('get_connections', filter={'uid': os.getuid(), 'queued': True, 'proto': 'tcp'}, limit=400)['connections']
        return [x for x in r['rows'] if x['local'] == f'127.0.0.1:{port}']
    rows = eventually(stuck, lambda x: len(x) == 1)
    check('own-uid stuck socket is found by filter with its holder', rows[0]['tx_queue'] > 0 and rows[0]['holders'] == [os.getpid()], json.dumps(rows)[:300])
    def own_pages():
        seen, offset = [], 0
        while offset is not None:
            page = mcp.tool('get_connections', pid=os.getpid(), filter={'proto': 'tcp'}, limit=1, offset=offset)['connections']
            seen += [x['inode'] for x in page['rows']]
            offset = page['next_offset']
        return seen
    seen = eventually(own_pages, lambda s: len(s) == 3)
    check('connection pages cover the owned sockets once', len(set(seen)) == 3)
    check('listen filter returns only listeners', all(x['state'] == 'LISTEN' for x in mcp.tool('get_connections', filter={'state': 'LISTEN'}, limit=50)['connections']['rows']))
    for s in (sender, receiver, listener):
        s.close()

    # History: bounded series with sample times, and an explicitly tracked process.
    burner = procs['rows'][0]['pid']
    tracked = mcp.tool('get_history', group='processes', pid=burner, seconds=10, step=1)
    check('a pid can be tracked explicitly', tracked.get('tracked') is True)
    def cpu_history():
        return mcp.tool('get_history', group='cpu', seconds=10, step=1)
    cpu = eventually(cpu_history, lambda r: not r['pending'] and r['retained_s'] >= 3, timeout=15)
    busy = cpu['series']['cpu_busy_pct']
    check('cpu history is bounded with sample times', cpu['points'] == 10 and len(busy) == 10 and len(cpu['times_s']) == 10 and cpu['times_s'][-1] == 0 and busy[-1] is not None, json.dumps(busy))
    check('history says what it retains', cpu['capacity_rows'] == 1200 and cpu['rows'] >= 3)
    psi = mcp.tool('get_history', group='psi', seconds=5)
    check('psi history has cpu, memory and io series', {'psi_cpu_some10', 'psi_memory_some10', 'psi_io_some10'} <= set(psi['series']))
    for name in ('per_cpu', 'memory', 'disks', 'network'):
        h = mcp.tool('get_history', group=name, seconds=5)
        check(f'{name} history answers', not h['pending'] and h['series'])
    def burner_history():
        r = mcp.tool('get_history', group='processes', pid=burner, seconds=5, step=0.5)
        return r['processes'][0]['series']['cpu_pct'] if r['processes'] else []
    series = eventually(burner_history, lambda s: sum(1 for v in s if v is not None and v > 5) >= 2)
    check('tracked process cpu history', max(v for v in series if v is not None) > 5)
    wide = mcp.tool('get_history', group='cpu', seconds=3600, step=0.1)
    check('replies widen the step rather than exceed 600 points', wide['points'] <= 600 and wide['step_s'] >= 6)

    # The socket endpoint serves the same cache without a window.
    sock_path = work / 's'
    socket_server = subprocess.Popen([xodb, '--overview', '--headless', '--session-socket', str(sock_path)], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log, env=headless_env())
    end = time.monotonic() + 5
    while not sock_path.exists():
        assert time.monotonic() < end and socket_server.poll() is None, 'socket endpoint did not start'
        time.sleep(.05)
    peer = Peer(sock_path)
    peer_rows = eventually(lambda: peer.tool('list_processes', filter={'match': 'overview-tree'}), lambda r: r['processes']['matched'] == CHILDREN + 1)
    check('socket peer reads the headless cache', {r['pid'] for r in peer_rows['processes']['rows']} == family)
    peer.sock.close()

    # Footprint and the absence of any graphics stack.
    rss = rss_kib(server.pid)
    check(f'headless RSS under {RSS_BOUND_MIB} MiB', rss < RSS_BOUND_MIB * 1024, f'{rss / 1024:.1f} MiB')
    check('no graphics driver or compositor is loaded', not graphics_mappings(server.pid) and not graphics_mappings(socket_server.pid), str(graphics_mappings(server.pid)))
    cost = mcp.tool('get_overview', limit=1)['self']
    print(f"INFO headless rss {rss / 1024:.1f} MiB collector cpu {cost['cpu_pct_of_core']} % of a core", flush=True)

    # stdin EOF ends the session promptly.
    started = time.monotonic()
    server.stdin.close()
    server.wait(timeout=5)
    elapsed = time.monotonic() - started
    check('stdin EOF exits in under 1 s', elapsed < 1.0 and server.returncode == 0, f'{elapsed:.3f} s rc={server.returncode}')
    server = None
    socket_server.send_signal(signal.SIGTERM)
    socket_server.wait(timeout=5)
    check('socket endpoint exits on SIGTERM', socket_server.returncode == 0)
    socket_server = None
finally:
    for p in (server, socket_server):
        if p is not None and p.poll() is None:
            p.kill()
            p.wait()
    if fixture.poll() is None:
        fixture.stdin.close()
        try:
            fixture.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(fixture.pid, signal.SIGKILL)
            fixture.wait()
(work / 'results.json').write_text(json.dumps(results, indent=1))
print(f'overview-headless: {len(results)} checks passed')
