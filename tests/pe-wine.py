#!/usr/bin/env python3
"""Periodic native PE integration: owned Wine, runtime PCs and header changes.

--eviction loads 260 extra DLLs and proves cold reload with a stable module ID.
All Wine and graphical processes belong to a fresh private work directory.
"""
import argparse, importlib.util, json, os, select, signal, shutil, struct, subprocess, time
from pathlib import Path
from client import Client
from helpers import orphans

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True)
p.add_argument('--wine',default='wine')
p.add_argument('--eviction',action='store_true')
p.add_argument('--wrong-result',action='store_true')
p.add_argument('--unwind',action='store_true')
p.add_argument('--profile',action='store_true',help='saved PE stacks and archive asset verification')
a=p.parse_args()
if a.profile:a.unwind=True
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022);orphans.adopt()
w=a.work.resolve();w.mkdir(parents=True)
start=time.monotonic();report=dict(status='running',eviction=a.eviction)

def command(args,name):
 r=subprocess.run(args,capture_output=True,text=True,timeout=60)
 (w/(name+'.log')).write_text(r.stdout+r.stderr)
 assert r.returncode==0,(name,r.returncode,r.stderr)
 return r.stdout

(w/'kernel32.def').write_text('LIBRARY KERNEL32.dll\nEXPORTS\n    GetCurrentProcessId\n    LoadLibraryA\n    GetProcAddress\n    GetStdHandle\n    WriteFile\n    Sleep\n    ExitProcess\n')
command(['lld-link','/lib','/def:'+str(w/'kernel32.def'),'/machine:x64','/out:'+str(w/'kernel32.lib')],'import-library')
for source in ('library','main'):
 command(['clang','--target=x86_64-pc-windows-msvc','-O2','-g','-gcodeview','-ffile-prefix-map='+str(root)+'=.',
          '-DPE_COUNT='+str(260 if a.eviction else 0),*(['-DPE_UNWIND'] if a.unwind else []),'-c','tests/fixtures/pe/'+source+'.c','-o',str(w/(source+'.obj'))],source+'-compile')
extra=[]
if a.unwind:
 (w/'ntdll.def').write_text('LIBRARY ntdll.dll\nEXPORTS\n    RtlCaptureStackBackTrace\n    __chkstk\n    __C_specific_handler\n')
 command(['lld-link','/lib','/def:'+str(w/'ntdll.def'),'/machine:x64','/out:'+str(w/'ntdll.lib')],'ntdll-library')
 command(['clang','--target=x86_64-pc-windows-msvc','-O2','-g','-gcodeview','-fomit-frame-pointer',
          '-ffile-prefix-map='+str(root)+'=.',*(['-DPE_PROFILE'] if a.profile else []),'-c','tests/fixtures/pe/unwind-live.c','-o',str(w/'unwind-live.obj')],'unwind-compile')
 extra=[str(w/'unwind-live.obj'),str(w/'ntdll.lib')]
command(['lld-link','/dll','/noentry','/machine:x64','/debug','/pdb:'+str(w/'library.pdb'),'/def:tests/fixtures/pe/library.def',
         '/out:'+str(w/'owned-pe.dll'),str(w/'library.obj'),str(w/'kernel32.lib'),*extra],'library-link')
command(['lld-link','/entry:entry','/subsystem:console','/machine:x64','/debug','/pdb:'+str(w/'main.pdb'),
         '/out:'+str(w/'owned-pe.exe'),str(w/'main.obj'),str(w/'kernel32.lib')],'main-link')
command(['cc','-O2','-Wall','-Wextra','-Werror','tests/fixtures/pe/launcher.c','-o',str(w/'launcher')],'launcher')
command(['llvm-readobj','--file-headers','--coff-exports','--unwind',str(w/'owned-pe.exe')],'exe-oracle')
if a.unwind:
 oracle=command(['llvm-readobj','--coff-exports','--unwind',str(w/'owned-pe.dll')],'dll-oracle')
 assert 'ExceptionHandler' in oracle and 'SET_FPREG' in oracle and 'FrameRegister: -' in oracle,oracle
if a.eviction:
 for i in range(260):shutil.copyfile(w/'owned-pe.dll',w/('module-%03d.dll'%i))

spec=importlib.util.spec_from_file_location('private_display',root/'tests/helpers/display.py')
display=importlib.util.module_from_spec(spec);spec.loader.exec_module(display);display.WORK=str(w/'display')
d=server=app=client=None

def owned():
 rows=[]
 for proc in Path('/proc').iterdir():
  if not proc.name.isdigit():continue
  try:
   cwd=(proc/'cwd').resolve(strict=True)
   if cwd==w or w in cwd.parents:rows.append(dict(pid=int(proc.name),comm=(proc/'comm').read_text().strip()))
  except (OSError,RuntimeError):pass
 return rows

def usage(pid):
 fields=Path('/proc')/str(pid)
 stat=(fields/'stat').read_text().rsplit(') ',1)[1].split()
 rss=int((fields/'statm').read_text().split()[1])*os.sysconf('SC_PAGESIZE')
 return dict(cpu_seconds=(int(stat[11])+int(stat[12]))/os.sysconf('SC_CLK_TCK'),rss_bytes=rss)

def settled():
 deadline=time.monotonic()+60
 while time.monotonic()<deadline:
  state=client.session()
  if state['state']=='stopped' and not state['pe_metadata_pending']:return state
  time.sleep(.002)
 raise AssertionError(('PE discovery did not finish',state))

def action(name,**args):
 deadline=time.monotonic()+20
 while True:
  response=client.tool(name,generation=client.session()['generation'],**args)
  result=response.get('result',{})
  if result.get('isError') and result.get('content')==[{'type':'text','text':'StaleSnapshot'}]:
   assert time.monotonic()<deadline,response
   continue
  assert 'error' not in response and not result.get('isError'),response
  return result['structuredContent']

def pages():
 rows=[];failures=[];cursor=None
 while True:
  args=dict(limit=512)
  if cursor:args['cursor']=cursor
  data=client.inspect('list_modules',**args);rows+=data['regions'];failures+=data['load_failures'];cursor=data['next']
  if not cursor:return rows,failures

def stack(tid):
 deadline=time.monotonic()+20
 while time.monotonic()<deadline:
  data=client.inspect('get_stack',tid=tid)
  if data['frames'] and data['frames'][0]['diagnostic']!='SymbolDiscoveryPending':return data['frames'][0]
  time.sleep(.002)
 raise AssertionError(('PE stack did not finish',data))

def interrupted(signum,frame):raise RuntimeError('bounded owned test interrupted')
signal.signal(signal.SIGTERM,interrupted)
try:
 d=display.Display('d');prefix=w/'prefix';prefix.mkdir(mode=0o700)
 env=dict(d.env,WINEPREFIX=str(prefix),WINEDEBUG='-all',WINEDLLOVERRIDES='mscoree,mshtml=d')
 serverlog=(w/'server.log').open('wb');errors=(w/'wine.log').open('wb')
 server=subprocess.Popen(['wineserver','-f'],env=env,cwd=w,stdout=serverlog,stderr=subprocess.STDOUT)
 app=subprocess.Popen([str(w/'launcher'),a.wine,str(w/'owned-pe.exe')],env=env,cwd=w,stdout=subprocess.PIPE,stderr=errors)
 output=b'';deadline=time.monotonic()+60
 while b'\n' not in output and time.monotonic()<deadline:
  if select.select([app.stdout],[],[],.1)[0]:
   chunk=os.read(app.stdout.fileno(),4096)
   if not chunk:break
   output+=chunk
  if app.poll() is not None:break
 assert b'\n' in output,(output,app.poll())
 base,inner,ready,hidden,first,first_inner,last,last_inner=[int(x,16) for x in output.splitlines()[0].split()]
 assert base!=0x180000000,'fixture did not exercise relocation'
 report['oracle']=dict(base=base,inner=inner,ready=ready,hidden=hidden,first=first,first_inner=first_inner,last=last,last_inner=last_inner)
 candidates=[]
 for row in owned():
  try:
   if str(w/'owned-pe.exe') in Path('/proc',str(row['pid']),'maps').read_text():candidates.append(row['pid'])
  except OSError:pass
 assert len(candidates)==1,candidates
 report['pid']=candidates[0]
 client=Client('mutate',None,options=['--attach',str(candidates[0])]);client.stopped(seconds=20)
 report['before']=usage(client.p.pid);state=settled();report['loaded']=state['pe_metadata'];report['after']=usage(client.p.pid)
 report['load']=os.getloadavg();report['cpus']=os.cpu_count();report['cpu_performance']='not measurable' if report['load'][0]>report['cpus'] else 'single-sample evidence'
 rows,failures=pages();report['rows']=rows;report['failures']=failures
 if a.eviction:
  # Every resident job owns a pinned source descriptor. Select a runtime-printed
  # endpoint whose descriptor was actually closed by eviction, rather than
  # assuming Wine's mapping order matches load order.
  open_files=[]
  for fd in Path('/proc',str(client.p.pid),'fd').iterdir():
   try:open_files.append(os.readlink(fd))
   except OSError:pass
  choices=[('module-000.dll',first,first_inner),('module-259.dll',last,last_inner)]
  cold=[choice for choice in choices if str(w/choice[0]) not in open_files]
  assert cold,('no proven cold endpoint',open_files)
  selected,expected_base,expected=cold[0]
  report['cold_source']=dict(path=str(w/selected),absent_before=True)
 else:
  expected,expected_base=inner,base
 row=next(r for r in rows if r['start']<=expected<r['end'])
 assert row['path']=='' and row['pe_image']['base']==expected_base,row
 module_id=row['pe_image']['id']
 if a.eviction:
  assert state['pe_metadata']['evictions']>0 and state['pe_metadata']['resident_images']<=256,state
  symbol_name=selected+'!pe_inner'
 else:symbol_name='owned-pe.dll!pe_inner'
 bp=action('set_breakpoint',symbol=symbol_name)['id']
 action('continue');state=client.stopped('breakpoint',seconds=25);tid=next(t['tid'] for t in state['threads'] if t['reason']=='breakpoint')
 frame=stack(tid);report['export_frame']=frame
 assert frame['pc']==expected and frame['symbol']==('wrong-export' if a.wrong_result and not a.unwind else symbol_name),frame
 assert frame['module_id']==module_id and frame['diagnostic'] is None and frame['unwind_method']=='windows_unwind',frame
 if not a.eviction:
  data=(w/'owned-pe.dll').read_bytes();pe=struct.unpack_from('<I',data,60)[0];stamp=base+pe+8
  original=client.inspect('read_memory',address=hex(stamp),length=4)['hex']
  changed=(int.from_bytes(bytes.fromhex(original),'little')^1).to_bytes(4,'little').hex()
  action('write_memory',address=hex(stamp),hex=changed)
  refused=stack(tid);report['changed_header_frame']=refused
  assert refused['symbol'] is None and refused['diagnostic']=='PeImageChanged',refused
  action('write_memory',address=hex(stamp),hex=original)
  restored=stack(tid);assert restored['symbol']==symbol_name and restored['module_id']==module_id,restored
  action('remove_breakpoint',id=bp);hidden_bp=action('set_breakpoint',address=hex(hidden))['id']
  action('continue');state=client.stopped('breakpoint',seconds=20);tid=next(t['tid'] for t in state['threads'] if t['reason']=='breakpoint')
  frame=stack(tid);report['hidden_frame']=frame
  assert frame['pc']==hidden and frame['symbol']=='owned-pe.exe!sub_'+format(hidden-0x140000000,'x'),frame
  assert frame['diagnostic'] is None and frame['unwind_method']=='windows_unwind',frame
  if a.unwind:
   # Stop before the next invocation so the pipe oracle belongs to this stack.
   action('remove_breakpoint',id=hidden_bp)
   marker=action('set_breakpoint',symbol='owned-pe.dll!uw_stop_marker')['id']
   action('continue');state=client.stopped('breakpoint',seconds=20)
   tid=next(t['tid'] for t in state['threads'] if t['reason']=='breakpoint')
   data=client.inspect('get_stack',tid=tid);report['unwind']=data
   pending=output.split(b'\n',1)[1]
   while select.select([app.stdout],[],[],0)[0]:
    chunk=os.read(app.stdout.fileno(),65536)
    if not chunk:break
    pending+=chunk
   oracle_lines=[line for line in pending.splitlines() if line.startswith(b'UW ')]
   assert oracle_lines,pending
   oracle=[int(x,16) for x in oracle_lines[-1].split()[1:]]
   return_pc,captured=oracle[0],oracle[1:]
   frames=data['frames'];report['runtime_backtrace']=captured;report['compiler_return_pc']=return_pc
   assert len(captured)>=12,(captured,frames)
   assert captured[1]==return_pc,(captured,return_pc)
   compare=captured[1:12]
   if a.wrong_result and not a.profile:compare[0]+=1
   assert [f['pc'] for f in frames[2:2+len(compare)]]==compare,(frames,captured)
   assert all(f['diagnostic'] is None for f in frames[:2+len(compare)]),frames
   assert frames[0]['unwind_method']=='windows_leaf',frames
   assert any(f['symbol']=='owned-pe.dll!uw_dynamic' for f in frames),frames
   assert all(frames[i]['cfa']<frames[i+1]['cfa'] for i in range(11)),frames
   # Every subsequent walk must validate the actual stopped unwind metadata,
   # including after user writes at the same instruction address.
   leaf=next(f for f in frames if f['symbol']=='owned-pe.dll!uw_leaf_live')
   data=(w/'owned-pe.dll').read_bytes();pe=struct.unpack_from('<I',data,60)[0]
   optional=pe+24;table=optional+struct.unpack_from('<H',data,pe+20)[0]
   sections=[struct.unpack_from('<IIII',data,table+40*i+8) for i in range(struct.unpack_from('<H',data,pe+6)[0])]
   def disk(rva):
    return next(raw+rva-start for virtual,start,size,raw in sections if start<=rva<start+size)
   pdata,psize=struct.unpack_from('<II',data,optional+112+3*8)
   begin,end,unwind=next(row for row in struct.iter_unpack('<III',data[disk(pdata):disk(pdata)+psize]) if row[0]<=leaf['pc']-base<row[1])
   address=base+unwind;original=client.inspect('read_memory',address=hex(address),length=1)['hex']
   action('write_memory',address=hex(address),hex=bytes([int(original,16)^1]).hex())
   refused=client.inspect('get_stack',tid=tid)['frames'];report['changed_unwind']=refused
   assert len(refused)==2 and refused[-1]['diagnostic']=='PeUnwindMetadataChanged',refused
   action('write_memory',address=hex(address),hex=original)
   restored=client.inspect('get_stack',tid=tid)['frames']
   assert [f['pc'] for f in restored]==[f['pc'] for f in frames],restored
   before=usage(client.p.pid)
   for _ in range(20):
    again=client.inspect('get_stack',tid=tid)['frames']
    assert [f['pc'] for f in again]==[f['pc'] for f in frames],again
   report['unwind_cost']=dict(walks=20,before=before,after=usage(client.p.pid),load=os.getloadavg(),cpus=os.cpu_count())
   if a.profile:
    from pe_profile import check
    check(client,w,report,base,compare,marker,action,usage,a.wrong_result)
 else:
  report['reloaded']=client.session()['pe_metadata']
  opened=[]
  for fd in Path('/proc',str(client.p.pid),'fd').iterdir():
   try:opened.append(os.readlink(fd))
   except OSError:pass
  assert str(w/selected) in opened,opened
  report['cold_source']['present_after']=True
  assert report['reloaded']['evictions']>report['loaded']['evictions'],report
 report['status']='pass'
finally:
 if report['status']!='pass':report['status']='fail'
 if client:
  report['transcript']=client.transcript
  try:client.close()
  except Exception as e:report['close_error']=repr(e)
 if app and app.poll() is None:
  app.terminate()
  try:app.wait(timeout=5)
  except subprocess.TimeoutExpired:app.kill();app.wait(timeout=5)
 if server and server.poll() is None:
  server.terminate()
  try:server.wait(timeout=5)
  except subprocess.TimeoutExpired:server.kill();server.wait(timeout=5)
 if d:d.close()
 extras=[]
 for row in owned():
  try:os.kill(row['pid'],signal.SIGTERM);extras.append(row)
  except ProcessLookupError:pass
 report['orphans_reaped']=orphans.reap()
 report['extra_cleanup']=extras;report['elapsed_seconds']=time.monotonic()-start
 (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
assert report['orphans_reaped'],'a Wine process is still running'
print(json.dumps(dict(status=report['status'],seconds=report['elapsed_seconds'],oracle=report['oracle'])))
