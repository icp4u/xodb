#!/usr/bin/env python3
"""Fast host lane: quit after an observed broken link reaps the owned transport."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import select
import shlex
import signal
import subprocess
import sys
import time

from helpers.agent_proxy import relay


def identity(pid):
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        return dict(pid=pid, start=fields[19], state=fields[0])
    except OSError:
        return None


def same(saved):
    current = identity(saved['pid']) if saved else None
    return current if current and current['start'] == saved['start'] else None


def proxy(directory, agent):
    directory = Path(directory)
    (directory/'proxy.json').write_text(json.dumps(identity(os.getpid())))
    def request(row):
        children = Path(f'/proc/{os.getpid()}/task/{os.getpid()}/children').read_text().split()
        if children and not (directory/'agent.json').exists():
            (directory/'agent.json').write_text(json.dumps(identity(int(children[0]))))
        only = (directory/'arm').read_text() if (directory/'arm').exists() else None
        if only is not None and (not only or row['op'] == int(only)):
            # Lose the stream, but keep its direct child alive until teardown.
            os.close(1)
            os.close(0)
            pending = directory/'fault.pending'
            pending.write_text(json.dumps(dict(phase='closed', op=row['op'])))
            pending.replace(directory/'fault.json')
            while True:
                signal.pause()  # relay's SIGTERM handler unwinds and reaps its child
        return True
    relay(agent, request, lambda row: row['header']+row['body'])


def wait(check, why, seconds=15):
    scale = max(1, os.getloadavg()[0]/len(os.sched_getaffinity(0)))
    deadline = time.monotonic()+seconds*scale
    while True:
        value = check()
        if value:
            return value
        assert time.monotonic() < deadline, why
        time.sleep(.005)


def run(args):
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    os.umask(0o022)
    assert ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) == 0
    work = args.work.resolve()
    work.mkdir(parents=True)
    binary = (args.binary or root/'zig-out/bin/xodb').resolve()
    names = re.findall(r'XRT_RPC_[A-Z_]+', (root/'src/runtime/rpc.h').read_text().split('enum xrt_rpc_op {', 1)[1].split('};', 1)[0])
    destroy = 1+names.index('XRT_RPC_DESTROY')
    rows = []
    result = dict(status='running', rows=rows, load=os.getloadavg())
    started = time.monotonic()
    try:
        for mode, stop in [('close', 'sigint'), ('dead', 'sigint'), ('close', 'eof'), ('dead', 'eof'), ('late', 'sigint')]:
            if args.only and mode != args.only:
                continue
            directory = work/(mode+'-'+stop)
            directory.mkdir()
            wrapper = directory/'transport'
            wrapper.write_text('#!/bin/sh\nexec '+shlex.join([sys.executable, '-B', str(Path(__file__).resolve()), '--proxy', str(directory), str(binary.with_name('xodb-agent'))])+'\n')
            wrapper.chmod(0o755)
            row = dict(mode=mode, stop=stop, status='running')
            rows.append(row)
            process = None
            owned = []
            with (directory/'stderr.log').open('wb') as log:
                try:
                    env = dict(os.environ)
                    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK'):
                        env.pop(key, None)
                    process = subprocess.Popen([str(binary), '--headless', '--mcp', '--agent-scope', 'control', '--runtime-agent', str(wrapper), '--', '/bin/sleep', '30'], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, bufsize=0)
                    serial = 0
                    def call(method, params):
                        nonlocal serial
                        serial += 1
                        process.stdin.write((json.dumps(dict(jsonrpc='2.0', id=serial, method=method, params=params))+'\n').encode())
                        deadline = time.monotonic()+15
                        while True:
                            assert select.select([process.stdout], [], [], max(0, deadline-time.monotonic()))[0], 'MCP response timeout'
                            line = process.stdout.readline()
                            assert line, 'MCP ended before the fault'
                            reply = json.loads(line)
                            if reply.get('id') == serial:
                                return reply
                    call('initialize', dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='broken-exit', version='1')))
                    process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
                    reply = call('tools/call', dict(name='get_session', arguments={}))
                    assert not reply['result'].get('isError'), reply
                    target = identity(reply['result']['structuredContent']['pid'])
                    transport = json.loads((directory/'proxy.json').read_text())
                    agent = json.loads((directory/'agent.json').read_text())
                    owned = [transport, agent, target]
                    assert all(same(item) for item in owned), owned
                    if mode == 'close':
                        (directory/'arm').touch()
                        fault = wait(lambda: json.loads((directory/'fault.json').read_text()) if (directory/'fault.json').exists() and (directory/'fault.json').stat().st_size else None, 'proxy did not close an active RPC')
                        assert fault['phase'] == 'closed' and same(transport)['state'] != 'Z', fault
                        row['fault'] = fault
                    elif mode == 'late':
                        # Healthy at the quit; the stream is lost on the owner's
                        # own teardown request, after its health check passed.
                        (directory/'arm.pending').write_text(str(destroy))
                        (directory/'arm.pending').replace(directory/'arm')
                    else:
                        os.kill(transport['pid'], signal.SIGKILL)
                        def departed():
                            state = same(transport)
                            return state is None or state['state'] == 'Z'
                        wait(departed, 'transport did not exit')
                        row['fault'] = dict(phase='transport_dead_before_quit')
                    at = time.monotonic()
                    if stop == 'eof':
                        process.stdin.close()
                    else:
                        process.send_signal(signal.SIGINT)
                    code = process.wait(timeout=20*max(1, os.getloadavg()[0]/len(os.sched_getaffinity(0))))
                    row['exit_seconds'] = time.monotonic()-at
                    row['exit_code'] = code
                    if mode == 'late':
                        row['fault'] = json.loads((directory/'fault.json').read_text()) if (directory/'fault.json').exists() else None
                        assert row['fault'] and row['fault']['phase'] == 'closed' and row['fault']['op'] == destroy, row
                    row['transport_gone'] = same(transport) is None
                    if args.wrong_result:
                        row['transport_gone'] = False
                    assert code == 0 and row['transport_gone'], row
                    text = (directory/'stderr.log').read_text()
                    row['cleanup_noise'] = 'handle retained' in text
                    assert not row['cleanup_noise'], text
                    row['status'] = 'pass'
                    print(json.dumps(row), flush=True)
                except BaseException as err:
                    row.update(status='fail', error=str(err))
                    raise
                finally:
                    if process is not None:
                        if process.poll() is None:
                            process.kill()
                            process.wait()
                        for item in owned:
                            if item and same(item):
                                try: os.kill(item['pid'], signal.SIGKILL)
                                except ProcessLookupError: pass
                        for stream in (process.stdin, process.stdout):
                            if stream and not stream.closed: stream.close()
                        # This subreaper owns only the synthetic descendants.
                        for item in owned:
                            if item:
                                try: os.waitpid(item['pid'], 0)
                                except ChildProcessError: pass
        result['status'] = 'pass'
    finally:
        if result['status'] == 'running': result['status'] = 'fail'
        result['seconds'] = time.monotonic()-started
        (work/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--proxy':
        proxy(sys.argv[2], sys.argv[3])
    else:
        p = argparse.ArgumentParser(description=__doc__)
        p.add_argument('--work', type=Path, required=True)
        p.add_argument('--binary', type=Path)
        p.add_argument('--only', choices=('close', 'dead', 'late'))
        p.add_argument('--wrong-result', action='store_true')
        run(p.parse_args())
