#!/usr/bin/env python3
"""Fast GUI lane: metadata load, candidates/containers, typed tree and input ownership."""
import argparse,importlib.util,json,os,re,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--agent',type=Path)
p.add_argument('--wrong-oracle',action='store_true')
p.add_argument('--pagination',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=root/'.work'/('input-jai-browser-'+str(time.time_ns())[-10:]);w.mkdir(parents=True,mode=0o755)
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
    d=h.Display(str(root),['--agent-scope','control',*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--',str(exe),str(oracle)])
    d.tool('set_breakpoint',generation=d.session()['generation'],symbol='discovery_ready')
    d.tool('set_breakpoint',generation=d.session()['generation'],symbol='discovery_changed')
    d.tool('continue',generation=d.session()['generation']);assert d.stopped('breakpoint')
    report['before']=usage()
    truth=json.loads(oracle.read_text());gen=d.session()['generation'];regs=d.tool('get_registers',tid=d.session()['pid'])['registers']
    if a.pagination:
        d.keys('tap',21,*entry_keys(38,truth['base']+' '+str(truth['size'])));ready(1)
        d.keys(*entry_keys(53,'fixturetypedbase'),*entry_keys(31,truth['many']+' '+str(truth['many_size'])+' entity_type FixtureTypedChild'))
        shot('candidate-first-page',lambda t:'+64/70' in t and 'candidate 1:' in t)
        d.keys('tap',27)
        shot('candidate-next-page',lambda t:'candidate 64:' in t and 'candidate 69:' in t)
        d.keys('tap',28)
        found=shot('candidate-page-value',lambda t:re.search(r'health\s*:\s*74\b',t) is not None,region='528,360 718x288')
        assert re.search(r'health\s*:\s*'+('75' if a.wrong_oracle else '74')+r'\b',found),found
        d.keys(*entry_keys(53,truth['dynamic_type']),*entry_keys(34,truth['many_dynamic']),'tap',27)
        shot('array-next-page',lambda t:'start 16' in t and re.search(r'16.*1127',t) is not None,region='528,360 718x288')
        d.keys('tap',26)
        shot('array-first-page',lambda t:re.search(r'start [0o]\b',t) is not None and re.search(r'4.*1115',t) is not None,region='528,360 718x288')
        assert d.session()['generation']==gen and d.tool('get_registers',tid=d.session()['pid'])['registers']==regs
        d.shot('paging-window')
    else:
        d.keys('tap',21,*entry_keys(34,'0xDEAD'))
        shot('empty-input-owned',lambda t:'loadruntimetypesfirst' in t.replace(' ',''))
        assert d.session()['state']=='stopped' and d.session()['generation']==gen
        d.keys('tap',1,*entry_keys(38,truth['base']+' '+str(truth['size'])));ready(1)
        enter(53,'fixturetypedbase')
        shot('type-selected',lambda t:'fixturetypedbase' in t and re.search(r'entity[ _]type',t) is not None and 'stale' not in t)
        child=d.tool('get_runtime_type',id=1,type_name='FixtureTypedChild')['type']['address_hex']
        enter(31,truth['area']+' '+str(truth['area_size'])+' entity_type '+child)
        candidates=shot('candidates',lambda t:'candidates 0+3/3' in t and 'candidate 1:' in t and 'candidate 2:' in t and 'lifetime unproved' in t)
        d.keys('tap',28)
        typed=shot('typed-first',lambda t:re.search(r'health\s*:\s*22\b',t) is not None,region='528,360 718x288')
        assert re.search(r'health\s*:\s*'+('23' if a.wrong_oracle else '22')+r'\b',typed),typed
        # These are human-owned jobs: an observer cannot cancel the GUI search,
        # even by bypassing the hidden tool list after control is returned.
        d.keys('tap',66)
        denied=d.request('tools/call',{'name':'cancel_memory_search','arguments':{'id':2}})
        assert denied['isError'] and denied['content'][0]['text']=='AgentScopeDenied',denied
        retained=d.request('tools/call',{'name':'release_runtime_types','arguments':{'id':1}})
        assert retained['isError'] and retained['content'][0]['text']=='JobNotOwned',retained
        d.keys('tap',66)
        # F8 invalidates generation; refresh metadata before continuing the demo.
        gen=d.session()['generation'];enter(38,truth['base']+' '+str(truth['size']));ready(2)
        d.keys(*entry_keys(53,'bucket'),*entry_keys(24,truth['bucket']))
        shot('occupied-slots',lambda t:'occupied slot 1:' in t and 'occupied slot 3:' in t)
        d.keys('tap',28)
        shot('container-value',lambda t:re.search(r'health\s*:\s*22\b',t) is not None,region='528,360 718x288')
        assert d.session()['generation']==gen and d.tool('get_registers',tid=d.session()['pid'])['registers']==regs
        d.tool('continue',generation=gen);assert d.stopped('breakpoint');new=d.session()['generation'];assert new!=gen
        shot('stale-after-continue',lambda t:'stale' in t and 'health:' not in t)
        enter(38,truth['base']+' '+str(truth['size']));ready(3)
        d.keys(*entry_keys(53,'fixturetypedchild'),*entry_keys(34,truth['candidates'][0]))
        shot('typed-new-stop',lambda t:re.search(r'health\s*:\s*23\b',t) is not None,region='528,360 718x288')
        d.shot('complete-window')
        d.tool('continue',generation=new)
        deadline=time.monotonic()+10
        while d.session()['state']!='exited':
            assert time.monotonic()<deadline,d.session()
            time.sleep(.002)
        before=d.session();enter(38,'0xDEAD 0xFACE')
        shot('exit-input-owned',lambda t:'notstopped' in t.replace(' ','') and re.search(r'[0o]xdead',t) is not None)
        after=d.session();assert after['state']=='exited' and after['generation']==before['generation'] and after['last_action']==before['last_action'],(before,after)
    report['after']=usage()
    report['status']='pass'
finally:
    if d:d.close()
    report.update(seconds=time.monotonic()-started,load=os.getloadavg())
    (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
