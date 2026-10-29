#!/usr/bin/env python3
"""Fast opt-in census MCP, immutable paging, refresh, scope and refusal checks.
Root is never requested: a caller may separately run the live probe in an owned
guest or privileged test environment. Only this script's own tasks are asserted.
"""
import os
from pathlib import Path
import sys
import time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)

def check(label, condition):
    if not condition:
        raise AssertionError(label)
    print('PASS ' + label, flush=True)

def until(probe, condition):
    deadline = time.monotonic() + 15
    while True:
        value = probe()
        if condition(value):
            return value
        if time.monotonic() >= deadline:
            raise AssertionError('census did not settle')
        time.sleep(.01)

client = Client('observe', executable=None, options=['--overview', '--kernel-pid', str(os.getpid())])
try:
    initial = client.inspect('get_kernel_stacks', refresh=False)
    check('cold passive read starts no worker', initial['sequence'] == 0 and not initial['pending'])
    result = until(lambda: client.inspect('get_kernel_stacks'), lambda r: r.get('status') == 'ready')
    check('scope and complete accounting', result['scope_pid'] == os.getpid() and result['task_count'] >= 1 and
          sum(g['count'] for g in result['groups']) == result['task_count'] and not result['truncated'])
    seq = result['sequence']
    check('non-atomic observation is explicit', result['atomic_snapshot'] is False)
    for group in result['groups']:
        members = client.inspect('get_kernel_stacks', refresh=False, sequence=seq, group=group['id'])
        check('group membership stays in owned scope', members['member_count'] == group['count'] and
              all(t['pid'] == os.getpid() and t['start_ticks'] > 0 for t in members['members']))
        check('task state is a single letter', all(isinstance(t['state'], str) and len(t['state']) == 1 for t in members['members']))
        check('unreadable is not a fake empty success', group['status'] in ('ready', 'empty', 'denied'))
    cached = client.inspect('get_kernel_stacks', refresh=False, sequence=seq, limit=1)
    check('passive pagination keeps generation', cached['sequence'] == seq and len(cached['groups']) == 1)
    stale = client.tool('get_kernel_stacks', refresh=False, sequence=seq + 999)
    check('stale pages refuse', stale['result']['isError'] and stale['result']['content'][0]['text'] == 'StaleCensus')
    wrong = client.tool('get_kernel_stacks', limit=33)
    check('reply bound refuses oversize', wrong.get('error', {}).get('code') == -32602)
    user = client.inspect('get_kernel_stacks', refresh=False, user_tid=os.getpid())
    check('no implicit user attach', user['user_stack']['status'] == 'ThreadNotInLocalDebugger')
    refreshed = until(lambda: client.inspect('get_kernel_stacks'), lambda r: r['sequence'] > seq)
    check('explicit demand refreshes', refreshed['sequence'] > seq)
    if '--plant' in sys.argv:
        check('planted wrong scope must fail', refreshed['scope_pid'] == -1)
finally:
    client.close()

import threading
threading.Thread(target=threading.Event().wait, daemon=True).start()  # an owned sleeper has a wait channel
client = Client('observe', executable=None, options=['--overview', '--redact', '--kernel-pid', str(os.getpid())])
try:
    result = until(lambda: client.inspect('get_kernel_stacks'), lambda r: r.get('status') == 'ready')
    members = [m for g in result['groups'] for m in client.inspect(
        'get_kernel_stacks', refresh=False, sequence=result['sequence'], group=g['id'])['members']]
    check('redaction hides task names only', members and all(m['comm'] == '<redacted>' for m in members) and
          any(m['wchan'] and m['wchan'] != '<redacted>' for m in members) and
          all(g['stack'] != '<redacted>' for g in result['groups']))
finally:
    client.close()
