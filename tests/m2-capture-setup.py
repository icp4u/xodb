#!/usr/bin/env python3
"""Production T14 controls with T10 prefs, on a private headless display."""
from datetime import datetime
import importlib.util, json, os, subprocess, time
from pathlib import Path
root=Path(__file__).resolve().parents[1];os.chdir(root)
spec=importlib.util.spec_from_file_location('input_repro',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
h.WORK=str(root/'.work'/('input-capture-'+datetime.now().strftime('%Y%m%dT%H%M%S%f')))
work=Path(h.WORK);(work/'tmp').mkdir(parents=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    for mode,suffix in (('client-header','.h'),('private-code','.c')):
        subprocess.run(['wayland-scanner',mode,xml,str(work/(stem+suffix))],check=True)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(work),str(root/'tests/helpers/vinput.c'),str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True)
config=work/'preferences.json';config.write_text(json.dumps({'profile':{'user_stack_bytes':64,'user_stack_budget_bytes':1024}}))
d=h.Display(str(root),['--config',str(config),'--agent-scope','control','--break','profile_ready','--','./zig-out/bin/xodb-profile-fixture','40','many','6'],trace=False)
try:
    assert d.stopped()
    d.tool('continue',generation=d.session()['generation']);snap=d.stopped('breakpoint');assert snap
    tids=[t['tid'] for t in snap['threads'] if t['state']!='exited']
    d.keys('tap',33,'tap',31) # F then S
    d.shot('setup-wide')
    d.keys('tap',108,'tap',28,'tap',108,'tap',28,'tap',25) # remove two workers, P
    cap=d.tool('get_profile')['capture']
    assert sorted(t['perf']['tid'] for t in cap['threads'])==sorted([tids[0]]+tids[3:]),cap
    assert cap['sampled_state']['requested_bytes']==64 and cap['sampled_state']['budget_bytes']==1024
    before=cap['duration_ms']
    d.keys('tap',20,'tap',20)
    assert d.tool('get_profile')['capture']['duration_ms']==before
    assert d.tool('get_profile')['defaults']['duration_ms']!=before
    d.tool('continue',generation=d.session()['generation']);time.sleep(.7)
    d.keys('tap',25,'tap',31) # stop capture and reopen setup
    cap=d.tool('get_profile')['capture'];assert cap['status']=='manual' and cap['stored_samples']>0,cap
    d.shot('completed-wide')
    subprocess.run(['swaymsg','output','HEADLESS-1','mode','640x480'],env=d.env,check=True,capture_output=True)
    time.sleep(.2);d.shot('completed-narrow')
    d.keys('tap',1) # Escape closes panel and keeps app alive
    assert d.alive();d.keys('tap',31);assert d.alive();d.shot('narrow-reopened')
    pid=snap['pid'];d.app.stdin.close();assert d.app.wait(10)==0
    assert not Path('/proc',str(pid)).exists()
    print('PASS: production setup, selected TIDs, T10 preference preservation, active/next distinction, P stop, 640x480 access, Escape and owned target cleanup')
    print(work)
finally:d.close()
