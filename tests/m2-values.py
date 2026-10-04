#!/usr/bin/env python3
"""Compiler fixtures exercise namespace scopes, enums, slices and bounded pages."""
from datetime import datetime
from pathlib import Path
import json,os,subprocess,time
from client import Client
root=Path(__file__).resolve().parents[1];os.chdir(root)
run=root/'.work'/('m2-values-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));run.mkdir()
env=dict(os.environ,TMPDIR=str(root/'.work/tmp'),ZIG_GLOBAL_CACHE_DIR=str(root/'.cache/zig-global'))

def error(r,name):assert r['result']['isError'] and r['result']['content'][0]['text']==name,r

for name,command in (
 ('rust-debug',['rustc','-g','-C','opt-level=0','-C','force-frame-pointers=yes','tests/fixtures/values.rs']),
 ('rust-optimized',['rustc','-g','-C','opt-level=2','-C','force-frame-pointers=yes','tests/fixtures/values.rs']),
 ('zig-llvm',['zig','build-exe','tests/fixtures/values.zig','-O','Debug','-fllvm']),
 ('zig-native',['zig','build-exe','tests/fixtures/values.zig','-O','Debug','-fno-llvm']),
):
 binary=run/name
 command+=['-o',str(binary)] if name.startswith('rust') else ['-femit-bin='+str(binary)]
 subprocess.run(command,env=env,check=True)
 c=Client('control',str(binary))
 try:
  c.action('set_breakpoint',symbol='value_checkpoint');c.action('continue');snap=c.stopped('breakpoint');tid=snap['threads'][0]['tid'];generation=snap['generation']
  regs=c.inspect('get_registers',tid=tid)
  def inspect(expr,**kw):return c.inspect('get_value_children',tid=tid,frame=1,expression=expr,generation=generation,**kw)['view']
  locals={v['name']:v['value'] for v in c.inspect('list_locals',tid=tid,frame=1,generation=generation)['locals']}
  lang='rust' if name.startswith('rust') else 'zig'
  assert locals['slice']['language']==lang,locals['slice']
  available=locals['slice']['availability']=='available'
  if not available:
   assert name=='rust-optimized' and locals['slice']['availability']=='unsupported' and locals['slice']['visualization'] is None
   error(c.tool('get_value_children',tid=tid,frame=1,expression='slice'),'ValueUnavailable')
  else:assert locals['slice']['visualization']['count']==3
  assert locals['mode']['enumerator']==('Idle' if lang=='rust' else 'idle') and locals['mode']['display'].endswith('(-2)'),locals['mode']
  assert locals['high']['kind']=='unsigned' and locals['high']['enumerator']==('High' if lang=='rust' else 'high') and locals['high']['display'].endswith('(9223372036854775809)')
  if available:
   seq=inspect('slice',limit=2)
   assert seq['presentation']=='slice' and seq['total']==3 and seq['next']==2
   assert [r['value']['display'] for r in seq['children']]==['-22','33']
   last=inspect('slice',start=2,limit=2);assert [r['value']['display'] for r in last['children']]==['44'] and last['next'] is None
   assert inspect('slice',start=3)['children']==[]
   raw=inspect('slice',raw=True)
   assert raw['presentation']=='fields' and {r['name'] for r in raw['children']}==({'data_ptr','length'} if lang=='rust' else {'ptr','len'})
  numbers=inspect('numbers');assert [r['value']['display'] for r in numbers['children']]==['11','-22','33','44']
  text=locals['text']['visualization'];assert text['text']=='hello λ\nworld' and text['preview_bytes']==len('hello λ\nworld'.encode()) and not text['truncated']
  assert '\\n' in locals['text']['display'] and '\n' not in locals['text']['display']
  assert locals['bytes']['visualization']['hex']=='00ff41' and locals['bytes']['visualization']['text'] is None
  assert inspect('empty')['total']==0 and inspect('empty')['children']==[]
  if 'pair' in locals:
   pair=inspect('pair');assert {r['name']:r['value']['display'] for r in pair['children']}==dict(left='-17',right='9001')
  else:raise AssertionError((name,'fixture pair missing'))
  if lang=='rust':
   assert locals['variant']['availability']=='unsupported' and locals['variant']['kind']=='unknown'
  if available:error(c.tool('get_value_children',tid=tid,frame=1,expression='slice',start=4),'InvalidValuePage')
  error(c.tool('get_value_children',tid=tid,frame=1,expression='slice',generation=generation-1),'StaleSnapshot')
  for kw in ({'limit':65},{'limit':0},{'start':-1},{'raw':1},{'extra':True}):
   assert c.tool('get_value_children',tid=tid,frame=1,expression='slice',**kw)['error']['code']==-32602
  # Explicit raw field access remains available in the expression evaluator.
  expr='slice.data_ptr[0]' if lang=='rust' else 'slice.ptr[0]'
  if available:assert c.inspect('evaluate_expression',tid=tid,frame=1,expression=expr)['value']['display']=='-22'
  assert c.inspect('get_registers',tid=tid)==regs and c.session()['generation']==generation
  print(name+f' (slice available={available}): namespace locals, named enum, slices/text/bytes/empty, raw fields, struct/array pages, bounds, stale guards and read-only state passed',flush=True)
 finally:
  (run/(name+'.rpc.json')).write_text(json.dumps(c.transcript,indent=2)+'\n');c.close()
  (run/(name+'.stderr.log')).write_bytes(c.p.stderr.read())
# Observe scope can inspect a scalar immediately without acquiring control.
c=Client('observe')
try:
 s=c.session();tid=s['threads'][0]['tid']
 view=c.inspect('get_value_children',tid=tid,expression='42')['view']
 assert view['value']['display']=='42' and view['total']==0
finally:c.close()
print(run)
