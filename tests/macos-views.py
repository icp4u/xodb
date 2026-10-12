#!/usr/bin/env python3
"""Darwin regions, thread metadata and stops from owned recorded packets."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import time
from client import Client
from helpers.fake_debugserver import Fake, run_control
from helpers.input import load_scale
from helpers.debugserver_scenario import modules as module_pages

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT/'tests/fixtures/macos-names'
spec = importlib.util.spec_from_file_location('macos_names', ROOT/'tests/macos-names.py')
names = importlib.util.module_from_spec(spec)
spec.loader.exec_module(names)


def stop_thread(packet):
    return int(re.search(r'thread:([0-9a-f]+);', packet)[1], 16)


def registers(packet):
    return {int(k, 16): value for pair in packet[3:].split(';')
            if re.fullmatch(r'[0-9a-f]+:[0-9a-f]+', pair)
            for k, value in [pair.split(':')]}


class Stop:
    def __init__(self, recording, at):
        rows = recording['exchanges']
        self.packet = rows[at][1][0]
        self.tid = stop_thread(self.packet) if self.packet.startswith('T') else 0
        end = next((i for i in range(at+1, len(rows)) if run_control(rows[i][0])), len(rows))
        self.reads = rows[at+1:end]
        self.banks = {self.tid: registers(self.packet)}
        self.memory = []
        selected = self.tid
        for query, replies in self.reads:
            for reply in replies:
                if reply.startswith('T'):
                    self.banks[stop_thread(reply)] = registers(reply)
            if query.startswith('Hg'):
                selected = int(query[2:], 16)
            elif re.fullmatch('p[0-9a-f]+', query) and not replies[0].startswith('E'):
                self.banks.setdefault(selected, {})[int(query[1:],16)] = replies[0]
            elif re.fullmatch(r'm[0-9a-f]+,[0-9a-f]+', query) and re.fullmatch('[0-9a-f]*', replies[0]):
                self.memory.append((int(query[1:].split(',')[0],16), bytes.fromhex(replies[0])))
        self.threads = next((replies[0] for q,replies in self.reads if q == 'qfThreadInfo'), None)
        self.thread_info = next((replies[0] for q,replies in self.reads if q == 'jThreadsInfo'), '')
        self.images = next((replies[0] for q,replies in reversed(rows[:end]) if q == names.IMAGES), '')
        self.process = next((replies[0] for q,replies in reversed(rows[:end]) if q == 'qProcessInfo'), names.COMMON['qProcessInfo'][0])
        self.regions = {q:r for q,r in self.reads if q.startswith('qMemoryRegionInfo:')}
        # Executable bytes from the UUID-matching owned corpus, as in the
        # frame-name replay. No unrecorded heap or stack bytes are invented.
        if self.images:
            for image in json.loads(self.images)['images']:
                if not image['pathname'].startswith('/xodb-corpus/'): continue
                local = FIXTURES/'corpus'/image['pathname'].removeprefix('/xodb-corpus/')
                if not local.is_file(): continue
                h=image['mach_header'];data=names.slice_bytes(local,h['cputype'],h['cpusubtype'])
                base=next(row['vmaddr'] for row in image['segments'] if row['name']=='__TEXT')
                for row in image['segments']:
                    if row['maxprot'] & 4 and row['filesize']:
                        self.memory.append((row['vmaddr']+image['load_address']-base,data[row['fileoff']:row['fileoff']+row['filesize']]))


class Replay(Fake):
    def __init__(self, recording, stops, transform=None):
        self.recording, self.stops, self.phase = recording, stops, 0
        self.selected = stops[0].tid
        self.transform = transform
        self.served = dict(threads=0, regions=0, process=0, controls=[])
        self.process_transform = None
        self.image_transform = None
        self.probes = set()
        self.extra = []
        super().__init__([])

    def lookup(self, query):
        stop = self.stops[self.phase]
        if query.startswith('qSupported:'):
            return next(r for q,r in self.recording['exchanges'] if q.startswith('qSupported:'))
        if query.startswith('qXfer:features:read:target.xml:'):
            at,size = (int(x,16) for x in query.rsplit(':',1)[1].split(','))
            return [('l' if at+size>=len(names.XML) else 'm')+names.XML[at:at+size]]
        if query == '?': return [stop.packet]
        if query == 'qProcessInfo':
            self.served['process'] += 1
            return [self.process_transform(stop.process) if self.phase and self.process_transform else stop.process]
        if query == 'qC': return ['QC%x'%stop.tid]
        if query.startswith('qMemoryRegionInfo:') and query in stop.regions:
            self.served['regions'] += 1
            return stop.regions[query]
        if query in self.probes: return ['OK']
        if query == 'c' or query.startswith('vCont;'):
            self.served['controls'].append(query)
            assert self.phase+1<len(self.stops), 'no recorded next stop'
            self.phase += 1
            stop = self.stops[self.phase]
            self.selected = stop.tid
            return [stop.packet]
        if query == 'qfThreadInfo':
            # Missing inventory is an unsupported optional packet. Only the
            # causal stop thread can then be known, never fabricated peers.
            return [stop.threads or '']
        if query == 'qsThreadInfo': return ['l']
        if query == 'jThreadsInfo':
            self.served['threads'] += 1
            return [self.transform(stop.thread_info) if self.transform else stop.thread_info]
        if query.startswith(('Hg','Hc')):
            tid = int(query[2:],16)
            assert tid in stop.banks, 'selection outside recorded thread bank'
            if query.startswith('Hg'): self.selected = tid
            return ['OK']
        if query == 'g': return ['']
        if re.fullmatch('p[0-9a-f]+', query): return [stop.banks[self.selected].get(int(query[1:],16),'E45')]
        if query == names.IMAGES: return [self.image_transform(stop.images) if self.image_transform else stop.images]
        if re.fullmatch(r'm[0-9a-f]+,[0-9a-f]+', query):
            address,size = (int(x,16) for x in query[1:].split(','))
            for at,data in stop.memory:
                if at <= address and address+size <= at+len(data):return [data[address-at:address-at+size].hex()]
            return ['E01']
        if query == 'D': return ['OK']
        if query in names.COMMON: return names.COMMON[query]
        if query in ('QStartNoAckMode','qAttached','qMemoryRegionInfo:0'): return ['']
        self.extra.append(query)
        return ['']


def resource(pid):
    return names.resources(pid)


def thread_case(work, kind, wrong):
    recording = json.loads((FIXTURES/'transcripts/c-threads.json').read_text())
    at = next(i for i,(q,r) in enumerate(recording['exchanges']) if q == 'c' and r[0].startswith('T05'))
    stop = Stop(recording, at)
    expected = json.loads(stop.thread_info)
    def change(raw):
        rows = json.loads(raw)
        if kind == 'duplicate': rows.append(rows[0])
        elif kind == 'unknown': rows.append(dict(tid=8191, name='phantom', qaddr=123))
        elif kind == 'oversized': return json.dumps([dict(tid=4097, extra='x'*600000)])
        elif kind == 'unsupported': return ''
        elif kind == 'name': rows[1]['name'] = 'worker\n\x1b' + 'x'*200
        return json.dumps(rows)
    stub = Replay(recording, [stop], change)
    stub.start()
    client = Client('mutate', executable=None, options=('--gdb-remote',stub.endpoint), reply_seconds=30)
    before = resource(client.p.pid)
    try:
        until = time.monotonic()+30*load_scale()
        while True:
            state = client.session()
            assert 'thread_info' in state['gdb_remote'], state['gdb_remote']
            labels = state['thread_labels']
            if len(labels) == 5:break
            assert time.monotonic()<until, state
            time.sleep(.002)
        assert stub.served['threads'] == 1, stub.served
        assert len(state['threads']) == 5 and {r['tid'] for r in labels} == {r['tid'] for r in expected}, state
        availability = state['gdb_remote']['thread_info']
        if kind in ('duplicate','oversized','unsupported'):
            assert availability == ('unsupported' if kind == 'unsupported' else 'failed'), state
            assert all(r['name'] is None and r['queue_address'] is None for r in labels), labels
            assert client.inspect('get_registers',tid=stop.tid)['registers']['pc']
        else:
            assert availability == 'available', state
            if wrong: labels[1]['queue_address'] = '0x1'
            for actual, recorded in zip(labels, expected):
                assert actual['source'] == 'gdb_thread_info' and not actual['wine_internal_name'], actual
                assert actual['queue_address'] == hex(recorded['qaddr']), actual
                if kind == 'name' and actual['tid'] == 4098:
                    assert actual['name'].startswith('worker??') and len(actual['name']) == 127 and actual['possibly_truncated'], actual
                else: assert actual['name'] == recorded.get('name'), actual
        after = resource(client.p.pid)
        assert not stub.extra, stub.extra
        return dict(case='threads-'+kind,status='pass',queries=stub.served,labels=labels,resources_before=before,resources_after=after)
    finally:
        client.close()
        stub.join(timeout=2)
        (work/(kind+'-mcp.json')).write_text(json.dumps(client.transcript,indent=2)+'\n')



def recorded_stops(kind):
    recording=json.loads((FIXTURES/('transcripts/c-'+kind+'.json')).read_text())
    stops=[Stop(recording,i) for i,(q,r) in enumerate(recording['exchanges'])
           if r and (q=='c' or q.startswith('vCont;')) and r[0].startswith(('T','W','X'))]
    assert len(stops)>=2, kind
    return recording,stops


def wait_state(client, state):
    until=time.monotonic()+30*load_scale()
    while True:
        value=client.session()
        if value['state']==state and not value.get('continue_pending'):return value
        assert time.monotonic()<until, value
        time.sleep(.002)


def stop_case(work, kind, wrong):
    recording,stops=recorded_stops(kind)
    stub=Replay(recording,stops)
    stub.close_on_exit=kind in ('exit','crash-abort')
    stub.start()
    client=Client('mutate',executable=None,options=('--gdb-remote',stub.endpoint),reply_seconds=30)
    before=resource(client.p.pid)
    evidence=[]
    try:
        original=client.stopped()
        tid=stops[0].tid
        probe=None
        if kind=='exec':
            # A synthetic retained probe at a real instruction tests that exec
            # discards it without trying to restore the old address space.
            pc=int.from_bytes(bytes.fromhex(stops[0].banks[tid][0x20]),'little')
            previous_label=client.inspect('get_macho_image',address=hex(pc))
            assert previous_label['label'].startswith('cprog+'),previous_label
            stub.probes.add('Z0,%x,4'%(pc+4))
            probe=client.action('set_breakpoint',address=hex(pc+4))['id']
            assert any(row['id']==probe for row in client.inspect('get_breakpoints')['breakpoints'])
        client.action('continue')
        if kind=='exit':
            state=wait_state(client,'exited')
            stub.join(timeout=2)
            assert stub.closed_on_exit and not stub.is_alive()
            assert client.session()['state']=='exited'
            events=client.inspect('query_events')['events']
            if wrong:events[-1]['detail']=4
            assert events[-1]['kind']=='exit' and events[-1]['detail']==3, events
            evidence.append(dict(state=state,events=events))
        else:
            state=client.stopped()
            info=client.inspect('get_stop_info',tid=stops[1].tid)['stop']
            if wrong: info['signal_name']='wrong'
            if kind=='crash-bad-access':
                assert info['reason']=='exception' and info['signal']==0 and info['signal_name']=='none',info
                assert info['fault_address']==16 and info['mach_exception']==dict(type=1,name='EXC_BAD_ACCESS',codes=['0x1','0x10']),info
                assert not info['pending_delivery'] and info['diagnostic'] is None,info
                client.action('continue');client.stopped('exception')
                assert stub.served['controls']==['vCont;c','vCont;c'],stub.served
            elif kind in ('crash-abort','fork'):
                number,label=(6,'SIGABRT') if kind=='crash-abort' else (20,'SIGCHLD')
                assert info['reason']=='signal' and info['signal']==number and info['signal_name']==label,info
                assert info['pending_delivery'] and info['mach_exception']['type']==5,info
                assert info['fault_address'] is None and info['diagnostic'] is None,info
                client.action('continue')
                assert stub.served['controls'][-1]=='vCont;C%02x:%x;c'%(number,tid),stub.served
                if kind=='crash-abort':
                    wait_state(client,'exited')
                    stub.join(timeout=2)
                    assert stub.closed_on_exit and not stub.is_alive()
                    assert client.session()['state']=='exited'
                    events=client.inspect('query_events')['events']
                    assert events[-1]['kind']=='exit' and events[-1]['detail']==-6,events
                else:
                    client.stopped()
                    processes=client.inspect('get_processes')
                    assert len(processes['processes'])==1,processes
            elif kind=='exec':
                if wrong:state['image_epoch']=original['image_epoch']
                assert info['reason']=='exec' and not info['pending_delivery'] and info['mach_exception'] is None,info
                assert state['image_epoch']==original['image_epoch']+1,state
                assert [r['tid'] for r in state['threads']]==[stops[1].tid] and stops[1].tid!=tid,state
                assert not client.inspect('get_breakpoints')['breakpoints'],state
                assert stub.served['process']==2,stub.served
                assert not any(q.startswith('z0,') for q in stub.requests),stub.requests
                absent=client.tool('get_macho_image',address=hex(pc))['result']
                assert absent.get('isError') and absent['content'][0]['text']=='MachOAddressUnavailable',absent
                client.action('continue');client.stopped('exception')
                assert stub.served['controls']==['vCont;c','vCont;c'],stub.served
            evidence.append(dict(stop=info,state=state))
        assert not stub.extra,stub.extra
        return dict(case='stops-'+kind,status='pass',queries=stub.served,evidence=evidence,
                    resources_before=before,resources_after=resource(client.p.pid))
    finally:
        client.close();stub.join(timeout=2)
        (work/(kind+'-mcp.json')).write_text(json.dumps(client.transcript,indent=2)+'\n')


def region_case(work, wrong, variant='recorded'):
    recording=json.loads((FIXTURES/'transcripts/c-regions.json').read_text())
    at=next(i for i,(q,r) in enumerate(recording['exchanges']) if q=='c')
    stop=Stop(recording,at)
    stub=Replay(recording,[stop])
    if variant=='overlap':
        def overlap(raw):
            value=json.loads(raw);image=value['images'][0]
            text=next(s['vmaddr'] for s in image['segments'] if s['name']=='__TEXT')
            segment=next(s for s in image['segments'] if s['name']=='__DATA').copy()
            twin=json.loads(json.dumps(image));twin['pathname']='/xodb-corpus/overlapping-image'
            twin['load_address']=image['load_address']+segment['vmaddr']-text
            segment['name']='__TEXT';segment['maxprot']=1
            twin['segments']=[segment];value['images'].append(twin)
            return json.dumps(value)
        stub.image_transform=overlap
    stub.start()
    client=Client('mutate',executable=None,options=('--gdb-remote',stub.endpoint),reply_seconds=30)
    before=resource(client.p.pid)
    try:
        regions,_=module_pages(client)
        assert stub.served['regions']>=103,stub.served
        images=json.loads(stop.images)['images']
        image=images[0]
        text=next(s['vmaddr'] for s in image['segments'] if s['name']=='__TEXT')
        data=next(s for s in image['segments'] if s['name']=='__DATA')
        address=image['load_address']+data['vmaddr']-text
        found=next(r for r in regions if r['start']<=address<r['end'])
        if wrong: found['path']='wrong-image'
        assert found['path']==(image['pathname'] if variant=='recorded' else '') and address!=image['load_address'],found
        assert any(r['path']=='[stack]' for r in regions),regions
        assert not stub.extra,stub.extra
        return dict(case='regions-'+variant,status='pass',queries=stub.served,regions=regions,
                    resources_before=before,resources_after=resource(client.p.pid))
    finally:
        client.close();stub.join(timeout=2)
        (work/('regions-'+variant+'-mcp.json')).write_text(json.dumps(client.transcript,indent=2)+'\n')


def refusal(client, name, error, **args):
    result=client.tool(name,generation=client.session()['generation'],**args)['result']
    assert result.get('isError') and result['content'][0]['text']==error,result


def hardware_case(work, wrong):
    recording,stops=recorded_stops('breakpoints-watchpoints-step')
    stop=stops[0]
    class Grants(Replay):
        def lookup(self,query):
            # Deliberately over-generous stub: a packet grant cannot increase
            # client slots or make execution watches a supported API.
            if query=='qWatchpointSupportInfo:':return ['num:100;']
            if query.startswith(('Z','z')):return ['OK']
            return super().lookup(query)
    stub=Grants(recording,[stop]);stub.start()
    client=Client('mutate',executable=None,options=('--gdb-remote',stub.endpoint),reply_seconds=30)
    before=resource(client.p.pid)
    try:
        capacity=client.inspect('get_breakpoints')
        if wrong:capacity['data_watch_slots']=8
        assert capacity['data_watch_slots']==4 and not capacity['execution_watches'],capacity
        address=next(at for at,data in stop.memory if at%4==0 and len(data)>=20)
        refusal(client,'set_watchpoint','ExecutionWatchpointsUnsupported',address=hex(address),length=1,kind='execute')
        ids=[client.action('set_watchpoint',address=hex(address+4*i),length=4,kind='write')['id'] for i in range(4)]
        refusal(client,'set_watchpoint','WatchpointLimit',address=hex(address+16),length=4,kind='write')
        assert len([q for q in stub.requests if q.startswith('Z2,')])==4,stub.requests
        assert not any(q.startswith('Z1,') for q in stub.requests),stub.requests
        for id in ids:client.action('remove_watchpoint',id=id)
        assert not stub.extra,stub.extra
        return dict(case='hardware-limits',status='pass',slots=capacity['data_watch_slots'],requests=[q for q in stub.requests if q.startswith(('Z','z'))],
                    resources_before=before,resources_after=resource(client.p.pid))
    finally:
        client.close();stub.join(timeout=2)
        (work/'hardware-mcp.json').write_text(json.dumps(client.transcript,indent=2)+'\n')


def exec_refusal_case(work, variant, wrong):
    recording,stops=recorded_stops('exec')
    stub=Replay(recording,stops)
    def change(process):
        if variant=='cpu':return process.replace('cputype:100000c;','cputype:1000007;')
        if variant=='pointer':return process.replace('ptrsize:8;','ptrsize:4;')
        if variant=='endian':return process.replace('endian:little;','endian:big;')
        if variant=='missing':return process.replace('endian:little;','')
        if variant=='pid':return process.replace('pid:4d2;','pid:4d3;')
        raise AssertionError(variant)
    stub.process_transform=change;stub.start()
    client=Client('mutate',executable=None,options=('--gdb-remote',stub.endpoint),reply_seconds=30)
    before=resource(client.p.pid)
    try:
        client.action('continue');state=client.stopped()
        assert not state['threads'] and 'architecture' in state['gdb_remote']['last_reason'],state
        refusal(client,'continue','UnsupportedArchitecture' if not wrong else 'WrongResult')
        at=stub.requests.index('vCont;c')
        assert stub.requests[at+1:]==['qProcessInfo'],stub.requests[at:]
        assert stub.served['process']==2 and stub.served['controls']==['vCont;c'],stub.served
        return dict(case='exec-refusal-'+variant,status='pass',queries=stub.served,
                    resources_before=before,resources_after=resource(client.p.pid))
    finally:
        client.close();stub.join(timeout=2)
        (work/('exec-'+variant+'-mcp.json')).write_text(json.dumps(client.transcript,indent=2)+'\n')


def malformed_stop_case(work, variant, wrong):
    recording,stops=recorded_stops('crash-bad-access')
    if variant=='count':stops[1].packet=stops[1].packet.replace('mecount:2;','mecount:3;')
    elif variant=='duplicate':stops[1].packet=stops[1].packet+'metype:1;'
    elif variant=='fault':stops[1].packet=stops[1].packet.replace('medata:10;','medata:11;')
    else:raise AssertionError(variant)
    stub=Replay(recording,stops);stub.start()
    client=Client('mutate',executable=None,options=('--gdb-remote',stub.endpoint),reply_seconds=30)
    before=resource(client.p.pid)
    try:
        client.action('continue');state=client.stopped()
        assert not state['threads'] and state['gdb_remote']['last_reason']=='Malformed GDB stop; reconnect required',state
        refusal(client,'continue','ProtocolError' if not wrong else 'WrongResult')
        assert stub.requests[-1]=='vCont;c',stub.requests
        return dict(case='malformed-stop-'+variant,status='pass',queries=stub.served,
                    resources_before=before,resources_after=resource(client.p.pid))
    finally:
        client.close();stub.join(timeout=2)
        (work/('malformed-'+variant+'-mcp.json')).write_text(json.dumps(client.transcript,indent=2)+'\n')

def main():
    os.umask(0o022)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work',type=Path,required=True)
    parser.add_argument('--only')
    parser.add_argument('--wrong-result',action='store_true')
    args = parser.parse_args()
    work = args.work.resolve();work.mkdir(parents=True)
    os.environ['XODB_BIN'] = str(Path(os.environ.get('XODB_BIN',ROOT/'zig-out/bin/xodb')).resolve())
    result = dict(status='running',rows=[],load=os.getloadavg())
    start = time.monotonic()
    try:
        for case in ['recorded','name','unknown','duplicate','oversized','unsupported']:
            if args.only not in (None,'threads-'+case):continue
            result['rows'].append(thread_case(work,case,args.wrong_result))
        for kind in ['crash-bad-access','crash-abort','fork','exec','exit']:
            if args.only in (None,'stops-'+kind):result['rows'].append(stop_case(work,kind,args.wrong_result))
        for variant in ['recorded','overlap']:
            if args.only in (None,'regions-'+variant):result['rows'].append(region_case(work,args.wrong_result,variant))
        for variant in ['cpu','pointer','endian','missing','pid']:
            if args.only in (None,'exec-refusal-'+variant):result['rows'].append(exec_refusal_case(work,variant,args.wrong_result))
        for variant in ['count','duplicate','fault']:
            if args.only in (None,'malformed-stop-'+variant):result['rows'].append(malformed_stop_case(work,variant,args.wrong_result))
        if args.only in (None,'hardware-limits'):result['rows'].append(hardware_case(work,args.wrong_result))
        assert result['rows'],'no selected case'
        result['status'] = 'pass'
    finally:
        if result['status'] == 'running':result['status'] = 'fail'
        result['seconds'] = time.monotonic()-start
        (work/'results.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(status=result['status'],cases=len(result['rows']),seconds=result['seconds'])))


if __name__=='__main__':main()
