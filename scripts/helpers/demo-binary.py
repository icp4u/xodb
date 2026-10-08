#!/usr/bin/env python3
"""Select a demo binary and check its advertised native language reader."""
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import time


def check(binary, language):
    # No target or display: query this executable's observer tool schema.
    process = subprocess.Popen([binary, '--headless', '--mcp', '--agent-scope', 'observe'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, bufsize=0)
    pending = bytearray()
    deadline = time.monotonic() + 10

    def call(sequence, method, params):
        message = dict(jsonrpc='2.0', id=sequence, method=method, params=params)
        process.stdin.write((json.dumps(message) + '\n').encode())
        while True:
            if b'\n' in pending:
                line, _, rest = pending.partition(b'\n')
                pending[:] = rest
                reply = json.loads(line)
                if reply.get('id') == sequence:
                    return reply.get('result', {})
                continue
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([process.stdout], [], [], left)[0]:
                raise RuntimeError('timed out checking the xodb language reader')
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError('xodb closed before advertising its language readers')
            pending.extend(chunk)
            if len(pending) > 2 * 1024 * 1024:
                raise RuntimeError('xodb tool list exceeded the demo check limit')

    try:
        call(1, 'initialize', dict(protocolVersion='2025-06-18', capabilities={},
                                  clientInfo=dict(name='demo-preflight', version='1')))
        process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        definitions = call(2, 'tools/list', {})
        for tool in definitions.get('tools', []):
            if tool.get('name') == 'get_language_stack':
                languages = tool.get('inputSchema', {}).get('properties', {}).get('language', {}).get('enum', [])
                if language in languages:
                    return
        raise RuntimeError(f'this xodb build does not advertise the {language} reader')
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        process.stdout.close()


def main():
    language, = sys.argv[1:]
    root = Path(__file__).resolve().parents[2]
    local = root/'zig-out/bin/xodb'
    chosen = os.environ.get('XODB') or (str(local) if os.access(local, os.X_OK) else shutil.which('xodb'))
    if not chosen:
        sys.exit('Build xodb with scripts/build, or set XODB to its executable.')
    binary = shutil.which(chosen)
    if not binary:
        sys.exit('Build xodb with scripts/build, or set XODB to its executable.')
    binary = str(Path(binary).resolve())
    print(f'Using xodb: {binary}', file=sys.stderr)
    try:
        check(binary, language)
    except (OSError, ValueError, RuntimeError) as error:
        sys.exit(f'{error}. Rebuild with scripts/build, or set XODB to a current installed executable.')
    print(binary)


if __name__ == '__main__':
    main()
