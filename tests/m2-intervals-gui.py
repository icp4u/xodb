#!/usr/bin/env python3
"""Imported application overlay and hover on an isolated live GUI capture."""
import importlib.util,json,os,time
from pathlib import Path
root=Path(__file__).resolve().parents[1];os.chdir(root)
spec=importlib.util.spec_from_file_location('timeline_repro',root/'tests/helpers/display.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
d=h.Display('intervals');app=None
try:
 app=h.Mcp(d,str(root))
 def action(name,**kw):return app.tool(name,generation=app.session()['generation'],**kw)
 app.await_state('stopped');action('continue');app.await_state('stopped','breakpoint')
 d.pointer('click',450,22)
 cap=action('start_profile',context_switch=True)['capture'];action('continue');time.sleep(.7)
 action('stop_profile',capture_id=cap['id']);action('interrupt');snap=app.await_state('stopped');tid=snap['threads'][0]['tid']
 cap=app.tool('get_profile')['capture'];extent=app.tool('get_profile_timeline',capture_id=cap['id'],revision=cap['revision'])['extent_ns']
 before=app.tool('get_registers',tid=tid)['registers']
 added=action('add_profile_intervals',capture_id=cap['id'],revision=cap['revision'],source='synthetic GUI fixture annotation',intervals=[dict(from_ns=extent//4,to_ns=extent*3//4,tid=tid,kind='frame',label='frame overlay fixture',correlation_id=60)])
 generation=app.session()['generation'];time.sleep(.4)
 view=app.tool('get_profile')['displayed_view'];assert view['revision']==added['revision']
 d.pointer('m',730,618);time.sleep(.2);d.shot('application-hover')
 d.pointer('drag',520,618,820,618,20);time.sleep(.3);d.shot('application-selected')
 selected=app.tool('get_profile')['displayed_view'];kw={k:v for k,v in selected['filter'].items() if v is not None}
 evidence=app.tool('get_profile_intervals',capture_id=cap['id'],revision=added['revision'],**kw)
 assert evidence['total']==1 and evidence['intervals'][0]['label']=='frame overlay fixture'
 assert app.session()['generation']==generation and app.tool('get_registers',tid=tid)['registers']==before
 app.proc.stdin.close();assert app.proc.wait(10)==0
 print('PASS: imported overlay, hover, selection/MCP agreement, unchanged registers and clean GUI shutdown');print(d.dir)
finally:
 if app:
  if app.proc.poll() is None:
   app.proc.stdin.close()
   try:app.proc.wait(10)
   except Exception:app.proc.kill();app.proc.wait()
  app.log.close()
 d.close()
