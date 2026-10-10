#!/usr/bin/env python3
"""Fast owned-target lane: typed writes, audit, conflict-aware undo and authority."""
import argparse,importlib.util,json,os,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True);p.add_argument('--agent',type=Path)
p.add_argument('--shared',action='store_true');p.add_argument('--wrong-oracle',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,exist_ok=True,mode=0o755)
if a.agent:os.environ['XODB_RUNTIME_AGENT']=str(a.agent.resolve())
started=time.monotonic();exe=w/'fixture';oracle=w/'oracle.json'
subprocess.run(['cc','-std=c11','-g','-O1','-DNDEBUG','-Wall','-Wextra','-Werror','tests/jai-discovery.c','src/language/jai_layout.c','src/language/jai_reader.c','src/language/jai_value.c','src/language/jai_container.c','-o',str(exe)],check=True,timeout=30)
from client import Client
server=None;c=None;observer=None;report={'status':'failed','shared':a.shared,'agent':bool(a.agent)}
def wait(probe,predicate):
 end=time.monotonic()+10
 while True:
  value=probe()
  if predicate(value):return value
  assert time.monotonic()<end,value
  time.sleep(.002)
def refuse(r,why):
 assert r.get('result',{}).get('isError') and r['result']['content'][0]['text']==why,r
def usage():
 pid=server.proc.pid if server else c.p.pid
 fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
 return {'cpu_seconds':(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),'rss_bytes':int(fields[21])*os.sysconf('SC_PAGE_SIZE')}
def load():
 cap=c.action('capture_memory',address=truth['base'],length=truth['size'])
 ident=c.action('load_runtime_types',provider='jai',snapshot_ids=[cap['id']])['id']
 listing=wait(lambda:c.inspect('list_runtime_types',id=ident),lambda r:r['state']!='pending')
 assert listing['state']=='ready',listing
 return ident
def field(**kwargs):return c.action('write_runtime_field',**(dict(id=ident,type_name='FixtureTypedChild',address=truth['candidates'][0],path='health',value='123')|kwargs))['change']
def undo(id,**kwargs):return c.action('undo_runtime_write',write_id=id,**kwargs)['change']
def health():
 rows=c.action('read_runtime_value',id=ident,type_name='FixtureTypedChild',address=truth['candidates'][0])['rows']
 return next(int(r['bits_hex'],16) for r in rows if r['name']=='health')
def journal():return c.inspect('list_runtime_writes')['rows']
try:
 if a.shared:
  spec=importlib.util.spec_from_file_location('shared_fixture',root/'tests/shared-sessions.py');shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)
  server=shared.Server(root,w,Path(os.environ.get('XODB_BIN',root/'zig-out/bin/xodb')).resolve(),exe,'mutate',fixture_args=[str(oracle)])
  class SocketClient(shared.Client):
   inspect=shared.Client.tool;tool=shared.Client.raw
   def session(self):return self.inspect('get_session')
   def action(self,name,**args):return self.inspect(name,generation=self.session()['generation'],**args)
   def stopped(self,reason=None):return wait(self.session,lambda s:s['state']=='stopped' and not s['symbol_discovery_pending'] and not s['continue_pending'] and (reason is None or any(t['reason']==reason for t in s['threads'])))
  c=SocketClient(server,'writer');server.remember_target(c.session());c.inspect('claim_session_control',generation=c.session()['generation'],ttl_ms=30000)
  observer=SocketClient(server,'reader')
 else:c=Client('mutate',str(exe),args=[str(oracle)])
 bp=c.action('set_breakpoint',symbol='discovery_ready')['id'];c.action('set_breakpoint',symbol='discovery_changed');c.action('continue');c.stopped('breakpoint')
 truth=json.loads(oracle.read_text());ident=load();report['before']=usage()
 regs=c.inspect('get_registers',tid=c.session()['pid'])['registers'];assert health()==22
 change=field();assert change['verified'] and change['state']=='verified' and change['write_attempted'],change
 assert health()==(124 if a.wrong_oracle else 123)
 assert change['before_hex']==(22).to_bytes(8,'little').hex() and change['requested_hex']==(123).to_bytes(8,'little').hex() and change['observed_hex']==change['requested_hex'],change
 first=change['id'];row=journal()[0]
 assert row['actor']=='agent' and row['attempts']==1 and not row['undone'] and row['same_target'] and row['before_hex']==change['before_hex'],row
 audit=c.inspect('get_audit')['actions'][-1];assert audit['action']=='write_runtime_field' and audit['runtime_write']==change,audit
 second=field(value='456')['id'];assert health()==456
 denied=undo(first);assert denied['reason']=='JaiWriteUndoConflict' and not denied['id'] and not denied['write_attempted'],denied
 assert undo(second)['verified'] and health()==123
 assert undo(first)['verified'] and health()==22
 page=c.inspect('list_runtime_writes',start=0,limit=1);assert page['total']==2 and page['next']==1 and len(page['rows'])==1,page
 assert c.inspect('list_runtime_writes',start=1,limit=1)['next'] is None
 # Refusals leave target generation, audit length, bytes and journal unchanged.
 before=c.session();count=len(c.inspect('get_audit')['actions']);total=len(journal())
 code=next(b['address'] for b in c.inspect('get_breakpoints')['breakpoints'] if b['id']==bp)
 for args,why in [({'value':str(1<<63)},'JaiWriteValueOutOfRange'),({'path':'base.entity_type'},'JaiWriteNeedsRaw'),({'address':truth['base']},'JaiWriteMetadataProtected'),({'address':hex(code)},'JaiWriteCodeProtected')]:
  result=field(**args);assert result['reason']==why and not result['id'] and not result['write_attempted'],result
 assert health()==22 and c.session()['generation']==before['generation'] and len(journal())==total and len(c.inspect('get_audit')['actions'])==count
 # Explicit raw Type-field write is journalled and recoverable too.
 raw=field(path='base.entity_type',value='0000000000000000',raw=True);assert raw['verified'] and raw['raw'],raw
 assert undo(raw['id'])['verified'] and health()==22
 if observer:
  assert observer.inspect('list_runtime_writes')['rows']==journal()
  for tool,args in [('write_runtime_field',dict(id=ident,address=truth['candidates'][0],path='health',value='999',type_name='FixtureTypedChild')),('undo_runtime_write',dict(write_id=first))]:
   refuse(observer.tool(tool,generation=c.session()['generation'],**args),'ControlLeaseRequired')
  c.inspect('release_session_control')
  refuse(c.tool('undo_runtime_write',generation=c.session()['generation'],write_id=first),'ControlLeaseRequired')
  c.inspect('claim_session_control',generation=c.session()['generation'],ttl_ms=30000)
 else:
  for scope in ('observe','control'):
   denied_client=Client(scope,str(exe),args=[str(w/(scope+'.json'))])
   try:
    for tool in ('write_runtime_field','undo_runtime_write'):refuse(denied_client.tool(tool),'AgentScopeDenied')
   finally:(w/(scope+'-transcript.json')).write_text(json.dumps(denied_client.transcript));denied_client.close()
 assert c.inspect('get_registers',tid=c.session()['pid'])['registers']==regs
 # Continue changes the field and makes metadata stale; checked undo must notice.
 pending=field(value='321')['id'];old_generation=c.session()['generation']
 c.action('continue');c.stopped('breakpoint')
 refuse(c.tool('write_runtime_field',id=ident,type_name='FixtureTypedChild',address=truth['candidates'][0],path='health',value='8',generation=c.session()['generation']),'RuntimeTypesStale')
 conflict=undo(pending);assert conflict['reason']=='JaiWriteUndoConflict' and not conflict['id'],conflict
 recovered=undo(pending,raw=True);assert recovered['verified'] and recovered['before_hex']==(23).to_bytes(8,'little').hex(),recovered
 ident=load();assert health()==22
 restart_id=field(value='222')['id'];c.action('restart');c.stopped()
 changed=undo(restart_id,raw=True);assert changed['reason']=='JaiWriteTargetChanged' and not changed['write_attempted'],changed
 assert all(not r['same_target'] for r in journal()),journal()
 report['after']=usage();report['records']=len(journal());report['status']='pass'
finally:
 if server:server.close()
 elif c:(w/'transcript.json').write_text(json.dumps(c.transcript));c.close()
 report.update(seconds=time.monotonic()-started,load=os.getloadavg())
 (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
