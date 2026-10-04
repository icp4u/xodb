#!/usr/bin/env python3
"""Inspect actual Rust locals in the private native GUI and correlate with MCP."""
import importlib.util,os,subprocess,time
from pathlib import Path
root=Path(__file__).resolve().parents[1];os.chdir(root)
spec=importlib.util.spec_from_file_location('timeline_repro',root/'tests/helpers/display.py');h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
d=h.Display('values');app=None
class ValuesMcp(h.Mcp):
 def __init__(self,display,binary):
  self.log=open(os.path.join(display.dir,'xodb.log'),'wb')
  self.proc=subprocess.Popen(['./zig-out/bin/xodb','--mcp','--agent-scope','control','--break','value_checkpoint','--source','tests/fixtures/values.rs','--',str(binary)],cwd=root,env=display.env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.log,bufsize=0)
  self.serial=0;self.pending=b''
  self.call('initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'values-test','version':'1'}})
  self.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
try:
 binary=Path(d.dir)/'rust-values'
 subprocess.run(['rustc','-g','-C','opt-level=0','-C','force-frame-pointers=yes','tests/fixtures/values.rs','-o',str(binary)],env=dict(os.environ,TMPDIR=str(root/'.work/tmp')),check=True)
 app=ValuesMcp(d,binary);app.await_state('stopped')
 app.tool('continue',generation=app.session()['generation']);snap=app.await_state('stopped','breakpoint');tid=snap['threads'][0]['tid']
 generation=snap['generation'];before=app.tool('get_registers',tid=tid)
 time.sleep(.3);d.shot('checkpoint')
 d.pointer('click',400,665);time.sleep(.3);d.shot('caller-values')
 d.resize(1600,1400);time.sleep(.4);d.shot('caller-values-tall')
 values=app.tool('list_locals',tid=tid,frame=1)['locals'];by_name={v['name']:v['value'] for v in values}
 assert by_name['text']['visualization']['text']=='hello λ\nworld' and by_name['mode']['display']=='Idle (-2)'
 assert app.tool('get_registers',tid=tid)==before and app.session()['generation']==generation
 app.proc.stdin.close();assert app.proc.wait(10)==0
 print('PASS: Rust caller selection, slice/string/enum summaries, stable registers/generation and clean native GUI shutdown');print(d.dir)
finally:
 if app:
  if app.proc.poll() is None:
   app.proc.stdin.close()
   try:app.proc.wait(10)
   except Exception:app.proc.kill();app.proc.wait()
  app.log.close()
 d.close()
