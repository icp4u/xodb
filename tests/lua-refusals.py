#!/usr/bin/env python3
"""Wrong-version and absent-DWARF refusals in owned static Lua fixtures."""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
from client import Client

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',required=True)
p.add_argument('--library',required=True)
p.add_argument('--work',required=True,type=Path)
a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
work=a.work.resolve();work.mkdir(parents=True,mode=0o755)
exe=work/'host'
subprocess.run([os.environ.get('CC','cc'),'-std=c11','-g','-O0','-fno-omit-frame-pointer',
    '-Wall','-Wextra','-Werror','-I'+a.source,'tests/fixtures/lua/host.c',a.library,'-lm','-ldl','-o',str(exe)],check=True,timeout=90)
data=exe.read_bytes()
for version in (b'5.4.9',b'5.2.4'):
    prefix=b'$LuaVersion: Lua '+version+b' '
    if prefix in data:break
else:raise AssertionError('expected exact Lua version')
assert data.count(prefix)==1
wrong=work/'wrong-version'
wrong.write_bytes(data.replace(prefix,b'$LuaVersion: Lua '+version[:-1]+b'0 '));wrong.chmod(0o755)
stripped=work/'stripped'
subprocess.run(['objcopy','--strip-debug',str(exe),str(stripped)],check=True,timeout=15)
evidence=[]
for target,expected in [(wrong,'LuaVersionUnsupported'),(stripped,'LuaDwarfUnavailable')]:
    process=subprocess.Popen([str(target),'tests/fixtures/lua/stopped.lua'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    client=None
    try:
        assert select.select([process.stdout],[],[],10)[0] and process.stdout.readline()==b'ready\n'
        client=Client('control',None,options=['--attach',str(process.pid)])
        client.action('set_breakpoint',symbol='xodb_lua_stop');client.action('continue')
        process.stdin.write(b'go\n');process.stdin.flush();client.stopped('breakpoint')
        before=client.inspect('get_registers',tid=process.pid);generation=client.session()['generation']
        result=client.tool('get_language_stack',tid=process.pid,language='lua')
        assert result.get('result',{}).get('isError') and result['result']['content'][0]['text']==expected,result
        assert client.inspect('get_registers',tid=process.pid)==before and client.session()['generation']==generation
        evidence.append({'case':target.name,'reason':expected,'session_usable':True})
    finally:
        if client:
            (work/(target.name+'-transcript.json')).write_text(json.dumps(client.transcript,indent=2)+'\n');client.close()
        if process.poll() is None:process.kill();process.wait(timeout=5)
        (work/(target.name+'-stderr.txt')).write_bytes(process.stderr.read())
        process.stdin.close();process.stdout.close();process.stderr.close()
(work/'results.json').write_text(json.dumps({'status':'pass','cases':evidence},indent=2)+'\n')
print('Lua wrong version and stripped layout refused; sessions usable')
