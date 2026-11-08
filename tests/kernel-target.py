#!/usr/bin/env python3
"""Fast observer contract on an owned ordinary target; real agent twin."""
import importlib.util
import os
from pathlib import Path
import tempfile
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
owner = Client('observe')
try:
    before = owner.session()
    tools = owner.call('tools/list')['result']['tools']
    tool = next(t for t in tools if t['name'] == 'get_kernel_target')
    assert tool['annotations']['readOnlyHint'] is True, tool
    for section in ('tasks', 'cpus', 'modules', 'waits'):
        reply = owner.tool('get_kernel_target', section=section, process_id=before['process_id'])
        assert reply['result']['isError'] and reply['result']['content'][0]['text'] == 'KernelTargetRequired', reply
    for args in ({'limit': 0}, {'limit': 129}, {'section': 'bogus'}, {'start': -1}, {'extra': True}):
        reply = owner.tool('get_kernel_target', **args)
        assert reply['error'] == {'code': -32602, 'message': 'InvalidArguments'}, reply
    after = owner.session()
    assert (after['state'], after['generation']) == (before['state'], before['generation'])
    print('PASS observer inventory contract and typed non-kernel refusal; no target control')
finally:
    owner.close()

spec = importlib.util.spec_from_file_location('shared_kernel', root / 'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
(root / '.work').mkdir(exist_ok=True)
work = Path(tempfile.mkdtemp(prefix='kt-', dir=root / '.work'))
work.chmod(0o755)
server = shared.Server(root, work, Path(os.environ.get('XODB_BIN', root / 'zig-out/bin/xodb')),
                       root / 'zig-out/bin/xodb-m1-fixture', 'observe')
try:
    peer = shared.Client(server, 'kernel-observer')
    before = peer.session()
    server.remember_target(before)
    reply = peer.raw('get_kernel_target')
    assert reply['result']['isError'] and reply['result']['content'][0]['text'] == 'KernelTargetRequired', reply
    assert peer.session()['generation'] == before['generation']
    print('PASS shared observer receives the same refusal without control lease')
finally:
    server.close()

overview = Client('observe', executable=None, options=['--overview'])
try:
    assert all(t['name'] != 'get_kernel_target' for t in overview.call('tools/list')['result']['tools'])
    reply = overview.tool('get_kernel_target')
    assert reply['error'] == {'code': -32602, 'message': 'UnknownTool'}, reply
    print('PASS target inventory is neither listed nor callable in host overview')
finally:
    overview.close()
