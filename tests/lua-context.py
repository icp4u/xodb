#!/usr/bin/env python3
"""Owned Lua states, VM entry, and interruption in a native I/O frame."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import threading
from client import Client
from helpers.readonly import audit

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',required=True)
p.add_argument('--library',required=True)
p.add_argument('--work',required=True,type=Path)
p.add_argument('--strace',action='store_true')
p.add_argument('--companion',action='store_true')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
work=a.work.resolve();work.mkdir(parents=True,mode=0o755);exe=work/'context'
subprocess.run(['cc','-std=c11','-g','-O0','-fno-omit-frame-pointer','-I'+a.source,
    'tests/fixtures/lua/context.c',a.library,'-lm','-ldl','-o',str(exe)],check=True,timeout=90)
options=[]
if a.companion:
    debug=work/'context.debug'
    subprocess.run(['objcopy','--only-keep-debug',str(exe),str(debug)],check=True,timeout=30)
    subprocess.run(['strip','--strip-debug',str(exe)],check=True,timeout=30)
    options=['--debug-file',str(debug)]
layout_source='build-id companion DWARF' if a.companion else 'same-image DWARF'
target=subprocess.Popen([str(exe)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
lines=queue.Queue()
def drain():
    for line in target.stdout:lines.put(line)
thread=threading.Thread(target=drain,daemon=True);thread.start()
client=None;result={}
try:
    assert lines.get(timeout=10)=='ready\n'
    client=Client('control',None,options=['--attach',str(target.pid),*options])
    states=client.action('set_breakpoint',symbol='xodb_lua_states_stop')
    entry=client.action('set_breakpoint',symbol='luaV_execute')
    client.action('continue');target.stdin.write('g');target.stdin.flush()
    client.stopped('breakpoint')
    kind,one,two=lines.get(timeout=10).split();assert kind=='states'
    result['states']=client.inspect('get_language_stack',tid=target.pid,language='lua')
    assert {int(s['runtime_instance']['address'],16) for s in result['states']['segments']}=={int(one,16),int(two,16)},result
    assert all(s['anchor'] is None and s['runtime']['layout_source']==layout_source for s in result['states']['segments'])
    result['slot']=client.inspect('evaluate_expression',tid=target.pid,frame=0,expression='slot')['value']
    assert result['slot']['display'] in ('integer 41','number 41'),result['slot']
    assert result['slot']['visualization']['lua']['layout_source']==layout_source,result['slot']
    client.action('remove_breakpoint',id=states['id']);client.action('continue')
    client.stopped('breakpoint')
    result['entry']=client.inspect('get_language_stack',tid=target.pid,language='lua')
    frames=[f for s in result['entry']['segments'] for f in s['frames']]
    assert any(f['reason']=='LuaFrameNotStarted' for f in frames),result['entry']
    assert all(f['reason']!='LuaSavedPcInvalid' for f in frames),result['entry']
    for f in frames:
        if f['reason']=='LuaFrameNotStarted':assert f['line']==f['defined_line'] or f['defined_line']==0 and f['line'] is None
    client.action('remove_breakpoint',id=entry['id']);client.action('continue')
    assert lines.get(timeout=10)=='io_waiting\n'
    client.action('interrupt');client.stopped()
    result['native']=client.inspect('get_stack',tid=target.pid)['frames']
    result['io']=client.inspect('get_language_stack',tid=target.pid,language='lua')
    own=next(s for s in result['io']['segments'] if int(s['runtime_instance']['address'],16)==int(one,16))
    assert own['anchor'] is not None and any(f['kind']=='Lua' and f['file']=='@context.lua' for f in own['frames']),result['io']
    # Libc has no usable locals here. Its failure is evidence attached to the
    # native frame, and cannot discard the lower VM frame's recovered state.
    assert any(d['frame']==0 for d in result['io']['native_argument_diagnostics']),result['io']
    if a.strace:result['readonly']=audit(client,target.pid,work/'io.strace',lambda:client.inspect('get_language_stack',tid=target.pid,language='lua'))
    client.action('continue');target.stdin.write('x');target.stdin.flush()
    target.wait(timeout=10);assert target.returncode==0,target.stderr.read()
    result['status']='pass'
finally:
    if client:client.close()
    if target.poll() is None:target.kill();target.wait()
    thread.join(timeout=5)
    (work/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Lua: distinct state arguments, valid VM entry, and libc interruption passed')
