#!/usr/bin/env python3
"""Run the scene demo, then leave the GUI and shared observers in charge."""
import json
import os
import select
import signal
import socket
import subprocess
import sys
import time
from redot_scene import start_scene


def main():
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    path = sys.argv[sys.argv.index('--session-socket') + 1]
    child = subprocess.Popen([sys.argv[1], '--agent-scope', 'control', '--redot-debugger', *sys.argv[2:]], stdin=subprocess.DEVNULL)
    connection = socket.socket(socket.AF_UNIX)
    stream = None
    sequence = 0

    def call(method, params):
        nonlocal sequence
        sequence += 1
        stream.write((json.dumps(dict(jsonrpc='2.0', id=sequence, method=method, params=params)) + '\n').encode())
        while True:
            if not select.select([connection], [], [], 30)[0]:
                raise TimeoutError('xodb MCP reply')
            line = stream.readline()
            if not line:
                raise RuntimeError('xodb closed')
            response = json.loads(line)
            if response.get('id') == sequence:
                return response

    def tool(name, **arguments):
        response = call('tools/call', dict(name=name, arguments=arguments))
        result = response.get('result', {})
        if 'error' in response or result.get('isError'):
            raise RuntimeError(str(response))
        return result['structuredContent']

    try:
        deadline = time.monotonic() + 30
        while True:
            try:
                connection.connect(path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if child.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError('xodb shared session did not start')
                time.sleep(.02)
        stream = connection.makefile('rwb', buffering=0)
        call('initialize', dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='redot-scene-demo', version='1')))
        stream.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        tool('claim_session_control', ttl_ms=60000)
        try:
            start_scene(tool)
            if os.environ.get('REDOT_TIME') == 'true':
                from redot_time import sample_time
                sample_time(tool)
                print('Time ready. Press U then T: F slowest frame; click a function for its native sample. Stops perturb wall timing.', file=sys.stderr)
            print('Scene ready. Press U: select a node, P properties, S signal values, R refresh.', file=sys.stderr)
        except Exception as error:
            print('Scene startup: ' + str(error) + '. Use O / Continue in the GUI.', file=sys.stderr)
        tool('release_session_control')
        stream.close()
        stream = None
        connection.close()
        return child.wait()
    finally:
        if stream:
            stream.close()
        connection.close()
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=10)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
