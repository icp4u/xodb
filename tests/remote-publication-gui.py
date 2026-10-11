#!/usr/bin/env python3
"""Private GUI: target-sized locals degrade visibly while other panes and MCP work.

Periodic GUI: the owned 4 MB C fixture and DWARF preparation exceed the fast
lane on loaded hosts. A short-name control uses the same stop and navigation.
"""
import argparse, importlib.util, json, os, pathlib, subprocess, sys, tempfile, time
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary');p.add_argument('--small-only',action='store_true')
p.add_argument('--wrong-result',action='store_true',help='plant an incorrect local count; the oracle must fail')
a=p.parse_args();root=pathlib.Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
spec=importlib.util.spec_from_file_location('publication_input',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
h.Display.reply_seconds=30*h.load_scale()
work=pathlib.Path(tempfile.mkdtemp(prefix='input-publication-',dir=root/'.work'));work.chmod(0o755);h.WORK=str(work)
for name in ['tmp','cache']:(work/name).mkdir(mode=0o755)
def usage(pid):
 f=pathlib.Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()
 return dict(cpu_seconds=(int(f[11])+int(f[12]))/os.sysconf('SC_CLK_TCK'),rss_bytes=int(f[21])*os.sysconf('SC_PAGE_SIZE'))
report=dict(status='running',load=os.getloadavg(),cpus=os.cpu_count(),cases=[]);started=time.monotonic()
try:
 for count,width in [(40,40)]+([] if a.small_only else [(4000,1000)]):
  source=work/f'locals-{count}.c';target=work/f'locals-{count}'
  with source.open('w') as out:subprocess.run(['python3','tests/fixtures/large-locals.py',str(count),str(width)],stdout=out,check=True,timeout=10)
  subprocess.run(['cc','-g','-O0','-fno-omit-frame-pointer',str(source),'-o',str(target)],check=True,timeout=60)
  row=dict(count=count,name_bytes=width,status='running');report['cases'].append(row);d=None;t=time.monotonic()
  try:
   d=h.Display(str(root),['--agent-scope','control','--runtime-agent',str(root/'zig-out/bin/xodb-agent'),'--',str(target)],binary=a.binary)
   state=d.wait(lambda s:s['state']=='stopped' and not s.get('continue_pending') and not s.get('symbol_discovery_pending'),seconds=30)
   assert state,d.tail();row['before']=usage(d.app.pid)
   # The int3 must be observed before any survival assertion counts.
   for _ in range(4):
    if any(t['reason']=='signal' and t.get('signal')==5 for t in state['threads']):break
    d.tool('continue',generation=state['generation'])
    state=d.wait(lambda s:s['state']=='stopped' and not s.get('continue_pending') and not s.get('symbol_discovery_pending'),seconds=30)
    assert state,d.tail()
   assert any(t['reason']=='signal' and t.get('signal')==5 for t in state['threads']),state
   row['signal_stop_observed']=True;tid=state['threads'][0]['tid']
   locals_=d.tool('list_locals',tid=tid,frame=0,limit=1)
   row['locals_observed']=locals_['total']
   expected=count+int(a.wrong_result)
   assert locals_['total']==expected and len(locals_['locals'][0]['name'])==width,locals_
   if count==4000:
    text=h.ocr_until(d,'oversized',lambda s:'view limit' in s and 'unavailable' in s and 'locals' in s,'--psm','11',seconds=25)
    assert 'view limit' in text and 'unavailable' in text and 'locals' in text,text
   else:
    text=h.ocr_until(d,'small',lambda s:'main' in s,'--psm','11')
    assert 'main' in text and 'view limit' not in text,text
   # Publication failure must not affect requests, confirmed stop identity or
   # subsequent target control. The small register response remains available.
   assert d.tool('get_registers',tid=tid),d.tail()
   assert d.session()['generation']==state['generation']
   row['after']=usage(d.app.pid);row['load']=os.getloadavg()
   d.tool('continue',generation=state['generation'])
   # Continue may forward the observed SIGTRAP and exit the owned target.
   # Either confirmed transition must replace the oversized stopped view.
   resumed_state=d.wait(lambda s:s['state'] in ('running','exited'),seconds=10);assert resumed_state,d.tail()
   assert resumed_state['generation']>state['generation'],resumed_state
   fresh=lambda s:('running' in s or 'exited' in s) and 'view limit' not in s
   resumed=h.ocr_until(d,'resumed',fresh,'--psm','11')
   assert fresh(resumed),resumed
   assert d.alive(),d.tail();row['control_after_limit']=True;row['status']='pass'
  finally:
   if row['status']!='pass':row['status']='failed'
   row['seconds']=time.monotonic()-t
   if d:row['log_tail']=d.tail();d.close()
 if not a.small_only and not a.wrong_result:
  # A deliberately wrong answer must fail after observing the same stop and
  # count. Keep this control in the registered periodic step.
  wrong=subprocess.run([sys.executable,__file__,'--small-only','--wrong-result',
                        *(['--binary',a.binary] if a.binary else [])],
                       capture_output=True,text=True,timeout=60*h.load_scale())
  (work/'wrong-result.log').write_text(wrong.stdout+wrong.stderr)
  observed=[json.loads(line) for line in wrong.stdout.splitlines() if line.startswith('{')]
  assert wrong.returncode!=0 and observed and 'AssertionError' in wrong.stderr,wrong.stdout+wrong.stderr
  control=observed[-1]['cases'][0]
  assert control.get('signal_stop_observed') and control.get('locals_observed')==40,control
  report['wrong_result']=dict(status='expected_failure',exit_code=wrong.returncode,observed=control)
 report['status']='pass'
finally:
 if report['status']!='pass':report['status']='failed'
 report['seconds']=time.monotonic()-started
 report['performance_measurable']=all(max(r.get('load',report['load']))<=report['cpus'] for r in report['cases'])
 (work/'results.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(dict(report,work=str(work))),flush=True)
