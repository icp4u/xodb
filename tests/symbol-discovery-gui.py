#!/usr/bin/env python3
"""Space cancels a queued continue in an owned private compositor."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
from helpers.symbols import build

root=Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work=root/'.work'/('input-sd'+str(time.time_ns())[-6:])
work.mkdir(parents=True,mode=0o755)
fixture,known=build(root,work)
spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
h.WORK=str(work)
for name in ('tmp','cache/mesa','cache/nvidia'):(work/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True,timeout=10)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True,timeout=10)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(work),'tests/helpers/vinput.c',str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=60)
os.environ['XODB_DISCOVERY_AGENT']=str(root/'zig-out/bin/xodb-agent')
os.environ['XODB_DISCOVERY_RATE']=str(256*1024)
d=None
try:
    d=h.Display(str(root),['--runtime-agent',str(root/'tests/fixtures/symbol-agent-proxy.py'),
                          '--break','large_symbol_hit','--',str(fixture)])
    # MCP can answer before the first mapped window receives keyboard focus.
    deadline=time.monotonic()+10
    while 'first window frame submitted' not in Path(d.log).read_text() and time.monotonic()<deadline:
        time.sleep(.05)
    assert 'first window frame submitted' in Path(d.log).read_text()
    before=d.session();assert before['symbol_discovery_pending'],before
    # This deliberately slow transport takes a quarter-second per chunk.
    # Keep the synthetic keyboard alive long enough for the application to
    # bind the new seat capability before sending a key, and to consume it.
    d.keys('layout','us','w',800,'tap',57,'w',800)
    queued=d.wait(lambda s:s['continue_pending']);assert queued
    assert d.tool('get_debug_view',summary_only=True)['continue_pending']
    d.shot('queued-continue')
    d.keys('layout','us','w',800,'tap',57,'w',800)
    cancelled=d.wait(lambda s:not s['continue_pending']);assert cancelled and cancelled['state']=='stopped'
    d.shot('cancelled-continue')
    settled=d.wait(lambda s:not s['symbol_discovery_pending'],seconds=40)
    assert settled and settled['state']=='stopped' and not settled['continue_pending'],settled
    assert all(t['reason']!='breakpoint' for t in settled['threads']),settled
    # A separate fresh keypress is required to resume after cancellation.
    d.keys('layout','us','w',800,'tap',57,'w',800)
    stopped=d.stopped('breakpoint');assert stopped
    counter=d.tool('read_memory',address=known['reached'],length=4)
    assert counter['hex']=='00000000',counter
    d.shot('first-breakpoint')
    (work/'results.json').write_text(json.dumps({'status':'pass','queued':queued,'cancelled':cancelled,'settled':settled,'first_stop':stopped,'counter':counter},indent=2)+'\n')
finally:
    if d:
        try:
            # Finish xodb's slow-agent shutdown while its compositor is still
            # available. The general harness stops both together and its
            # five-second fallback can kill xodb before its child is reaped.
            d.app.stdin.close()
            assert d.app.wait(timeout=30) == 0, d.tail()
        finally:
            d.close()
    fixture.unlink(missing_ok=True)
print('Private GUI Space cancel, stopped discovery and fresh first-hit continue passed:',work)
