#!/usr/bin/env python3
"""Owned THP/COW fixtures and shared observer MCP. Private evidence in .work.
Run --mib 1024 under gate-slot for the large-memory acceptance case.
"""
import argparse
import json
import os
from pathlib import Path
import re
import select
import socket
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
parser = argparse.ArgumentParser()
parser.add_argument('--mib', type=int, default=64)
args = parser.parse_args()
work = root / '.work' / ('mem-' + str(time.time_ns())[-8:])
work.mkdir(parents=True)
ipc = work / 'ipc'
ipc.mkdir(mode=0o700)
results, snapshots = [], []
fixture = server = peer = client = None

def check(name, condition):
    results.append(dict(check=name, status='pass' if condition else 'fail'))
    print(('PASS ' if condition else 'FAIL ') + name, flush=True)
    assert condition, name

def skip(name, reason):
    results.append(dict(check=name, status='skip', reason=reason))
    print('SKIP ' + name + ': ' + reason, flush=True)

class Client:
    def __init__(self, reader, writer, sock=False):
        self.reader, self.writer, self.sock = reader, writer, sock
        self.buffer, self.serial = b'', 0
        r = self.call('initialize', dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='memory-test', version='1')))
        assert 'result' in r, r
        self.send(dict(jsonrpc='2.0', method='notifications/initialized'))
    def send(self, value):
        data = (json.dumps(value)+'\n').encode()
        if self.sock: self.writer.sendall(data)
        else:
            self.writer.write(data)
            self.writer.flush()
    def call(self, method, params=None):
        self.serial += 1
        self.send(dict(jsonrpc='2.0', id=self.serial, method=method, params=params or {}))
        deadline = time.monotonic() + 15
        while True:
            while b'\n' not in self.buffer:
                remaining = deadline-time.monotonic()
                assert remaining > 0 and select.select([self.reader],[],[],remaining)[0], 'MCP watchdog'
                data = self.reader.recv(65536) if self.sock else os.read(self.reader.fileno(),65536)
                assert data, 'MCP disconnected'
                self.buffer += data
            line,self.buffer = self.buffer.split(b'\n',1)
            value=json.loads(line)
            if value.get('id') == self.serial: return value
    def tool(self,name,**arguments):
        r=self.call('tools/call',dict(name=name,arguments=arguments))
        if r.get('error') or r.get('result',{}).get('isError'): return None,r
        return r['result']['structuredContent'],None

def ticks(pid):
    return int(Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[19])

def phase(command=None):
    if command:
        fixture.stdin.write((command+'\n').encode()); fixture.stdin.flush()
    assert select.select([fixture.stdout],[],[],30)[0], 'fixture watchdog'
    v=json.loads(fixture.stdout.readline())
    snapshots.append(dict(fixture=v))
    return v

def await_tool(connection,name,predicate=lambda v:True,**arguments):
    deadline=time.monotonic()+20
    last=None
    while time.monotonic()<deadline:
        value,error=connection.tool(name,**arguments)
        last=error or value
        if value and predicate(value): return value
        # A publication mutex can be briefly busy. Other errors are never retried.
        if error: assert 'MemoryCacheBusy' in json.dumps(error), error
        time.sleep(.04)
    raise AssertionError(('publication watchdog',last))

def proc_huge(pid):
    smaps=Path(f'/proc/{pid}/smaps').read_text()
    rollup=Path(f'/proc/{pid}/smaps_rollup').read_text()
    return sum(int(n)*1024 for n in re.findall(r'^AnonHugePages:\s+(\d+) kB$',smaps,re.M)), int(re.search(r'^AnonHugePages:\s+(\d+) kB$',rollup,re.M)[1])*1024

def coverage_oracle(pid):
    pmd = int(Path('/sys/kernel/mm/transparent_hugepage/hpage_pmd_size').read_text())
    numerator = denominator = 0
    row = None
    for line in Path(f'/proc/{pid}/smaps').read_text().splitlines():
        header = re.match(r'^([0-9a-f]+)-([0-9a-f]+) (\S{4}) \S+ ([0-9a-f]+):([0-9a-f]+) (\d+)', line)
        if header:
            row = dict(start=int(header[1], 16), end=int(header[2], 16), private=header[3][-1] == 'p',
                       anonymous=int(header[4],16) == int(header[5],16) == int(header[6]) == 0)
            continue
        key, _, value = line.partition(':')
        if row is None: continue
        if key == 'AnonHugePages': row['huge'] = int(value.split()[0]) * 1024
        if key == 'THPeligible': row['eligible'] = int(value)
        if key == 'VmFlags' and row.get('eligible') and row['anonymous'] and row['private'] and not {'ht','io','pf'}.intersection(value.split()):
            numerator += row['huge']
            denominator += max(0, row['end']//pmd - (row['start']+pmd-1)//pmd) * pmd
    return numerator, denominator

def check_coverage(label, data):
    expected = coverage_oracle(fixture.pid)
    actual = data['process']['coverage']
    check(label, actual['numerator_known'] and actual['denominator_known'] and
          (actual['numerator_bytes'], actual['denominator_bytes']) == expected)


try:
    subprocess.run(['cc','-std=c11','-O2','-Wall','-Wextra','-Werror','tests/memory-map-fixture.c','-o',str(work/'fixture')],check=True,timeout=30)
    fixture=subprocess.Popen([str(work/'fixture'),str(args.mib)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,bufsize=0)
    initial=phase()
    identity=dict(pid=fixture.pid,start_ticks=ticks(fixture.pid))
    selection=dict(identity,range_start=initial['start'],range_end=initial['end'])
    with (work/'server.log').open('w') as stderr:
        environment={k:v for k,v in os.environ.items() if k not in ('DISPLAY','WAYLAND_DISPLAY')}
        server=subprocess.Popen(['./zig-out/bin/xodb','--headless','--session-socket',str(ipc/'s')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,bufsize=0,env=environment)
    deadline=time.monotonic()+10
    while True:
        connection=socket.socket(socket.AF_UNIX);connection.settimeout(15)
        try:
            connection.connect(str(ipc/'s'));break
        except (FileNotFoundError,ConnectionRefusedError):
            connection.close()
            assert time.monotonic()<deadline
            time.sleep(.02)
    peer=Client(connection,connection,True)
    second_connection=socket.socket(socket.AF_UNIX);second_connection.settimeout(15)
    second_connection.connect(str(ipc/"s"))
    client=Client(second_connection,second_connection,True)
    names={t['name']:t for t in peer.call('tools/list')['result']['tools']}
    expected={'get_memory_map','get_thp_state','get_fragmentation'}
    check('three memory tools advertised to observer peer',expected <= names.keys() and all(names[n]['annotations']['readOnlyHint'] and names[n]['annotations']['xodbSessionAccess']=='observer' for n in expected))
    for bad in [dict(pid=fixture.pid),dict(identity,root='fixture'),dict(selection,view='cells',cell_bytes=123)]:
        value,error=peer.tool('get_memory_map',**bad)
        check('invalid memory arguments refused '+str(len(results)),value is None and error is not None)
    ready=lambda v:v.get('process') is not None and not v['cache']['pending']
    data=await_tool(peer,'get_memory_map',ready,**selection,view='cells',limit=256)
    snapshots.append(dict(ready=data))
    check('owned fixture identity and full bounded coverage',data['process']['start_ticks']==identity['start_ticks'] and data['process']['scanned_bytes']==initial['bytes'] and data['process']['pages_status']['state']=='ok')
    huge,rollup=proc_huge(fixture.pid)
    check('smaps huge totals match independent smaps and rollup oracle',huge==rollup==data['process']['anon_huge'])
    check('complete smaps avoids an extra rollup and NUMA walk',data['process']['rollup_anon_huge'] is None and data['process']['rollup_status']['state']=='unavailable' and data['process']['numa_status']['state']=='unavailable')
    check_coverage('initial coverage matches exact independent numerator and denominator',data)
    thp=huge>0
    if not thp: skip('THP formation and split','kernel did not back the owned MADV_HUGEPAGE fixture with PMD THP; settings retained')
    else:
        check('THP coverage has aligned known numerator and denominator',data['process']['coverage']['numerator_known'] and data['process']['coverage']['denominator_known'] and data['process']['coverage']['numerator_bytes']<=data['process']['coverage']['denominator_bytes'])
    other=await_tool(client,'get_memory_map',ready,**selection,view='cells',limit=1)
    check('two socket readers reuse one memory owner and scope',other['owner_instances']==data['owner_instances']==1 and other['ticket']==data['ticket'])
    if data['count']>256:
        # A sequence may legitimately advance between pages; restart the page pair.
        deadline=time.monotonic()+20
        while True:
            first=await_tool(peer,'get_memory_map',ready,**selection,view='cells',limit=256)
            second,error=peer.tool('get_memory_map',**selection,view='cells',limit=256,offset=256,sequence=first['cache']['sequence'])
            if second: break
            assert 'StaleMemorySnapshot' in json.dumps(error) or 'MemoryCacheBusy' in json.dumps(error),error
            assert time.monotonic()<deadline
        check('second page advances fixed virtual cells',int(second['rows'][0]['start'],16)==int(initial['start'],16)+(256<<21))
    stale_seq=data['cache']['sequence']
    fresh=await_tool(peer,'get_memory_map',lambda v:ready(v) and v['cache']['sequence']>stale_seq,**selection,view='cells',limit=1)
    value,error=peer.tool('get_memory_map',**selection,view='cells',limit=1,sequence=stale_seq)
    check('stale publication is refused',value is None and 'StaleMemorySnapshot' in json.dumps(error))
    redacted=await_tool(peer,'get_memory_map',ready,**identity,redact=True,limit=256)
    plain=await_tool(client,'get_memory_map',ready,**identity,limit=256)
    check('redaction removes names paths and inodes without changing shared cache',redacted['process']['name'] is None and all(row['path'] is None and row['inode'] is None for row in redacted['rows']) and plain['process']['name'] is not None and any(row['path'] for row in plain['rows']))
    numa=await_tool(peer,'get_memory_map',ready,**identity,numa=True,limit=256)
    check('explicit NUMA request collects VMA totals in its own capable scope',numa['ticket']!=plain['ticket'] and numa['process']['numa_status']['state']=='ok' and any(row['numa_vma_totals'] is not None for row in numa['rows']))
    before=await_tool(peer,'get_memory_map',ready,**selection,view='cells',limit=1)
    split=phase('split')
    check('owned split operation succeeds',split['rc']==0)
    changed=await_tool(peer,'get_memory_map',lambda v:ready(v) and v['cache']['sequence']>before['cache']['sequence'],**selection,view='cells',limit=1)
    snapshots.append(dict(split=changed))
    check_coverage('split coverage matches exact independent numerator and denominator',changed)
    huge2,rollup2=proc_huge(fixture.pid)
    check('split sample agrees with independent smaps and rollup',changed['process']['anon_huge']==huge2==rollup2)
    if thp and before['rows'][0]['categories_all'] & 8:
        check('PMD split has distinct highlight and no invented migration',changed['rows'][0]['pmd_change_known'] and changed['rows'][0]['split_bytes']==2<<20 and changed['rows'][0]['physical_change_known'] is False)
    fork=phase('fork');check('owned fork/COW child reached stable phase',fork['child']>0 and fork['rc']==0)
    child_id=dict(pid=fork['child'],start_ticks=ticks(fork['child']))
    cow=await_tool(peer,'get_thp_state',ready,**child_id)
    ch,cr=proc_huge(fork['child'])
    check('fork/COW child retains separate identity and truthful huge totals',cow['process']['pid']==fork['child'] and cow['process']['start_ticks']==child_id['start_ticks'] and cow['process']['anon_huge']==ch==cr)
    snapshots.append(dict(cow=cow))
    phase('reap')
    before=await_tool(peer,'get_memory_map',ready,**selection,view='cells',limit=1)
    fragment=phase('fragment');check('owned allocation-hole stress succeeds',fragment['rc']==0)
    holes=await_tool(peer,'get_memory_map',lambda v:ready(v) and v['cache']['sequence']>before['cache']['sequence'],**selection,view='cells',limit=1)
    check('holes show mixed presence without treating absent pages as free RAM',holes['rows'][0]['mixed'] & 1 and holes['rows'][0]['changed_categories'] & 1 and holes['rows'][0]['change_known'] & 1 and holes['rows'][0]['mapped_bytes']==2<<20 and holes['process']['pages_status']['state'] in ('ok','partial'))
    snapshots.append(dict(holes=holes))
    compact=phase('compact')
    if compact['rc']: skip('MADV_COLLAPSE after allocation-hole stress','owned advisory operation unavailable: errno '+str(compact['errno']))
    else:
        after=await_tool(peer,'get_memory_map',lambda v:ready(v) and v['cache']['sequence']>holes['cache']['sequence'],**selection,view='cells',limit=1)
        check('owned refill/collapse restores presence',after['rows'][0]['categories_all'] & 1)
        check('MADV_COLLAPSE reports exactly one PMD of collapsed bytes',after['rows'][0]['pmd_change_known'] and after['rows'][0]['collapsed_bytes']==2<<20 and after['rows'][0]['split_bytes']==0)
        check_coverage('collapse coverage matches exact independent numerator and denominator',after)
        snapshots.append(dict(compacted=after))
    system=await_tool(peer,'get_thp_state',lambda v:v.get('system') is not None and v['system']['delta_interval_ns']>0)
    check('kernel activity deltas are system-wide with measured interval',system['system']['activity_scope'].startswith('system-wide') and all(not row['reset'] or row['delta'] is None for row in system['system']['counters']))
    snapshots.append(dict(system=system))
    frag=await_tool(peer,'get_fragmentation',lambda v:v.get('system') is not None)
    check('buddy fragmentation preserves order histogram and allocation sentinel',bool(frag['system']['zones']) and all(len(z['blocks_by_order'])>0 and (z['suitable_blocks'] is None or z['suitable_blocks']==0 or z['index_permille']==-1000) for z in frag['system']['zones']))
    wrong=await_tool(peer,'get_memory_map',ready,pid=fixture.pid,start_ticks=identity['start_ticks']+1)
    check('wrong birth is explicit and contains no map rows',wrong['process']['maps_status']['state']=='identity_changed' and not wrong['rows'])
    before_denial=await_tool(peer,'get_memory_map',ready,**selection,view='cells',limit=1)
    check('owned fixture becomes non-dumpable',phase('deny')['rc']==0)
    try:
        Path(f'/proc/{fixture.pid}/smaps').read_text()
    except PermissionError:
        denied=await_tool(peer,'get_memory_map',lambda v:ready(v) and v['cache']['sequence']>before_denial['cache']['sequence'],**selection,view='cells',limit=1)
        check('denied owned process has a null name and unavailable values',denied['process']['maps_status']['state']=='denied' and denied['process']['name'] is None and denied['process']['rss'] is None and denied['process']['coverage']['numerator_bytes'] is None)
    else:
        skip('denied process name','runner can read the non-dumpable fixture')
    check('owned fixture restores dumpability',phase('allow')['rc']==0)
    # No delegated cgroup is created unless current cgroup ownership permits it.
    membership=Path('/proc/self/cgroup').read_text()
    unified=next((line.split(':',2)[2] for line in membership.splitlines() if line.startswith('0::')),None)
    cg=Path('/sys/fs/cgroup')/unified.lstrip('/') if unified else None
    delegated=bool(cg and os.access(cg,os.W_OK) and os.access(cg/'cgroup.procs',os.W_OK))
    assert not delegated, 'writable delegation exists: implement and run owned swap-pressure fixture before claiming this check'
    skip('memory-cgroup swap pressure','no writable delegated memory cgroup')
    check('observer never ptrace-stops the fixture',int(re.search(r'^TracerPid:\s+(\d+)',Path(f'/proc/{fixture.pid}/status').read_text(),re.M)[1])==0)
finally:
    if client:
        client.reader.close()
    if peer:
        peer.reader.close()
    if server:
        if server.stdin: server.stdin.close()
        try:server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.terminate()
            try:server.wait(timeout=5)
            except subprocess.TimeoutExpired:server.kill();server.wait()
    if fixture:
        if fixture.stdin: fixture.stdin.close()
        try:fixture.wait(timeout=5)
        except subprocess.TimeoutExpired:
            fixture.terminate()
            try:fixture.wait(timeout=5)
            except subprocess.TimeoutExpired:fixture.kill();fixture.wait()
    (work/'results.json').write_text(json.dumps(dict(mib=args.mib,checks=results),indent=2)+'\n')
    (work/'snapshots.json').write_text(json.dumps(snapshots,indent=2)+'\n')
    print('Evidence:',work,flush=True)
print('memory observer:',sum(x['status']=='pass' for x in results),'passed,',sum(x['status']=='skip' for x in results),'skipped',flush=True)
