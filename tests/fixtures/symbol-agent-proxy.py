#!/usr/bin/env python3
"""Bound an owned local agent's replies to model a slow remote connection."""
import os
import struct
import subprocess
import sys
import threading
import time

agent = subprocess.Popen([os.environ['XODB_DISCOVERY_AGENT'], '--stdio'],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE)
rate = int(os.environ.get('XODB_DISCOVERY_RATE', str(1024 * 1024)))
file_delay = float(os.environ.get('XODB_DISCOVERY_FILE_DELAY', '0'))
reply_delay = float(os.environ.get('XODB_DISCOVERY_REPLY_DELAY', '0'))

def requests():
    try:
        while data := os.read(0, 65536):
            agent.stdin.write(data)
            agent.stdin.flush()
    except (BrokenPipeError, OSError):
        pass
    finally:
        agent.stdin.close()

thread = threading.Thread(target=requests, daemon=True)
thread.start()
try:
    while header := agent.stdout.read(32):
        assert len(header) == 32
        magic, version, op, request, target, status, size, flags = struct.unpack('>4sHHQIIII', header)
        assert magic == b'XRT1' and size <= 1024 * 1024
        body = agent.stdout.read(size)
        assert len(body) == size
        time.sleep(reply_delay)  # Include FILE_OPEN, SYNC and control replies.
        if op == 39: time.sleep(file_delay)  # FILE_READ may cross the slice deadline.
        frame = header + body
        for at in range(0, len(frame), 8192):
            data = frame[at:at + 8192]
            time.sleep(.002 + len(data) / rate)
            view = memoryview(data)
            while view:
                view = view[os.write(1, view):]
except (BrokenPipeError, OSError):
    pass
finally:
    if agent.poll() is None:
        agent.terminate()
        try:
            agent.wait(timeout=5)
        except subprocess.TimeoutExpired:
            agent.kill()
            agent.wait()
sys.exit(agent.returncode or 0)
