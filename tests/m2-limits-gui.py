#!/usr/bin/env python3
"""Inspect a configured large offline capture on a private headless display."""
import importlib.util,json,subprocess,time,sys,os
from pathlib import Path
root=Path(__file__).resolve().parents[1];os.chdir(root)
artifact=Path(sys.argv[1]).resolve()
spec=importlib.util.spec_from_file_location('timeline_repro',root/'tests/helpers/display.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
# Keep compositor socket paths below the Unix-domain length limit in scratch trees.
h.WORK=str(root/'.work'/('timeline-'+str(time.time_ns())[-8:]))
d=h.Display('limits');app=None
class App(h.Mcp):
    def __init__(self):
        self.log=open(Path(d.dir)/'xodb.log','wb')
        self.proc=subprocess.Popen(['./zig-out/bin/xodb','--mcp','--agent-scope','control','--open-capture',str(artifact)],env=d.env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.log,bufsize=0)
        self.serial,self.pending=0,b''
        self.call('initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'limits-gui','version':'1'}})
        self.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
try:
    app=App();deadline=time.monotonic()+15
    while True:
        p=app.tool('get_profile');cap=p['capture']
        if cap and p['displayed_view'] and p['displayed_view']['visible']:break
        assert time.monotonic()<deadline,p
        time.sleep(.05)
    assert cap['sample_limit']==65536 and cap['stored_samples']==65536,cap
    d.shot('01-large-capture')
    d.pointer('click',1080,110);time.sleep(.25);d.shot('02-large-capture-setup')
    (Path(d.dir)/'evidence.json').write_text(json.dumps(p,indent=2)+'\n')
    app.proc.stdin.close();assert app.proc.wait(10)==0
    print(d.dir)
finally:
    if app:
        if app.proc.poll() is None:app.proc.terminate();app.proc.wait(10)
        app.log.close()
    d.close()
