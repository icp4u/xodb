#!/usr/bin/env python3
"""Read-only Lua views against an owned, statically linked debug host."""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import struct
import threading
from client import Client
from helpers.readonly import audit

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source', required=True, help='Matching Lua internal source header directory')
p.add_argument('--library', required=True, help='Matching Lua static library with DWARF')
p.add_argument('--cpp-host', action='store_true', help='Embed Lua in a C++ host with unrelated Node/Table/Proto types')
p.add_argument('--lua', help='Test an installed interpreter using a probe module instead of the embedded host')
p.add_argument('--strace', action='store_true', help='Audit observer operations on the owned stopped fixture')
p.add_argument('--adversarial', action='store_true', help='Mutate and restore only the owned fixture to check explicit refusals')
p.add_argument('--work', required=True, type=Path)
args = p.parse_args()
root = Path(__file__).resolve().parent.parent
os.chdir(root)
os.umask(0o022)
work = args.work.resolve()
work.mkdir(parents=True, mode=0o755)
exe = work/'lua-host'
command = [os.environ.get('CC', 'cc'), '-std=c11', '-g', '-O0', '-fno-omit-frame-pointer',
    '-fno-optimize-sibling-calls', '-Wall', '-Wextra', '-Werror', '-I'+args.source,
    'tests/fixtures/lua/host.c']
if args.cpp_host:
    assert not args.lua, 'C++ embedding and an installed interpreter are separate fixtures'
    obj=work/'probe.o'
    subprocess.run(command+['-Dmain=lua_host_main','-c','-o',str(obj)],check=True,timeout=90)
    subprocess.run(['c++','-g','-O0','-fno-eliminate-unused-debug-types',
        'tests/fixtures/lua/embedded.cc',str(obj),args.library,'-lm','-ldl','-o',str(exe)],check=True,timeout=90)
else:
    command += ['-DXODB_LUA_MODULE', '-shared', '-fPIC'] if args.lua else [args.library, '-lm', '-ldl']
    subprocess.run(command+['-o', str(exe)], check=True, timeout=90)
launch = [args.lua, 'tests/fixtures/lua/driver.lua', str(exe), 'tests/fixtures/lua/stopped.lua'] if args.lua else [str(exe), 'tests/fixtures/lua/stopped.lua']
target = subprocess.Popen(launch, stdin=subprocess.PIPE,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
lines = queue.Queue()
def drain():
    for line in target.stdout:
        lines.put(line)
thread = threading.Thread(target=drain, daemon=True)
thread.start()
client = None
rows = []
audits = []
try:
    assert lines.get(timeout=10) == 'ready\n'
    client = Client('mutate' if args.adversarial else 'control', None, options=['--attach', str(target.pid)])
    tool = next(t for t in client.call('tools/list')['result']['tools'] if t['name']=='get_language_stack')
    assert tool['annotations']['readOnlyHint'] and tool['annotations']['xodbSessionAccess']=='observer'
    assert 'lua' in tool['inputSchema']['properties']['language']['enum']
    client.action('set_breakpoint', symbol='xodb_lua_stop')
    client.action('continue')
    target.stdin.write('go\n'); target.stdin.flush()
    for _ in range(23):
        stopped = client.stopped('breakpoint')
        ground = json.loads(lines.get(timeout=10))
        registers = client.inspect('get_registers', tid=target.pid)
        value = client.inspect('evaluate_expression', tid=target.pid, frame=0, expression='value')['value']
        state = client.inspect('evaluate_expression', tid=target.pid, frame=0, expression='L')['value']
        stack = client.inspect('get_language_stack', tid=target.pid, language='lua')
        local = client.inspect('list_locals', tid=target.pid, frame=0)
        assert client.inspect('get_registers', tid=target.pid) == registers
        assert client.session()['generation'] == stopped['generation']
        assert value['visualization']['lua'], value
        if value['diagnostic'] is not None:
            assert value['visualization']['lua']['advisory'] and value['diagnostic'] in ('LuaStringExtentUnproved','LuaTableExtentUnproved'), value
        assert state['diagnostic'] is None and state['visualization']['lua']['type']=='thread', state
        assert any(v['name']=='value' and v['value']['display']==value['display'] for v in local['locals'])
        assert len({s['runtime_instance']['address'] for s in stack['segments']})==len(stack['segments'])
        seg=next(s for s in stack['segments'] if s['runtime_instance']['address']==hex(state['bits']))
        assert seg['runtime']['version'] in ('5.4.9','5.2.4') and seg['runtime']['layout_source']=='same-image DWARF'
        assert seg['runtime_instance']['address']==hex(state['bits'])
        assert len(seg['frames'])==len(ground['frames']), (stack,ground)
        for actual, expected in zip(seg['frames'],ground['frames']):
            assert (actual['kind']=='C')==(expected['kind']=='C'), (actual,expected)
            if actual['kind']=='Lua':
                assert (actual['file'],actual['line'])==(expected['file'],expected['line']), (actual,expected)
        assert seg['state']=='partial' and seg['reason']
        manual=client.inspect('get_language_stack',tid=target.pid,language='lua',state=hex(state['bits']))
        assert len(manual['segments'])==1, manual
        assert manual['segments'][0]['frames']==seg['frames']
        if ground['label']=='table':
            native=client.inspect('get_stack',tid=target.pid)['frames']
            # The outer startup frame has no Lua parameter or usable debug
            # locals. An explicitly supplied state must remain inspectable.
            outer=client.inspect('get_language_stack',tid=target.pid,language='lua',state=hex(state['bits']),frame=len(native)-1)
            assert outer['segments'][0]['frames']==seg['frames'] and outer['segments'][0]['anchor'] is None,outer
            assert outer['native_argument_diagnostics'],outer
        value_stack = None
        if 'value_frames' in ground:
            pointer=value['visualization']['lua']['object']
            value_stack=client.inspect('get_language_stack',tid=target.pid,language='lua',state=hex(pointer))
            assert len(value_stack['segments'])==1
            part=value_stack['segments'][0]
            assert len(part['frames'])==len(ground['value_frames']), (part,ground)
            for actual,expected in zip(part['frames'],ground['value_frames']):
                assert (actual['kind']=='C')==(expected['kind']=='C')
                if actual['kind']=='Lua':
                    assert (actual['file'],actual['line'])==(expected['file'],expected['line']), (actual,expected)
            if ground['label']=='suspended_coroutine':
                assert part['reason']=='LuaCoroutineSuspended' and part['anchor'] is None, part
        rows.append({'ground':ground,'value':value,'state':state,'stack':stack,'value_stack':value_stack})
        if args.strace and ground['label'] in ('table','suspended_coroutine'):
            def observe():
                client.inspect('get_language_stack',tid=target.pid,language='lua')
                client.inspect('evaluate_expression',tid=target.pid,frame=0,expression='value')
                if ground['label']=='suspended_coroutine':
                    client.inspect('get_language_stack',tid=target.pid,language='lua',state=hex(value['visualization']['lua']['object']))
            audits.append(audit(client,target.pid,work/(ground['label']+'.strace'),observe))
        if args.adversarial and ground['label']=='table':
            offsets=ground['offsets']
            ci=int(seg['frames'][0]['call_info'],16)
            lua_ci=int(next(f for f in seg['frames'] if f['kind']=='Lua')['call_info'],16)
            ident=client.inspect('find_symbol',name='lua_ident')['address']
            if isinstance(ident,str):ident=int(ident,0)
            def expect_cycle():
                result=client.inspect('get_language_stack',tid=target.pid,language='lua')
                assert result['segments'][0]['reason']=='LuaCallInfoCycle',result
            def expect_pc():
                result=client.inspect('get_language_stack',tid=target.pid,language='lua')
                assert any(f['reason']=='LuaSavedPcInvalid' for f in result['segments'][0]['frames']),result
            def expect_value(why):
                result=client.inspect('evaluate_expression',tid=target.pid,frame=0,expression='value')['value']
                assert result['diagnostic']==why,result
            cases=[(ci+offsets['ci_prev'],struct.pack('<Q',ci),expect_cycle),
                (lua_ci+offsets['ci_pc'],struct.pack('<Q',1),expect_pc),
                (value['bits']+offsets['tag'],(255).to_bytes(offsets['tag_size'],'little'),lambda:expect_value('LuaTagUnsupported')),
                (ident,b'!',lambda:expect_value('LuaVersionMismatch'))]
            for address,data,check in cases:
                original=client.inspect('read_memory',address=hex(address),length=len(data))['hex']
                try:
                    client.action('write_memory',address=hex(address),hex=data.hex());check()
                finally:
                    client.action('write_memory',address=hex(address),hex=original)
            after=client.inspect('get_language_stack',tid=target.pid,language='lua')
            assert after['segments'][0]['frames']==seg['frames']
            assert client.inspect('evaluate_expression',tid=target.pid,frame=0,expression='value')['value']['display']==value['display']
        client.action('continue')
    target.wait(timeout=10)
    assert target.returncode==0, target.stderr.read()
    values={row['ground']['label']:row['value'] for row in rows}
    prefix='integer ' if rows[0]['ground']['version']=='Lua 5.4.9' else 'number '
    expected={'nil':'nil','false':'false','true':'true','integer':prefix+'42','negative':prefix+'-73',
        'number':'number 3.5','string':'string "hi"','bytes':'string "a\\x00b\\xff"'}
    for key,display in expected.items():
        assert values[key]['display']==display,(key,values[key])
    assert values['long']['visualization']['truncated'] and values['long']['visualization']['count']==300
    assert values['long']['diagnostic']=='LuaStringExtentUnproved' and values['long']['visualization']['lua']['advisory']
    items=values['table']['visualization']['lua']['items']
    assert {(i['key'],i['display']) for i in items}=={('[1]',prefix+'1'),('[2]',prefix+'2'),('string "x"','string "hi"')},items
    closure=values['closure']['visualization']['lua']
    assert [(i['key'],i['display']) for i in closure['items']]==[('captured',prefix+'73')],closure
    assert values['userdata']['display']=='userdata (16 bytes)'
    (work/'results.json').write_text(json.dumps({'status':'pass','rows':rows,'audits':audits},indent=2)+'\n')
    print('Lua live values and exact frame positions passed:',len(rows),'stops')
except BaseException:
    (work/'results.json').write_text(json.dumps({'status':'fail','rows':rows,'audits':audits},indent=2)+'\n')
    raise
finally:
    if client:
        (work/'transcript.json').write_text(json.dumps(client.transcript,indent=2)+'\n')
        client.close()
    if target.poll() is None:
        target.kill(); target.wait(timeout=10)
    thread.join(timeout=5)
    (work/'stderr.txt').write_text(target.stderr.read())
    target.stdin.close(); target.stdout.close(); target.stderr.close()
