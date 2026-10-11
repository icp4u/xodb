#!/usr/bin/env python3
"""Fast private-GUI lane: hold a real gdbserver memory reply through close."""
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import threading
import time


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def run():
    root = Path(__file__).resolve().parents[1]
    owner = module('owner_test', root/'tests/remote-owner-gui.py')
    gdb = module('gdb_test', root/'tests/gdb-remote.py')
    h, work = owner.setup(root)
    assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
    (work/'stub').mkdir(mode=0o755)
    stub = gdb.Stub('gdbserver-launch', work/'stub')
    display = None
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    listener.settimeout(20*h.load_scale())
    endpoint = '127.0.0.1:'+str(listener.getsockname()[1])
    hold = threading.Event()
    disconnected = threading.Event()
    released = threading.Event()
    held = threading.Event()
    errors = []
    active = []
    report = {'passed': False, 'load': os.getloadavg(), 'cpus': len(os.sched_getaffinity(0))}
    started = time.monotonic()

    def proxy():
        try:
            client, _ = listener.accept()
            backend = socket.create_connection(tuple([stub.endpoint.rsplit(':', 1)[0], int(stub.endpoint.rsplit(':', 1)[1])]))
            active.extend([client, backend])
            def requests():
                observed = bytearray()
                try:
                    while True:
                        data = client.recv(65536)
                        if not data:
                            break
                        observed.extend(data)
                        if len(observed) > 65536:
                            del observed[:-8192]
                        if (work/'arm').exists() and re.search(rb'\$m[0-9a-fA-F]+,[0-9a-fA-F]+#[0-9a-fA-F]{2}', observed):
                            hold.set()
                            (work/'request-observed').write_bytes(bytes(observed[-512:]))
                        backend.sendall(data)
                except OSError as error:
                    if not released.is_set() and not held.is_set():
                        errors.append(str(error))
                finally:
                    disconnected.set()
            thread = threading.Thread(target=requests)
            thread.start()
            try:
                while True:
                    data = backend.recv(65536)
                    if not data:
                        break
                    if hold.is_set() and not held.is_set():
                        (work/'reply-held').write_bytes(data)
                        held.set()
                        while not released.is_set():
                            if disconnected.wait(.01):
                                (work/'cancelled-before-release').touch()
                                return
                    client.sendall(data)
            finally:
                for sock in (client, backend):
                    try:
                        sock.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                thread.join(timeout=10*h.load_scale())
                assert not thread.is_alive()
        except Exception as error:
            errors.append(repr(error))

    thread = None
    try:
        stub.start_server()
        thread = threading.Thread(target=proxy)
        thread.start()
        display = h.Display(str(root), ['--gdb-remote', endpoint])
        state = display.stopped()
        assert state, display.tail()
        report['before'] = owner.usage(display.app.pid)
        (work/'arm').touch()
        display.serial += 1
        request = {'jsonrpc': '2.0', 'id': display.serial, 'method': 'tools/call', 'params': {
            'name': 'read_memory', 'arguments': {'address': '0x'+stub.symbols['marker'], 'length': 8}}}
        display.app.stdin.write((json.dumps(request)+'\n').encode())
        display.app.stdin.flush()
        assert held.wait(10*h.load_scale()), (errors, display.tail())
        assert (work/'request-observed').exists() and (work/'reply-held').stat().st_size > 0
        display.keys('tap', 18)
        owner.wait(lambda: 'editor=open' in Path(display.log).read_text(), 'GDB held-reply editor did not paint', timeout=10*h.load_scale())
        report['during'] = owner.usage(display.app.pid)
        subprocess.run(['swaymsg', '-s', display.env['SWAYSOCK'], '[app_id="xodb"] kill'], env=display.env,
                       capture_output=True, check=True, timeout=10*h.load_scale())
        display.app.wait(timeout=15*h.load_scale())
        assert display.app.returncode == 0, Path(display.log).read_text()
        replies = [json.loads(line) for line in display.app.stdout.read().splitlines()]
        terminal = next(reply for reply in replies if reply.get('id') == request['id'])
        assert terminal['result']['isError'] and 'RemoteCancelled' in json.dumps(terminal), terminal
        report['terminal_reply'] = terminal
        owner.wait(lambda: (work/'cancelled-before-release').exists(), 'GDB socket did not close before release')
        assert not released.is_set() and 'remote owner closed' in Path(display.log).read_text()
        report['owner_done_before_release'] = True
        report['passed'] = True
    finally:
        released.set()
        if display:
            display.close()
        for sock in active:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()
        listener.close()
        if thread:
            thread.join(timeout=10*h.load_scale())
            assert not thread.is_alive()
        stub.close()
        if stub.pid:
            try:
                os.waitpid(stub.pid, 0)
            except ChildProcessError:
                pass
        report['seconds'] = time.monotonic()-started
        report['proxy_errors'] = errors
        report['performance_measurable'] = os.getloadavg()[0] <= report['cpus']
        (work/'result.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps({**report, 'work': str(work)}), flush=True)
    assert not errors, errors


if __name__ == '__main__':
    run()
