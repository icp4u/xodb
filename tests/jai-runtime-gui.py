#!/usr/bin/env python3
"""Fast GUI lane: native typed watch, late type publication and stale recapture."""
import argparse,importlib.util,json,os,re,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--agent',type=Path)
p.add_argument('--wrong-oracle',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=root/'.work'/('input-jai-'+str(time.time_ns())[-10:]);w.mkdir(parents=True,mode=0o755)
spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(w)
for name in ('tmp','cache/mesa','cache/nvidia'):(w/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    for mode,suffix in (('client-header','.h'),('private-code','.c')):
        subprocess.run(['wayland-scanner',mode,xml,str(w/(stem+suffix))],check=True,timeout=10)
h.HELPER=str(w/'vinput')
subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(w),'tests/helpers/vinput.c',str(w/'virtual-pointer.c'),str(w/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=30)
exe=w/'fixture';oracle=w/'oracle.json'
subprocess.run(['cc','-std=c11','-g','-O1','-DNDEBUG','-Wall','-Wextra','-Werror','tests/jai-runtime.c','src/language/jai_layout.c','src/language/jai_reader.c','src/language/jai_value.c','-o',str(exe)],check=True,timeout=30)
started=time.monotonic();d=None;report={'status':'failed'}
def shot(name,predicate):
    # Read only the watch pane: source code may contain the expected literals.
    path=Path(d.dir)/(name+'.png');deadline=time.monotonic()+20
    while True:
        subprocess.run(['grim','-g','616,584 664x180',str(path)],env=d.env,check=True,timeout=10)
        raw=subprocess.run(['tesseract',str(path),'stdout','--psm','6'],capture_output=True,text=True,check=True,timeout=10).stdout
        path.with_suffix('.txt').write_text(raw)
        result=' '.join(raw.lower().split())
        if predicate(result):return result
        assert time.monotonic()<deadline,result
        time.sleep(.02)
def type_keys(text):
    codes={**dict(zip('1234567890',range(2,12))),**dict(zip('qwertyuiop',range(16,26))),**dict(zip('asdfghjkl',range(30,39))),**dict(zip('zxcvbnm',range(44,51))),' ':57}
    out=[]
    for char in text:
        code=codes[char.lower()]
        out.extend(['down',42,'tap',code,'up',42] if char.isupper() else ['tap',code])
    return out
def load(truth):
    gen=d.session()['generation']
    cap=d.tool('capture_memory',generation=gen,address=truth['base'],length=truth['size'])
    ident=d.tool('load_runtime_types',generation=gen,provider='jai',snapshot_ids=[cap['id']])['id']
    deadline=time.monotonic()+10
    while True:
        result=d.tool('list_runtime_types',id=ident)
        if result['state']!='pending':break
        assert time.monotonic()<deadline,result
        time.sleep(.002)
    assert result['state']=='ready',result
    return ident
try:
    d=h.Display(str(root),['--agent-scope','control',*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--',str(exe),str(oracle)])
    d.tool('set_breakpoint',generation=d.session()['generation'],symbol='runtime_ready')
    d.tool('set_breakpoint',generation=d.session()['generation'],symbol='runtime_changed')
    d.tool('continue',generation=d.session()['generation']);assert d.stopped('breakpoint')
    truth=json.loads(oracle.read_text());gen=d.session()['generation']
    # Shift+E enters a display that follows the selected frame. Text includes
    # hex letters/global keys, so it must remain in the editor until Return.
    d.keys('down',42,'tap',18,'up',42,*type_keys(truth['object']+' as FixtureBase'),'tap',28)
    assert d.session()['state']=='stopped' and d.session()['generation']==gen
    shot('before-types',lambda t:'runtime type not found' in t)
    load(truth)
    shot('late-types-ready',lambda t:'fixturebase' in t and re.search(r'1 fields',t) is not None and 'not found' not in t)
    assert d.session()['generation']==gen
    d.keys('tap',28)
    first=shot('expanded-first',lambda t:'score' in t and re.search(r'-\s*42\b',t) is not None)
    assert re.search(r'-\s*'+('41' if a.wrong_oracle else '42')+r'\b',first),first
    d.tool('continue',generation=gen);assert d.stopped('breakpoint')
    new=d.session()['generation'];assert new!=gen
    shot('after-continue-stale',lambda t:'runtime types stale' in t and 'score' not in t)
    load(truth)
    shot('recaptured-ready',lambda t:re.search(r'1 fields',t) is not None and 'runtime types stale' not in t)
    d.keys('tap',28)
    shot('expanded-changed',lambda t:'score' in t and re.search(r'-\s*43\b',t) is not None)
    assert d.session()['state']=='stopped' and d.session()['generation']==new
    d.shot('complete-window')
    report['status']='pass'
finally:
    if d:d.close()
    report.update(seconds=time.monotonic()-started,load=os.getloadavg())
    (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
