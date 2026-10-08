#!/usr/bin/env python3
"""Exact-capture host-cost status, expiry and human revocation on private Sway."""
import importlib.util
import json
import os
from pathlib import Path
import select
import subprocess
import time
from types import SimpleNamespace

from PIL import Image


def main():
    os.umask(0o022)
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    work = root / '.work' / ('input-fds-' + str(time.time_ns())[-8:])
    work.mkdir(parents=True, mode=0o755)
    for name in ('tmp', 'cache'):
        (work / name).mkdir(mode=0o755)
    run = work / 'run'; run.mkdir(mode=0o700)
    assert len(os.fsencode(work / 'rt/1')) <= 72, 'Use a shorter checkout for private Sway'

    def module(name, path):
        spec = importlib.util.spec_from_file_location(name, root / path)
        value = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(value)
        return value

    h = module('fd_input', 'tests/helpers/input.py')
    shared = module('fd_shared', 'tests/shared-sessions.py')
    h.WORK = str(work)
    h.HELPER = str(work / 'vinput')
    for protocol, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
        for mode, suffix in (('client-header', '.h'), ('private-code', '.c')):
            subprocess.run(['wayland-scanner', mode, protocol, str(work / (stem + suffix))], check=True, timeout=10)
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work),
                    'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'),
                    str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon',
                    '-lm', '-o', h.HELPER], check=True, timeout=30)
    results, peers = [], []
    d = event = None

    def check(label, condition):
        results.append({'check': label, 'status': 'pass' if condition else 'fail'})
        print(('PASS ' if condition else 'FAIL ') + label, flush=True)
        assert condition, label

    def until(fn, predicate, label, seconds=8):
        return shared.eventually(fn, predicate, label, timeout=seconds)

    def cache(peer, name, **args):
        end = time.monotonic() + 5
        while True:
            reply = peer.raw(name, **args)
            if not reply.get('error') and not reply['result'].get('isError'):
                return reply['result']['structuredContent']
            assert reply.get('result', {}).get('content', [{}])[0].get('text') == 'FdCacheBusy' and time.monotonic() < end, reply
            time.sleep(.003)

    def perf_fds():
        found = []
        for path in Path(f'/proc/{d.app.pid}/fd').iterdir():
            try:
                if 'perf_event' in os.readlink(path): found.append(path.name)
            except FileNotFoundError:
                pass
        return found

    def footer(name):
        path = d.shot(name)
        with Image.open(path) as shot:
            shot.crop((0, shot.height - 32, shot.width, shot.height)).save(path + '.footer.png')
        return ' '.join(h.ocr(path + '.footer.png', '--psm', '7').split()).lower()

    try:
        d = h.Display.__new__(h.Display)
        d.__init__(str(root), ['--session-socket', str(run / 's'), '--agent-scope', 'control',
                                 '--source', 'tests/fixtures/m1.c', '--', './zig-out/bin/xodb-m1-fixture', 'w'], stdio=False)
        host = SimpleNamespace(path=run / 's', clients=[])
        controller = shared.Client(host, 'fd-status-controller'); peers.append(controller)
        observer = shared.Client(host, 'fd-status-observer'); peers.append(observer)
        until(controller.session, lambda r: r['state'] == 'stopped', 'owned debugger fixture stopped')
        check('ordinary GUI status opens no perf events', not perf_fds() and 'exact fd capture' not in footer('inactive'))
        event = subprocess.Popen([str(root / 'zig-out/bin/xodb-fd-events'), str(d.app.pid)], cwd=work,
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        assert select.select([event.stdout], [], [], 5)[0]
        assert event.stdout.readline().startswith('ready ')
        start = int(shared.process_identity(event.pid)[0])
        args = dict(mode='events', pid=event.pid, start_ticks=start)
        consent = dict(pid=event.pid, start_ticks=start, acknowledge_host_cost=True)
        idle = cache(observer, 'get_fd_activity', **args)
        check('observer GUI reads do not activate exact mode', not idle['running'] and not perf_fds())
        controller.claim()

        def begin():
            cache(controller, 'start_fd_events', **consent)
            return until(lambda: cache(observer, 'get_fd_activity', **args), lambda r: r['running'], 'capture active')

        begin()
        text = until(lambda: footer('active-wide'), lambda t: 'capture active' in t and 'roughly 10' in t, 'wide host-cost footer')
        check('wide GUI shows active capture and full host-wide syscall cost', 'all syscalls on this machine' in text and len(perf_fds()) == 2)
        for width in (900, 640):
            begin()  # Explicit controller renewal while checking the layout.
            subprocess.run(['swaymsg', 'output', 'HEADLESS-1', 'mode', f'{width}x800'], env=d.env, check=True, capture_output=True, timeout=10)
            text = until(lambda: footer('active-' + str(width)), lambda t: 'capture active' in t and 'all host syscalls' in t, 'compact host-cost footer')
            check(f'{width}px GUI retains active state and host-wide cost', 'roughly 10' in text and 'slower' in text)
        cache(controller, 'stop_fd_events')
        until(perf_fds, lambda r: not r, 'explicit stop closes events')
        until(lambda: footer('stopped'), lambda t: 'exact fd capture' not in t, 'stopped footer')
        check('explicit stop clears the warning after handles close', True)
        begin()
        until(lambda: cache(observer, 'get_fd_activity', **args), lambda r: not r['running'], 'GUI and observers cannot renew demand', 5)
        until(perf_fds, lambda r: not r, 'expiry closes events')
        until(lambda: footer('expired'), lambda t: 'exact fd capture' not in t, 'expired footer')
        check('GUI status and observer reads let authorization expire', True)
        begin()
        d.keys('tap', 66)
        until(observer.info, lambda r: r['scope'] == 'observe' and r['controller_id'] is None, 'human revocation')
        until(perf_fds, lambda r: not r, 'human revocation closes events')
        until(lambda: footer('revoked'), lambda t: 'exact fd capture' not in t, 'revoked footer')
        check('human revocation clears exact capture and its warning', True)
        print(f'FD capture GUI: {len(results)} passed, 0 failed: {work}', flush=True)
    finally:
        (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        for peer in peers: peer.close()
        if event is not None and event.poll() is None:
            event.terminate()
            try: event.wait(timeout=5)
            except subprocess.TimeoutExpired:
                event.kill(); event.wait(timeout=5)
        if d is not None: d.close()


if __name__ == '__main__':
    main()
