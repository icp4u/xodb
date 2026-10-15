#!/usr/bin/env python3
"""Fast: typed core control, old-view interrupt and direct observer refusal.

Runs headless on an owned fixture, locally or with XODB_RUNTIME_AGENT. Existing
run-control, breakpoint-policy and GUI input lanes cover source/finish/policy
parity; this checks the migrated request/reply and authority boundary itself.
"""
import json
import os
from pathlib import Path
import subprocess
import time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
started = time.monotonic()
work = root / '.work' / ('command-' + str(time.time_ns())[-9:])
work.mkdir(parents=True)
fixture = work / 'fixture'
subprocess.run(['cc', '-g', '-O0', 'tests/fixtures/m1.c', '-o', str(fixture)], check=True, timeout=30)
checks = []


def require(condition, label, detail=None):
    if not condition:
        raise AssertionError((label, detail))
    checks.append(label)


def refused(reply, name):
    result = reply.get('result', {})
    require(result.get('isError') and result.get('content') == [{'type': 'text', 'text': name}], name, reply)


client = Client('control', executable=str(fixture), args=('w',))
try:
    stopped = client.stopped()
    generation = stopped['generation']
    bp = client.action('set_breakpoint', symbol='change_value')
    require(bp['id'] > 0 and 'pending' in bp and 'process_id' in bp, 'typed symbolic reply', bp)
    refused(client.tool('continue', generation=generation), 'StaleSnapshot')
    client.action('continue')
    stopped = client.stopped('breakpoint')
    thread = next(t['tid'] for t in stopped['threads'] if t['reason'] == 'breakpoint')
    policy = client.action('configure_breakpoint', id=bp['id'], condition='1', ignore_count=2)
    require(policy['policy']['ignore_remaining'] == 2, 'typed policy reply', policy)
    client.action('remove_breakpoint', id=bp['id'])
    client.action('step_instruction', tid=thread)
    client.stopped('single_step')
    old = client.session()['generation']
    client.action('continue')
    deadline = time.monotonic() + 10
    while True:
        current = client.session()
        if current['state'] == 'running' and not current['continue_pending']:
            break
        require(time.monotonic() < deadline, 'running readiness', current)
        time.sleep(.002)
    require(current['generation'] != old, 'interrupt actually uses an old observation')
    client.inspect('interrupt', generation=old)
    client.stopped()
    require(True, 'old-view interrupt stops the owned target')
    audit = client.inspect('get_audit')['actions']
    require(any(row['action'] == 'interrupt' and row['actor'] == 'agent' for row in audit), 'typed command audit')
finally:
    (work / 'control.json').write_text(json.dumps(client.transcript, indent=2))
    client.close()

client = Client('observe', executable=str(fixture), args=('w',))
try:
    state = client.stopped()
    tid = state['threads'][0]['tid']
    operations = {
        'continue': {}, 'interrupt': {}, 'step_instruction': {'tid': tid},
        'step_over_instruction': {'tid': tid}, 'step_source': {'tid': tid},
        'step_over': {'tid': tid}, 'set_breakpoint': {'symbol': 'main'},
        'remove_breakpoint': {'id': 1}, 'configure_breakpoint': {'id': 1},
        'finish': {'tid': tid}, 'run_to': {'tid': tid, 'address': '0x1'},
        'restart': {}, 'detach': {},
    }
    for name, args in operations.items():
        refused(client.tool(name, generation=state['generation'], **args), 'AgentScopeDenied')
    require(not client.inspect('get_audit')['actions'], 'observer calls have no side effects or audit acceptance')
finally:
    (work / 'observer.json').write_text(json.dumps(client.transcript, indent=2))
    client.close()

report = {'status': 'pass', 'checks': checks, 'seconds': time.monotonic() - started}
(work / 'results.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report))
