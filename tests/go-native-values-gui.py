#!/usr/bin/env python3
"""Fast GUI lane: Go map watch expansion and interface preview on private Sway.
Cold Go compilation and input-helper setup are measured separately."""
import argparse, importlib.util, json, os, re, subprocess, time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--go',required=True);p.add_argument('--work',type=Path,required=True);a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
# Keep private Wayland socket paths short even when .work points off-device.
w=a.work.absolute();assert '/.work/input-' in str(w),'--work must be .work/input-NAME for the private input helper';w.mkdir(parents=True,exist_ok=True);w.chmod(0o755)
spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h);h.WORK=str(w)
for name in ('tmp','cache/mesa','cache/nvidia'):(w/name).mkdir(parents=True,exist_ok=True)
began=time.monotonic()
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
 subprocess.run(['wayland-scanner','client-header',xml,str(w/(stem+'.h'))],check=True,timeout=10)
 subprocess.run(['wayland-scanner','private-code',xml,str(w/(stem+'.c'))],check=True,timeout=10)
h.HELPER=str(w/'vinput')
subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(w),'tests/helpers/vinput.c',str(w/'virtual-pointer.c'),str(w/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=30)
env=dict(os.environ,GOCACHE=str(w.parent/'go-native-cache'),GOPATH=str(w/'gopath'),GOFLAGS='',GOTOOLCHAIN='local',CGO_ENABLED='0',GOMAXPROCS='2')
exe=w/'go-demo'
subprocess.run([a.go,'build','-p','2','-o',str(exe),'examples/go-demo.go'],env=env,check=True,timeout=120)
built=time.monotonic();d=None
try:
 d=h.Display(str(root),['--agent-scope','control','--source','examples/go-demo.go','--',str(exe),str(w/'truth.txt')])
 d.tool('set_breakpoint',generation=d.session()['generation'],symbol='main.marker')
 d.tool('continue',generation=d.session()['generation'])
 s=d.wait(lambda s:s['state']=='stopped' and any(t['reason']=='breakpoint' for t in s['threads']),seconds=30)
 tid=next(t['tid'] for t in s['threads'] if t['reason']=='breakpoint')
 gen=s['generation'];d.tool('step_over',generation=gen,tid=tid)
 s=d.wait(lambda s:s['state']=='stopped' and s['generation']>gen,seconds=30)
 d.tool('select_language_tab',generation=s['generation'],tab='native')
 regs=d.tool('get_registers',tid=tid);gen=d.session()['generation']
 # E, counts, Return; Return again expands the selected map watch.
 d.keys('tap',18,'tap',46,'tap',24,'tap',22,'tap',49,'tap',20,'tap',31,'tap',28,'tap',28)
 wanted=lambda t:all(x in t for x in ('alpha','beta','bytes')) and re.search(r'map.*len 2',t)
 text=h.ocr_until(d,'go-map-watch',wanted,'--psm','11',seconds=10);assert wanted(text),text
 # A second watch resolves a non-empty interface's concrete pointer type.
 d.keys('tap',18,'tap',18,'tap',19,'tap',19,'tap',28)
 wanted=lambda t:'errorstring' in re.sub(r'[^a-z0-9]','',t) and 'err' in t
 iface=h.ocr_until(d,'go-interface-watch',wanted,'--psm','11',seconds=10);assert wanted(iface),iface
 assert d.session()['generation']==gen and d.tool('get_registers',tid=tid)==regs
 (w/'results.json').write_text(json.dumps(dict(status='pass',setup_seconds=built-began,gui_seconds=time.monotonic()-built,map=text,interface=iface),indent=2)+'\n')
finally:
 if d:d.close()
print(f'go-native-values GUI: map entries and concrete interface watch visible; setup {built-began:.2f}s, GUI {time.monotonic()-built:.2f}s')
