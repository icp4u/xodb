#!/usr/bin/env python3
"""Detached owned fixtures must be reaped by the shared-test harness."""
import argparse, ctypes, importlib.util, json, os, subprocess, sys, time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--work',type=Path,default=Path('.work/shared-cleanup'));a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,exist_ok=True)
# Own any orphan even when probing an older helper that lacks subreaping.
libc=ctypes.CDLL(None,use_errno=True)
assert libc.prctl(36,1,0,0,0)==0
source=w/'fixture.c';source.write_text('#include <unistd.h>\nint main(void) { for (;;) pause(); }\n');fixture=w/'fixture'
subprocess.run(['cc','-g','-O0',str(source),'-o',str(fixture)],check=True,timeout=30)
spec=importlib.util.spec_from_file_location('shared',root/'tests/shared-sessions.py');s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)
report=[]
try:
 for agent in (False,True):
  os.environ.pop('XODB_RUNTIME_AGENT',None)
  if agent:os.environ['XODB_RUNTIME_AGENT']=str(root/'zig-out/bin/xodb-agent')
  part=w/('agent' if agent else 'native');part.mkdir();server=s.Server(root,part,root/'zig-out/bin/xodb',fixture,'control',fixture_args=())
  try:
   owner=s.Client(server,'owner');owner.claim();state=s.eventually(owner.session,lambda v:v['state']=='stopped' and not v['symbol_discovery_pending'],'initial stop');server.remember_target(state);pid=server.target_pid
   owner.action('detach');server.close()
   # A remaining adopted child is observed at exit without reaping it. This
   # makes a missing wait deterministic rather than a scheduler race.
   try:
    ended=os.waitid(os.P_PID,pid,os.WEXITED|os.WNOWAIT)
    assert False,('owned detached fixture left unreaped',ended.si_pid,ended.si_status)
   except ChildProcessError:pass
   assert s.process_identity(pid) is None
   report.append(dict(transport='agent' if agent else 'native',target_reaped=True))
  finally:
   if server.proc.poll() is None:server.close()
   try:os.waitpid(server.target_pid,0)
   except (ChildProcessError,TypeError):pass
finally:(w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print('Shared cleanup: detached native/agent fixtures are killed and reaped before returning')
