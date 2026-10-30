#!/usr/bin/env python3
"""A stopped local debugger thread exposes user frames alongside its census."""
import os
import importlib.util
from pathlib import Path
import tempfile
import time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
spec = importlib.util.spec_from_file_location('census_shared', 'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)

def scoped(inspect):
    cold = inspect('get_kernel_stacks', refresh=False)
    assert cold['scope_pid'] == os.getpid() and cold['sequence'] == 0 and not cold['pending'], cold
    end = time.monotonic() + 15
    while True:
        result = inspect('get_kernel_stacks')
        if result.get('status') == 'ready':
            break
        assert time.monotonic() < end, result
        time.sleep(.01)
    assert result['scope_pid'] == os.getpid() and result['task_count'] > 0, result
    assert result['reason'] == ('StackAccessDenied' if result['denied'] and result['denied'] == result['task_count'] - result['vanished'] else None), result
    for group in result['groups']:
        page = inspect('get_kernel_stacks', refresh=False, sequence=result['sequence'], group=group['id'])
        assert page['members'] and all(t['pid'] == os.getpid() for t in page['members']), page
    return result

options = ['--kernel-pid', str(os.getpid())]
owner = Client('observe', options=options)
try:
    scoped(owner.inspect)
    assert owner.session()['state'] == 'stopped'
    print('PASS debugger host PID scope, passive/ready/member replies and no resume: stdio', flush=True)
finally:
    owner.close()

# Shared owners use sockets, not --mcp stdio. Preserve their private test logs.
(root / '.work').mkdir(exist_ok=True)
work = Path(tempfile.mkdtemp(prefix='kc-', dir=root / '.work'))
work.chmod(0o755)
server = shared.Server(root, work, Path(os.environ.get('XODB_BIN', root / 'zig-out/bin/xodb')),
                       root / 'zig-out/bin/xodb-m1-fixture', 'observe', options=options)
try:
    first = shared.Client(server, 'census-first')
    second = shared.Client(server, 'census-second')
    server.remember_target(first.session())
    result = scoped(first.tool)
    cached = second.tool('get_kernel_stacks', refresh=False)
    assert cached['sequence'] == result['sequence'] and cached['scope_pid'] == os.getpid(), cached
    assert first.session()['state'] == 'stopped'
    print('PASS debugger host PID scope and publication shared by two socket observers', flush=True)
finally:
    server.close()

client = Client('observe')
try:
    session = client.session()
    thread = next(t for t in session['threads'] if t['state'] == 'stopped')
    tid = thread['tid']
    expected = client.inspect('get_stack', tid=tid)
    if client.runtime_agent:
        result = client.inspect('get_kernel_stacks', user_tid=tid)
        assert result['user_stack']['status'] == 'ThreadNotInLocalDebugger'
        assert client.session()['state'] == 'stopped'
        print('PASS remote target identity is not joined to a host kernel census')
        raise SystemExit(0)
    end = time.monotonic() + 15
    while True:
        result = client.inspect('get_kernel_stacks', user_tid=tid)
        if result['user_stack']['status'] == 'ready':
            break
        assert time.monotonic() < end, result['user_stack']
        time.sleep(.02)
    actual = result['user_stack']
    assert actual['generation'] == expected['generation']
    assert actual['frames'] and actual['frames'][0]['pc'] == expected['frames'][0]['pc']
    assert actual['simultaneous_with_census'] is False
    assert client.session()['state'] == 'stopped'
    print('PASS existing stopped thread: matching user frames alongside kernel census, no resume/attach')
finally:
    client.close()
