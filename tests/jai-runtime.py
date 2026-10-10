#!/usr/bin/env python3
"""Fast lane: owned process, generic type tools, exact values and stale stops.

--shared adds two real socket clients and cache ownership checks. No Jai
compiler, game files, GUI, privilege changes or unrelated processes are used.
"""
import argparse, importlib.util, json, os, subprocess, time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--agent', type=Path)
p.add_argument('--shared', action='store_true')
p.add_argument('--wrong-oracle', action='store_true')
p.add_argument('--wrong-native-oracle', action='store_true')
a=p.parse_args(); root=Path(__file__).resolve().parents[1]; os.chdir(root); os.umask(0o022)
w=a.work.resolve(); w.mkdir(parents=True,mode=0o755)
if a.agent: os.environ['XODB_RUNTIME_AGENT']=str(a.agent.resolve())
exe=w/'fixture'; oracle=w/'oracle.json'; started=time.monotonic()
subprocess.run(['cc','-std=c11','-g','-O1','-DNDEBUG','-Wall','-Wextra','-Werror',
                'tests/jai-runtime.c','src/language/jai_layout.c','src/language/jai_reader.c',
                'src/language/jai_value.c','-o',str(exe)],check=True)
from client import Client
server=None; c=None; observers=[]; report={'status':'failed'}
def wait(probe,predicate):
    deadline=time.monotonic()+10
    while True:
        result=probe()
        if predicate(result): return result
        assert time.monotonic()<deadline,result
        time.sleep(.002)
def refuse(reply,why):
    if why=='InvalidArguments':
        assert reply.get('error')=={'code':-32602,'message':'InvalidArguments'},reply
        return
    assert reply.get('result',{}).get('isError') and reply['result']['content'][0]['text']==why,reply
def ready(client,ident):
    result=wait(lambda:client.inspect('list_runtime_types',id=ident),lambda r:r['state']!='pending')
    assert result['state']=='ready',result
    return result
def resource(pid):
    fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
    return {'cpu_seconds':(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),
            'rss_bytes':int(fields[21])*os.sysconf('SC_PAGE_SIZE')}
try:
    if a.shared:
        spec=importlib.util.spec_from_file_location('shared_fixture',root/'tests/shared-sessions.py')
        shared=importlib.util.module_from_spec(spec); spec.loader.exec_module(shared)
        server=shared.Server(root,w,Path(os.environ.get('XODB_BIN',root/'zig-out/bin/xodb')).resolve(),exe,'control',fixture_args=[str(oracle)])
        # Adapt the socket helper's naming to the stdio helper.
        class SocketClient(shared.Client):
            inspect=shared.Client.tool
            tool=shared.Client.raw
            def session(self): return self.inspect('get_session')
            def action(self,name,**args): return self.inspect(name,generation=self.session()['generation'],**args)
            def stopped(self,reason=None):
                return wait(self.session,lambda s:s['state']=='stopped' and not s['symbol_discovery_pending'] and not s['continue_pending'] and (reason is None or any(t['reason']==reason for t in s['threads'])))
        c=SocketClient(server,'controller'); server.remember_target(c.session())
        c.inspect('claim_session_control',generation=c.session()['generation'],ttl_ms=30000)
        observers=[SocketClient(server,'observer-one'),SocketClient(server,'observer-two')]
    else: c=Client('control',str(exe),args=[str(oracle)])
    c.action('set_breakpoint',symbol='runtime_ready'); c.action('set_breakpoint',symbol='runtime_changed')
    c.action('continue'); c.stopped('breakpoint'); truth=json.loads(oracle.read_text())
    before=c.session(); gen=before['generation']; pid=server.proc.pid if server else c.p.pid
    regs=c.inspect('get_registers',tid=before['pid']); report['resources_before']=resource(pid)
    defs=c.call('tools/list')['result']['tools']; names={d['name']:d for d in defs}
    for name in ('load_runtime_types','list_runtime_types','get_runtime_type','read_runtime_value','release_runtime_types'):
        assert names[name]['annotations']['readOnlyHint'],names[name]
    cap=c.action('capture_memory',address=truth['base'],length=truth['size'])
    ident=c.action('load_runtime_types',provider='jai',snapshot_ids=[cap['id']])['id']
    listing=ready(c,ident); assert not listing['stale'] and listing['generation']==gen,listing
    def get(**kw): return c.inspect('get_runtime_type',id=ident,**kw)
    def value(**kw): return c.action('read_runtime_value',id=ident,**kw)
    obj=get(type_name='FixtureObject'); assert int(obj['type']['size_hex'],16)==truth['object_size'],obj
    assert int(obj['members'][1]['offset_hex'],16)==truth['energy_offset'],obj
    paged=get(type_name='FixtureObject',start=1,limit=1)
    assert len(paged['members'])==1 and paged['members'][0]['name']=='energy' and paged['next']==2,paged
    enum=get(type_name='FixtureState'); assert enum['enumerators']==[{'name':'NEGATIVE','bits_hex':'0xfffffffffffffffd'},{'name':'READY','bits_hex':'0x7'}],enum
    poly=get(type_name='FixtureBox(s32)'); assert poly['parameters'][0]['constant'] and poly['parameters'][0]['constant_address_hex'],poly
    first=c.inspect('list_runtime_types',id=ident,limit=2); second=c.inspect('list_runtime_types',id=ident,start=first['next'],limit=2)
    assert first['next']==2 and second['start']==2 and len(first['types'])==len(second['types'])==2
    refuse(c.tool('get_runtime_type',id=ident,type_name='FixtureDuplicate'),'RuntimeTypeAmbiguous')
    refuse(c.tool('get_runtime_type',id=ident,type_name='FixtureObject',type_address=obj['type']['address_hex']),'InvalidArguments')
    v=value(type_name='FixtureObject',address=truth['object']); rows=v['rows']
    assert v['state']=='complete' and len(rows)==9,v
    assert rows[2]['bits_hex']==hex((-41 if a.wrong_oracle else -42)&((1<<64)-1)),rows[2]
    assert rows[3]['bits_hex']=='0x4029000000000000' and rows[4]['bits_hex']==truth['object'],rows
    assert int(rows[3]['address_hex'],16)==int(truth['object'],16)+truth['energy_offset']
    cycle=value(type_name='FixtureObject',address=truth['object'],depth=8,follow_pointers=True)
    assert cycle['state']=='partial' and any(r['reason']=='JaiValueCycle' for r in cycle['rows']),cycle
    string=value(type_address=truth['string_type'],address=truth['text'])
    assert string['rows'][0]['preview_hex']=='68690078ff',string
    dynamic=value(type_name='FixtureTypedBase',address=truth['child'],self_type_field='entity_type')
    assert dynamic['type_address_hex']==get(type_name='FixtureTypedChild')['type']['address_hex'] and dynamic['rows'][3]['bits_hex']=='0x63',dynamic
    invalid=value(type_name='FixtureTypedBase',address=truth['object'],self_type_field='entity_type')
    assert invalid['state']=='unavailable' and invalid['reason']=='JaiTypePointerUnknown' and invalid['rows']==[],invalid
    unreadable=value(type_name='FixtureObject',address='0x1')
    assert unreadable['state']=='partial' and unreadable['rows'][2]['bits_hex'] is None and unreadable['rows'][2]['reason']=='JaiValueUnreadable',unreadable
    writable=c.action('capture_memory',address=truth['object'],length=truth['object_size'])
    refuse(c.tool('load_runtime_types',generation=gen,provider='jai',snapshot_ids=[writable['id']]),'RuntimeTypesNeedReadonlyCapture')
    refuse(c.tool('load_runtime_types',generation=gen,provider='jai',snapshot_ids=[cap['id'],cap['id']]),'RuntimeTypesInvalidCapture')
    refuse(c.tool('read_runtime_value',id=ident,generation=gen+1,type_name='FixtureObject',address=truth['object']),'StaleSnapshot')
    # Native expression preview and children use the same C type/value reader.
    expression=truth['object']+' as FixtureObject'
    def native(expr): return c.inspect('evaluate_expression',tid=before['pid'],expression=expr)
    n=native(expression)
    assert n['value']['provider']=='jai' and n['value']['display']=='{4 fields}' and n['bits'] is None,n
    page=c.inspect('get_value_children',tid=before['pid'],expression=expression,start=1,limit=1)['view']
    assert page['next']==2 and page['children'][0]['name']=='energy' and page['children'][0]['value']['display']=='12.5',page
    assert page['children'][0]['value']['bits_hex']=='0x4029000000000000',page
    scalar=get(type_name='FixtureBase')['members'][0]['type_address_hex']
    signed=native(truth['object']+' as '+scalar)
    assert signed['value']['display']==('-41' if a.wrong_native_oracle else '-42') and signed['bits']=='0xffffffffffffffd6',signed
    no_value=native('1 as '+scalar)
    assert no_value['availability']=='unavailable' and no_value['bits'] is None and no_value['value']['bits'] is None and no_value['value']['diagnostic']=='JaiValueUnreadable',no_value
    raw=native(truth['text']+' as '+truth['string_type'])
    assert raw['value']['display']=='hex 68690078ff [5 bytes]' and raw['value']['provider']=='jai',raw
    items=obj['members'][3]
    array_expression=hex(int(truth['object'],16)+int(items['offset_hex'],16))+' as '+items['type_address_hex']
    array=c.inspect('get_value_children',tid=before['pid'],expression=array_expression,start=1,limit=1)['view']
    assert array['total']==3 and array['next']==2 and array['children'][0]['name']=='[1]' and array['children'][0]['value']['display']=='-2',array
    refuse(c.tool('evaluate_expression',tid=before['pid'],expression=truth['object']+' as FixtureDuplicate'),'RuntimeTypeAmbiguous')
    refuse(c.tool('evaluate_expression',tid=before['pid'],expression=truth['object']+' as FixtureObject as FixtureBase'),'InvalidRuntimeTypeExpression')
    assert c.session()['generation']==gen and c.inspect('get_registers',tid=before['pid'])==regs
    report['resources_after']=resource(pid); report['type_count']=listing['total']; report['retained_bytes']=listing['retained_bytes']
    if observers:
        one,two=observers; c.inspect('release_session_control')
        ids=[]
        # Observer can retain and read already captured immutable bytes.
        for _ in range(4):
            own=one.action('load_runtime_types',provider='jai',snapshot_ids=[cap['id']])['id'];ready(one,own);ids.append(own)
        # Fourth context belongs to controller; observer replaced only its own oldest.
        refuse(one.tool('list_runtime_types',id=ids[0]),'RuntimeTypesExpired')
        ready(c,ident)
        refuse(two.tool('release_runtime_types',id=ids[-1]),'JobNotOwned')
        refuse(two.tool('load_runtime_types',generation=gen,provider='jai',snapshot_ids=[cap['id']]),'JobNotOwned')
        assert one.inspect('read_runtime_value',id=ids[-1],generation=gen,type_name='FixtureObject',address=truth['object'])['rows'][2]['bits_hex']=='0xffffffffffffffd6'
        # Several same-stop captures of the same type address are coalesced.
        assert two.inspect('evaluate_expression',tid=before['pid'],expression=truth['object']+' as '+scalar)['value']['display']=='-42'
        one.inspect('release_runtime_types',id=ids[-1]);ready(one,ids[-2])
        c.inspect('claim_session_control',generation=gen,ttl_ms=30000)
        c.inspect('release_runtime_types',id=ids[-2])
    c.action('continue');c.stopped('breakpoint');current=c.session()['generation'];assert current!=gen
    assert c.inspect('get_runtime_type',id=ident,type_name='FixtureObject')['stale']
    refuse(c.tool('evaluate_expression',tid=c.session()['pid'],expression=expression),'RuntimeTypesStale')
    refuse(c.tool('read_runtime_value',id=ident,generation=current,type_name='FixtureObject',address=truth['object']),'RuntimeTypesStale')
    refuse(c.tool('load_runtime_types',generation=current,provider='jai',snapshot_ids=[cap['id']]),'RuntimeTypesStale')
    fresh=c.action('capture_memory',address=truth['base'],length=truth['size'])
    new=c.action('load_runtime_types',provider='jai',snapshot_ids=[fresh['id']])['id'];ready(c,new)
    changed=c.action('read_runtime_value',id=new,type_name='FixtureObject',address=truth['object'])
    assert changed['rows'][2]['bits_hex']=='0xffffffffffffffd5',changed
    refreshed=c.inspect('evaluate_expression',tid=c.session()['pid'],expression=truth['object']+' as '+scalar)
    assert refreshed['value']['display']=='-43',refreshed
    old=c.session();c.action('restart');restarted=c.stopped()
    assert restarted['image_epoch']>old['image_epoch'] and restarted['pid']!=old['pid'],(old,restarted)
    if server: server.remember_target(restarted)
    assert c.inspect('list_runtime_types',id=new)['stale']
    refuse(c.tool('read_runtime_value',id=new,generation=restarted['generation'],type_name='FixtureObject',address=truth['object']),'RuntimeTypesStale')
    c.inspect('release_runtime_types',id=ident)
    refuse(c.tool('list_runtime_types',id=ident),'RuntimeTypesExpired')
    report['status']='pass'
finally:
    if server: server.close()
    elif c:
        (w/'transcript.json').write_text(json.dumps(c.transcript));c.close()
    report.update(seconds=time.monotonic()-started,load=os.getloadavg(),allowed_cpus=len(os.sched_getaffinity(0)))
    (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
