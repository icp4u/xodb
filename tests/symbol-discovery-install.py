#!/usr/bin/env python3
"""Install the first-call breakpoint even when the final file read ends its slice."""
import argparse
import atexit
import importlib.util
import json
import os
from pathlib import Path
import time

from helpers.symbols import build_sparse_library

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reply-delay-ms',type=float,default=0)
parser.add_argument('--read-delay-ms',type=float,default=30)
parser.add_argument('--rate',type=int,default=1024*1024)
parser.add_argument('--timeout',type=float,default=45)
parser.add_argument('--cases',nargs='+',choices=['complete','interrupt','address-restart'],default=['complete','interrupt','address-restart'])
args=parser.parse_args()
assert args.reply_delay_ms>=0 and args.read_delay_ms>=0 and args.rate>0 and args.timeout>0
root = Path(__file__).resolve().parents[1]
os.chdir(root)
spec = importlib.util.spec_from_file_location('shared', root/'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
work = root/'.work'/('symbol-install-' + str(time.time_ns()))
work.mkdir(parents=True, mode=0o755)
fixture, library, known = build_sparse_library(root, work)
atexit.register(library.unlink, missing_ok=True)
os.environ['XODB_DISCOVERY_AGENT'] = os.environ.get('XODB_DISCOVERY_AGENT',str(root/'zig-out/bin/xodb-agent'))
os.environ['XODB_DISCOVERY_RATE'] = str(args.rate)
# By default even the last short read crosses the 25 ms slice deadline.
os.environ['XODB_DISCOVERY_FILE_DELAY'] = str(args.read_delay_ms/1000)
os.environ['XODB_DISCOVERY_REPLY_DELAY'] = str(args.reply_delay_ms/1000)
proxy = root/'tests/fixtures/symbol-agent-proxy.py'
results = {'file_bytes': library.stat().st_size, 'cases': [], 'reply_delay_ms':args.reply_delay_ms,'read_delay_ms':args.read_delay_ms,'rate':args.rate}

def settled(s):
    return s['state'] == 'stopped' and not s['continue_pending'] and not s['symbol_discovery_pending']

def action(client, name, **args):
    for _ in range(20):
        reply = client.raw(name, generation=client.session()['generation'], **args)
        if reply.get('result', {}).get('isError') and reply['result']['content'][0]['text'] == 'StaleSnapshot':
            continue
        assert not reply.get('error') and not reply['result']['isError'], reply
        return reply['result']['structuredContent']
    raise AssertionError('generation never stabilized')

for case in args.cases:
    case_work = work/case
    case_work.mkdir(mode=0o755)
    server = shared.Server(root, case_work, Path(os.environ.get('XODB_BIN',str(root/'zig-out/bin/xodb'))), fixture, 'control',
                           options=['--runtime-agent', str(proxy)], fixture_args=[str(library)])
    row = {'case': case, 'states': []}
    results['cases'].append(row)
    try:
        one = shared.Client(server, 'owner')
        initial = one.session()
        server.remember_target(initial)
        one.tool('claim_session_control', ttl_ms=60000)
        action(one, 'run_to', tid=initial['pid'], address=known['symbols_ready'])
        shared.eventually(one.session, lambda s: settled(s) and s['running_to'] is None,
                          'library ready', timeout=20)
        symbol_name = 'sparse_symbol_hit'
        if case == 'address-restart':
            symbol_name = 'symbols_ready'
            bp = action(one, 'set_breakpoint', address=known['symbols_ready'])
            action(one, 'restart')
            server.remember_target(one.session())
        else:
            bp = action(one, 'set_breakpoint', symbol=symbol_name)
            assert bp['pending'], bp
        queued = action(one, 'continue')['session']
        assert queued['state'] == 'stopped' and queued['continue_pending'], queued
        if case == 'interrupt': action(one, 'interrupt')
        start = time.monotonic()
        while time.monotonic() - start < args.timeout:
            state = one.session()
            probes = one.tool('get_breakpoints')
            actual = next(p for p in probes['breakpoints'] if p['id'] == bp['id'])
            definition = next(p for p in probes['definitions'] if p['id'] == bp['id'])
            row['states'].append({'state': state, 'breakpoint': actual, 'definition': definition})
            if not state['symbol_discovery_pending']:
                assert not (actual['pending'] and definition['diagnostic'] in
                            ('SymbolDiscoveryPending', 'SymbolDiscoveryBudgetExceeded')), row
            if settled(state): break
        else: raise AssertionError(('discovery never completed', row))
        assert not actual['pending'], row
        if case == 'interrupt':
            assert actual['hit_count'] == 0 and not state['continue_pending'], row
            time.sleep(.1)
            assert one.session()['state'] == 'stopped'
            action(one, 'continue')
            state = shared.eventually(one.session, lambda s: settled(s) and
                                      any(t['reason'] == 'breakpoint' for t in s['threads']),
                                      'fresh continue first hit', timeout=10)
        assert any(t['reason'] == 'breakpoint' for t in state['threads']), row
        symbol_reply = one.call('tools/call', {'name': 'find_symbol', 'arguments': {'name': symbol_name}})['result']
        assert not symbol_reply['isError'], symbol_reply
        symbol = symbol_reply['structuredContent']
        regs = one.tool('get_registers', tid=state['pid'])
        counter = one.tool('read_memory', address=known['reached'], length=4)
        assert int(symbol['address'], 16) == actual['address'] == int(regs['registers']['rip'], 16)
        assert counter['hex'] == '00000000', counter
        row.update(symbol=symbol, registers=regs, counter=counter, seconds=time.monotonic()-start)
        server.stop_and_check()
    finally:
        server.close()
        (work/'results.json').write_text(json.dumps(results, indent=2) + '\n')
print('Budget-ending reads install first-call breakpoints, including Interrupt and address restart:', work)
