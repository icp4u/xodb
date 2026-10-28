#!/usr/bin/env python3
"""Fast host lane: observed headless startup faults cancel without owned children left,
and an undisturbed headless startup still answers and reports errors as a local one does."""
import argparse
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import signal
import socket
import subprocess
import sys
import time

from helpers.agent_proxy import relay
from helpers.listen import listen_and_report

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('broken_exit', root/'tests/remote-broken-exit.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def descendants(pid):
    result = set()
    try:
        tasks = list(Path(f'/proc/{pid}/task').iterdir())
    except OSError:
        return result
    for task in tasks:
        try:
            for value in (task/'children').read_text().split():
                child = int(value)
                if child not in result:
                    result.add(child)
                    result.update(descendants(child))
        except OSError:
            pass
    return result


def proxy(directory, agent):
    directory = Path(directory)
    config = json.loads((directory/'config.json').read_text())
    def request(row):
        if row['op'] != config['op']:
            return True
        owned = [helper.identity(pid) for pid in [os.getpid(), *sorted(descendants(os.getpid()))]]
        assert all(owned), owned
        event = dict(mode=config['mode'], op=row['op'], owned=owned)
        pending = directory/'fault.pending'
        pending.write_text(json.dumps(event))
        if config['mode'] == 'close':
            os.close(0)
            os.close(1)
        pending.replace(directory/'fault.json')
        if config['mode'] == 'kill':
            os.kill(os.getpid(), signal.SIGKILL)
        while True:
            signal.pause()
    relay(agent, request, lambda row: row['header']+row['body'])


def plain(name, binary, fixture, directory, row, wrong):
    """No fault: what a client saw before startup moved to the owner thread."""
    directory.mkdir()
    env = dict(os.environ)
    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK'):
        env.pop(key, None)
    argv = [str(binary), '--headless', '--mcp', '--agent-scope', 'control', '--runtime-agent', str(binary.with_name('xodb-agent'))]
    if name == 'batch':
        argv += ['--', str(fixture)]
    elif name == 'missing-capture':
        argv += ['--capture-out', str(directory/'out'), '--', str(directory/'no-such-program')]
    else:
        gone = subprocess.Popen([str(fixture)])
        gone.kill()
        gone.wait()
        argv += ['--attach', str(gone.pid)]
    owned = {}
    with (directory/'stderr.log').open('wb') as log, (directory/'stdout.log').open('wb') as out:
        process = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE, stdout=out, stderr=log, bufsize=0)
        try:
            if name == 'batch':
                # The whole batch is written and the pipe closed before startup can finish.
                process.stdin.write(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"batch","version":"1"}}}\n'
                                    b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
                                    b'{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_session","arguments":{}}}\n')
                process.stdin.close()
            deadline = time.monotonic()+30*max(1, os.getloadavg()[0]/len(os.sched_getaffinity(0)))
            while process.poll() is None:
                assert time.monotonic() < deadline, 'startup did not end'
                for pid in descendants(process.pid):
                    saved = helper.identity(pid)
                    if saved: owned.setdefault(pid, saved)
                time.sleep(.001)
            row['exit_code'] = process.returncode
            helper.wait(lambda: not any(helper.same(saved) for saved in owned.values()), 'startup left an owned agent or target')
            text = (directory/'stderr.log').read_text()
            replies = [json.loads(line) for line in (directory/'stdout.log').read_text().splitlines()]
            if wrong: replies, text = [], ''
            if name == 'batch':
                answered = {reply.get('id'): reply for reply in replies}
                assert process.returncode == 0 and set(answered) >= {1, 2}, (process.returncode, replies, text)
                assert answered[2]['result']['structuredContent']['state'] == 'stopped', answered[2]
                assert owned, 'no agent or target was ever started'
            elif name == 'missing-capture':
                assert process.returncode == 1 and 'error: ExecFailed' in text and 'archive save failed' not in text, text
                assert not (directory/'out').exists()
            else:
                assert process.returncode == 1 and 'xodb: attach failed: ProcessGone; pid=' in text and 'error: ProcessGone' in text, text
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            if not process.stdin.closed: process.stdin.close()
            for saved in owned.values():
                if helper.same(saved):
                    try: os.kill(saved['pid'], signal.SIGKILL)
                    except ProcessLookupError: pass


def run(args):
    os.chdir(root)
    os.umask(0o022)
    assert ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) == 0
    work = args.work.resolve()
    work.mkdir(parents=True)
    binary = (args.binary or root/'zig-out/bin/xodb').resolve()
    source = work/'fixture.c'
    source.write_text('#include <unistd.h>\nint main(void) { for (;;) pause(); }\n')
    fixture = work/'fixture'
    subprocess.run(['cc', '-g', '-O0', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(fixture)], check=True, timeout=30)
    names = re.findall(r'XRT_RPC_[A-Z_]+', (root/'src/runtime/rpc.h').read_text().split('enum xrt_rpc_op {', 1)[1].split('};', 1)[0])
    cases = [('hold-hello', 'hold', 'HELLO', 'sigint'), ('hold-launch', 'hold', 'LAUNCH', 'sigint'),
             ('hold-bpset', 'hold', 'BP_SET', 'sigint'), ('hold-launch-eof', 'hold', 'LAUNCH', 'eof'),
             ('close-launch', 'close', 'LAUNCH', 'sigint'), ('kill-launch', 'kill', 'LAUNCH', 'sigint')]
    if args.matrix:
        cases += [('hold-hello-eof', 'hold', 'HELLO', 'eof'), ('hold-bpset-eof', 'hold', 'BP_SET', 'eof'),
                  ('hold-launch-buffered-eof', 'hold', 'LAUNCH', 'buffered-eof'),
                  ('hold-launch-file-eof', 'hold', 'LAUNCH', 'file-eof'),
                  ('hold-launch-socket-eof', 'hold', 'LAUNCH', 'socket-eof')]
    rows = []
    result = dict(status='running', rows=rows, load=os.getloadavg())
    started = time.monotonic()
    try:
        for name, mode, operation, stop in cases:
            if args.only and name != args.only:
                continue
            directory = work/name
            directory.mkdir()
            op = 1+names.index('XRT_RPC_'+operation)
            (directory/'config.json').write_text(json.dumps(dict(mode=mode, op=op)))
            wrapper = directory/'transport'
            wrapper.write_text('#!/bin/sh\nexec '+shlex.join([sys.executable, '-B', str(Path(__file__).resolve()), '--proxy', str(directory), str(binary.with_name('xodb-agent'))])+'\n')
            wrapper.chmod(0o755)
            row = dict(case=name, status='running')
            rows.append(row)
            process = None
            owned = []
            redirected = None
            peer = None
            with (directory/'stderr.log').open('wb') as log:
                try:
                    env = dict(os.environ)
                    for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK'):
                        env.pop(key, None)
                    if stop == 'file-eof':
                        (directory/'input').write_text(' ')
                        redirected = (directory/'input').open('rb')
                    argv = [str(binary), '--headless', '--mcp', '--agent-scope', 'control', '--runtime-agent', str(wrapper)]
                    if stop == 'socket-eof':
                        argv += ['--listen', '127.0.0.1:0']
                    if operation == 'BP_SET': argv += ['--break', 'main']
                    argv += ['--', str(fixture)]
                    process = subprocess.Popen(argv, env=env, stdin=redirected or subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, bufsize=0)
                    if stop == 'socket-eof':
                        port, _ = listen_and_report(process, directory/'stderr.log', timeout=10)
                        peer = socket.create_connection(('127.0.0.1', port), timeout=5)
                    fault = helper.wait(lambda: json.loads((directory/'fault.json').read_text()) if (directory/'fault.json').exists() else None, 'startup fault not reached')
                    owned = fault['owned']
                    assert fault['op'] == op and fault['mode'] == mode and len(owned) >= 2, fault
                    if operation == 'BP_SET': assert len(owned) >= 3, 'target must exist before the held breakpoint request'
                    row['fault'] = dict(op=op, mode=mode, owned_count=len(owned))
                    at = time.monotonic()
                    if stop.endswith('eof'):
                        if stop == 'buffered-eof':
                            # Unread requests are still owed an answer: the hangup
                            # alone must not cancel. A signal still does, at once.
                            process.stdin.write(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n')
                            process.stdin.close()
                            try:
                                process.wait(timeout=.5)
                                raise AssertionError('a hangup dropped unread requests')
                            except subprocess.TimeoutExpired:
                                pass
                            at = time.monotonic()
                            process.send_signal(signal.SIGINT)
                        elif stop == 'file-eof':
                            (directory/'input').write_text('')
                        elif stop == 'socket-eof':
                            peer.shutdown(socket.SHUT_WR)
                        else:
                            process.stdin.close()
                    else:
                        process.send_signal(signal.SIGINT)
                    row['exit_code'] = process.wait(timeout=30*max(1, os.getloadavg()[0]/len(os.sched_getaffinity(0))))
                    row['exit_seconds'] = time.monotonic()-at
                    row['transport_gone'] = helper.same(owned[0]) is None
                    if args.wrong_result: row['transport_gone'] = False
                    assert row['transport_gone'], row
                    # The frontend owns the proxy; the proxy's orphaned children
                    # can be adopted by this harness after an injected SIGKILL.
                    def children_gone():
                        for saved in owned[1:]:
                            try: os.waitpid(saved['pid'], os.WNOHANG)
                            except ChildProcessError: pass
                        return not any(helper.same(saved) for saved in owned[1:])
                    helper.wait(children_gone, 'startup left an owned agent or target')
                    row['descendants_gone'] = True
                    text = (directory/'stderr.log').read_text()
                    assert 'handle retained' not in text, text
                    assert (row['exit_code'] == 0 if mode == 'hold' else row['exit_code'] in (0, 1)), row
                    row['status'] = 'pass'
                    print(json.dumps(row), flush=True)
                except BaseException as err:
                    row.update(status='fail', error=repr(err))
                    raise
                finally:
                    if process is not None:
                        known = {item['pid'] for item in owned}
                        for pid in descendants(process.pid):
                            saved = helper.identity(pid)
                            if saved and pid not in known: owned.append(saved)
                        if process.poll() is None:
                            process.kill()
                            process.wait()
                        for saved in owned:
                            if helper.same(saved):
                                try: os.kill(saved['pid'], signal.SIGKILL)
                                except ProcessLookupError: pass
                        for stream in (process.stdin, process.stdout, redirected):
                            if stream and not stream.closed: stream.close()
                        if peer: peer.close()
                        for saved in owned:
                            try: os.waitpid(saved['pid'], 0)
                            except ChildProcessError: pass
        for name in ('batch', 'missing-capture', 'attach-gone'):
            if not (args.only or name) == name:
                continue
            row = dict(case=name, status='running')
            rows.append(row)
            try:
                plain(name, binary, fixture, work/name, row, args.wrong_result)
                row['status'] = 'pass'
                print(json.dumps(row), flush=True)
            except BaseException as err:
                row.update(status='fail', error=repr(err))
                raise
        assert rows, 'no startup case selected'
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
        p.add_argument('--only')
        p.add_argument('--matrix', action='store_true')
        p.add_argument('--wrong-result', action='store_true')
        run(p.parse_args())
