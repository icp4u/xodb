#!/usr/bin/env python3
"""Capture duration controls on a private headless Sway display."""
import importlib.util, json, os, subprocess, time
from pathlib import Path
root=Path(__file__).resolve().parents[1];os.chdir(root)
spec=importlib.util.spec_from_file_location('timeline_repro',root/'tests/helpers/display.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
d=h.Display('preferences');app=None
try:
    app=h.Mcp(d,str(root))
    def action(name,**kw):return app.tool(name,generation=app.session()['generation'],**kw)
    app.await_state('stopped');action('continue');app.await_state('stopped','breakpoint')
    d.pointer('click',450,22);time.sleep(.3)
    assert app.tool('get_profile')['defaults']['duration_ms']==60000
    d.shot('default-duration')
    # Duration is below scheduling at the right edge of the flame header.
    for expected in (300000,0):
        d.pointer('click',1100,140);time.sleep(.08)
        assert app.tool('get_profile')['defaults']['duration_ms']==expected
    d.shot('until-stopped')
    d.pointer('click',290,110);time.sleep(.1)
    cap=app.tool('get_profile')['capture'];assert cap['duration_ms']==0 and cap['status']=='collecting'
    # Changing the next duration leaves the active capture and target untouched.
    generation=app.session()['generation']
    d.pointer('click',1100,140);time.sleep(.1)
    current=app.tool('get_profile')
    assert current['defaults']['duration_ms']==10000 and current['capture']['duration_ms']==0
    assert app.session()['generation']==generation
    d.shot('active-and-next')
    d.pointer('click',290,110);time.sleep(.1)
    d.pointer('click',290,110);time.sleep(.1)
    current=app.tool('get_profile')
    assert current['capture']['duration_ms']==10000 and current['capture']['id']>cap['id']
    action('stop_profile',capture_id=current['capture']['id'])
    app.proc.stdin.close();assert app.proc.wait(10)==0
    print('PASS: GUI duration presets, until-stopped capture, active/next separation, next-capture application and target isolation')
    print(d.dir)
finally:
    if app:
        if app.proc.poll() is None:app.proc.terminate();app.proc.wait(10)
        app.log.close()
    d.close()
