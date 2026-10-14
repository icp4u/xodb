#!/usr/bin/env python3
"""Log levels with a window, on a private headless display: the default text,
-qq, a per-topic override, and one start and one end line per hidden period."""
import importlib.util
import os
from pathlib import Path
import re
import signal
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
spec = importlib.util.spec_from_file_location('private_display', root/'tests/helpers/display.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
# Short: the compositor's socket path must fit sun_path.
h.WORK = str(root/'.work'/('lg'+str(time.time_ns())[-8:]))
xodb = './zig-out/bin/xodb'
d = h.Display('d')
env = {k: v for k, v in d.env.items() if k not in ('XODB_LOG', 'XODB_LOG_FILE')}
PREFIXED = re.compile(r'^xodb\[([a-z]+)\] \+\d+\.\d{3}s \S', re.M)
checks = 0
running = []


def check(condition, *detail):
    global checks
    assert condition, detail
    checks += 1


def run(*options):
    done = subprocess.run([xodb, *options], stdin=subprocess.DEVNULL, capture_output=True, env=env, timeout=60)
    return done.returncode, done.stdout.decode(), done.stderr.decode()


def swap(workspace):
    subprocess.run(['swaymsg', 'workspace', 'number', str(workspace)], env=env, check=True, capture_output=True, timeout=5)


def wait_for(probe, seconds, what):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if probe():
            return
        time.sleep(0.05)
    raise AssertionError(what)


try:
    debugger = ('--frames', '3', '--', './zig-out/bin/xodb-fixture')
    overview = ('--overview', '--frames', '3')
    for name, command, last in (('debugger', debugger, r'xodb: 3 frames, clean shutdown \(reason=frame_limit, signal=0\)\n'),
                                ('overview', overview, r'xodb: overview 3 frames, \d+ samples, clean shutdown \(reason=frame_limit\)\n')):
        # Default: the lines of every release so far and no prefixed ones.
        status, stdout, stderr = run(*command)
        check(status == 0, name, status, stderr)
        check(re.search(r'^Vulkan device: \S.*\n', stderr, re.M) and re.search(last + r'\Z', stderr) and not PREFIXED.search(stderr), name, stderr)
        check(re.fullmatch(r'xodb: first window frame submitted in \d+\.\d{3} ms\n', stdout), name, stdout)
        usual = len(stderr.splitlines())
        # -qq: a clean run prints nothing on either stream.
        status, stdout, stderr = run('-qq', *command)
        check(status == 0 and stderr == '' and stdout == '', name, stdout, stderr)
        # One topic raised: its debug lines appear, no other topic's, and the usual lines stay.
        status, stdout, stderr = run('--log=render=trace', *command)
        topics = set(PREFIXED.findall(stderr))
        check(status == 0 and topics == {'render'}, name, topics, stderr)
        check(re.search(r'^xodb\[render\] \+\d+\.\d{3}s Vulkan device \d+ of \d+ chosen: \S', stderr, re.M), name, stderr)
        check(re.search(r'^Vulkan device: \S.*\n', stderr, re.M) and re.search(last + r'\Z', stderr), name, stderr)
        check(len([line for line in stderr.splitlines() if not PREFIXED.match(line)]) == usual, name, stderr)
        # Another topic raised leaves the renderer's debug lines out.
        status, stdout, stderr = run('--log=agent=trace,mcp=debug', *command)
        check(status == 0 and not PREFIXED.search(stderr), name, stderr)
        # --log-file takes the lines, the first-frame line included.
        log = Path(d.dir)/f'{name}.log'
        status, stdout, stderr = run('-v', '--log-file', str(log), *command)
        text = log.read_text()
        check(status == 0 and stderr == '' and stdout == '', name, stdout, stderr)
        check('xodb: first window frame submitted in ' in text and re.search(last + r'\Z', text) and 'xodb[render] ' in text, name, text)

    # A hidden window: one line when frames start to be deferred and one when
    # they flow again, however long it stays hidden; nothing at the default level.
    # The pair is written at most once in ten seconds.
    for options, shown in ((('-v',), True), ((), False)):
        log = Path(d.dir)/('hidden-v.log' if shown else 'hidden.log')
        with log.open('wb') as stream:
            app = subprocess.Popen([xodb, *options, '--overview'], stdin=subprocess.DEVNULL, stdout=stream, stderr=stream, env=env)
        running.append(app)
        wait_for(lambda: 'first window frame submitted' in log.read_text(), 20, log.read_text())
        time.sleep(0.5)
        # (period, pairs written so far): the second hide follows the first at
        # once and is inside the quiet time of the pair, so it says nothing; the
        # third comes after it and is reported again.
        first = 0.0
        for period, pairs in ((1, 1), (2, 1), (3, 2)):
            if period == 3:
                time.sleep(max(0.0, first + 10.5 - time.monotonic()))
            before = pairs - 1 if period != 2 else pairs
            swap(2)
            if shown and period != 2:
                wait_for(lambda: log.read_text().count('frame deferred, event loop remains active') == pairs, 10, log.read_text())
                if period == 1:
                    first = time.monotonic()
            time.sleep(3.5)
            text = log.read_text()
            check(app.poll() is None, text)
            check(text.count('frame deferred, event loop remains active') == (pairs if shown else 0), period, text)
            check(len(re.findall(r'^xodb\[render\] \+\d+\.\d{3}s render .* ready after \d+ ms$', text, re.M)) == (before if shown else 0), period, text)
            swap(1)
            if shown and period != 2:
                wait_for(lambda: log.read_text().count(' ready after ') == pairs, 10, log.read_text())
            else:
                time.sleep(1.5)
                check(log.read_text().count(' ready after ') == (pairs if shown else 0), period, log.read_text())
        text = log.read_text()
        if shown:
            starts = re.findall(r'^xodb\[render\] \+\d+\.\d{3}s render (.*) not ready for (\d+) ms; frame deferred, event loop remains active$', text, re.M)
            ends = re.findall(r'^xodb\[render\] \+\d+\.\d{3}s render (.*) ready after (\d+) ms$', text, re.M)
            check(len(starts) == 2 and len(ends) == 2, text)
            # The end names what was awaited and how long no frame was drawn: the whole hidden time.
            check(all(a[0] == b[0] and int(b[1]) >= 3000 and int(b[1]) >= int(a[1]) for a, b in zip(starts, ends)), starts, ends)
        else:
            check('not ready' not in text and ' ready after ' not in text and not PREFIXED.search(text), text)
        app.send_signal(signal.SIGTERM)
        check(app.wait(15) == 0, log.read_text())
        check(re.search(r'xodb: overview \d+ frames, \d+ samples, clean shutdown \(reason=signal\)\n\Z', log.read_text()), log.read_text())
    print(f'log levels with a window: {checks} checks; {d.dir}')
finally:
    for app in running:
        if app.poll() is None:
            app.kill()
            app.wait()
    d.close()
