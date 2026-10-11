#!/usr/bin/env python3
"""Fast host oracle: a lost mutation reply must report RemoteOutcomeUnknown.

A fault-injecting agent proxy sits between a headless xodb owner and the real
xodb-agent. For each (tool, fault) it lets the agent execute the mutation,
records the agent's own status, then loses/truncates/corrupts the reply (or
drops the request before the agent sees it). The MCP client's answer is then
compared with what the proxy knows really happened.

The default runs each operation once. --matrix adds truncated/corrupt replies
and a request dropped before forwarding, in the periodic lane.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import struct
import sys
import time


def proxy(directory, agent):
    from helpers.agent_proxy import relay, write
    directory = Path(directory)
    fault = json.loads((directory/'fault.json').read_text())
    hit = None
    def log(row):
        with (directory/'events.jsonl').open('a') as out:
            out.write(json.dumps(row)+'\n')
    def request(row):
        nonlocal hit
        armed = (directory/'arm').exists() and hit is None and row['op'] == fault['op']
        if armed:
            hit = row['request']
            forwarded = fault['mode'] != 'eof_before_forward'
            log(dict(op=row['op'], request=hit, forwarded=forwarded))
            return forwarded
        if (directory/'arm').exists() and row['op'] == fault['op']:
            log(dict(op=row['op'], request=row['request'], forwarded=True, replay=True))
        return True
    def reply(row):
        data = row['header']+row['body']
        if row['request'] == hit and row['op'] == fault['op']:
            log(dict(op=row['op'], request=hit, agent_status=row['status'], reply_bytes=len(data)))
            if fault['mode'] == 'drop_reply':
                return None
            if fault['mode'] == 'truncate_reply':
                write(1, data[:16])
                return None
            if fault['mode'] == 'bad_reply':
                data = data[:8]+struct.pack('>Q', hit+7)+data[16:]
        return data
    relay(agent, request, reply)


def drive(args):
    root = Path(__file__).resolve().parents[1]
    binary = (Path(args.binary) if args.binary else root/'zig-out/bin/xodb').resolve()
    work = Path(args.work).resolve()
    work.mkdir(mode=0o755, parents=True, exist_ok=False)
    sys.path.insert(0, str(root/'tests'))
    spec = importlib.util.spec_from_file_location('shared_sessions', root/'tests/shared-sessions.py')
    shared = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shared)
    shared.TIMEOUT = 10
    enum = (root/'src/runtime/rpc.h').read_text().split('enum xrt_rpc_op {', 1)[1].split('};', 1)[0]
    ops = {name: index+1 for index, name in enumerate(re.findall(r'XRT_RPC_[A-Z_]+', enum))}
    # The loader hook is also a mutation inside set_breakpoint; its unknown
    # outcome must not be hidden by optional loader discovery.
    cases = [('write_memory', 'XRT_RPC_WRITE'), ('set_breakpoint', 'XRT_RPC_BP_RESERVE'),
             ('set_breakpoint', 'XRT_RPC_BP_RESOLVE'), ('set_breakpoint', 'XRT_RPC_BP_SET'), ('set_breakpoint', 'XRT_RPC_BP_INTERNAL'), ('remove_breakpoint', 'XRT_RPC_BP_REMOVE'),
             ('step_instruction', 'XRT_RPC_STEP'), ('continue', 'XRT_RPC_CONTINUE')]
    cases = [c for c in cases if not args.only or c[0] in args.only.split(',')]
    modes = ['drop_reply', 'truncate_reply', 'bad_reply', 'eof_before_forward'] if args.matrix else ['drop_reply']
    rows, bad = [], 0
    for tool, op in cases:
        for mode in modes:
            case = work/f'{len(rows):02}'
            case.mkdir(mode=0o755)
            (case/'fault.json').write_text(json.dumps({'op': ops[op], 'mode': mode}))
            wrapper = case/'agent'
            wrapper.write_text('#!/bin/sh\nexec '+' '.join(map(shlex.quote, [sys.executable, '-B', str(Path(__file__).resolve()),
                               '--proxy', str(case), str(binary.with_name('xodb-agent'))]))+'\n')
            wrapper.chmod(0o755)
            os.environ['XODB_RUNTIME_AGENT'] = str(wrapper)
            server = None
            row = {'tool': tool, 'op': op, 'mode': mode}
            try:
                server = shared.Server(root, case, binary, binary.with_name('xodb-m1-fixture'), 'mutate')
                client = shared.Client(server, 'chaos')
                snapshot = client.session()
                server.remember_target(snapshot)
                client.claim()
                address = client.raw('find_symbol', name='state')['result']['structuredContent']['address']
                tid = client.tool('list_threads')['threads'][0]['tid']
                arguments = {'write_memory': {'address': address, 'hex': '6300000000000000'},
                             'set_breakpoint': {'symbol': 'main'}, 'remove_breakpoint': {'id': 0}, 'step_instruction': {'tid': tid}, 'continue': {}}[tool]
                if tool == 'remove_breakpoint':
                    arguments = {'id': client.action('set_breakpoint', symbol='main')['id']}
                generation = client.session()['generation']
                (case/'arm').touch()
                started = time.monotonic()
                reply = client.call('tools/call', {'name': tool, 'arguments': {'generation': generation, **arguments}})
                row['seconds'] = round(time.monotonic()-started, 3)
                text = json.dumps(reply)
                row['reply'] = text[:300]
                (case/'reply.json').write_text(text)
                events = [json.loads(line) for line in (case/'events.jsonl').read_text().splitlines()] if (case/'events.jsonl').exists() else []
                row['events'] = events
                hit = [e for e in events if not e.get('unarmed')]
                row['fault_fired'] = bool(hit)
                forwarded = any(e.get('forwarded') for e in hit)
                is_error = 'error' in reply or reply['result'].get('isError')
                row['unknown'] = 'RemoteOutcomeUnknown' in text
                if args.wrong_result and not rows:
                    row['unknown'] = not row['unknown']
                row['agent_applied'] = any(e.get('agent_status') == 0 for e in hit)
                # Truth rule: once the request reached the agent, the only honest
                # non-success answer is RemoteOutcomeUnknown.
                row['honest'] = row['fault_fired'] and (row['unknown'] and row['agent_applied'] if forwarded else is_error)
                # No replay: the faulted op must appear exactly once, and the owner survives.
                again = client.call('tools/call', {'name': 'get_session', 'arguments': {}})
                if tool == 'set_breakpoint':
                    (case/'breakpoints.json').write_text(json.dumps(client.call('tools/call', {'name': 'get_breakpoints', 'arguments': {}})))
                row['after'] = json.dumps(again)[:160]
                row['owner_alive'] = server.proc.poll() is None
                events = [json.loads(line) for line in (case/'events.jsonl').read_text().splitlines()]
                row['requests_of_op'] = sum(1 for e in events if 'forwarded' in e)
                row['ok'] = row['honest'] and row['requests_of_op'] == 1 and row['owner_alive']
            except BaseException as error:  # record, continue with the next case
                row['exception'] = repr(error)[:300]
                row['ok'] = False
            finally:
                if server:
                    server.close()
                    row['exit'] = server.proc.returncode
                    row['log_tail'] = (server.work/'server.log').read_text()[-300:]
            bad += not row['ok']
            rows.append(row)
            print(json.dumps(row), flush=True)
    (work/'result.json').write_text(json.dumps(rows, indent=1)+'\n')
    print(f'chaos: {len(rows)-bad}/{len(rows)} honest')
    return 1 if bad else 0


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--proxy':
        proxy(sys.argv[2], sys.argv[3])
    else:
        parser = argparse.ArgumentParser()
        parser.add_argument('--work', required=True)
        parser.add_argument('--binary')
        parser.add_argument('--matrix', action='store_true')
        parser.add_argument('--wrong-result', action='store_true')
        parser.add_argument('--only')
        raise SystemExit(drive(parser.parse_args()))
