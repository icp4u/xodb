#!/usr/bin/env python3
"""Read-only CRuby frames/locals, with a cooperating Binding oracle."""
import argparse,json,os,queue,re,signal,subprocess,threading,time
from pathlib import Path
from client import Client
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--strace',action='store_true');p.add_argument('--ruby',required=True);p.add_argument('--agent');p.add_argument('--work',type=Path,required=True)
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,exist_ok=True);w.chmod(0o755)
os.environ['XDG_CACHE_HOME']=str(w/'cache')
headers=json.loads(subprocess.check_output([a.ruby,'-rjson','-rrbconfig','-e','puts JSON.generate(RbConfig::CONFIG.values_at("rubyhdrdir","rubyarchhdrdir","DLEXT"))'],text=True,timeout=30))
addon=w/('xodb_probe.'+headers[2])
subprocess.run(['cc','-g','-O0','-fno-omit-frame-pointer','-fPIC','-shared','-I'+headers[0],'-I'+headers[1],'tests/fixtures/ruby/probe.c','-o',str(addon)],check=True,timeout=60)
expected={'plain-slots':('plain_slots',{'seed':7,'word':'hello','truth':True,'negative':-7,'fraction':3.5}),'sample':('sample',{'seed':7,'captured':41,'stack_only':17})}
for depth in range(3):expected['recursive-'+str(depth)]=('recursive',{'depth':depth,'own':depth*10})
expected['closure']=('block in outer',{'captured':99,'seed':7})
expected['fiber-0']=('block in <main>',{'captured':11});expected['fiber-1']=('block in <main>',{'captured':12})
def plain(row):
 assert row['name_diagnostic'] is None and row['value']['diagnostic'] is None,row
 v=row['value'];d=v['display']
 if v['type']=='Integer':return int(d)
 if v['type']=='Float':return float(d)
 if v['type']=='String':return json.loads(d)
 return {'true':True,'false':False,'nil':None}[d]
def usage(pid):
 fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
 rss=int(re.search(r'^VmRSS:\s*(\d+)',Path(f'/proc/{pid}/status').read_text(),re.M)[1])
 return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),rss_kib=rss)
def audit(client, target, args):
    def scheduled():
        return {p.name:(p/'schedstat').read_text().split()[0] for p in Path(f'/proc/{target.pid}/task').iterdir()}
    regs = client.inspect('get_registers',tid=target.pid); generation = client.session()['generation']; before = scheduled()
    path = w/'readonly.strace'
    observer = client.collector_pid() if a.agent else client.p.pid
    tracer = subprocess.Popen(['strace','-f','-qq','-o',str(path),'-e',
        'trace=ptrace,process_vm_readv,process_vm_writev,pread64,pwrite64,pwritev,pwritev2,kill,tgkill,tkill',
        '-p',str(observer)],stderr=subprocess.PIPE)
    try:
        # Read the observer's TracerPid rather than assuming strace is ready.
        deadline = time.monotonic()+10
        while True:
            status = Path(f'/proc/{observer}/status').read_text()
            if re.search(r'^TracerPid:\s*'+str(tracer.pid)+r'\s*$',status,re.M): break
            assert tracer.poll() is None and time.monotonic()<deadline, status
            time.sleep(.01)
        for _ in range(2):
            client.inspect('get_language_locals',**args)
            value = client.inspect('evaluate_language_expression',**args,expression='seed')
            assert value['diagnostic'] is None and value['rows'][0]['value']['display']=='7', value
            refusal = client.inspect('evaluate_language_expression',**args,expression='puts(1)')
            assert refusal['diagnostic']=='RubyExpressionUnsupported' and not refusal['rows'], refusal
    finally:
        if tracer.poll() is None: tracer.send_signal(signal.SIGINT)
        tracer.wait(timeout=10)
    text = path.read_text()
    assert re.search(r'process_vm_readv|pread64|PTRACE_PEEKDATA',text), text
    assert not re.search(r'process_vm_writev\(|pwrite64\(|pwritev2?\(|(?:kill|tgkill|tkill)\(|PTRACE_(?:POKE\w*|SET\w*|CONT|SINGLESTEP|SYSCALL)\b',text), text
    assert scheduled()==before and client.session()['generation']==generation and client.inspect('get_registers',tid=target.pid)==regs
results=[];resources=[]
for mode in ('plain','binding'):
 target=subprocess.Popen([a.ruby,'tests/fixtures/ruby/locals.rb',mode],env=dict(os.environ,XODB_RUBY_PROBE=str(addon)),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 lines=queue.Queue()
 def drain():
  for line in target.stdout:lines.put(line)
 thread=threading.Thread(target=drain,daemon=True);thread.start();client=None
 try:
  assert lines.get(timeout=15)=='ready\n'
  options=['--attach',str(target.pid)]+(['--runtime-agent',a.agent] if a.agent else [])
  client=Client('control',None,options=options)
  client.action('set_breakpoint',symbol='xodb_ruby_stop');client.continue_initial_stop();target.stdin.write('go\n');target.stdin.flush()
  measured={'frontend':client.p.pid}
  if a.agent:measured['runtime_agent']=client.collector_pid()
  prior=None
  for label,(function,wanted) in expected.items():
   client.stopped('breakpoint',seconds=20);oracle=json.loads(lines.get(timeout=15));assert oracle['label']==label,oracle
   before={k:usage(pid) for k,pid in measured.items()};started=time.monotonic()
   stack=client.inspect('get_language_stack',tid=target.pid,language='ruby')
   assert stack['segments'],stack
   selected=next((si,fi,f) for si,s in enumerate(stack['segments']) for fi,f in enumerate(s['frames']) if f['name']==function)
   si,fi,f=selected;assert f['reason'] is None and f['line_reason'] is None and f['line']>0,f
   source=Path('tests/fixtures/ruby/locals.rb').read_text().splitlines()[f['line']-1]
   assert 'mark(' in source,source
   generation=client.session()['generation'];args=dict(generation=generation,tid=target.pid,language='ruby',segment=si,frame=fi)
   regs=client.inspect('get_registers',tid=target.pid)
   schedule={p.name:(p/'schedstat').read_text().split()[0] for p in Path(f'/proc/{target.pid}/task').iterdir()}
   data=client.inspect('get_language_locals',**args);assert data['diagnostic'] is None,data
   rows={row['name']:row for row in reversed(data['rows']) if not row['hidden']}
   assert {name:plain(rows[name]) for name in wanted}==wanted,data
   if label=='plain-slots':
    assert rows['items']['value']['count']==3 and [plain({'name_diagnostic':None,'value':v}) for v in rows['items']['value']['children']]==[1,None,True],rows['items']
    assert rows['long_text']['value']['count']==512 and rows['long_text']['value']['truncated'],rows['long_text']
    if a.strace:audit(client,target,args)
   if label=='closure':
    captures=[row for row in data['rows'] if row['name']=='captured']
    assert [plain(row) for row in captures]==[99,41],captures
   if mode=='binding':assert all(plain(rows[name])==oracle['locals'][name] for name in wanted), (label,oracle,wanted,data)
   for name,value in wanted.items():
    found=client.inspect('evaluate_language_expression',expression=name,**args)
    assert found['diagnostic'] is None and len(found['rows'])==1 and plain(found['rows'][0])==value,found
   denied=client.inspect('evaluate_language_expression',expression='puts(1)',**args)
   assert denied['diagnostic']=='RubyExpressionUnsupported' and not denied['rows'],denied
   page=client.inspect('get_language_locals',start=1,limit=1,**args)
   if data['total']>1:assert page['rows'][0]==data['rows'][1],page
   assert client.inspect('get_registers',tid=target.pid)==regs and client.session()['generation']==generation
   assert {p.name:(p/'schedstat').read_text().split()[0] for p in Path(f'/proc/{target.pid}/task').iterdir()}==schedule
   if prior:
    stale=client.tool('get_language_locals',**prior)
    assert stale['result']['isError'] and stale['result']['content'][0]['text']=='StaleSnapshot',stale
   prior=args
   resources.append(dict(mode=mode,label=label,before=before,after={k:usage(pid) for k,pid in measured.items()},elapsed_seconds=time.monotonic()-started,load=os.getloadavg(),allowed_cpus=len(os.sched_getaffinity(0))))
   native=client.inspect('list_locals',tid=target.pid,frame=0)
   values=[v['value'].get('visualization') for v in native['locals'] if v['name']=='value']
   assert len(values)==1 and values[0] and values[0].get('ruby'),native
   assert plain({'name_diagnostic':None,'value':values[0]['ruby']['value']})==label,values
   results.append(dict(mode=mode,label=label,oracle=oracle,stack=stack,locals=data,registers_and_schedule_unchanged=True))
   (w/'results.json').write_text(json.dumps(dict(status='running',stops=results,resources=resources),indent=2)+'\n')
   client.action('continue')
  target.wait(timeout=15);assert target.returncode==0,target.stderr.read()
 finally:
  if client:client.close()
  if target.poll() is None:target.kill()
  target.wait();thread.join(timeout=2)
(w/'results.json').write_text(json.dumps(dict(status='pass',stops=results,resources=resources),indent=2)+'\n')
print('Ruby16 plain/Binding stops: values, lines, recursion, fiber/GC, pages, expressions, native VALUE previews and observer invariants passed')
