#!/usr/bin/env python3
"""Fast live lane: compiler C++ frames retain linkage names and readable display."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
from client import Client
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True)
p.add_argument('--binary',type=Path,default=Path('zig-out/bin/xodb'))
p.add_argument('--agent',type=Path)
p.add_argument('--shared',action='store_true')
p.add_argument('--wrong-result',action='store_true')
a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,exist_ok=True)
started=time.monotonic();fixture=w/'fixture'
subprocess.run(['cc','-std=c++17','-g','-O1','-fno-inline','-fno-optimize-sibling-calls',
                '-fno-exceptions','-fno-rtti','-Wall','-Wextra','-Werror',
                'tests/fixtures/stack-symbol-names.cc','-o',str(fixture)],check=True,timeout=30)
names=subprocess.check_output(['nm','--defined-only',str(fixture)],text=True,timeout=10)
(w/'compiler-symbols.txt').write_text(names)
expected={'_ZN4demo4leafIiEET_S1_':'demo::leaf<>()','_ZN4demo6Engine3runEi':'demo::Engine::run()'}
for name in expected:assert name in names,name
if a.wrong_result:expected['_ZN4demo6Engine3runEi']='demo::Wrong::run()'
os.environ['XODB_BIN']=str(a.binary.resolve())
report=dict(status='failed',transport='shared observer' if a.shared else 'agent' if a.agent else 'host')
client=None;server=None;observer=None
try:
    if a.shared:
        spec=importlib.util.spec_from_file_location('shared',root/'tests/shared-sessions.py')
        shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)
        server=shared.Server(root,w,a.binary.resolve(),fixture,'control',fixture_args=())
        client=shared.Client(server,'owner');observer=shared.Client(server,'observer');client.claim(ttl_ms=60000)
        initial=shared.eventually(client.session,lambda v:v['state']=='stopped' and not v['symbol_discovery_pending'],'initial stop')
        server.remember_target(initial)
        client.action('set_breakpoint',symbol='symbol_name_stop');client.action('continue')
        stopped=shared.eventually(client.session,lambda v:v['state']=='stopped' and not v['continue_pending'] and any(t['reason']=='breakpoint' for t in v['threads']),'symbol stop')
        query=lambda name,**kw:observer.tool(name,**kw)
    else:
        client=Client('control',str(fixture),options=['--runtime-agent',str(a.agent.resolve())] if a.agent else [])
        client.stopped();client.action('set_breakpoint',symbol='symbol_name_stop');client.continue_initial_stop();stopped=client.stopped('breakpoint')
        query=client.inspect
    deadline=time.monotonic()+15
    while True:
        stack=query('get_stack',tid=stopped['pid'])
        if not any(f.get('diagnostic')=='DebugMetadataPending' for f in stack['frames']):break
        assert time.monotonic()<deadline,stack
        time.sleep(.002)
    (w/'stack.json').write_text(json.dumps(stack,indent=2)+'\n')
    seen={row['symbol']:row for row in stack['frames'] if row.get('symbol')}
    for raw,display in expected.items():
        assert raw in seen,seen
        assert seen[raw].get('symbol_display')==display,seen[raw]
    assert seen['symbol_name_stop']['symbol_display']=='symbol_name_stop',seen['symbol_name_stop']
    assert seen['main']['symbol_display']=='main',seen['main']
    report.update(status='passed',cpp_names=len(expected),raw_names_retained=True)
    print('PASS compact C++ names and exact linkage identities: '+report['transport'])
finally:
    if server:server.close()
    elif client:
        (w/'transcript.json').write_text(json.dumps(client.transcript,indent=2)+'\n');client.close()
    report['seconds']=time.monotonic()-started
    (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
