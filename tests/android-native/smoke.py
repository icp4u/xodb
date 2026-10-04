#!/usr/bin/env python3
"""Owned-fixture MCP checks, locally or on the separately approved Pixel plan.

Device mode uploads exactly xodb, xodb-android-demo and demo.c to a fresh
/data/local/tmp/xodb-native.* directory. No TCP listener or port forward yet.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import select
import shlex
import subprocess
import time

root = Path(__file__).resolve().parents[2]
os.chdir(root)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bundle', required=True, type=Path)
parser.add_argument('--device', action='store_true')
parser.add_argument('--execute-reviewed-plan', action='store_true')
args = parser.parse_args()
if args.device and not args.execute_reviewed_plan:
    parser.error('Device writes require review of docs/ANDROID_NATIVE_PLAN.md and --execute-reviewed-plan')
bundle = args.bundle.resolve()
names = ('xodb', 'xodb-android-demo', 'demo.c')
assert all((bundle / name).is_file() for name in names), bundle
run = root / '.work' / ('android-smoke-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir(parents=True)
transcript = []
operations = []
directory = None
process = None
target_pid = None
clean = True
passed = False
pending = b''


def adb(*argv, timeout=20):
    done = subprocess.run(['adb', '-d', *argv], capture_output=True, text=True, timeout=timeout)
    operations.append({'argv': argv, 'code': done.returncode, 'stdout': done.stdout, 'stderr': done.stderr})
    done.check_returncode()
    return done.stdout.strip()


def request(method, params=None):
    global pending
    identity = len(transcript) + 1
    message = {'jsonrpc': '2.0', 'id': identity, 'method': method, 'params': params or {}}
    process.stdin.write((json.dumps(message) + '\n').encode())
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        while b'\n' not in pending:
            assert select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))[0], 'MCP response timeout'
            data = os.read(process.stdout.fileno(), 65536)
            assert data, (run / 'server.log').read_text()
            pending += data
        line, pending = pending.split(b'\n', 1)
        response = json.loads(line)
        if response.get('id') != identity:
            assert 'id' not in response, response
            continue
        transcript.append({'request': message, 'response': response})
        return response
    raise AssertionError('MCP response timeout')


def tool(tool_name, **arguments):
    response = request('tools/call', {'name': tool_name, 'arguments': arguments})
    assert 'error' not in response and not response['result']['isError'], response
    return response['result']['structuredContent']


def action(tool_name, **arguments):
    return tool(tool_name, generation=tool('get_session')['generation'], **arguments)


def wait_state(state, reason=None):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        session = tool('get_session')
        if session['state'] == state and (reason is None or any(t['reason'] == reason for t in session['threads'])):
            return session
        time.sleep(.01)
    raise AssertionError(session)


try:
    if args.device:
        assert adb('shell', 'getprop', 'ro.product.model') == 'Pixel 8 Pro'
        assert adb('shell', 'id', '-u') == '2000'
        assert adb('shell', 'getenforce') == 'Enforcing'
        candidate = adb('shell', 'mktemp', '-d', '/data/local/tmp/xodb-native.XXXXXX')
        assert re.fullmatch(r'/data/local/tmp/xodb-native\.[a-zA-Z0-9]{6}', candidate), candidate
        directory = candidate
        for name in names:
            adb('push', str(bundle / name), directory + '/' + name)
        adb('shell', 'chmod', '700', directory + '/xodb', directory + '/xodb-android-demo')
        command = ['adb', '-d', 'shell', '-T', 'cd ' + shlex.quote(directory) +
                   ' && exec /system/bin/timeout -s TERM -k 3 90 ./xodb --headless --mcp'
                   ' --agent-scope control --source ./demo.c -- ./xodb-android-demo']
    else:
        command = [str(bundle / 'xodb'), '--headless', '--mcp', '--agent-scope', 'control',
                   '--source', str(bundle / 'demo.c'), '--', str(bundle / 'xodb-android-demo')]
    operations.append({'server': command})
    with (run / 'server.log').open('xb') as log:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=log, bufsize=0)
    request('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                          'clientInfo': {'name': 'android-owned-fixture', 'version': '1'}})
    process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    initial = tool('get_session')
    target_pid = initial['pid']
    assert initial['state'] == 'stopped' and initial['agent_scope'] == 'control', initial
    line = next(i for i, s in enumerate((bundle / 'demo.c').read_text().splitlines(), 1) if 'WATCH_WRITE' in s)
    bp = action('set_breakpoint', file='demo.c', line=line)['id']
    action('continue')
    stopped = wait_state('stopped', 'breakpoint')
    tid = stopped['threads'][0]['tid']
    view = tool('get_debug_view', tid=tid)
    if args.device:
        assert view['architecture'] == 'aarch64', view['architecture']
    assert view['frames'][0]['symbol'] == 'change_value', view['frames']
    assert view['frames'][1]['symbol'] == 'main', view['frames']
    assert view['registers'] and view['instructions'] and 'WATCH_WRITE' in view['source']['text'], view
    assert {v['name']: v['display'] for v in view['locals']}['next'] == '12', view['locals']
    assert tool('evaluate_expression', tid=tid, expression='item->value')['value']['display'] == '7'
    symbol = tool('find_symbol', name='state')
    address = symbol['address']
    if isinstance(address, int):
        address = hex(address)
    assert int.from_bytes(bytes.fromhex(tool('read_memory', address=address, length=8)['hex']), 'little') == 7
    stale = request('tools/call', {'name': 'continue', 'arguments': {'generation': initial['generation']}})
    assert stale['result']['isError'] and stale['result']['content'][0]['text'] == 'StaleSnapshot', stale
    watch = action('set_watchpoint', address=address, length=8, kind='write')['id']
    action('remove_breakpoint', id=bp)
    for before, after in ((7, 12), (12, 21)):
        action('continue')
        wait_state('stopped', 'watchpoint')
        hits = [e for e in tool('query_events')['events'] if e['kind'] == 'watchpoint_hit']
        hit = hits[-1]
        assert hit['before_valid'] and hit['after_valid'], hit
        phase = 'completed' if view['architecture'] == 'aarch64' else 'after_access'
        assert (hit['before'], hit['after'], hit['watch_phase']) == (before, after, phase), hit
        if view['architecture'] == 'aarch64':
            assert hit['trap_pc'] + 4 == hit['pc'] and hit['trap_code'] == 4, hit
        assert tool('evaluate_expression', tid=tid, expression='item->value')['value']['display'] == str(after)
        if after == 12:
            old = tool('get_debug_view', tid=tid)['frames'][0]['source']['line']
            action('step_source', tid=tid)
            wait_state('stopped')
            assert tool('get_debug_view', tid=tid)['frames'][0]['source']['line'] != old
    action('remove_watchpoint', id=watch)
    action('continue')
    wait_state('exited')
    assert any(e['kind'] == 'exit' and e['detail'] == 0 for e in tool('query_events')['events'])
    passed = True
finally:
    try:
        if process:
            try:
                process.stdin.close()
            except BrokenPipeError:
                pass
            try:
                code = process.wait(timeout=100 if args.device else 5)
                clean = code == 0
            except subprocess.TimeoutExpired:
                clean = False
                process.kill()
                process.wait(timeout=5)
            if target_pid:
                if args.device:
                    # Existence check only; never signal a PID learned from a stale snapshot.
                    clean = clean and adb('shell', 'sh', '-c', shlex.quote(f'test ! -e /proc/{target_pid} && echo gone')) == 'gone'
                else:
                    clean = clean and not Path(f'/proc/{target_pid}').exists()
        if directory and clean:
            for name in names:
                adb('shell', 'rm', '-f', directory + '/' + name)
            adb('shell', 'rmdir', directory)
    except BaseException:
        clean = False
        raise
    finally:
        (run / 'results.json').write_text(json.dumps({
            'passed': passed, 'clean': clean, 'device': args.device, 'directory': directory,
            'operations': operations, 'transcript': transcript,
        }, indent=2) + '\n')
        print(run, flush=True)
    if not clean:
        raise RuntimeError('Cleanup unconfirmed; preserved device directory for inspection: ' + str(directory))
print('PASS: source breakpoint, stack/locals/registers/assembly, eval, memory, stale rejection, two hardware writes, source step, target exit and cleanup')
