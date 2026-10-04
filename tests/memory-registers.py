#!/usr/bin/env python3
"""Real ptrace memory coverage, incremental search and Linux xstate values."""
from datetime import datetime
import json, os, struct, subprocess, time
from pathlib import Path
from client import Client
root=Path(__file__).resolve().parents[1]; os.chdir(root)
run=root/'.work'/('memory-registers-'+datetime.now().strftime('%Y%m%dT%H%M%S%f')); run.mkdir()
exe=run/'fixture'
subprocess.run(['gcc','-g','-O0','-fno-omit-frame-pointer','tests/fixtures/inspection.c','-o',str(exe)],check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
c=Client('control',str(exe)); timings=[]
try:
    ready=c.inspect('find_symbol',name='inspect_ready')['address']
    c.action('set_breakpoint',address=ready); c.action('continue'); s=c.stopped('breakpoint'); tid=s['threads'][0]['tid']
    def value(expr): return c.inspect('evaluate_expression',tid=tid,expression=expr)['value']['scalar_bits']
    # Symbol addresses avoid depending on scalar formatting in the expression UI.
    def pointer(name):
        addr=c.inspect('find_symbol',name=name)['address']
        cap=c.action('capture_memory',address=addr,length=8)
        return int.from_bytes(bytes.fromhex(c.inspect('read_memory_snapshot',id=cap['id'])['hex']),'little')
    region,arena=pointer('region'),pointer('arena')
    values=c.inspect('find_symbol',name='values')['address']
    baseline=c.action('capture_memory',address=values,length=32)
    snap=c.action('capture_memory',address=hex(region+4093),length=4101)
    got=c.inspect('read_memory_snapshot',id=snap['id'],limit=4096)
    assert got['hex'].startswith('414241????'),got
    assert snap['readable']==5,snap
    x=c.inspect('get_extended_registers',tid=tid,format='f32',width=128)
    assert [float(v) for v in x['vectors'][0]['lanes']]==[1.25,-2.5,3.75,4.5],x
    assert x['x87'][0]['valid'] and float(x['x87'][0]['value'])==6.25,x
    assert not any(v['valid'] for v in x['x87'][1:]),x
    raw=c.inspect('get_extended_registers',tid=tid,format='hex')
    assert raw['vectors'][0]['hex'].startswith(struct.pack('<4f',1.25,-2.5,3.75,4.5).hex()),raw
    actual=c.inspect('evaluate_expression',tid=tid,expression='vector_width')['value']['bits']
    if actual>128:
        full=c.inspect('get_extended_registers',tid=tid,format='f32',width=actual)
        expected=[1.25,-2.5,3.75,4.5]+[i+.25 for i in range(5,17)]
        assert [float(v) for v in full['vectors'][0]['lanes']]==expected[:actual//32],full
        if actual==512:
            assert [float(v) for v in full['vectors'][31]['lanes']]==expected,full
            assert int(full['opmask'][1],16)==0xa55a,full
    def search(address,length,pattern):
        job=c.action('search_memory',address=hex(address),length=length,pattern=pattern,encoding='utf8')
        deadline=time.monotonic()+8
        while True:
            before=time.monotonic(); result=c.inspect('get_memory_search',id=job['id']); timings.append(time.monotonic()-before)
            if result['state']!='running': return result
            assert time.monotonic()<deadline,result
    holes=search(region,12288,'ABABA')
    assert holes['state']=='complete' and holes['hits']==[] and holes['unreadable']==4096,holes
    matches=search(arena,64*1024*1024,'ABA')
    assert matches['state']=='complete' and list(map(lambda x:int(x,16),matches['hits']))==[arena+4093,arena+4095,arena+65534,arena+65536],matches
    capped=search(arena,65536,'\0')
    assert capped['state']=='match_limit' and capped['total_hits']==1024,capped
    job=c.action('search_memory',address=hex(arena),length=64*1024*1024,pattern='aabb')
    assert c.inspect('cancel_memory_search',id=job['id'])['state']=='cancelled'
    changed=c.inspect('find_symbol',name='inspect_changed')['address']; c.action('set_breakpoint',address=changed)
    job=c.action('search_memory',address=hex(arena),length=64*1024*1024,pattern='aabb')
    c.action('continue'); c.stopped('breakpoint')
    assert c.inspect('get_memory_search',id=job['id'])['state']=='stale'
    now=c.action('capture_memory',address=values,length=32)
    diff=c.inspect('read_memory_snapshot',id=now['id'],baseline=baseline['id'])
    assert [i for i,v in enumerate(diff['comparison']) if v=='changed']==[1,17],diff
    after=c.inspect('get_extended_registers',tid=tid,format='f32',width=128)
    assert all(float(v)==0 for v in after['vectors'][0]['lanes']),after
    assert not any(v['valid'] for v in after['x87']),after
    denied=c.tool('capture_memory',address=values,length=32,generation=s['generation'])
    assert denied['result']['isError'] and denied['result']['content'][0]['text']=='StaleSnapshot',denied
    assert max(timings)<.5,max(timings)
finally:
    (run/'transcript.json').write_text(json.dumps(c.transcript,indent=2)); c.close()
print('Memory holes, cross-page/overlapping search, cancellation, stale jobs, diffs and x87/SIMD passed:',run,'max status ms',round(max(timings)*1000,2))
