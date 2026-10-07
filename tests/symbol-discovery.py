#!/usr/bin/env python3
"""Owned >256 MiB executables; cooperative symbol discovery and lease revocation.

The local stdio proxy models 1 MiB/s plus 2 ms reply latency. No SSH service,
privilege, external process or interactive display is involved.
"""
import atexit
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
spec = importlib.util.spec_from_file_location('shared', root/'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
work = root/'.work'/('symbols-'+str(time.time_ns()))
work.mkdir(parents=True, mode=0o755)
from helpers.symbols import build
fixture, known = build(root, work)
atexit.register(fixture.unlink, missing_ok=True)
os.environ['XODB_DISCOVERY_AGENT'] = str(root/'zig-out/bin/xodb-agent')
proxy = root/'tests/fixtures/symbol-agent-proxy.py'
results = {'file_bytes':fixture.stat().st_size, 'cases':[]}

def settled(s):
    return s['state']=='stopped' and not s.get('continue_pending') and not s.get('symbol_discovery_pending')

def action(client, name, **args):
    for _ in range(20):
        reply = client.raw(name, generation=client.session()['generation'], **args)
        if reply.get('result',{}).get('isError') and reply['result']['content'][0]['text']=='StaleSnapshot': continue
        assert not reply.get('error') and not reply['result']['isError'],reply
        return reply['result']['structuredContent']
    raise AssertionError('generation never stabilized')

for case in ('complete','renew','release-reclaim','expiry','interrupt','disconnect','generation'):
    case_work=work/case;case_work.mkdir(mode=0o755)
    server=shared.Server(root,case_work,root/'zig-out/bin/xodb',fixture,'control',
                         options=['--runtime-agent',str(proxy)],fixture_args=[])
    row={'case':case,'latencies':[]}
    results['cases'].append(row)
    try:
        one,two=shared.Client(server,'owner'),shared.Client(server,'observer')
        first=one.session();server.remember_target(first)
        one.tool('claim_session_control',ttl_ms=60000)
        started=time.monotonic()
        bp=action(one,'set_breakpoint',symbol='large_symbol_hit')
        row['set_seconds']=time.monotonic()-started
        assert bp['pending'],bp
        queued=action(one,'continue')['session']
        assert queued['continue_pending'] and queued['state']=='stopped',queued
        if case=='renew':
            one.tool('claim_session_control',ttl_ms=60000)
        elif case=='disconnect':
            one.close()
        elif case=='generation':
            action(one,'set_breakpoint',address=known['alias_target'])
        elif case=='release-reclaim':
            # Same client regaining control must not resurrect the prior intent.
            one.tool('release_session_control')
            one.tool('claim_session_control',ttl_ms=60000)
        elif case=='expiry':
            one.tool('claim_session_control',ttl_ms=100)
        elif case=='interrupt':
            action(one,'interrupt')
        deadline=time.monotonic()+45
        saw_pending=False
        while time.monotonic()<deadline:
            t=time.monotonic();state=two.session();row['latencies'].append(time.monotonic()-t)
            if state['symbol_discovery_pending']:
                saw_pending=True
                assert state['state']=='stopped',state
            if settled(state):break
        else:raise AssertionError(('discovery never completed',state))
        assert saw_pending
        assert max(row['latencies']) < .6, row
        row['max_observer_seconds']=max(row['latencies'])
        row['final']=state
        if case in ('complete','renew'):
            assert any(t['reason']=='breakpoint' for t in state['threads']),state
            resolved=two.tool('get_breakpoints')
            actual=next(p for p in resolved['breakpoints'] if p['id']==bp['id'])
            assert not actual['pending'],actual
            symbol=two.call('tools/call',{'name':'find_symbol','arguments':{'name':'large_symbol_hit'}})['result']['structuredContent']
            regs=two.tool('get_registers',tid=state['pid'])
            row['symbol']=symbol;row['registers']=regs
            assert int(symbol['address'],16)==actual['address'],(symbol,actual)
            assert int(regs['registers']['rip'],16)==actual['address'],regs
            counter=two.tool('read_memory',address=known['reached'],length=4)
            assert counter['hex']=='00000000',counter  # no missed first hit
            row['counter']=counter
            # The full-file path remains capped without failing the connection.
            row['stack']=two.tool('get_stack',tid=state['pid'])
            assert two.session()['pid']==state['pid']
            assert resolved['symbol_transfer']['retained_bytes'] < 8*1024*1024,resolved
            row['transfer']=resolved['symbol_transfer']
        else:
            assert not state['continue_pending']
            assert all(t['reason']!='breakpoint' for t in state['threads']),state
            time.sleep(.1)
            assert two.session()['state']=='stopped'
            if case=='expiry':one.tool('claim_session_control',ttl_ms=60000)
            control=one
            if case=='disconnect':
                two.tool('claim_session_control',ttl_ms=60000)
                control=two
            # Cancellation kept the session usable; a fresh command may resume.
            action(control,'continue')
            final=shared.eventually(two.session,lambda s:settled(s) and any(t['reason']=='breakpoint' for t in s['threads']), 'fresh continue',timeout=10)
            row['fresh_continue']=final
    finally:
        server.close()
        (work/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print('Large-file symbols, bounded observer latency, deferred continue and lease cancellation passed:',work)
