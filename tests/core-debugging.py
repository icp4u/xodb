#!/usr/bin/env python3
"""Read a real owned-process ELF core without contacting its recorded PIDs."""
from datetime import datetime
from pathlib import Path
import os, json, signal, subprocess, struct, shutil
from client import Client
root=Path(__file__).resolve().parents[1];os.chdir(root)
run=root/'.work'/('core-debugging-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));run.mkdir()
binary=run/'fixture';core=run/'fixture.core';source=root/'tests/fixtures/core.c'
subprocess.run(['gcc','-g','-O0','-pthread','-fno-omit-frame-pointer',str(source),'-o',str(binary)],check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
command=['gdb','-nx','-nh','-batch','-iex','set auto-load safe-path /nonexistent','-ex','set debuginfod enabled off','-ex','set confirm off','-ex','run','-ex','info registers rip rsp','-ex','p held','-ex','generate-core-file '+str(core),'-ex','kill',str(binary)]
with (run/'gdb.txt').open('w') as log:
    p=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try:assert p.wait(timeout=45)==0
    finally:
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGKILL);p.wait()
assert core.exists()
c=Client('mutate',None,options=('--core',str(core)))
try:
    snap=c.session();assert snap['mode']=='core' and snap['state']=='stopped',snap
    assert len(snap['threads'])==2,snap
    tid=snap['threads'][0]['tid']
    details=c.inspect('get_core_info',limit=2)
    assert details['read_only'] and details['mapping_next']==2 and len(details['mappings'])==2,details
    stop=c.inspect('get_stop_info',tid=tid)['stop']
    assert stop['signal_name']=='SIGSEGV' and stop['code']==1 and stop['fault_address']==0x12345000 and stop['read_only'] and not stop['pending_delivery'],stop
    frames=c.inspect('get_stack',tid=tid)['frames']
    assert frames[0]['symbol']=='crash_site',frames
    assert frames[0]['source']['path']==str(source),frames
    value=c.inspect('evaluate_expression',tid=tid,expression='held')['value']
    assert value['display']=='71',value
    for name,args in (
        ('continue',{}),('interrupt',{}),('detach',{}),('restart',{}),
        ('step_instruction',{'tid':tid}),('step_source',{'tid':tid}),
        ('write_register',{'tid':tid,'name':'rip','value':'0x0'}),
        ('write_memory',{'address':hex(value['address']),'hex':'00'}),
        ('set_breakpoint',{'address':hex(frames[0]['pc'])}),
        ('set_watchpoint',{'address':hex(value['address']),'length':8,'kind':'write'}),
        ('start_profile',{})):
        result=c.tool(name,generation=c.session()['generation'],**args)
        assert 'ReadOnlyCore' in json.dumps(result),(name,result)
    raw=c.inspect('read_memory',address=hex(value['address']),length=8)
    extended=c.inspect('get_extended_registers',tid=tid)
    (run/'values.json').write_text(json.dumps({'stack':frames,'memory':raw,'extended':extended},indent=2))
finally:
    (run/'transcript.json').write_text(json.dumps(c.transcript,indent=2));c.close()
# Recorded PIDs may have been reused: opening/closing/mutation must not touch
# a different live process. Substitute our own untraced sentinel's identity.
original=core.read_bytes()
def notes(data):
    phoff=struct.unpack_from('<Q',data,32)[0];count=struct.unpack_from('<H',data,56)[0]
    for i in range(count):
        kind,flags,offset,va,pa,size,mem,align=struct.unpack_from('<IIQQQQQQ',data,phoff+i*56)
        if kind!=4:continue
        at=offset
        while at<offset+size:
            ns,ds,t=struct.unpack_from('<III',data,at);at+=12
            name=data[at:at+ns];at+=(ns+3)&~3
            yield name,t,at,ds
            at+=(ds+3)&~3
sentinel=subprocess.Popen(['sleep','30'])
try:
    altered=bytearray(original);first=True
    for name,kind,offset,size in notes(altered):
        if name.startswith(b'CORE') and kind==1 and first:
            struct.pack_into('<i',altered,offset+32,sentinel.pid);first=False
        if name.startswith(b'CORE') and kind==3:struct.pack_into('<i',altered,offset+24,sentinel.pid)
    copy=run/'reused-pid.core';copy.write_bytes(altered)
    c=Client('mutate',None,options=('--core',str(copy)))
    try:
        snap=c.session();assert snap['pid']==sentinel.pid,snap
        assert c.inspect('evaluate_expression',tid=sentinel.pid,expression='held')['value']['display']=='71'
        for action in ('continue','detach','restart','interrupt'):
            result=c.tool(action,generation=snap['generation']);assert 'ReadOnlyCore' in json.dumps(result),result
    finally:c.close()
    assert sentinel.poll() is None,'Core operation affected a live process with a reused PID'
finally:
    sentinel.terminate();sentinel.wait(timeout=3)
# Move a preserved executable and explicitly supply it by matching captured ID.
shutil.copy2(binary,run/'fixture.backup');moved=run/'moved-executable';binary.rename(moved)
c=Client('observe',None,options=('--core',str(core),'--exe',str(moved)))
try:
    tid=c.session()['threads'][0]['tid']
    assert c.inspect('evaluate_expression',tid=tid,expression='held')['value']['display']=='71'
finally:c.close()
# A substituted binary at the recorded name must not silently supply symbols.
subprocess.run(['gcc','-g','-O0',str(root/'tests/fixtures/optimized.c'),'-o',str(binary)],check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
c=Client('observe',None,options=('--core',str(core)))
try:
    tid=c.session()['threads'][0]['tid'];frame=c.inspect('get_stack',tid=tid)['frames'][0]
    assert frame['symbol'] is None and frame['diagnostic']=='CoreModuleBuildIdMismatch',frame
finally:c.close()
wrong=subprocess.run([os.environ.get('XODB_BIN','zig-out/bin/xodb'),'--headless','--mcp','--core',str(core),'--exe',str(binary)],input=b'',capture_output=True,timeout=5)
assert wrong.returncode and b'CoreExecutableBuildIdMismatch' in wrong.stderr,wrong.stderr
shutil.copy2(binary,run/'foreign-executable.backup')
# Restore the original fixture for GUI demos and independently reject corruption.
shutil.copy2(moved,binary)
for name,changed,expected in (
    ('short',original[:80],'TruncatedCore'),
    ('class',original[:4]+b'\x01'+original[5:],'UnsupportedCoreFormat'),
):
    broken=run/(name+'.core');broken.write_bytes(changed)
    result=subprocess.run([os.environ.get('XODB_BIN','zig-out/bin/xodb'),'--headless','--mcp','--core',str(broken)],input=b'',capture_output=True,timeout=5)
    assert result.returncode and expected.encode() in result.stderr,(name,result.stderr)
# Remove only the stored bytes of the stack segment in a copied core. It must
# not borrow the live address space or manufacture zero-filled stack data.
missing=bytearray(original);phoff=struct.unpack_from('<Q',missing,32)[0];count=struct.unpack_from('<H',missing,56)[0]
for i in range(count):
    ph=phoff+i*56;kind,flags,off,va,pa,size,mem,align=struct.unpack_from('<IIQQQQQQ',missing,ph)
    if kind==1 and va<=value['address']<va+mem:struct.pack_into('<Q',missing,ph+32,0)
omitted=run/'omitted-stack.core';omitted.write_bytes(missing)
c=Client('observe',None,options=('--core',str(omitted)))
try:
    result=c.tool('read_memory',address=hex(value['address']),length=8)
    assert 'CoreMemoryOmitted' in json.dumps(result),result
finally:c.close()
c=Client('control',str(binary))
try:
    c.action('set_breakpoint',symbol='crash_site');c.action('continue');snap=c.stopped('breakpoint')
    c.action('continue');snap=c.stopped('signal')
    tid=next(t['tid'] for t in snap['threads'] if t['signal']==11)
    stop=c.inspect('get_stop_info',tid=tid)['stop']
    assert stop['signal_name']=='SIGSEGV' and stop['fault_address']==0x12345000 and stop['pending_delivery'] and not stop['read_only'],stop
    (run/'live-stop.json').write_text(json.dumps(stop,indent=2))
finally:c.close() # kill our stopped child; do not deliver a fatal signal/core dump
print('Core threads, symbols, source, locals, memory, FP/XMM and execution/mutation rejection passed:',run)
