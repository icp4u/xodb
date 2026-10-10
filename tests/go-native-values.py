#!/usr/bin/env python3
"""Fast live lane: native Go map/interface/channel previews and pages against
owned Go oracles. --shared checks a real second observer; --agent uses C agent.
Cold compiler setup is measured separately. No target calls by the reader.
"""
import argparse, importlib.util, json, os, re, signal, subprocess, time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--go',required=True);p.add_argument('--work',type=Path,required=True)
p.add_argument('--agent',type=Path);p.add_argument('--shared',action='store_true')
p.add_argument('--strace',action='store_true');p.add_argument('--wrong-oracle',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,exist_ok=True);w.chmod(0o755)
if a.agent:os.environ['XODB_RUNTIME_AGENT']=str(a.agent.resolve())
env=dict(os.environ,GOCACHE=str(w.parent/'go-native-cache'),GOPATH=str(w/'gopath'),GOFLAGS='',GOTOOLCHAIN='local',CGO_ENABLED='0',GOMAXPROCS='2')
exe=w/'values';truth_file=w/'truth.json';began=time.monotonic()
subprocess.run([a.go,'build','-p','2','-o',str(exe),'tests/fixtures/go/native-values.go'],env=env,check=True,timeout=120)
built=time.monotonic()
from client import Client

def wait(probe,predicate):
 deadline=time.monotonic()+30
 while True:
  result=probe()
  if predicate(result):return result
  assert time.monotonic()<deadline,result
  time.sleep(.002)
def resource(pid):
 f=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
 return dict(cpu_seconds=(int(f[11])+int(f[12]))/os.sysconf('SC_CLK_TCK'),rss_bytes=int(f[21])*os.sysconf('SC_PAGE_SIZE'))
server=None;c=None;observer=None;report={'status':'failed'}
try:
 if a.shared:
  spec=importlib.util.spec_from_file_location('shared',root/'tests/shared-sessions.py');shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)
  server=shared.Server(root,w,Path(os.environ.get('XODB_BIN',root/'zig-out/bin/xodb')).resolve(),exe,'control',fixture_args=[str(truth_file)])
  class SocketClient(shared.Client):
   inspect=shared.Client.tool
   tool=shared.Client.raw
   def session(self):return self.inspect('get_session')
   def action(self,name,**kw):return self.inspect(name,generation=self.session()['generation'],**kw)
   def stopped(self,reason=None,seconds=30):
    return wait(self.session,lambda s:s['state']=='stopped' and not s['symbol_discovery_pending'] and not s['continue_pending'] and (reason is None or any(t['reason']==reason for t in s['threads'])))
  c=SocketClient(server,'controller');server.remember_target(c.session())
  c.inspect('claim_session_control',generation=c.session()['generation'],ttl_ms=30000)
  observer=SocketClient(server,'observer')
 else:c=Client('control',str(exe),args=[str(truth_file)])
 c.action('set_breakpoint',symbol='main.marker');c.action('continue');c.stopped('breakpoint')
 results=[]
 for stage in range(2):
  session=c.session();tid=next(t['tid'] for t in session['threads'] if t['reason']=='breakpoint')
  # First source step passes the prologue while keeping arguments live.
  c.action('step_over',tid=tid);c.stopped(seconds=30)
  truth=json.loads(truth_file.read_text());assert truth['stage']==stage,truth
  gen=c.session()['generation']
  if stage:
   stale=c.tool('get_value_children',tid=tid,frame=0,expression='v->Small',generation=previous_generation,start=0,limit=7)
   assert stale.get('result',{}).get('isError') and stale['result']['content'][0]['text']=='StaleSnapshot',stale
  previous_generation=gen;regs=c.inspect('get_registers',tid=tid)
  pid=server.proc.pid if server else c.p.pid
  trace_pids=[pid]
  if a.agent:
   children=Path(f'/proc/{pid}/task/{pid}/children').read_text().split()
   assert len(children)==1,children
   trace_pids.append(int(children[0]))
  before=resource(pid);started=time.monotonic()
  def value(expr,client=c):return client.inspect('evaluate_expression',tid=tid,frame=0,generation=gen,expression=expr)['value']
  def page(expr,start=0,limit=64,raw=False,client=c):return client.inspect('get_value_children',tid=tid,frame=0,generation=gen,expression=expr,start=start,limit=limit,raw=raw)['view']
  def complete(v):
   assert not v['partial'] and v['availability']=='available',v
   return v['display']
  def check_values(wrong=False):
   displays={name:value('v->'+name) for name in ('Small','Large','NilMap','AnyNil','AnyInt','AnyString','AnyPair','AnyPointer','AnyTypedNil','AnyOnePointer','AnyMap','Error','ErrorNil','Buffered','Closed','NilChannel')}
   (w/f'values-{stage}.json').write_text(json.dumps(displays,indent=2)+'\n')
   for name,reason in (('Late','GoInterfaceHashUnproved'),('Dynamic','GoRuntimeTypeUnmapped'),('Timer','GoChannelTimerUnproved')):
    refused=value('v->'+name)
    assert refused['partial'] and refused['diagnostic']==reason and refused['display']=='partial: '+reason,refused
   expected_int=truth['int']+(1 if wrong else 0)
   assert complete(displays['AnyInt'])==f'int({expected_int})',displays['AnyInt']
   assert complete(displays['AnyString'])=='string("sample" [6 bytes])',displays['AnyString']
   assert complete(displays['AnyNil'])==complete(displays['ErrorNil'])=='nil interface'
   assert complete(displays['AnyTypedNil'])=='*main.Pair(0x0)',displays['AnyTypedNil']
   assert complete(displays['AnyPointer'])==f'*int({hex(truth["pointer"])})',displays['AnyPointer']
   assert complete(displays['AnyPair'])=='main.Pair({2 fields})',displays['AnyPair']
   assert complete(displays['AnyOnePointer'])=='main.OnePointer({1 fields})',displays['AnyOnePointer']
   assert complete(displays['Error'])=='main.Notice("notice" [6 bytes])',displays['Error']
   assert complete(displays['NilMap'])=='nil map[int]string',displays['NilMap']
   assert complete(displays['Small'])==f'map[int]string len {len(truth["small"])}',displays['Small']
   assert complete(displays['AnyMap'])==f'map[int]string(map[int]string len {len(truth["small"])})',displays['AnyMap']
   for expr,key in (('v->Small','small'),('v->Large','large')):
    rows=[];start=0
    while True:
     v=page(expr,start,7);assert v['total']==len(truth[key]) and v['start']==start,v
     rows+=v['children']
     if v['next'] is None:break
     assert v['next']==start+len(v['children']),v
     start=v['next']
    actual={x['name'][1:-1]:complete(x['value']) for x in rows}
    expected={str(k):json.dumps(v)+f' [{len(v)} bytes]' if isinstance(v,str) else str(v) for k,v in truth[key].items()}
    assert len(rows)==len(actual) and actual==expected,(actual,expected)
   assert page('v->NilMap')['total']==0 and page('v->AnyNil')['children']==[]
   pair=page('v->AnyPair');assert pair['total']==2 and {x['name']:complete(x['value']) for x in pair['children']}=={k:str(v) for k,v in truth['pair'].items()},pair
   direct_struct=page('v->AnyOnePointer');assert direct_struct['total']==1 and direct_struct['children'][0]['name']=='P' and complete(direct_struct['children'][0]['value'])==hex(truth['pointer']),direct_struct
   assert page('v->AnyMap')['children']==page('v->Small')['children']
   for name,length,capacity,state in (('Buffered',truth['channel_len'],truth['channel_cap'],'open'),('Closed',truth['closed_len'],truth['closed_cap'],'closed')):
    shown=complete(displays[name]);assert f' len {length} cap {capacity} {state}; queue entries send 0, recv 0, select 0' in shown,shown
   assert complete(displays['NilChannel'])=='nil chan int'
   direct=value('direct');assert complete(direct)==f'int({truth["int"]})' and direct['composite'],direct
   nonempty=value('nonempty');assert complete(nonempty)=='main.Notice("notice" [6 bytes])' and nonempty['composite'],nonempty
   assert {x['name'] for x in page('v->AnyPair',raw=True)['children']}=={'_type','data'}
   if observer:
    assert value('v->Small',observer)==displays['Small']
    assert page('v->Large',7,7,client=observer)==page('v->Large',7,7)
   return displays
  tracer=None
  if a.strace:
   trace=w/f'readonly-{stage}.strace'
   tracer=subprocess.Popen(['strace','-f','-qq','-o',str(trace),'-e','trace=ptrace,process_vm_readv,process_vm_writev,pread64,pwrite64,pwritev,pwritev2,kill,tgkill,tkill',*sum((['-p',str(n)] for n in trace_pids),[])],stderr=subprocess.PIPE)
   for traced in trace_pids:
    wait(lambda:Path(f'/proc/{traced}/status').read_text(),lambda t:re.search(r'^TracerPid:\s*'+str(tracer.pid)+r'\s*$',t,re.M))
  try:
   check_values(a.wrong_oracle)
   if stage==0:
    try:check_values(True)
    except AssertionError as expected:
     assert str(expected).find(f"int({truth['int']})")>=0,expected
    else:raise AssertionError('planted wrong interface value was accepted')
  finally:
   if tracer:
    if tracer.poll() is None:tracer.send_signal(signal.SIGINT)
    tracer.wait(timeout=10)
  if a.strace:
   text=trace.read_text();assert re.search(r'process_vm_readv|pread64|PTRACE_PEEKDATA',text),'no observed reads'
   assert not re.search(r'process_vm_writev\(|pwrite64\(|pwritev2?\(|(?:kill|tgkill|tkill)\(|PTRACE_(?:POKE\w*|SET\w*|CONT|SINGLESTEP|SYSCALL)\b',text),'unexpected mutation in read interval'
  assert c.session()['generation']==gen and c.inspect('get_registers',tid=tid)==regs,'inspection changed state'
  results.append(dict(stage=stage,seconds=time.monotonic()-started,before=before,after=resource(pid)))
  if stage==0:
   c.action('continue');c.stopped('breakpoint')
 report=dict(status='pass',agent=bool(a.agent),shared=a.shared,stages=results,load_average=os.getloadavg(),cpus=os.cpu_count(),compile_seconds=built-began,live_seconds=time.monotonic()-built)
 print(json.dumps(report))
finally:
 (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
 if c and not server:c.close()
 if server:server.close()
