#!/usr/bin/env python3
"""Fast private-GUI lane: hold a real agent SYNC reply, then repaint an editor.

The pixels must approach a previously rendered editor while the reply remains
held. This test also runs against the prior binary as a negative oracle; it
must fail after the proxy has recorded the held reply, before release.
"""
import importlib.util
import json
import os
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
            body = exact(source, size)
            if body is None:
                raise RuntimeError('missing proxy body')
            # SYNC is the actual owner poll, not a timer pretending to do IO.
            if responses and op == 4 and (directory/'arm').exists() and not (directory/'held.json').exists():
                (directory/'held.json').write_text(json.dumps({'op': op, 'request': request,
                    'target': target, 'status': status, 'flags': flags, 'bytes': size}))
                deadline = time.monotonic() + 30
                while not (directory/'release').exists():
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


def run(binary=None):
    from PIL import Image, ImageChops, ImageStat
    started = time.monotonic()
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
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
    wrapper = work/'agent-proxy'
    wrapper.write_text('#!/usr/bin/env python3\nimport os, sys\nos.execv(sys.executable, '+repr([
        sys.executable, str(Path(__file__).resolve()), '--proxy', str(work), str(root/'zig-out/bin/xodb-agent')])+')\n')
    wrapper.chmod(0o755)
    display = None
    result = {'load': os.getloadavg(), 'cpus': os.cpu_count(), 'barrier_observed': False, 'passed': False}
    try:
        display = h.Display(str(root), ['--runtime-agent', str(wrapper), '--source', 'tests/fixtures/m1.c',
            '--', './zig-out/bin/xodb-m1-fixture', 'w'], binary=binary)
        state = display.stopped()
        assert state, 'owned target did not stop'
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
        result['before'] = usage(display.app.pid)
        (work/'arm').touch()
        held = wait(lambda: json.loads((work/'held.json').read_text()) if (work/'held.json').exists() else None,
                    'proxy did not observe a real remote reply')
        assert held['op'] == 4 and held['flags'] == 1 and held['bytes'] > 0, held
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
        run(sys.argv[1] if len(sys.argv) > 1 else None)
