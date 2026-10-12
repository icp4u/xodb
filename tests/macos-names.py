#!/usr/bin/env python3
"""macOS frame labels from recorded stops and Apple-linked owned binaries.

The loopback stub serves recorded register/stack/image bytes. Text reads for
the prologue heuristic come from the matching corpus file, never invented
instructions. Unrecorded memory is unavailable. No Mac or system cache needed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time

from client import Client
from helpers.fake_debugserver import Fake
from helpers import macho_fixture

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests/fixtures/macos-names'
IMAGES = 'jGetLoadedDynamicLibrariesInfos:{"fetch_all_solibs":true}'
HANDSHAKE = json.loads((FIXTURES/'transcripts/c-handshake.json').read_text())
COMMON = dict(HANDSHAKE['exchanges'])
XML = ''.join(r[0][1:] for q,r in HANDSHAKE['exchanges'] if q.startswith('qXfer:features:read:target.xml:'))


def slice_bytes(path, cpu, subtype):
    data = path.read_bytes()
    if data[:4] == bytes.fromhex('cafebabe'):
        count = struct.unpack_from('>I', data, 4)[0]
        for i in range(count):
            c,s,off,size,_ = struct.unpack_from('>IIIII', data, 8+20*i)
            if c == cpu and s & 0xffffff == subtype & 0xffffff:
                return data[off:off+size]
        raise AssertionError('recorded universal architecture has no slice')
    return data


class Stop:
    def __init__(self, recording, at):
        rows = recording['exchanges']
        self.stop = rows[at][1][0]
        end = next((i for i in range(at+1,len(rows)) if rows[i][0] in ('c','k','D') or rows[i][0].startswith('vCont;')),len(rows))
        self.replies = dict(rows[at+1:end])
        self.images = json.loads(self.replies[IMAGES][0])['images']
        self.registers = {}
        for pair in self.stop[3:].split(';'):
            if re.fullmatch('[0-9a-f]+:[0-9a-f]+',pair):
                k,v=pair.split(':');self.registers[int(k,16)]=v
        for q,r in self.replies.items():
            if re.fullmatch('p[0-9a-f]+',q) and not r[0].startswith('E'):
                self.registers[int(q[1:],16)] = r[0]
        self.memory = []
        for q,r in self.replies.items():
            match = re.fullmatch(r'm([0-9a-f]+),([0-9a-f]+)',q)
            if match and re.fullmatch('[0-9a-f]*',r[0]):
                self.memory.append((int(match[1],16),bytes.fromhex(r[0])))
        for image in self.images:
            path = image['pathname']
            if not path.startswith('/xodb-corpus/'): continue
            local = FIXTURES/'corpus'/path.removeprefix('/xodb-corpus/')
            if not local.is_file(): continue
            header = image['mach_header'];data = slice_bytes(local,header['cputype'],header['cpusubtype'])
            text = next(s['vmaddr'] for s in image['segments'] if s['name']=='__TEXT')
            for segment in image['segments']:
                if segment['maxprot'] & 4 and segment['filesize']:
                    self.memory.append((segment['vmaddr']+image['load_address']-text,data[segment['fileoff']:segment['fileoff']+segment['filesize']]))
        self.pc = int.from_bytes(bytes.fromhex(self.registers[0x20]),'little')


class Replay(Fake):
    def __init__(self, recording, phases, mutate=None):
        self.recording,self.phases,self.phase = recording,phases,0
        self.extra,self.image_reads,self.probes = [],0,[]
        self.metadata = dict(recording['exchanges'][:4])
        super().__init__([],mutate)

    def lookup(self, request):
        stop = self.phases[self.phase]
        if request.startswith('qSupported:'):
            return next(r for q,r in self.recording['exchanges'] if q.startswith('qSupported:'))
        if request.startswith('qXfer:features:read:target.xml:'):
            at,size = (int(x,16) for x in request.rsplit(':',1)[1].split(','))
            return [('l' if at+size>=len(XML) else 'm')+XML[at:at+size]]
        if request in ('qHostInfo','qProcessInfo'): return self.metadata.get(request,COMMON[request])
        if request == '?': return [stop.stop]
        if request == IMAGES:
            self.image_reads += 1
            return [json.dumps({'images':stop.images},separators=(',',':'))]
        if request == 'g': return ['']
        if re.fullmatch(r'p[0-9a-f]+',request): return [stop.registers.get(int(request[1:],16),'E45')]
        if request.startswith('m'):
            address,size = (int(x,16) for x in request[1:].split(','))
            for at,data in stop.memory:
                if at<=address and address+size<=at+len(data): return [data[address-at:address-at+size].hex()]
            return ['E01']
        if request == 'qfThreadInfo': return ['m1001']
        if request == 'qsThreadInfo': return ['l']
        if request in ('Hg1001','Hc1001'): return ['OK']
        if re.fullmatch(r'[Zz]0,[0-9a-f]+,[0-9a-f]+',request):
            self.probes.append(request)
            return ['OK']
        if request == 'D': return ['OK']
        if request in ('vCont;c','c') and self.phase+1<len(self.phases):
            self.phase += 1
            return [self.phases[self.phase].stop]
        if request in COMMON: return COMMON[request]
        # These optional capabilities were not enabled in the recording.
        if request in ('QStartNoAckMode','qAttached','qMemoryRegionInfo:0') or request.startswith('jThreadExtendedInfo:'): return ['']
        self.extra.append(request)
        return ['']


def phases(recording, all_stops=False):
    rows = recording['exchanges'];found=[]
    for at,(q,r) in enumerate(rows):
        if not r or not r[0].startswith(('T05','T06')) or q=='qThreadStopInfo1001':continue
        try: stop=Stop(recording,at)
        except KeyError:continue
        found.append(stop)
    assert found,'no stopped snapshot with a recorded image list'
    return found if all_stops else [found[-1] if 'abort' in recording['description'] else found[0]]


def resources(pid):
    fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
    return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),rss_kib=int(fields[21])*os.sysconf('SC_PAGE_SIZE')//1024)


def wait_stack(client,tid):
    deadline=time.monotonic()+30
    while True:
        stack=client.inspect('get_stack',tid=tid)['frames']
        if not any(f.get('diagnostic')=='MachOSymbolsPending' for f in stack):return stack
        assert time.monotonic()<deadline,'symbol workers did not settle'
        time.sleep(.01)


def wait_label(client,address):
    deadline=time.monotonic()+30
    while True:
        value=client.inspect('get_macho_image',address=hex(address))
        if value['status']!='pending':return value
        assert time.monotonic()<deadline,'symbol worker did not settle'
        time.sleep(.01)


def close(client,stub,work,name):
    client.p.stdin.close()
    try:client.p.wait(timeout=15)
    except subprocess.TimeoutExpired:client.p.kill();client.p.wait();raise
    (work/(name+'.stderr')).write_bytes(client.p.stderr.read())
    stub.join(timeout=2)


def address_cases(work):
    rows=[]
    recording=json.loads((FIXTURES/'transcripts/c-crash-abort.json').read_text())
    stub=Replay(recording,phases(recording));stub.start()
    binary=FIXTURES/'corpus'/recording['program']
    client=Client('mutate',executable=None,options=('--gdb-remote',stub.endpoint,'--exe',str(binary)),reply_seconds=30)
    try:
        expected={0x186ee45e8:'libsystem_kernel.dylib+0x95e8',0x186f1f8d8:'libsystem_pthread.dylib+0x68d8',0x186e25978:'libsystem_c.dylib+0x78978',0x102fc8f30:'cprog!requests+0x1a0',0x102fc8c8c:'cprog!main+0x4ec',0x186b544e4:'dyld+0x204e4'}
        labels={hex(address):wait_label(client,address)['label'] for address in expected}
        assert labels=={hex(k):v for k,v in expected.items()},labels
        rows.append(dict(case='worked-example',status='pass',labels=labels))
    finally:close(client,stub,work,'worked-example')
    recording=json.loads((FIXTURES/'transcripts/c-images-dlopen.json').read_text())
    stops=phases(recording,True);assert len(stops)==3
    stub=Replay(recording,stops);stub.start();binary=FIXTURES/'corpus'/recording['program']
    client=Client('mutate',executable=None,options=('--gdb-remote',stub.endpoint,'--debug-dir',str(binary.parent)),reply_seconds=30)
    try:
        previous=None;plugin=None;results=[]
        for n,stop in enumerate(stops):
            if n:
                generation=client.session()['generation'];client.action('continue');deadline=time.monotonic()+15
                while True:
                    state=client.session()
                    if state['state']=='stopped' and state['generation']!=generation:break
                    assert time.monotonic()<deadline,'next recorded stop absent'
                    time.sleep(.01)
            dep=next(i for i in stop.images if i['pathname'].endswith('/libdep.dylib'))
            # Independent llvm-nm oracle on the published Apple-linked file:
            # _dep_add T 4c8 and _plug_entry T 390 (link addresses).
            label=wait_label(client,dep['load_address']+0x4c8)
            assert label['label']=='libdep.dylib!dep_add+0x0' and label['status']=='ready',label
            if previous is not None:assert label['module_id']==previous,label
            previous=label['module_id'];results.append(label)
            if n==1:
                plug=next(i for i in stop.images if i['pathname'].endswith('/libplug.dylib'));plugin=plug['load_address']+0x390
                label=wait_label(client,plugin);assert label['label']=='libplug.dylib!plug_entry+0x0',label;results.append(label)
            if n==2:
                assert not any(i['pathname'].endswith('/libplug.dylib') for i in stop.images)
                answer=client.tool('get_macho_image',address=hex(plugin))['result']
                assert answer['isError'] and answer['content'][0]['text']=='MachOAddressUnavailable',answer
        assert stub.image_reads>=3 and not stub.extra,stub.extra
        rows.append(dict(case='dylibs-dlopen-dlclose',status='pass',labels=results))
    finally:close(client,stub,work,'dylibs-dlopen-dlclose')
    return rows


def hostile_case(name,work):
    recording=json.loads((FIXTURES/'transcripts/cxx-basic.json').read_text());stops=phases(recording)
    binary=FIXTURES/'corpus'/recording['program'];directory=work/name;directory.mkdir()
    local=directory/binary.name;shutil.copyfile(binary,local)
    fault={'served':0}
    def mutate(request,replies):
        if request!=IMAGES:return replies
        fault['served']+=1;value=json.loads(replies[0]);image=value['images'][0]
        if name=='uuid-mismatch':image['uuid']='00000000-0000-0000-0000-000000000000'
        if name=='duplicate-image':value['images'].append(image)
        if name=='overlap':
            clone=dict(image);clone['load_address']+=4;value['images'].append(clone)
        if name=='bad-uuid':image['uuid']='bad'
        if name=='segment-overflow':image['segments'][1]['vmaddr']=(1<<64)-1
        if name=='segment-cap':image['segments']*=33
        if name=='image-list-cap':value['images']=[image]*4097
        if name=='basename-dot':image['pathname']='/owned/.'
        if name=='basename-dotdot':image['pathname']='/owned/..'
        if name=='remote-path':image['pathname']='/../../'+str(binary)
        # '!' separates image from symbol; a stub-chosen name must not supply it.
        if name=='image-name-separator':image['pathname']='/xodb-corpus/out/libsystem_c.dylib!abort'
        return [json.dumps(value,separators=(',',':'))]
    if name=='symlink':local.unlink();local.symlink_to(binary)
    if name=='fifo':local.unlink();os.mkfifo(local)
    options=['--exe',str(local)]
    if name in ('remote-path','image-name-separator'):options=['--debug-dir',str(directory/'empty')];(directory/'empty').mkdir()
    stub=Replay(recording,stops,mutate);stub.start();client=Client('mutate',executable=None,options=('--gdb-remote',stub.endpoint,*options),reply_seconds=30)
    try:
        if name in ('duplicate-image','overlap','bad-uuid','segment-overflow','segment-cap','image-list-cap'):
            answer=client.tool('get_macho_image',address=hex(stops[0].pc))['result']
            expected={'duplicate-image':'MachODuplicateImageAddress','overlap':'MachOAmbiguousImageRange','image-list-cap':'GdbListTooLarge'}.get(name,'ProtocolError')
            assert answer['isError'] and answer['content'][0]['text']==expected,answer
            if name=='image-list-cap':
                frame=wait_stack(client,client.session()['threads'][0]['tid'])[0]
                assert frame['diagnostic']==expected,frame
        else:
            label=wait_label(client,stops[0].pc)
            if name=='file-changed':
                assert label['status']=='ready',label
                before=local.stat()
                with local.open('r+b') as out:out.seek(64);byte=out.read(1);out.seek(64);out.write(bytes([byte[0]^1]))
                os.utime(local,ns=(before.st_atime_ns,before.st_mtime_ns+1000000000))
                label=wait_label(client,stops[0].pc)
            expected={'uuid-mismatch':'MachOUuidMismatch','file-changed':'MachOFileChanged','symlink':'MachOLocalFileRefused','fifo':'MachOLocalFileRefused','remote-path':'MachOLocalFileUnavailable','basename-dot':'MachOImageBasenameInvalid','basename-dotdot':'MachOImageBasenameInvalid','image-name-separator':'MachOLocalFileUnavailable'}[name]
            assert label['status']=='image_only' and label['diagnostic']==expected and '!' not in label['label'],label
            if name=='image-name-separator':
                assert label['label']=='libsystem_c.dylib?abort+0x%x'%(stops[0].pc-stops[0].images[0]['load_address']),label
                frame=wait_stack(client,client.session()['threads'][0]['tid'])[0]
                assert frame['symbol']==label['label'] and frame['diagnostic']==expected,frame
        assert fault['served']>=1,fault
        return dict(case=name,status='pass',fault_observed=fault['served'])
    finally:close(client,stub,work,name)


def large_index(work):
    # More entries than the old advertised 131072 lookup threshold. The
    # external _main wins the address tie over the extra local symbols.
    extra=macho_fixture.nlist(1,0x0e,1,0,0x100000800)
    data,facts=macho_fixture.image(extra_symbols=[extra]*131073)
    local=work/'large-macho';local.write_bytes(data)
    recording=json.loads((FIXTURES/'transcripts/cxx-basic.json').read_text());stops=phases(recording)
    image={'load_address':0x100000000,'pathname':'/synthetic/large-macho','uuid':facts['uuid'],'mach_header':{'cputype':macho_fixture.ARM64,'cpusubtype':0,'filetype':2},'segments':[{'name':'__TEXT','vmaddr':0x100000000,'vmsize':0x1000,'maxprot':5}]}
    rows=[]
    for limited in (False,True):
        observed={'images':0}
        def mutate(request,replies):
            if request!=IMAGES:return replies
            observed['images']+=1
            return [json.dumps({'images':[image]})]
        stub=Replay(recording,stops,mutate);stub.start();options=['--exe',str(local)]
        if limited:options+=['--image-limit','1M']
        client=Client('mutate',executable=None,options=('--gdb-remote',stub.endpoint,*options),reply_seconds=30)
        try:
            before=resources(client.p.pid);label=wait_label(client,0x100000800)
            if limited:assert label['status']=='image_only' and label['diagnostic']=='MachOSymbolBudget',label
            else:assert label['status']=='ready' and label['label']=='large-macho!main+0x0',label
            assert observed['images']>=1
            rows.append(dict(case='large-index-budget' if limited else 'large-index',status='pass',symbols=facts['symbols'],resources_before=before,resources_after=resources(client.p.pid)))
        finally:close(client,stub,work,'large-index-'+str(int(limited)))
    return rows


def case(name,work,wrong=False,no_exe=False):
    recording=json.loads((FIXTURES/'transcripts'/(name+'.json')).read_text())
    stops=phases(recording)
    stub=Replay(recording,stops);stub.start()
    binary=FIXTURES/'corpus'/recording['program']
    options=['--gdb-remote',stub.endpoint,'--debug-dir',str(binary.parent)]
    if not no_exe:options+=['--exe',str(binary)]
    client=Client('mutate',executable=None,options=options,reply_seconds=30)
    try:
        before=resources(client.p.pid)
        session=client.session();tid=session['threads'][0]['tid'];stack=wait_stack(client,tid)
        if wrong:stack[0]['symbol']='planted-wrong-name'
        pc=stops[0].pc
        if 'crash-abort' in name:
            assert stack[0]['symbol']=='libsystem_kernel.dylib+0x95e8',stack[0]
            expected=['libsystem_c.dylib+0x78978','cprog!requests+0x1a0','cprog!main+0x4ec','dyld+0x204e4']
            for label in expected:assert any(f['symbol']==label for f in stack),(label,stack)
        else:
            main=next(image for image in stops[0].images if image['pathname'].endswith('/'+binary.name))
            text=next(s['vmaddr'] for s in main['segments'] if s['name']=='__TEXT')
            link=pc-main['load_address']+text
            wanted=next((n for n,value in recording['static']['symbols'].items() if value==link),None)
            assert wanted,(name,hex(link))
            assert stack[0]['symbol']==binary.name+'!'+wanted+'+0x0',stack[0]
            assert stack[0]['module_id'] is not None and stack[0]['diagnostic'] is None,stack[0]
        signed=any(int.from_bytes(data[8:16],'little')>>47 for _,data in stops[0].memory if len(data)==16)
        if name in ('c-arm64e-basic','c-universal-basic'):
            assert signed,'recording did not contain a signed return address'
            assert all((int(f['pc'],16) if isinstance(f['pc'],str) else f['pc'])<1<<47 for f in stack),stack
            assert any(f['symbol'] and 'main' in f['symbol'] for f in stack[1:]),stack
        assert stub.image_reads>=1 and not stub.extra,stub.extra
        row=dict(case=name,status='pass',frames=stack,signed_return_observed=signed,resources_before=before,resources_after=resources(client.p.pid))
        (work/(name+'.json')).write_text(json.dumps(row,indent=2)+'\n')
        print(json.dumps(dict(case=name,status='pass',frames=len(stack))),flush=True)
        return row
    finally:
        close(client,stub,work,name)


def main():
    os.umask(0o022);os.chdir(ROOT)
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--work',type=Path,required=True);p.add_argument('--only');p.add_argument('--matrix',action='store_true');p.add_argument('--no-exe',action='store_true');p.add_argument('--wrong-result',action='store_true');args=p.parse_args();work=args.work.resolve();work.mkdir(parents=True)
    os.environ['XODB_BIN']=str(Path(os.environ.get('XODB_BIN',ROOT/'zig-out/bin/xodb')).resolve())
    for name,digest in json.loads((FIXTURES/'SHA256.json').read_text()).items():assert hashlib.sha256((FIXTURES/name).read_bytes()).hexdigest()==digest,name
    names=['c-O2-basic','c-arm64e-basic','c-universal-basic','c-stripped-basic','cxx-basic','objc-basic','swift-basic','c-crash-abort']
    hostile=['uuid-mismatch','file-changed','symlink','fifo','remote-path','image-name-separator','basename-dot','basename-dotdot','image-list-cap','duplicate-image','overlap','bad-uuid','segment-overflow','segment-cap']
    selected=[n for n in names+hostile+['addresses']+(['large-index'] if args.matrix else []) if args.only in (None,n)];assert selected,'no selected case'
    result=dict(status='running',rows=[],load=os.getloadavg());started=time.monotonic()
    try:
        for name in selected:
            if name=='addresses':result['rows'].extend(address_cases(work))
            elif name=='large-index':result['rows'].extend(large_index(work))
            elif name in hostile:result['rows'].append(hostile_case(name,work))
            else:result['rows'].append(case(name,work,args.wrong_result,args.no_exe))
        result['status']='pass'
    finally:
        if result['status']=='running':result['status']='fail'
        result['seconds']=time.monotonic()-started;(work/'results.json').write_text(json.dumps(result,indent=2)+'\n')


if __name__=='__main__':main()
