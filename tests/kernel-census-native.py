#!/usr/bin/env python3
"""A stopped local debugger thread exposes user frames alongside its census."""
import os
from pathlib import Path
import time
from client import Client

os.chdir(Path(__file__).resolve().parents[1])
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
