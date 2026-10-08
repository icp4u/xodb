#!/usr/bin/env python3
"""One live GUI cache, stdio plus two socket peers, and confirmed process actions.

Only an owned sleeping fixture is inspected/attached. Private headless Sway;
no inherited display. Saved screenshots and live logs stay in .work.
"""
import importlib.util
import ctypes
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import time
from PIL import Image

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-ol-' + str(time.time_ns())[-8:])
work.mkdir(parents=True)
for name in ('tmp', 'cache'):
    (work / name).mkdir()
spec = importlib.util.spec_from_file_location('overview_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
# Keep the exact byte evidence if a peer violates JSON framing.
original_json_loads = h.json.loads
def checked_json(line, *args, **kwargs):
    try: return original_json_loads(line, *args, **kwargs)
    except json.JSONDecodeError:
        (work / 'invalid-response.bin').write_bytes(line if isinstance(line, bytes) else line.encode())
        raise
h.json.loads = checked_json
for xml, stem in ((h.VPTR, 'vp'), (h.VKBD, 'vk')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
# vinput uses these header names.
(work / 'virtual-pointer.h').write_bytes((work / 'vp.h').read_bytes())
(work / 'virtual-keyboard.h').write_bytes((work / 'vk.h').read_bytes())
h.HELPER = str(work / 'input')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'vp.c'), str(work / 'vk.c'),
                '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
results = []
def check(name, condition):
    results.append(dict(check=name, status='pass' if condition else 'fail'))
    print(('PASS ' if condition else 'FAIL ') + name, flush=True)
    assert condition, name

def eventually(probe, predicate, timeout=5):
    end = time.monotonic() + timeout
    while True:
        value = probe()
        if predicate(value): return value
        assert time.monotonic() < end, 'cache did not reach expected state'
        time.sleep(.03)

class Peer:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(5)
        self.sock.connect(str(path))
        self.pending = b''
        self.serial = 0
        self.call('initialize', dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='overview-test', version='1')))
        self.sock.sendall(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    def call(self, method, params=None):
        self.serial += 1
        self.sock.sendall((json.dumps(dict(jsonrpc='2.0', id=self.serial, method=method, params=params or {}))+'\n').encode())
        while True:
            while b'\n' not in self.pending:
                data = self.sock.recv(65536)
                assert data, 'peer closed'
                self.pending += data
            line, self.pending = self.pending.split(b'\n', 1)
            value = json.loads(line)
            if value.get('id') == self.serial: return value
    def tool(self, name, **arguments):
        r = self.call('tools/call', dict(name=name, arguments=arguments))
        assert not r.get('error') and not r['result']['isError'], r
        return r['result']['structuredContent']
    def close(self): self.sock.close()

def start_ticks(pid):
    return int(Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[19])

def tracer(pid):
    text = Path(f'/proc/{pid}/status').read_text()
    return int(re.search(r'^TracerPid:\s*(\d+)', text, re.M)[1])

# Handoff windows can outlive their parent. Adopt only this test's descendants
# so terminal/debugger grandchildren are reaped here rather than by the gate.
libc = ctypes.CDLL(None, use_errno=True)
if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER, process-local
    raise OSError(ctypes.get_errno(), 'test subreaper')

def reap_descendants():
    children_file = Path(f'/proc/{os.getpid()}/task/{os.getpid()}/children')
    for sig in (signal.SIGTERM, signal.SIGKILL):
        deadline = time.monotonic() + 2
        while True:
            children = [int(x) for x in children_file.read_text().split()]
            if not children: return
            for pid in children:
                try:
                    # Still our unreaped child: its PID cannot be reused here.
                    if os.waitpid(pid, os.WNOHANG)[0] == 0: os.kill(pid, sig)
                except (ChildProcessError, ProcessLookupError): pass
            if time.monotonic() >= deadline: break
            time.sleep(.02)
    assert not children_file.read_text().strip(), 'owned handoff descendants remain'

fixture = subprocess.Popen(['sleep', '120'])
d = None
peers = []
handed_children = {}
os.environ['XODB_OVERVIEW_AUDIT'] = '1'
try:
    ticks = start_ticks(fixture.pid)
    d = h.Display.__new__(h.Display)
    h.Display.__init__(d, str(root), ['--overview', '--panel', 'processes', '--interval-ms', '1000', '--session-socket', str(work / 's')], trace=False)
    peers = [Peer(work / 's'), Peer(work / 's')]
    definitions = d.request('tools/list')['tools']
    names = {x['name'] for x in definitions}
    expected = {'get_overview','get_process','list_processes','get_connections','get_sensors','get_memory_map','get_thp_state','get_fragmentation',
                'get_fd_activity','who_has_open','get_fd_leaks','get_deleted_open'}
    check('overview exposes only observer tools', names == expected and all(x['annotations']['readOnlyHint'] for x in definitions))
    shared_names = {x['name'] for x in peers[0].call('tools/list')['result']['tools']}
    check('socket peers expose only observation and membership tools', shared_names == names | {'get_session_clients','get_session_events'})
    for forbidden in ('attach','claim_session_control'):
        denied_peer = peers[0].call('tools/call',dict(name=forbidden,arguments={'pid':fixture.pid}))
        check('socket observer rejects ' + forbidden, bool(denied_peer.get('error')) and tracer(fixture.pid) == 0)
    denied = d.request('tools/call', dict(name='attach', arguments={'pid':fixture.pid}))
    check('overview MCP cannot attach', denied is None or denied.get('isError', False))
    event_args = dict(pid=fixture.pid, start_ticks=ticks, acknowledge_host_cost=True)
    denied_event = peers[0].call('tools/call', dict(name='start_fd_events', arguments=event_args))
    check('overview socket cannot start costly exact capture', denied_event.get('result', {}).get('isError', False))
    denied_event_stdio = d.request('tools/call', dict(name='start_fd_events', arguments=event_args))
    check('overview stdio cannot start costly exact capture', denied_event_stdio is None or denied_event_stdio.get('isError', False))
    idle_events = peers[0].tool('get_fd_activity', mode='events', pid=fixture.pid, start_ticks=ticks)
    check('opening cached event observation leaves capture inactive', not idle_events['running'] and not idle_events['exact_mode_active'] and 'roughly 10 %' in idle_events['host_cost'])
    def observed(peer): return peer.tool('get_process', pid=fixture.pid)
    first = eventually(lambda: observed(peers[0]), lambda x: x['processes']['rows'] and not x['process_detail_pending'] and not any(g['pending'] for g in x['cache'].values()))
    row = first['processes']['rows'][0]
    check('owned process identity and state agree with proc', row['pid'] == fixture.pid and row['start_ticks'] == ticks and row['state'] == 'S')
    check('full process fields are collected', row['fds'] > 0 and isinstance(row['io_read_bytes'], int))
    def memory_peer(peer):
        reply = peer.call('tools/call', dict(name='get_memory_map', arguments=dict(pid=fixture.pid,start_ticks=ticks,limit=1)))
        if reply.get('error') or reply.get('result',{}).get('isError'):
            assert 'MemoryCacheBusy' in json.dumps(reply), reply
            return None
        value = reply['result']['structuredContent']
        return value if value.get('process') is not None else None
    memory = eventually(lambda:memory_peer(peers[0]),bool,timeout=20)
    second_memory = eventually(lambda:memory_peer(peers[1]),bool,timeout=20)
    check('overview memory peers share one owner and pinned scope', memory['owner_instances']==second_memory['owner_instances']==1 and memory['ticket']==second_memory['ticket'] and memory['process']['start_ticks']==ticks)
    def memory_stdio():
        reply = d.request('tools/call', dict(name='get_memory_map', arguments=dict(pid=fixture.pid,start_ticks=ticks,limit=1)))
        if reply.get('error') or reply.get('isError'):
            assert 'MemoryCacheBusy' in json.dumps(reply), reply
            return None
        return reply['structuredContent']
    shared_memory = eventually(memory_stdio,bool,timeout=20)
    check('overview stdio borrows the same memory owner', shared_memory['ticket']==memory['ticket'] and shared_memory['owner_instances']==1)
    before = observed(peers[0])
    burst = [observed(peers[i % 2]) for i in range(12)]
    check('request burst reads existing samples', len({x['sequence'] for x in burst}) <= 2 and all(x['processes']['rows'][0]['start_ticks'] == ticks for x in burst))
    redacted = peers[0].tool('get_process', pid=fixture.pid, redact=True)
    plain = observed(peers[1])
    check('reply redaction preserves the shared cache', isinstance(redacted['processes']['rows'][0]['cmdline'], dict) and isinstance(plain['processes']['rows'][0]['cmdline'], str))
    peers[0].close(); peers.pop(0)
    check('disconnect preserves the collector', observed(peers[0])['sequence'] >= before['sequence'])
    # Select only our target by PID, then inspect/cancel each action dialog.
    d.keys('tap', 47) # flat list, so ancestors cannot be selected
    d.keys('tap', 53) # slash
    typed = [item for digit in str(fixture.pid) for item in ('tap', 11 if digit == '0' else int(digit)+1)]
    d.keys(*typed, 'tap', 28)
    d.keys('tap', 108)
    before_children = Path(f'/proc/{d.app.pid}/task/{d.app.pid}/children').read_text()
    d.keys('down', 28, *(['group', 0] * 25), 'up', 28)
    check('holding Enter cannot confirm attach', tracer(fixture.pid) == 0 and Path(f'/proc/{d.app.pid}/task/{d.app.pid}/children').read_text() == before_children)
    d.keys('tap', 1)
    for key, label, words in ((38,'files',('Read-only','once per second','permissions')), (33,'profile',('99 Hz','10 seconds','stops all threads')), (28,'attach',('stops all threads','ptrace','separate debugger window'))):
        d.keys('tap', key)
        path = d.shot('confirm-' + label)
        crop = Path(path).with_suffix('.dialog.png')
        Image.open(path).crop((190,260,1090,540)).save(crop)
        text = subprocess.check_output(['tesseract', str(crop), 'stdout', '--psm', '6'], stderr=subprocess.DEVNULL, text=True)
        crop.with_suffix('.txt').write_text(text)
        check(label + ' states cost and access before confirmation', all(word in text for word in words))
        check(label + ' has no side effect before confirmation', tracer(fixture.pid) == 0)
        d.keys('tap', 1)
        check(label + ' cancel leaves target running', tracer(fixture.pid) == 0)
    def descendants(pid):
        found = []
        try: children = Path(f'/proc/{pid}/task/{pid}/children').read_text().split()
        except FileNotFoundError: return found
        for child in children:
            child = int(child)
            found.append(child)
            found.extend(descendants(child))
        return found
    def remember(pid):
        handed_children[pid] = start_ticks(pid)
        return pid
    def perf_count(pid):
        count = 0
        for fd in Path(f'/proc/{pid}/fd').iterdir():
            try: count += 'perf_event' in os.readlink(fd)
            except FileNotFoundError: pass
        return count
    cadence_audit = Path(d.log).read_text()
    d.keys('tap',38)
    time.sleep(.3)
    d.keys('tap',28)
    files_audit = eventually(lambda: Path(d.log).read_text(), lambda text: re.search(rf'filter_pid={fixture.pid} start={ticks} rows=[1-9][0-9]* mode=files', text) is not None, timeout=25)
    check('confirmed Files opens the selected identity inside overview', f'filter_pid={fixture.pid} start={ticks}' in files_audit and tracer(fixture.pid) == 0)
    check('Files drilldown starts no terminal child', not descendants(d.app.pid))
    text = h.ocr(d.shot('files-pane'))
    check('Files pane title and polling qualification are visible', 'Files' in text and ('progress' in text.lower() or 'shared polling' in text.lower()))
    d.keys('tap',4) # Return to Processes, preserving selected identity.
    d.keys('tap',33)
    time.sleep(.3)
    d.keys('tap',28)
    profiler = remember(eventually(lambda: tracer(fixture.pid), bool))
    check('confirmed Profile starts perf and resumes owned target', eventually(lambda:perf_count(profiler),lambda n:n>0)>0 and Path(f'/proc/{fixture.pid}/stat').read_text().rsplit(')',1)[1].split()[0] != 't')
    eventually(lambda:perf_count(profiler),lambda n:n==0,timeout=13)
    check('profile duration closes perf without pausing target', fixture.poll() is None and Path(f'/proc/{fixture.pid}/stat').read_text().rsplit(')',1)[1].split()[0] not in ('T','t'))
    os.kill(profiler,signal.SIGTERM)
    eventually(lambda:tracer(fixture.pid),lambda pid:pid==0)
    d.wait_focused()
    d.keys('tap', 28) # open attach confirmation
    d.keys('tap', 28) # confirm: target is still our unchanged owned sleep
    owner = remember(eventually(lambda: tracer(fixture.pid), lambda pid:pid != 0))
    owner_status = Path(f'/proc/{owner}/status').read_text()
    check('confirmed GUI handoff creates a debugger child', int(re.search(r'^PPid:\s*(\d+)', owner_status, re.M)[1]) == d.app.pid)
    os.kill(owner, signal.SIGTERM)
    eventually(lambda: tracer(fixture.pid), lambda pid:pid == 0)
    d.wait_focused()
    check('closing handed-off debugger resumes owned target', fixture.poll() is None)
    # No attach on stale identity, including the actual debugger consumer boundary.
    stale = subprocess.run([str(root/'zig-out/bin/xodb'),'--headless','--mcp','--attach',str(fixture.pid),'--expected-start-ticks',str(ticks+1)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    check('consumer refuses changed start identity', stale.returncode != 0 and b'ProcessIdentityChanged' in stale.stderr and tracer(fixture.pid) == 0)
    # Correct identity is accepted; EOF detaches rather than kills an attached target.
    attached = subprocess.run([str(root/'zig-out/bin/xodb'),'--headless','--mcp','--attach',str(fixture.pid),'--expected-start-ticks',str(ticks)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8)
    check('consumer accepts owned identity and detaches on EOF', attached.returncode == 0 and fixture.poll() is None and tracer(fixture.pid) == 0)
    d.keys('tap', 2) # Summary
    # Let full demand expire without asking process tools, then inspect audit only.
    time.sleep(4.2)
    audit = Path(d.log).read_text()
    rows = re.findall(r'collector opens=(\d+) sequence=(\d+) groups=([0-9a-f]+) light=(true|false) processes_sample_ns=(\d+)', audit)
    check('GUI and all peers open one collector', rows and all(int(x[0]) == 1 for x in rows))
    check('Summary returns to light process sampling', any(x[3] == 'true' and int(x[2],16) & (1 << 11) for x in rows[-5:]))
    cadence_rows = re.findall(r'collector opens=(\d+) sequence=(\d+) groups=([0-9a-f]+) light=(true|false) processes_sample_ns=(\d+)', cadence_audit)
    times = sorted({int(x[4]) for x in cadence_rows if int(x[4])})
    gaps = [(b-a)/1e9 for a,b in zip(times,times[1:])]
    check('process samples follow the one-second owner clock', len(gaps) >= 3 and all(.95 <= t < 1.35 for t in gaps))
    check('MCP full demand waits for owner tick', peers[0].tool('list_processes', limit=1)['process_detail_pending'])
    eventually(lambda: peers[0].tool('list_processes', limit=1), lambda x:not x['process_detail_pending'])
    # Pause freezes the view while the owner's requested groups can still update.
    d.keys('tap',25)
    x = peers[0].tool('list_processes', limit=1)
    time.sleep(1.2)
    y = peers[0].tool('list_processes', limit=1)
    check('paused GUI can serve fresh MCP data', y['sequence'] > x['sequence'])
    d.keys('tap', 4)  # Processes; keep the selected owned identity
    d.keys('tap', 45) # irrevocable redaction
    for key, label in ((33, 'Profile'), (28, 'Attach')):
        before_children = Path(f'/proc/{d.app.pid}/task/{d.app.pid}/children').read_text()
        d.keys('tap', key)
        shot = d.shot('redacted-' + label.lower())
        text = subprocess.check_output(['tesseract', str(shot), 'stdout', '--psm', '11'], stderr=subprocess.DEVNULL, text=True)
        check('redacted ' + label + ' refuses an unredacted window', 'redaction mode' in text and tracer(fixture.pid) == 0 and Path(f'/proc/{d.app.pid}/task/{d.app.pid}/children').read_text() == before_children)

finally:
    for pid, identity in reversed(list(handed_children.items())):
        try:
            if start_ticks(pid) == identity: os.kill(pid,signal.SIGTERM)
        except (ProcessLookupError,FileNotFoundError): pass
    for peer in peers: peer.close()
    if d: d.close()
    fixture.terminate(); fixture.wait(timeout=5)
    reap_descendants()
    (work/'results.json').write_text(json.dumps(results, indent=2)+'\n')
print(f'overview live: {sum(x["status"] == "pass" for x in results)}/{len(results)} passed; {work}', flush=True)
