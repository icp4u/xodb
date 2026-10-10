#!/usr/bin/env python3
"""Fast ELF / periodic PE lane: stripped owned demo, RTTI and Wine attach/recapture."""
import argparse,ctypes,json,os,select,shutil,signal,struct,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True)
p.add_argument('--kind',choices=('elf','pe'),default='elf')
p.add_argument('--wine',default='wine');p.add_argument('--zig',default='zig')
p.add_argument('--agent',type=Path);p.add_argument('--wrong-oracle',action='store_true')
p.add_argument('--writes',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,exist_ok=True,mode=0o755)
started=time.monotonic();exe=w/('fixture.exe' if a.kind=='pe' else 'fixture');oracle=w/'oracle.json'
libc=ctypes.CDLL(None,use_errno=True)
assert libc.prctl(36,1,0,0,0)==0,'owned fixture subreaper'
env=dict(os.environ)
for key in ('DISPLAY','WAYLAND_DISPLAY','SWAYSOCK','DBUS_SESSION_BUS_ADDRESS'):env.pop(key,None)
for name in ('tmp','cache','run'):(w/name).mkdir(mode=0o700 if name=='run' else 0o755,exist_ok=True)
env.update(TMPDIR=str(w/'tmp'),XDG_RUNTIME_DIR=str(w/'run'),XDG_CACHE_HOME=str(w/'cache'),
           ZIG_GLOBAL_CACHE_DIR=str(root/'.cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(root/'.zig-cache'))
cmd=[a.zig,'cc','-target','x86_64-windows-gnu'] if a.kind=='pe' else ['cc']
with (w/'build.log').open('wb') as log:
 subprocess.run([*cmd,'-std=c11','-O1','-DNDEBUG','-s','-Wall','-Wextra','-Werror','tests/jai-demo.c','src/language/jai_layout.c','src/language/jai_reader.c','-o',str(exe)],env=env,check=True,stdout=log,stderr=subprocess.STDOUT,timeout=300)
report={'status':'failed','kind':a.kind,'agent':bool(a.agent),'compile_seconds':time.monotonic()-started}
if a.kind=='pe':
 image=exe.read_bytes();pe=struct.unpack_from('<I',image,0x3c)[0];assert image[:2]==b'MZ' and image[pe:pe+4]==b'PE\0\0'
 assert struct.unpack_from('<H',image,pe+4)[0]==0x8664 and struct.unpack_from('<I',image,pe+16)[0]==0
 env.update(WINEPREFIX=str(w/'wine'),WINEARCH='win64',WINEDEBUG='-all',WINEDLLOVERRIDES='mscoree,mshtml=')
 argv=[shutil.which(a.wine) or a.wine,str(exe),'Z:'+str(oracle)]
else:argv=[str(exe),str(oracle)]
from client import Client
c=None;target=None;log=(w/'target.log').open('wb')
def allow_parent():
 if libc.prctl(0x59616d61,os.getppid(),0,0,0)!=0:os._exit(127) # PR_SET_PTRACER

def identity(pid):
 try:return Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[19]
 except (FileNotFoundError,ProcessLookupError):return None

def descendants():
 out={};pending=[os.getpid()]
 while pending:
  parent=pending.pop()
  try:children=Path(f'/proc/{parent}/task/{parent}/children').read_text().split()
  except (FileNotFoundError,ProcessLookupError):continue
  for token in children:
   pid=int(token)
   if pid not in out:
    stamp=identity(pid)
    if stamp:out[pid]=stamp;pending.append(pid)
 return out

def cleanup():
 # Only this runner's descendants, including adopted private-Wine helpers.
 deadline=time.monotonic()+5;sent=set()
 while True:
  owned=descendants()
  if not owned:break
  for pid,stamp in owned.items():
   if identity(pid)!=stamp:continue
   try:os.kill(pid,signal.SIGKILL if time.monotonic()>deadline else signal.SIGTERM)
   except ProcessLookupError:pass
  while True:
   try:pid,_=os.waitpid(-1,os.WNOHANG)
   except ChildProcessError:break
   if pid==0:break
   sent.add(pid)
  assert time.monotonic()<deadline+5,owned
  time.sleep(.01)
 return len(sent)

def wait(probe,predicate,seconds=30):
 end=time.monotonic()+seconds
 while True:
  value=probe()
  if predicate(value):return value
  assert time.monotonic()<end,value
  time.sleep(.002)

def usage():
 f=Path(f'/proc/{c.p.pid}/stat').read_text().rsplit(')',1)[1].split()
 return {'cpu_seconds':(int(f[11])+int(f[12]))/os.sysconf('SC_CLK_TCK'),'rss_bytes':int(f[21])*os.sysconf('SC_PAGE_SIZE')}

def load():
 cap=c.action('capture_memory',address=truth['base'],length=truth['size'])
 ident=c.action('load_runtime_types',provider='jai',snapshot_ids=[cap['id']])['id']
 info=wait(lambda:c.inspect('list_runtime_types',id=ident),lambda r:r['state']!='pending')
 assert info['state']=='ready',info
 return ident
try:
 target=subprocess.Popen(argv,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,env=env,bufsize=0,preexec_fn=allow_parent)
 end=time.monotonic()+90
 while not select.select([target.stdout],[],[],.1)[0]:
  assert target.poll() is None,(target.returncode,(w/'target.log').read_text())
  assert time.monotonic()<end,'fixture startup deadline'
 assert target.stdout.readline().strip()==b'ready'
 truth=json.loads(oracle.read_text());report['startup_seconds']=time.monotonic()-started-report['compile_seconds']
 # Locate the PE only within processes spawned by this runner, never globally.
 candidates=[]
 for pid in descendants():
  try:maps=Path(f'/proc/{pid}/maps').read_text()
  except (FileNotFoundError,ProcessLookupError,PermissionError):continue
  if str(exe) in maps:candidates.append(pid)
 assert len(candidates)==1,candidates
 pid=candidates[0];stamp=identity(pid)
 options=['--attach',str(pid),*(['--runtime-agent',str(a.agent.resolve())] if a.agent else [])]
 c=Client('mutate' if a.writes else 'control',None,options=options);c.stopped(seconds=60)
 assert identity(pid)==stamp
 report['resources_before']=usage();gen=c.session()['generation'];regs=c.inspect('get_registers',tid=pid)['registers']
 ident=load();entity=c.inspect('get_runtime_type',id=ident,type_name='FixtureEntity')
 assert entity['type']['address_hex']==truth['entity_type'] and int(entity['type']['size_hex'],16)==truth['entity_size'],entity
 assert int(entity['members'][1]['offset_hex'],16)==truth['health_offset'],entity
 enum=c.inspect('get_runtime_type',id=ident,type_name='FixtureState')
 assert enum['enumerators']==[{'name':'NEGATIVE','bits_hex':'0xfffffffffffffffd'},{'name':'READY','bits_hex':'0x7'}],enum
 def read(context,address):return c.action('read_runtime_value',id=context,type_name='FixtureEntity',address=address)
 value=read(ident,truth['first']);assert value['rows'][3]['bits_hex']==hex(truth['health']+(1 if a.wrong_oracle else 0)),value
 assert value['rows'][3]['address_hex']==hex(int(truth['first'],16)+truth['health_offset']),value
 bucket=c.action('read_runtime_container',id=ident,type_name='Bucket',address=truth['bucket'])
 assert [r['address_hex'] for r in bucket['rows']]==truth['bucket_items'] and [r['slot_hex'] for r in bucket['rows']]==['0x1','0x3'],bucket
 array=c.action('read_runtime_value',id=ident,type_address=truth['dynamic_type'],address=truth['dynamic'],start=4,limit=1)
 assert array['rows'][0]['count_hex']=='0x6' and array['rows'][1]['bits_hex']==hex(1115),array
 search=c.action('search_runtime_instances',id=ident,type_name='FixtureEntityBase',self_type_field='entity_type',dynamic_type_address=truth['entity_type'],address=truth['area'],length=truth['area_size'])
 found=wait(lambda:c.action('get_runtime_instances',id=search['id']),lambda r:r['state']!='running')
 assert found['candidate_hit_count']==3 and not found['lifetime_proved'],found
 assert [r['candidate_address_hex'] for r in found['rows']]==[truth['first'],truth['unrelated'],truth['last']],found
 assert c.session()['generation']==gen and c.inspect('get_registers',tid=pid)['registers']==regs
 if a.writes:
  result=c.action('write_runtime_field',id=ident,type_name='FixtureEntity',address=truth['first'],path='health',value='123')['change']
  assert result['verified'] and result['before_hex']==truth['health'].to_bytes(8,'little').hex(),result
  assert read(ident,truth['first'])['rows'][3]['bits_hex']==hex(123)
  undo=c.action('undo_runtime_write',write_id=result['id'])['change']
  assert undo['verified'] and undo['observed_hex']==truth['health'].to_bytes(8,'little').hex(),undo
  assert read(ident,truth['first'])['rows'][3]['bits_hex']==hex(truth['health'])
  assert c.inspect('get_audit')['actions'][-1]['runtime_write']==undo
  assert c.inspect('get_registers',tid=pid)['registers']==regs
  report['writes']='typed write123/readback/undo/native restored-value check'
 c.action('set_breakpoint',address=truth['changed']);target.stdin.write(b'c\n');target.stdin.flush();c.action('continue');c.stopped('breakpoint',seconds=60)
 stale=c.tool('read_runtime_value',id=ident,generation=c.session()['generation'],type_name='FixtureEntity',address=truth['first'])
 assert stale['result']['isError'] and stale['result']['content'][0]['text']=='RuntimeTypesStale',stale
 newer=load();changed=read(newer,truth['first']);assert changed['rows'][3]['bits_hex']==hex(78),changed
 report['resources_after']=usage();c.action('continue');wait(c.session,lambda s:s['state']=='exited')
 assert target.wait(timeout=30)==0
 report['status']='pass'
finally:
 try:
  if c:
   (w/'transcript.json').write_text(json.dumps(c.transcript))
   c.close()
 finally:
  report['reaped_helpers']=cleanup();log.close();report.update(seconds=time.monotonic()-started,load=os.getloadavg())
  (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
