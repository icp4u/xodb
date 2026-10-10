#!/usr/bin/env python3
"""Fast lane: owned synthetic containers and candidate search, never live-object claims."""
import argparse,importlib.util,json,os,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True);p.add_argument('--agent',type=Path)
p.add_argument('--shared',action='store_true');p.add_argument('--wrong-oracle',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755);exe=w/'fixture';oracle=w/'oracle.json'
if a.agent:os.environ['XODB_RUNTIME_AGENT']=str(a.agent.resolve())
started=time.monotonic();subprocess.run(['cc','-std=c11','-O1','-g','-DNDEBUG','-Wall','-Wextra','-Werror','tests/jai-discovery.c','src/language/jai_layout.c','src/language/jai_reader.c','src/language/jai_value.c','src/language/jai_container.c','-o',str(exe)],check=True,timeout=30)
from client import Client
server=None;c=None;observer=None;report={'status':'failed'}
def wait(probe,predicate):
    end=time.monotonic()+10
    while True:
        r=probe()
        if predicate(r):return r
        assert time.monotonic()<end,r
        time.sleep(.002)
def refuse(r,reason):
    if reason=='InvalidArguments':assert r.get('error')=={'code':-32602,'message':reason},r
    else:assert r.get('result',{}).get('isError') and r['result']['content'][0]['text']==reason,r
def resource(pid):
    f=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
    return {'cpu_seconds':(int(f[11])+int(f[12]))/os.sysconf('SC_CLK_TCK'),'rss_bytes':int(f[21])*os.sysconf('SC_PAGE_SIZE')}
try:
    if a.shared:
        spec=importlib.util.spec_from_file_location('shared_fixture',root/'tests/shared-sessions.py');shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)
        server=shared.Server(root,w,Path(os.environ.get('XODB_BIN',root/'zig-out/bin/xodb')).resolve(),exe,'control',fixture_args=[str(oracle)])
        class SocketClient(shared.Client):
            inspect=shared.Client.tool;tool=shared.Client.raw
            def session(self):return self.inspect('get_session')
            def action(self,name,**args):return self.inspect(name,generation=self.session()['generation'],**args)
            def stopped(self,reason=None):return wait(self.session,lambda s:s['state']=='stopped' and not s['symbol_discovery_pending'] and not s['continue_pending'] and (reason is None or any(t['reason']==reason for t in s['threads'])))
        c=SocketClient(server,'controller');server.remember_target(c.session());c.inspect('claim_session_control',generation=c.session()['generation'],ttl_ms=30000)
        observer=SocketClient(server,'observer')
    else:c=Client('control',str(exe),args=[str(oracle)])
    c.action('set_breakpoint',symbol='discovery_ready');c.action('set_breakpoint',symbol='discovery_changed');c.action('continue');c.stopped('breakpoint')
    truth=json.loads(oracle.read_text());before=c.session();gen=before['generation'];regs=c.inspect('get_registers',tid=before['pid'])
    report['resources_before']=resource(server.proc.pid if server else c.p.pid)
    cap=c.action('capture_memory',address=truth['base'],length=truth['size'])
    ident=c.action('load_runtime_types',provider='jai',snapshot_ids=[cap['id']])['id']
    listing=wait(lambda:c.inspect('list_runtime_types',id=ident),lambda r:r['state']!='pending');assert listing['state']=='ready',listing
    child=c.inspect('get_runtime_type',id=ident,type_name='FixtureTypedChild')['type']['address_hex']
    def container(**args):return c.action('read_runtime_container',id=ident,**args)
    first=container(type_name='Bucket',address=truth['bucket'],limit=1)
    assert first['state']=='truncated' and first['total_count_hex']=='0x2' and first['capacity_hex']=='0x4' and not first['lifetime_proved'],first
    assert first['rows']==[{'address_hex':truth['bucket_items'][0],'slot_hex':'0x1','type_address_hex':child}] and first['next']==1,first
    last=container(type_name='Bucket',address=truth['bucket'],start=first['next'],limit=1)
    assert last['rows'][0]['address_hex']==truth['bucket_items'][1] and last['rows'][0]['slot_hex']=='0x3' and last['next'] is None,last
    value=c.action('read_runtime_value',id=ident,type_address=child,address=first['rows'][0]['address_hex'])
    assert value['rows'][3]['bits_hex']==('0x17' if a.wrong_oracle else '0x16'),value
    bad=container(type_name='Bucket',address=truth['bad_bucket'])
    assert bad['state']=='unavailable' and bad['reason']=='JaiBucketCountMismatch' and bad['rows']==[] and bad['total_count_hex'] is None,bad
    table=container(type_name='Table',address=truth['bucket']);assert table['reason']=='JaiTableOccupancyUnproved' and not table['rows'],table
    arr=container(type_address=truth['dynamic_type'],address=truth['dynamic'],start=1,limit=1)
    assert arr['total_count_hex']=='0x3' and arr['capacity_hex']=='0x4' and arr['rows'][0]['address_hex']==hex(int(truth['numbers'],16)+8),arr
    native=c.inspect('get_value_children',tid=before['pid'],expression=truth['dynamic']+' as '+truth['dynamic_type'],start=2,limit=1)['view']
    assert native['total']==3 and native['children'][0]['value']['display']=='33',native
    search_args=dict(id=ident,type_name='FixtureTypedBase',self_type_field='entity_type',dynamic_type_address=child,address=truth['area'],length=truth['area_size'])
    search=c.action('search_runtime_instances',**search_args)
    def page(start=0,limit=32,client=c):return client.action('get_runtime_instances',id=search['id'],start=start,limit=limit)
    result=wait(page,lambda r:r['state']!='running')
    assert result['state']=='complete' and result['candidate_hit_count']==3 and not result['lifetime_proved'],result
    assert [r['candidate_address_hex'] for r in result['rows']]==truth['candidates'],result
    # The middle word is not an object. It remains explicitly a candidate.
    assert all(r['type_address_hex']==child and r['reason'] is None for r in result['rows']),result
    assert result['unreadable_bytes']==0 and result['scanned_bytes']==truth['area_size'] and 'unrelated storage' in result['basis'],result
    paged=page(1,1);assert paged['next']==2 and len(paged['rows'])==1 and paged['rows'][0]['candidate_address_hex']==truth['candidates'][1],paged
    refuse(c.tool('search_runtime_instances',generation=gen,**(search_args|{'length':1073741825})),'InvalidArguments')
    refuse(c.tool('search_runtime_instances',generation=gen,**(search_args|{'self_type_field':'health'})),'RuntimeSelfTypeFieldUnproved')
    assert page()['candidate_hit_count']==3
    if observer:
        c.inspect('release_session_control')
        refuse(observer.tool('search_runtime_instances',generation=gen,**search_args),'ControlLeaseRequired')
        refuse(observer.tool('cancel_memory_search',id=search['id']),'ControlLeaseRequired')
        assert page(client=observer)['rows']==result['rows']
        assert observer.action('read_runtime_container',id=ident,type_name='Bucket',address=truth['bucket'])['total_count_hex']=='0x2'
        c.inspect('claim_session_control',generation=gen,ttl_ms=30000)
    else:
        denied=Client('observe',str(exe),args=[str(w/'observe.json')])
        try:refuse(denied.tool('search_runtime_instances',generation=denied.session()['generation'],**search_args),'AgentScopeDenied')
        finally:(w/'observer-transcript.json').write_text(json.dumps(denied.transcript));denied.close()
    # Existing cancellation must catch an actually running search, not a done one.
    slow=c.action('search_runtime_instances',**(search_args|{'address':truth['slow'],'length':truth['slow_size']}))
    progress=c.action('get_runtime_instances',id=slow['id'])
    assert progress['state']=='running' and progress['scanned_bytes']<progress['range_bytes'],progress
    # Cancel immediately after the running observation; lease checks above are separate.
    cancelled=c.inspect('cancel_memory_search',id=slow['id'])
    assert cancelled['state']=='cancelled',cancelled
    report['cancellation']={k:cancelled[k] for k in ('state','scanned','length','total_hits')}
    assert c.action('get_runtime_instances',id=slow['id'])['state']=='cancelled'
    holes=c.action('search_runtime_instances',**(search_args|{'address':truth['holes'],'length':3*4096}))
    hole_result=wait(lambda:c.action('get_runtime_instances',id=holes['id']),lambda r:r['state']!='running')
    assert hole_result['state']=='complete' and hole_result['unreadable_bytes']==4096 and hole_result['candidate_hit_count']==2,hole_result
    assert [r['candidate_address_hex'] for r in hole_result['rows']]==[truth['holes'],hex(int(truth['holes'],16)+8192)],hole_result
    report['holes']={k:hole_result[k] for k in ('state','candidate_hit_count','unreadable_bytes','scanned_bytes')}
    replacement=c.action('search_memory',address=truth['area'],length=truth['area_size'],pattern='ee',encoding='hex')
    wait(lambda:c.inspect('get_memory_search',id=replacement['id']),lambda r:r['state']!='running')
    refuse(c.tool('get_runtime_instances',id=search['id'],generation=gen),'StaleRuntimeInstanceSearch')
    offset_search=c.action('search_runtime_instances',id=ident,type_name='FixtureOffsetSelf',self_type_field='entity_type',address=truth['offset'],length=truth['offset_size'])
    off=wait(lambda:c.action('get_runtime_instances',id=offset_search['id']),lambda r:r['state']!='running')
    assert off['candidate_hit_count']==1 and off['rows'][0]['hit_hex']==hex(int(truth['offset'],16)+8) and off['rows'][0]['candidate_address_hex']==truth['offset'],off
    assert c.session()['generation']==gen and c.inspect('get_registers',tid=before['pid'])==regs
    report['resources_after']=resource(server.proc.pid if server else c.p.pid)
    c.action('continue');c.stopped('breakpoint');current=c.session()['generation'];assert current!=gen
    refuse(c.tool('get_runtime_instances',id=offset_search['id'],generation=current),'RuntimeTypesStale')
    refuse(c.tool('read_runtime_container',id=ident,generation=current,type_name='Bucket',address=truth['bucket']),'RuntimeTypesStale')
    c.inspect('release_runtime_types',id=ident)
    refuse(c.tool('get_runtime_instances',id=offset_search['id'],generation=current),'RuntimeTypesExpired')
    report['status']='pass'
finally:
    if server:server.close()
    elif c:(w/'transcript.json').write_text(json.dumps(c.transcript));c.close()
    report.update(seconds=time.monotonic()-started,load=os.getloadavg(),allowed_cpus=len(os.sched_getaffinity(0)))
    (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
