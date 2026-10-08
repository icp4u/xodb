#!/usr/bin/env python3
"""Owned metadata worker transport: bounded delay and one malformed reply."""
import os
import struct
import subprocess
import sys
import threading
import time

agent = subprocess.Popen([os.environ['XODB_METADATA_AGENT'], '--stdio'],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE)
delay = float(os.environ.get('XODB_METADATA_DELAY', '0'))
fault = os.environ.get('XODB_METADATA_FAULT', '')
view = None

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
        magic, version, op, request, target, status, size, flags = struct.unpack('>4sHHQIIII', header)
        assert magic == b'XRT1' and size <= 1024 * 1024
        body = agent.stdout.read(size)
        assert len(body) == size
        if op == 37 and status == 0:  # VIEW, never LAUNCH
            view = body
        if fault == 'snapshot' and op == 39 and view is not None:
            body = view
            header = struct.pack('>4sHHQIIII', magic, version, op, request, target, 2, len(body), flags)
            fault = ''
        time.sleep(delay)
        pending = memoryview(header + body)
        while pending:
            pending = pending[os.write(1, pending):]
except (BrokenPipeError, OSError):
    pass
finally:
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
