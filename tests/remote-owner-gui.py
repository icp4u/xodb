#!/usr/bin/env python3
"""Fast private-GUI lane: hold a real agent SYNC reply, then repaint an editor.

The pixels must approach a previously rendered editor while the reply remains
held. This test also runs against the prior binary as a negative oracle; it
must fail after the proxy has recorded the held reply, before release.
"""
import argparse
import importlib.util
import json
import os
import re
import math
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import threading
import time


def proxy(directory, agent):
    directory = Path(directory)
    child = subprocess.Popen([agent, '--stdio'], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, bufsize=0)
    (directory/'agent.json').write_text(json.dumps({'pid': child.pid}))
    disconnected = threading.Event()

    def exact(fd, size):
        result = bytearray()
        while len(result) < size:
            chunk = os.read(fd, size - len(result))
            if not chunk:
                if result:
                    raise RuntimeError('truncated agent frame')
                return None
            result.extend(chunk)
        return bytes(result)

    def relay(source, destination, responses):
        while True:
            header = exact(source, 32)
            if header is None:
                return
            magic, version, op, request, target, status, size, flags = struct.unpack('>4sHHQIIII', header)
            if magic != b'XRT1' or version != 2 or size > 1024*1024:
                raise RuntimeError('invalid proxy frame')
            if not responses:
                with (directory/'requests.jsonl').open('a') as log:
                    log.write(json.dumps({'transport': os.getpid(), 'op': op, 'request': request})+'\n')
            body = exact(source, size)
            if body is None:
                raise RuntimeError('missing proxy body')
            # SYNC is the actual owner poll, not a timer pretending to do IO.
            if responses and op == (int((directory/'hold-op').read_text()) if (directory/'hold-op').exists() else 4) and (directory/'arm').exists() and not (directory/'held.json').exists():
                (directory/'held.json').write_text(json.dumps({'op': op, 'request': request,
                    'target': target, 'status': status, 'flags': flags, 'bytes': size}))
                deadline = time.monotonic() + 30
                while not (directory/'release').exists():
                    if disconnected.is_set():
                        (directory/'cancelled-before-release').touch()
                        return
                    if time.monotonic() >= deadline:
                        raise TimeoutError('barrier release deadline')
                    time.sleep(.005)
            data = header + body
            while data:
                data = data[os.write(destination, data):]

    def requests():
        try:
            relay(0, child.stdin.fileno(), False)
        finally:
            disconnected.set()
            child.stdin.close()

    thread = threading.Thread(target=requests, daemon=True)
    thread.start()
    try:
        relay(child.stdout.fileno(), 1, True)
    finally:
        if child.poll() is None:
            child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def wait(predicate, message, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError(message)


def usage(pid):
    fields = Path('/proc', str(pid), 'stat').read_text().split(') ', 1)[1].split()
    return {'cpu_s': (int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),
            'rss_bytes': int(fields[21])*os.sysconf('SC_PAGE_SIZE')}


def retry_failure(display, work, result, scale):
    """Actual failing captures stay paced while local input continues painting."""
    def frame():
        # An active producer can leave a partial trailing line. Only completed
        # records provide evidence; never try to parse the current tail.
        text = Path(display.log).read_text()
        lines = text[:text.rfind('\n')+1].splitlines()
        rows = [re.search(r'remote frame=(\d+) publication=(\d+) editor=(\w+) preparations=(\d+)', line) for line in lines]
        return next((tuple(int(v) if i != 2 else v for i, v in enumerate(row.groups())) for row in reversed(rows) if row), None)
    initial = wait(lambda: row if (row := frame()) and row[1] else None, 'first confirmed publication', timeout=10*scale)
    result['before'] = usage(display.app.pid)
    (work/'fail-publication').touch()
    # A confirmed breakpoint changes the workspace, forcing a real new capture.
    generation = display.session()['generation']
    display.tool('set_breakpoint', symbol='change_value', generation=generation)
    display.keys('tap', 18)
    first = wait(lambda: row if (row := frame()) and row[3] > initial[3] else None, 'injected preparation was not attempted', timeout=10*scale)
    result['failure_observed'] = True
    shot = display.shot('persistent-failure')
    visible = subprocess.run(['tesseract', shot, 'stdout'], capture_output=True, text=True, check=True, env={**os.environ, 'OMP_THREAD_LIMIT': '1'}, timeout=10*scale).stdout
    (work/'failure-ocr.txt').write_text(visible)
    assert 'OutOfMemory' in visible and 'last confirmed' in visible, visible
    started = time.monotonic()
    display.keys(*[item for code in ([30, 14]*20) for item in ('tap', code)])
    after = frame()
    elapsed = time.monotonic()-started
    result['during'] = usage(display.app.pid)
    result['frames_during_failure'] = after[0]-first[0]
    result['preparations_during_failure'] = after[3]-first[3]
    result['failure_seconds'] = elapsed
    assert after[0]-first[0] >= 30 and after[2] == 'open', (first, after)
    # Two independently paced producers (inspection and refresh), allowing
    # their initial retries; after ramp-up neither may retry over once per 4s.
    assert after[3]-first[3] <= 10+2*math.ceil(elapsed/4), result
    # Pending work must not grow behind the failing presentation path.
    assert display.session()['state'] == 'stopped'
    (work/'fail-publication').unlink()
    display.keys('tap', 1, 'tap', 47)
    recovered = wait(lambda: row if (row := frame()) and row[1] > initial[1] else None, 'publication did not recover', timeout=10*scale)
    assert display.session()['state'] == 'stopped'
    result['after'] = usage(display.app.pid)
    result['recovered_publication'] = recovered[1]
    result['performance_measurable'] = os.getloadavg()[0] <= result['cpus']


def setup(root):
    spec = importlib.util.spec_from_file_location('input_repro', root/'tests/helpers/input.py')
    h = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(h)
    work = Path(tempfile.mkdtemp(prefix='input-owner-', dir=root/'.work'))
    work.chmod(0o755)
    h.WORK = str(work)
    for name in ('tmp', 'cache'):
        (work/name).mkdir(mode=0o755)
    for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
        for mode, suffix in (('client-header', '.h'), ('private-code', '.c')):
            subprocess.run(['wayland-scanner', mode, xml, str(work/(stem+suffix))], check=True, timeout=10)
    h.HELPER = str(work/'vinput')
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), str(root/'tests/helpers/vinput.c'),
                    str(work/'virtual-pointer.c'), str(work/'virtual-keyboard.c'), '-lwayland-client',
                    '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=20)
    return h, work


def run(binary=None, close_held=False, failure_retry=False, capture_held=False, capture_ack=False):
    from PIL import Image, ImageChops, ImageStat
    started = time.monotonic()
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    h, work = setup(root)
    wrapper = work/'agent-proxy'
    wrapper.write_text('#!/usr/bin/env python3\nimport os, sys\nos.execv(sys.executable, '+repr([
        sys.executable, str(Path(__file__).resolve()), '--proxy', str(work), str(root/'zig-out/bin/xodb-agent')])+')\n')
    wrapper.chmod(0o755)
    display = None
    if failure_retry:
        os.environ['XODB_TEST_REMOTE_DIR'] = str(work)
    result = {'load': os.getloadavg(), 'cpus': len(os.sched_getaffinity(0)), 'barrier_observed': False, 'close_held': close_held, 'failure_retry': failure_retry, 'capture_held': capture_held, 'capture_ack': capture_ack, 'passed': False}
    try:
        display = h.Display(str(root), [*(['--agent-scope', 'control'] if failure_retry or capture_held else []), '--runtime-agent', str(wrapper), '--source', 'tests/fixtures/m1.c',
            '--', './zig-out/bin/xodb-m1-fixture', 'w'], binary=binary)
        state = display.stopped()
        assert state, 'owned target did not stop'
        if failure_retry:
            retry_failure(display, work, result, h.load_scale())
            result['passed'] = True
            return
        # The watch editor has a distinct body in this fixed viewport. Establish
        # its expected pixels before holding anything; a frozen initial GUI is
        # not evidence that the slow-remote condition caused a freeze.
        crop = (650, 630, 1250, 760)
        def shot(name):
            return Image.open(display.shot(name)).convert('RGB').crop(crop)
        def distance(left, right):
            return sum(ImageStat.Stat(ImageChops.difference(left, right)).sum)
        closed = shot('closed-initial')
        display.keys('tap', 18)
        opened = wait(lambda: (img if distance(img := shot('calibrate-editor'), closed) > 0 else None),
                      'local editor did not paint before the barrier')
        display.keys('tap', 1, 'tap', 47)
        closed = wait(lambda: (img if distance(img := shot('calibrate-closed'), opened) > 0 else None),
                      'local editor did not close before the barrier')
        if capture_held:
            capture = display.tool('start_profile', generation=display.session()['generation'], frequency_hz=99, duration_ms=0)['capture']
            result['capture_started'] = capture
            display.tool('continue', generation=display.session()['generation'])
            enum = (root/'src/runtime/rpc.h').read_text().split('enum xrt_rpc_op {', 1)[1].split('};', 1)[0]
            operations = re.findall(r'XRT_RPC_[A-Z_]+', enum)
            (work/'hold-op').write_text(str(operations.index('XRT_RPC_PERF_ACK' if capture_ack else 'XRT_RPC_PERF_RING')+1))
        result['before'] = usage(display.app.pid)
        (work/'arm').touch()
        held = wait(lambda: json.loads((work/'held.json').read_text()) if (work/'held.json').exists() else None,
                    'proxy did not observe a real remote reply')
        assert held['op'] == (int((work/'hold-op').read_text()) if capture_held else 4) and held['flags'] == 1 and held['bytes'] > 0, held
        result['barrier_observed'] = True
        result['held'] = held
        display.keys('tap', 18)
        def editor_painted():
            assert not (work/'release').exists(), 'barrier was released before repaint'
            image = shot('held-editor')
            return distance(image, opened) < distance(image, closed)/4
        wait(editor_painted, 'editor did not repaint while the remote reply was held')
        result['held_usage'] = usage(display.app.pid)
        result['held_load'] = os.getloadavg()
        result['performance_measurable'] = result['held_load'][0] <= result['cpus']
        if close_held:
            # Sway sends the application's real close event. The held reply is
            # never released until both the owner and its transport have ended.
            close_started = time.monotonic()
            subprocess.run(['swaymsg', '-s', display.env['SWAYSOCK'], '[app_id="xodb"] kill'],
                           env=display.env, capture_output=True, check=True, timeout=10*h.load_scale())
            display.app.wait(timeout=15*h.load_scale())
            assert display.app.returncode == 0, display.tail()
            assert not (work/'release').exists()
            assert (work/'cancelled-before-release').exists(), 'transport did not observe close while holding reply'
            log = Path(display.log).read_text()
            if capture_held:
                expected = 'RemoteOutcomeUnknown' if capture_ack else 'RemoteCancelled'
                assert expected in log and 'ring header is unusable' not in log, log[-2000:]
            else:
                assert 'remote quiesce poll_error=RemoteCancelled' in log, log[-2000:]
            assert 'remote owner closed' in log, log[-2000:]
            result['close_s'] = time.monotonic()-close_started
            result['owner_done_before_release'] = True
        else:
            (work/'release').touch()
            after = display.session()
            assert after['generation'] == state['generation'] and after['state'] == 'stopped', after
            display.keys('tap', 1)
            assert display.alive(), display.tail()
        result['passed'] = True
    finally:
        (work/'release').touch()
        if display:
            display.close()
        result['wall_s'] = time.monotonic() - started
        (work/'result.json').write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps({**result, 'work': str(work)}), flush=True)
    assert result['passed']


if __name__ == '__main__':
    if len(sys.argv) >= 4 and sys.argv[1] == '--proxy':
        proxy(sys.argv[2], sys.argv[3])
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('binary', nargs='?')
        parser.add_argument('--close-held', action='store_true')
        parser.add_argument('--failure-retry', action='store_true')
        parser.add_argument('--capture-held', action='store_true')
        parser.add_argument('--capture-ack', action='store_true')
        args = parser.parse_args()
        capture = args.capture_held or args.capture_ack
        run(args.binary, args.close_held or capture, args.failure_retry, capture, args.capture_ack)
