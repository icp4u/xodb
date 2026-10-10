#!/usr/bin/env python3
"""Fast GUI lane: typed write/readback, MCP-driven refresh and human undo after F8."""
import argparse,importlib.util,json,os,re,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--agent',type=Path)
p.add_argument('--wrong-oracle',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=root/'.work'/('input-jai-writes-'+str(time.time_ns())[-10:]);w.mkdir(parents=True,mode=0o755)
spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(w)
for name in ('tmp','cache/mesa','cache/nvidia'):(w/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    for mode,suffix in (('client-header','.h'),('private-code','.c')):
        subprocess.run(['wayland-scanner',mode,xml,str(w/(stem+suffix))],check=True,timeout=10)
h.HELPER=str(w/'vinput')
subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(w),'tests/helpers/vinput.c',str(w/'virtual-pointer.c'),str(w/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=30)
exe=w/'fixture';oracle=w/'oracle.json'
subprocess.run(['cc','-std=c11','-g','-O1','-DNDEBUG','-Wall','-Wextra','-Werror','tests/jai-discovery.c','src/language/jai_layout.c','src/language/jai_reader.c','src/language/jai_value.c','src/language/jai_container.c','-o',str(exe)],check=True,timeout=30)
started=time.monotonic();d=None;report={'status':'failed'}
def shot(name,predicate,region='20,96 1240x664'):
    path=Path(d.dir)/(name+'.png');deadline=time.monotonic()+20
    while True:
        subprocess.run(['grim','-g',region,str(path)],env=d.env,check=True,timeout=10)
        raw=subprocess.run(['tesseract',str(path),'stdout','--psm','6'],capture_output=True,text=True,check=True,timeout=10).stdout
        path.with_suffix('.txt').write_text(raw);result=' '.join(raw.lower().split())
        if predicate(result):return result
        assert time.monotonic()<deadline,result
        time.sleep(.02)
def usage():
    stat=Path('/proc')/str(d.app.pid)/'stat'
    fields=stat.read_text().rsplit(')',1)[1].split()
    return {'cpu_seconds':(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),
            'rss_bytes':int(fields[21])*os.sysconf('SC_PAGE_SIZE')}
def type_keys(text):
    codes={**dict(zip('1234567890',range(2,12))),**dict(zip('qwertyuiop',range(16,26))),**dict(zip('asdfghjkl',range(30,39))),**dict(zip('zxcvbnm',range(44,51))),' ':57,'_':12,'/':53}
    out=[];codes_run=[];shifted=None
    def flush():
        if not codes_run:return
        if shifted:out.extend(['down',42])
        out.extend(['burst',len(codes_run),*codes_run])
        if shifted:out.extend(['up',42])
        codes_run.clear()
    for char in text:
        shift=char.isupper() or char=='_'
        if shifted is not None and shift!=shifted:flush()
        shifted=shift;codes_run.append(codes[char.lower()])
    flush();return out

def entry_keys(code,text):return ['tap',code,*type_keys(text),'tap',28]
def enter(code,text):d.keys(*entry_keys(code,text))
def ready(ident):
    end=time.monotonic()+10
    while True:
        r=d.tool('list_runtime_types',id=ident)
        if r['state']!='pending':break
        assert time.monotonic()<end,r
        time.sleep(.002)
    assert r['state']=='ready',r
try:
    d=h.Display(str(root),['--agent-scope','mutate',*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--',str(exe),str(oracle)])
    d.tool('set_breakpoint',generation=d.session()['generation'],symbol='discovery_ready')
    d.tool('set_breakpoint',generation=d.session()['generation'],symbol='discovery_changed')
    d.tool('continue',generation=d.session()['generation']);assert d.stopped('breakpoint')
    report['before']=usage();truth=json.loads(oracle.read_text());regs=d.tool('get_registers',tid=d.session()['pid'])['registers']
    d.keys('tap',21,*entry_keys(17,'DEAD 99'))
    shot('empty-write-input',lambda t:'loadruntimetypesfirst' in t.replace(' ',''))
    assert d.session()['state']=='stopped'
    d.keys('tap',1,*entry_keys(38,truth['base']+' '+str(truth['size'])));ready(1)
    d.keys(*entry_keys(53,'fixturetypedchild'),*entry_keys(34,truth['candidates'][0]),*entry_keys(17,'health 77'))
    typed=shot('human-write',lambda t:re.search(r'health\s*:\s*77\b',t) is not None,region='528,360 718x288')
    assert re.search(r'health\s*:\s*'+('78' if a.wrong_oracle else '77')+r'\b',typed),typed
    first=d.tool('list_runtime_writes')['rows'][0]
    assert first['actor']=='human' and first['before_hex']==(22).to_bytes(8,'little').hex() and first['requested_hex']==(77).to_bytes(8,'little').hex(),first
    written=d.tool('write_runtime_field',generation=d.session()['generation'],id=1,type_name='FixtureTypedChild',address=truth['candidates'][0],path='health',value='88')['change']
    assert written['verified'],written
    shot('agent-write-refresh',lambda t:re.search(r'health\s*:\s*88\b',t) is not None,region='528,360 718x288')
    d.keys('tap',66)
    assert d.session()['agent_scope']=='observe'
    for tool in ('write_runtime_field','undo_runtime_write'):
        denied=d.request('tools/call',{'name':tool,'arguments':{}})
        assert denied['isError'] and denied['content'][0]['text']=='AgentScopeDenied',denied
    d.keys('tap',22) # Unmodified U must not undo.
    assert not d.tool('list_runtime_writes')['rows'][-1]['undone']
    d.keys('down',42,'tap',22,'up',42)
    recovered=d.tool('list_runtime_writes')['rows'][-1]
    assert recovered['undone'] and recovered['last_actor']=='human' and recovered['observed_hex']==(77).to_bytes(8,'little').hex(),recovered
    assert d.tool('get_audit')['actions'][-1]['runtime_write']['verified']
    d.keys(*entry_keys(38,truth['base']+' '+str(truth['size'])));ready(2)
    d.keys(*entry_keys(53,'fixturetypedchild'),*entry_keys(34,truth['candidates'][0]),'down',42,'tap',22,'up',42)
    shot('human-undo',lambda t:re.search(r'health\s*:\s*22\b',t) is not None,region='528,360 718x288')
    assert all(r['undone'] for r in d.tool('list_runtime_writes')['rows'])
    assert d.tool('get_registers',tid=d.session()['pid'])['registers']==regs
    d.shot('write-undo-window')
    d.keys('tap',57);assert d.stopped('breakpoint')
    stopped=d.session();d.keys(*entry_keys(17,'DEAD 99'))
    shot('stale-write-input',lambda t:'runtimetypesstale' in t.replace(' ',''))
    assert d.session()['generation']==stopped['generation'] and d.session()['state']=='stopped'
    d.keys('tap',1,'tap',57)
    deadline=time.monotonic()+10
    while d.session()['state']!='exited':
        assert time.monotonic()<deadline,d.session()
        time.sleep(.002)
    before=d.session();d.keys(*entry_keys(17,'DEAD 99'))
    shot('exit-write-input',lambda t:'runtimetypesstale' in t.replace(' ',''))
    assert d.session()['state']=='exited' and d.session()['generation']==before['generation'] and d.session()['last_action']==before['last_action']
    report['after']=usage();report['status']='pass'
finally:
    if d:d.close()
    report.update(seconds=time.monotonic()-started,load=os.getloadavg())
    (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
