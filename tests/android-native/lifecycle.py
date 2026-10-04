#!/usr/bin/env python3
"""Device-write test: owned Android listener cancellation and deadline cleanup."""
import argparse
import json
from pathlib import Path
import runpy
import shlex
import socket
import time

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bundle', required=True, type=Path)
parser.add_argument('--case', choices=('cancel-before-client', 'deadline-before-client', 'deadline-stopped-client'))
args = parser.parse_args()
DeviceDemo = runpy.run_path(str(root / 'scripts/demo-android'))['DeviceDemo']
for mode, seconds in (('cancel-before-client', 30), ('deadline-before-client', 3), ('deadline-stopped-client', 5)):
    if args.case and args.case != mode:
        continue
    connection = stream = None
    target_pid = None
    device = DeviceDemo(args.bundle, seconds)
    try:
        device.start()
        if mode == 'deadline-stopped-client':
            connection = socket.create_connection(('127.0.0.1', device.port), timeout=3)
            stream = connection.makefile('rb')
            def request(identity, method, params):
                connection.sendall((json.dumps({'jsonrpc':'2.0', 'id':identity, 'method':method, 'params':params})+'\n').encode())
                return json.loads(stream.readline())
            assert 'result' in request(1, 'initialize', {'protocolVersion':'2025-06-18', 'capabilities':{}, 'clientInfo':{'name':'android-deadline', 'version':'1'}})
            connection.sendall(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            session = request(2, 'tools/call', {'name':'get_session', 'arguments':{}})['result']['structuredContent']
            assert session['state'] == 'stopped'
            target_pid = session['pid']
        if mode.startswith('deadline-'):
            assert device.server.wait(timeout=8) == 124
            assert 'XODB_DEMO_REAPED=' in device.log.read_text()
    finally:
        if stream:
            stream.close()
        if connection:
            connection.close()
        start = time.monotonic()
        device.close()
        elapsed = time.monotonic() - start
    assert elapsed < 5, elapsed
    assert device.adb('shell', 'sh', '-c', shlex.quote('test ! -e ' + device.directory + ' && echo gone')) == 'gone'
    if target_pid:
        assert device.adb('shell', 'sh', '-c', shlex.quote(f'test ! -e /proc/{target_pid} && echo gone')) == 'gone'
    forwards = device.adb('forward', '--list')
    assert not any(line.split()[1] == 'tcp:' + str(device.port) for line in forwards.splitlines())
    (device.run / 'check.json').write_text(json.dumps({'mode': mode, 'passed': True, 'cleanup_seconds': elapsed, 'target_pid': target_pid, 'target_gone': target_pid is not None}, indent=2) + '\n')
    print('PASS: ' + mode, device.run)
