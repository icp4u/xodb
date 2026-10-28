#!/usr/bin/env python3
"""Count FILE_READ reply bytes from the owned agent and forward every frame."""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import threading

agent = subprocess.Popen([os.environ['XODB_FILE_AGENT'], '--stdio'],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE)
out_path = Path(os.environ['XODB_FILE_COUNT'])
FILE_READ = 39
state = {'read_bytes': 0, 'reads': 0, 'opens': 0}


def publish():
    tmp = out_path.with_suffix('.tmp')
    tmp.write_text(json.dumps(state) + '\n')
    os.replace(tmp, out_path)


publish()


def requests():
    try:
        while data := os.read(0, 65536):
            agent.stdin.write(data)
            agent.stdin.flush()
    except (BrokenPipeError, OSError):
        pass
    finally:
        agent.stdin.close()


threading.Thread(target=requests, daemon=True).start()
try:
    while header := agent.stdout.read(32):
        assert len(header) == 32
        magic, _version, op, _request, _target, status, size, _flags = struct.unpack('>4sHHQIIII', header)
        assert magic == b'XRT1' and size <= 1024 * 1024
        body = agent.stdout.read(size)
        assert len(body) == size
        if op == 38 and status == 0:
            state['opens'] += 1
        if op == FILE_READ and status == 0:
            state['reads'] += 1
            state['read_bytes'] += size
            publish()
        elif op == 38 and status == 0:
            publish()
        pending = memoryview(header + body)
        while pending:
            pending = pending[os.write(1, pending):]
except (BrokenPipeError, OSError):
    pass
finally:
    publish()
    try:
        agent.wait(timeout=5)
    except subprocess.TimeoutExpired:
        agent.terminate()
        try:
            agent.wait(timeout=5)
        except subprocess.TimeoutExpired:
            agent.kill()
            agent.wait()
sys.exit(agent.returncode or 0)
