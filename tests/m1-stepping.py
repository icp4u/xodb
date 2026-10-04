#!/usr/bin/env python3
"""Source next/step, C++ values, stripped and malformed-debug availability."""
from datetime import datetime
import os
from pathlib import Path
import subprocess
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('m1-stepping-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir(parents=True)
env = dict(os.environ, TMPDIR=str(root / '.work/tmp'))
source = root/'tests/fixtures/m1.c'
lines = source.read_text().splitlines()
first = next(i for i,s in enumerate(lines,1) if 'FIRST_CALL' in s)
second = next(i for i,s in enumerate(lines,1) if 'SECOND_CALL' in s)
write = next(i for i,s in enumerate(lines,1) if 'WATCH_WRITE' in s)
binary = run/'steps'
subprocess.run(['gcc','-g','-O0',str(source),'-o',str(binary)],env=env,check=True)
client = Client('control',str(binary))
try:
    probes = client.action('set_breakpoint',file=str(source),line=first)['ids']
    client.action('continue')
    tid = client.stopped('breakpoint')['threads'][0]['tid']
    for probe in probes: client.action('remove_breakpoint',id=probe)
    client.action('step_over',tid=tid)
    snap=client.stopped()
    assert not snap['source_stepping'] and not snap['step_diagnostic'], snap
    regs=client.inspect('get_registers',tid=tid)['registers']
    assert client.inspect('get_source_location',address=regs['rip'])['source']['line']==second
    assert client.inspect('evaluate_expression',tid=tid,expression='state.value')['value']['display']=='12'
    assert not client.inspect('get_breakpoints')['breakpoints']
    client.action('step_source',tid=tid)
    snap=client.stopped()
    assert not snap['source_stepping'] and not snap['step_diagnostic']
    assert client.inspect('get_stack',tid=tid)['frames'][0]['symbol']=='change_value'
finally: client.close()

# C++ methods and modifiers use the same basic type/location model.
cpp = root/'tests/fixtures/m1.cpp'
cpp_line = next(i for i,s in enumerate(cpp.read_text().splitlines(),1) if 'CPP_BREAK' in s)
for compiler in ['g++','clang++']:
    executable=run/compiler
    subprocess.run([compiler,'-g','-gdwarf-5','-O0',str(cpp),'-o',str(executable)],env=env,check=True)
    client=Client('control',str(executable))
    try:
        client.action('set_breakpoint',file=str(cpp),line=cpp_line)
        client.action('continue')
        tid=client.stopped('breakpoint')['threads'][0]['tid']
        for expression, expected in [('this->value','7'),('amount','5'),('next','12'),('this->value + amount','12'),('values[1]','4')]:
            result=client.inspect('evaluate_expression',tid=tid,expression=expression)['value']
            assert result['display']==expected,(compiler,expression,result)
    finally: client.close()

# Stripping removes source/locals but keeps usable unwind information.
stripped=run/'stripped'
subprocess.run(['objcopy','--strip-debug',str(binary),str(stripped)],check=True,env=env)
client=Client('control',str(stripped))
try:
    client.action('set_breakpoint',symbol='change_value')
    client.action('continue')
    tid=client.stopped('breakpoint')['threads'][0]['tid']
    frames=client.inspect('get_stack',tid=tid)['frames']
    assert len(frames)>=2 and frames[0]['source'] is None
    assert client.tool('list_locals',tid=tid)['result']['isError']
    assert client.inspect('evaluate_expression',tid=tid,expression='$rip')['availability']=='available'
finally: client.close()

# Keep the executable loadable while truncating only debug_info.
section=run/'broken.info'
section.write_bytes(b'\x20\x00\x00\x00\x05')
broken=run/'broken-debug'
subprocess.run(['objcopy','--update-section',f'.debug_info={section}',str(binary),str(broken)],check=True,env=env)
client=Client('control',str(broken))
try:
    client.action('set_breakpoint',symbol='change_value')
    client.action('continue')
    tid=client.stopped('breakpoint')['threads'][0]['tid']
    assert client.tool('list_locals',tid=tid)['result']['isError']
    assert len(client.inspect('get_stack',tid=tid)['frames'])>=2
finally: client.close()
print(f'M1 source stepping, C++ values, stripped CFI and malformed debug checks passed. Artifacts: {run}')
