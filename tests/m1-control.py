#!/usr/bin/env python3
"""Real MCP agents exercise symbol breakpoints, watch evidence, and scoped writes."""
from datetime import datetime
import json
import os
from pathlib import Path
import select
import subprocess
import time

os.chdir(Path(__file__).resolve().parents[1])
run = Path('.work') / ('m1-control-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir(parents=True)

from client import Client

for scope in ['control','mutate']:
    client = Client(scope)
    try:
        tools = client.call('tools/list')['result']['tools']
        names = {t['name'] for t in tools}
        assert ('write_memory' in names)==(scope=='mutate')
        old = client.session()['generation']
        function = client.inspect('find_symbol', name='change_value')
        state = client.inspect('find_symbol', name='state')
        breakpoint = client.action('set_breakpoint', symbol='change_value')['id']
        assert client.tool('continue',generation=old)['result']['isError']
        client.action('continue')
        stopped = client.stopped('breakpoint')
        tid = stopped['threads'][0]['tid']
        regs = client.inspect('get_registers',tid=tid)['registers']
        assert regs['rip']==function['address']
        assert client.inspect('evaluate_expression',tid=tid,expression='$rip + 1')['bits']==hex(int(regs['rip'],16)+1)
        assert client.tool('evaluate_expression',tid=tid,expression='item->value')['result']['isError']
        client.action('step_instruction',tid=tid)
        client.stopped('single_step')
        original = client.inspect('read_memory', address=state['address'],length=8)['hex']
        assert int.from_bytes(bytes.fromhex(original),'little')==7
        if scope=='control':
            result=client.tool('write_memory',address=state['address'],hex='0a00000000000000',generation=client.session()['generation'])
            assert result['result']['isError']
        else:
            client.action('write_memory',address=state['address'],hex='0a00000000000000')
            assert client.inspect('read_memory',address=state['address'],length=8)['hex']=='0a00000000000000'
            client.action('write_memory',address=state['address'],hex=original)
            client.action('write_register',tid=tid,name='rax',value=regs['rax'])
        client.action('remove_breakpoint',id=breakpoint)
        watch = client.action('set_watchpoint',address=state['address'],length=8)['id']
        for before,after in [(7,12),(12,21)]:
            client.action('continue')
            client.stopped('watchpoint')
            events = client.inspect('query_events')['events']
            hit = [e for e in events if e['kind']=='watchpoint_hit'][-1]
            assert (hit['before'],hit['after'])==(before,after),hit
            assert hit['pc']>0 and hit['address']==int(state['address'],16)
        client.action('remove_watchpoint',id=watch)
        audit=client.inspect('get_audit')['actions']
        assert any(a['actor']=='agent' and a['action']=='set_watchpoint' for a in audit)
        client.action('continue')
        deadline=time.monotonic()+5
        while client.session()['state']!='exited':
            assert time.monotonic()<deadline
            time.sleep(.002)
        events=client.inspect('query_events')['events']
        assert [e for e in events if e['kind']=='exit'][-1]['detail']==0
    finally:
        (run / (scope + '.json')).write_text(json.dumps({'question':'Why did state.value change?', 'scope':scope, 'before_semantics':'previous debugger sample, not an atomic pre-write read', 'pc_semantics':'post-instruction PC for data watchpoints', 'transcript':client.transcript}, indent=2)+'\n')
        client.close()

# Running over a real call must stop at its return address and retire its probe.
client = Client('control')
try:
    main = client.inspect('find_symbol',name='main')
    breakpoint = client.action('set_breakpoint',symbol='main')['id']
    client.action('continue')
    stopped = client.stopped('breakpoint')
    tid = stopped['threads'][0]['tid']
    client.action('remove_breakpoint',id=breakpoint)
    for _ in range(100):
        regs = client.inspect('get_registers',tid=tid)['registers']
        instruction = client.inspect('disassemble',address=regs['rip'])['instructions'][0]
        if instruction['mnemonic']=='call':
            after = int(instruction['address'],16)+instruction['size']
            client.action('step_over_instruction',tid=tid)
            client.stopped('breakpoint')
            assert int(client.inspect('get_registers',tid=tid)['registers']['rip'],16)==after
            assert not client.inspect('get_breakpoints')['breakpoints']
            break
        client.action('step_instruction',tid=tid)
        client.stopped('single_step')
    else: raise AssertionError('No call reached')
finally: client.close()

# exec invalidates physical locations; logical symbols remain pending.
client = Client('control',args=('exec',))
try:
    old = client.inspect('find_symbol',name='state')
    symbolic_id=client.action('set_breakpoint',symbol='change_value')['id']
    client.action('set_watchpoint',address=old['address'],length=8)
    client.action('continue')
    client.stopped('exec')
    probes = client.inspect('get_breakpoints')
    user_probes=[p for p in probes['breakpoints'] if not p['internal']]
    assert len(user_probes)==1 and user_probes[0]['id']==symbolic_id,probes
    assert user_probes[0]['pending'] and not user_probes[0]['patched'] and user_probes[0]['address']==0,probes
    assert all(w is None for w in probes['watchpoints'])
    assert len([e for e in client.inspect('query_events')['events'] if e['kind']=='image_replaced'])==2
finally: client.close()
print(f'Recorded MCP evidence: {run}')
print('M1 control passed: symbol breakpoints, stepping, two watch writes, stale commands, scope enforcement, mutation and audit')
