#!/usr/bin/env python3
"""Native ARM64 debugger acceptance checks; creates and cleans only owned fixtures."""
import os,sys,json,time
from pathlib import Path
os.chdir(str(Path(__file__).resolve().parents[1]))
sys.path.insert(0,'tests')
from client import Client
results=[]
client=Client('mutate')
pid=None
try:
 s=client.session();pid=s['pid'];tid=s['threads'][0]['tid']
 assert s['architecture']=='aarch64',s
 regs=client.inspect('get_registers',tid=tid)['registers']
 assert all(k in regs for k in ['x0','x30','sp','pc','pstate']),regs
 symbol=client.inspect('find_symbol',name='change_value');site=symbol['address'];addr=int(site,16)
 original=client.inspect('read_memory',address=site,length=8)['hex']
 ident=client.action('set_breakpoint',symbol='change_value')['id']
 assert client.inspect('read_memory',address=hex(addr+1),length=2)['hex']==original[2:6]
 bad=client.tool('set_breakpoint',address=hex(addr+1),generation=client.session()['generation'])
 assert bad['result']['isError'] and bad['result']['content'][0]['text']=='InvalidBreakpointAddress',bad
 original_byte=original[2:4]
 changed_byte='{:02x}'.format(int(original_byte,16)^1)
 client.action('write_memory',address=hex(addr+1),hex=changed_byte)
 assert client.inspect('read_memory',address=hex(addr+1),length=1)['hex']==changed_byte
 client.action('write_memory',address=hex(addr+1),hex=original_byte)
 saved=regs['x19'];client.action('write_register',tid=tid,name='x19',value='0x1234')
 assert client.inspect('get_registers',tid=tid)['registers']['x19']=='0x1234'
 client.action('write_register',tid=tid,name='x19',value=saved)
 client.action('continue');client.stopped('breakpoint')
 regs=client.inspect('get_registers',tid=tid)['registers'];assert int(regs['pc'],16)==addr,regs
 frames=client.inspect('get_stack',tid=tid)['frames']
 assert len(frames)>=2 and frames[0]['symbol']=='change_value' and frames[1]['symbol']=='main',frames
 client.action('step_instruction',tid=tid);client.stopped('single_step')
 assert int(client.inspect('get_registers',tid=tid)['registers']['pc'],16)==addr+4
 client.action('remove_breakpoint',id=ident)
 assert client.inspect('read_memory',address=site,length=8)['hex']==original
 ids=client.action('set_breakpoint',file='m1.c',line=10)['ids']
 client.action('continue');client.stopped('breakpoint')
 frames=client.inspect('get_stack',tid=tid)['frames']
 assert len(frames)>=2 and frames[1]['symbol']=='main',frames
 locals_=client.inspect('list_locals',tid=tid)['locals']
 value=client.inspect('evaluate_expression',tid=tid,expression='item->value + amount')['value']
 assert value['display']=='12',value
 assert client.inspect('evaluate_expression',tid=tid,expression='$pc')['availability']=='available'
 assert client.tool('evaluate_expression',tid=tid,expression='$rip')['result']['isError']
 for i in ids:client.action('remove_breakpoint',id=i)
 client.action('step_source',tid=tid);snap=client.stopped()
 assert not snap['source_stepping'] and not snap['step_diagnostic'],snap
 assert client.inspect('evaluate_expression',tid=tid,expression='item->value')['value']['display']=='12'
 results.append({'case':'breakpoint/register/overlay/step/stack/locals','frames':[f['symbol'] for f in frames], 'value':value['display'], 'locals':locals_})
finally:
 client.close()
 assert pid is None or not Path('/proc/'+str(pid)).exists(),('owned target left',pid)
 print(json.dumps({'results':results,'transcript':client.transcript}),flush=True)


import os,sys,json,time,subprocess
from pathlib import Path
os.chdir(str(Path(__file__).resolve().parents[1]))
sys.path.insert(0,'tests')
from client import Client
reports=[]
source=Path('tests/fixtures/m1.c').read_text().splitlines()
first=next(i for i,s in enumerate(source,1) if 'FIRST_CALL' in s)
second=next(i for i,s in enumerate(source,1) if 'SECOND_CALL' in s)
client=Client('control')
try:
 ids=client.action('set_breakpoint',file='m1.c',line=first)['ids']
 client.action('continue');s=client.stopped('breakpoint');tid=s['threads'][0]['tid'];pid=s['pid']
 for i in ids:client.action('remove_breakpoint',id=i)
 client.action('step_over',tid=tid);s=client.stopped()
 assert not s['source_stepping'] and not s['step_diagnostic'],s
 pc=client.inspect('get_registers',tid=tid)['registers']['pc']
 loc=client.inspect('get_source_location',address=pc)['source']
 assert loc['line']==second,loc
 assert client.inspect('evaluate_expression',tid=tid,expression='state.value')['value']['display']=='12'
 client.action('step_source',tid=tid);s=client.stopped()
 assert client.inspect('get_stack',tid=tid)['frames'][0]['symbol']=='change_value'
 denied=client.tool('write_register',tid=tid,name='x19',value='0',generation=s['generation'])
 assert denied['result']['isError'] and denied['result']['content'][0]['text']=='AgentScopeDenied',denied
 reports.append({'case':'source next/step and scope gate','ok':True,'line_after_next':loc['line']})
finally:
 client.close();assert not Path('/proc/'+str(pid)).exists()
 reports.append({'transcript':client.transcript})
class Attached(Client):
 def __init__(self,pid):
  self.transcript=[];self.id=0
  self.p=subprocess.Popen(['./zig-out/bin/xodb','--mcp','--agent-scope','control','--attach',str(pid)],bufsize=0,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  self.call('initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'ARM64-attach','version':'1'}})
  self.p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n');self.p.stdin.flush()
def threads(pid):
 return list(Path('/proc/'+str(pid)+'/task').iterdir())
def wait_threads(pid,n):
 end=time.monotonic()+5
 while len(threads(pid))<n and time.monotonic()<end:time.sleep(.01)
 assert len(threads(pid))>=n
owned=Client('control','./zig-out/bin/xodb-lifecycle-fixture',('worker',))
try:
 pid=owned.session()['pid'];owned.action('continue');wait_threads(pid,2)
 owned.action('interrupt');s=owned.stopped()
 assert len(s['threads'])==2 and all(t['state']=='stopped' for t in s['threads']),s
 tids=[t['tid'] for t in s['threads']]
 reports.append({'case':'owned multithread interrupt','ok':True,'threads':len(tids)})
finally:
 owned.close()
 assert all(not Path('/proc/'+str(t)).exists() for t in tids)
fixture=subprocess.Popen(['./zig-out/bin/xodb-lifecycle-fixture','worker'])
try:
 wait_threads(fixture.pid,2)
 a=Attached(fixture.pid)
 try:
  s=a.session();assert s['architecture']=='aarch64' and len(s['threads'])==2,s
  address=a.inspect('find_symbol',name='main')['address']
  original=a.inspect('read_memory',address=address,length=8)['hex']
  a.action('set_breakpoint',address=address)
 finally:a.close()
 assert fixture.poll() is None
 assert 'TracerPid:\t0' in Path('/proc/'+str(fixture.pid)+'/status').read_text()
 a=Attached(fixture.pid)
 try:
  assert a.inspect('read_memory',address=address,length=8)['hex']==original
 finally:a.close()
 assert fixture.poll() is None
 reports.append({'case':'owned fixture attach/detach/restoration','ok':True})
finally:
 fixture.terminate()
 try:fixture.wait(timeout=3)
 except subprocess.TimeoutExpired:fixture.kill();fixture.wait(timeout=3)
 assert not Path('/proc/'+str(fixture.pid)).exists()
print(json.dumps({'reports':reports}),flush=True)
