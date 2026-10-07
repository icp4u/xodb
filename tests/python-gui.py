#!/usr/bin/env python3
"""CPython Locals/Watch, observer MCP stack and the demo script on a private
headless compositor. Pass a NEW SHORT work path so the compositor's Unix
sockets fit sun_path.
Run: python3 tests/python-gui.py --python /path/to/dwarf/python3 --work /tmp/pg
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import time

root = Path(__file__).resolve().parent.parent
os.chdir(root)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--python', required=True)
p.add_argument('--work', required=True, type=Path)
args = p.parse_args()
work = (args.work/'.work/input-python').resolve()
work.mkdir(parents=True, mode=0o755)
spec = importlib.util.spec_from_file_location('private_input', root/'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (work/name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work/(stem+'.h'))], check=True, timeout=10)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work/(stem+'.c'))], check=True, timeout=10)
h.HELPER = str(work/'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), 'tests/helpers/vinput.c', str(work/'virtual-pointer.c'), str(work/'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=60)
LETTERS = dict(v=47, a=30, l=38, u=22, e=18, k=37, y=21, m=50, p=25)
RETURN, SPACE, F8 = 28, 57, 66


def watch(d, expression):
    sequence = ['tap', LETTERS['e']]
    for letter in expression:
        sequence.extend(['tap', LETTERS[letter]])
    sequence.extend(['tap', RETURN])
    d.keys(*sequence)


checks = []
# 1. The fixture under MCP control: Locals, an E watch, then observer reads.
target = subprocess.Popen([args.python, 'tests/fixtures/python/stopped.py', 'nested'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
d = None
try:
    assert select.select([target.stdout], [], [], 20)[0]
    assert target.stdout.readline() == b'ready\n'
    d = h.Display(str(root), ['--agent-scope', 'control', '--attach', str(target.pid)])
    d.tool('set_breakpoint', generation=d.session()['generation'], symbol='_PyDict_SetItem_Take2')
    d.tool('continue', generation=d.session()['generation'])
    target.stdin.write(b'go\n')
    target.stdin.flush()
    for attempt in range(50):
        snap = d.stopped('breakpoint')
        assert snap
        key = d.tool('evaluate_expression', tid=target.pid, frame=0, expression='key')['value']
        if key['display'].startswith("str 'answer'"):
            break
        d.tool('continue', generation=d.session()['generation'])
    regs = d.tool('get_registers', tid=target.pid)
    value = d.tool('evaluate_expression', tid=target.pid, frame=0, expression='value')['value']
    local_values = d.tool('list_locals', tid=target.pid, frame=0)['locals']
    assert re.fullmatch(r'list \(3 items\) \(refcnt \d+\)', value['display']), value
    assert next(v for v in local_values if v['name'] == 'value')['value']['display'] == value['display']
    assert next(v for v in local_values if v['name'] == 'key')['value']['display'] == key['display']
    time.sleep(.3)
    d.shot('fixture-locals')
    watch(d, 'value')
    time.sleep(.3)
    d.shot('fixture-watch')
    assert d.tool('get_registers', tid=target.pid) == regs and d.session()['generation'] == snap['generation']
    d.keys('tap', F8)
    assert d.wait(lambda s: s['agent_scope'] == 'observe')
    observer_generation = d.session()['generation']
    observer_regs = d.tool('get_registers', tid=target.pid)
    logical = d.tool('get_language_stack', tid=target.pid, language='python')
    names = [f['name'] for s in logical['segments'] for f in s['frames']]
    assert names == ['store', 'c', 'b', 'a', '<module>'] and logical['segments'][0]['state'] == 'complete', logical
    assert d.tool('get_registers', tid=target.pid) == observer_regs and d.session()['generation'] == observer_generation
    (work/'fixture-results.json').write_text(json.dumps({'value': value, 'locals': local_values, 'language_stack': logical}, indent=2)+'\n')
    subprocess.run(['swaymsg', 'output', 'HEADLESS-1', 'mode', '1600x1000'], env=d.env, check=True, capture_output=True, timeout=5)
    time.sleep(.3)
    d.shot('fixture-watch-large')
    d.app.stdin.close()
    assert d.app.wait(timeout=10) == 0
    checks.append('fixture: Locals and E watch show list (3 items); observer Python stack store<-c<-b<-a<-<module>; registers/generation unchanged; clean shutdown')
finally:
    if d:
        d.close()
    if target.poll() is None:
        target.terminate()
    try:
        target.wait(timeout=5)
    except subprocess.TimeoutExpired:
        target.kill()
        target.wait()
    (work/'fixture-stderr.txt').write_bytes(target.stderr.read())


class Demo(h.Display):
    """The same private compositor, running scripts/demo-python instead."""
    def __init__(self):
        Demo.count = getattr(h.Display, 'count', 0) + 1
        h.Display.count = Demo.count
        self.dir = os.path.join(h.WORK, f'run-{Demo.count:02d}')
        self.runtime = os.path.join(h.WORK, 'rt', str(Demo.count))
        os.makedirs(self.dir)
        os.makedirs(self.runtime, mode=0o700)
        config = os.path.join(self.dir, 'sway.conf')
        with open(config, 'w') as f:
            f.write('xwayland disable\noutput HEADLESS-1 mode 1280x800\noutput * bg #0b0f16 solid_color\ndefault_border none\nfocus_follows_mouse no\nseat seat0 hide_cursor 100\n')
        env = dict(os.environ)
        for key in ('DISPLAY', 'WAYLAND_DISPLAY', 'SWAYSOCK', 'DBUS_SESSION_BUS_ADDRESS'):
            env.pop(key, None)
        env.update(TMPDIR=os.path.join(h.WORK, 'tmp'), XDG_CACHE_HOME=os.path.join(h.WORK, 'cache'), XDG_RUNTIME_DIR=self.runtime, WLR_BACKENDS='headless', WLR_HEADLESS_OUTPUTS='1', WLR_LIBINPUT_NO_DEVICES='1', XODB_TEST_PRIVATE_DISPLAY='1', PYTHON=args.python)
        self.env = env
        self.procs = []
        self.sway = subprocess.Popen(['sway', '--unsupported-gpu', '--config', config], env=env, stdout=open(os.path.join(self.dir, 'sway.log'), 'wb'), stderr=subprocess.STDOUT)
        self.procs.append(self.sway)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            sockets = [s for s in Path(self.runtime).glob('wayland-*') if not s.name.endswith('.lock')]
            ipc = list(Path(self.runtime).glob('sway-ipc*.sock'))
            if sockets and ipc:
                break
            time.sleep(0.05)
        else:
            raise TimeoutError('private compositor did not start')
        env['WAYLAND_DISPLAY'] = sockets[0].name
        env['SWAYSOCK'] = str(ipc[0])
        self.log = os.path.join(self.dir, 'demo.log')
        # Its own process group: the script, xodb and the demo Python.
        self.app = subprocess.Popen(['scripts/demo-python'], cwd=str(root), env=env, stdin=subprocess.DEVNULL, stdout=open(self.log, 'ab'), stderr=subprocess.STDOUT, start_new_session=True)

    def stack(self):
        done = subprocess.run(['scripts/demo-python', 'stack', 'key', 'value', 'mp'], cwd=str(root), env=self.env, capture_output=True, text=True, timeout=30)
        return done.returncode, done.stdout + done.stderr

    def close(self):
        if self.app.poll() is None:
            os.killpg(self.app.pid, signal.SIGTERM)
            try:
                self.app.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.app.pid, signal.SIGKILL)
                self.app.wait()
        if self.sway.poll() is None:
            self.sway.terminate()
            self.sway.wait(timeout=10)


# 2. The demo exactly as a user runs it: Space, E watches, `stack` twice.
demo = Demo()
try:
    socket = Path(demo.runtime)/f'xodb-demo-python-{os.getuid()}'/'session.sock'
    deadline = time.monotonic() + 30
    while not socket.exists() and time.monotonic() < deadline:
        time.sleep(0.1)
    assert socket.exists(), open(demo.log).read()
    time.sleep(1)
    # Attaching stops the target wherever it was; Space runs to the break.
    code, attached = demo.stack()
    assert code == 0 and re.search(r'^  <module> +examples/python-demo\.py:\d+$', attached, re.M), attached
    demo.keys('tap', SPACE)
    outputs = [attached]
    for _ in range(2):
        for attempt in range(50):
            code, text = demo.stack()
            if code == 0 and '  record ' in text and text not in outputs:
                break
            time.sleep(0.1)
        assert code == 0 and '  record ' in text, text
        outputs.append(text)
        if len(outputs) == 2:
            time.sleep(.3)
            demo.shot('demo-stop')
            watch(demo, 'value')
            watch(demo, 'key')
            watch(demo, 'mp')
            time.sleep(.5)
            demo.shot('demo-watches')
            demo.keys('tap', SPACE)
            time.sleep(1)
    (work/'demo-stack.txt').write_text('\n---\n'.join(outputs))
    for text in outputs[1:]:
        assert re.search(r'^  record +examples/python-demo\.py:9$', text, re.M), text
        assert re.search(r'^  tick +examples/python-demo\.py:14$', text, re.M), text
        assert re.search(r'^  <module> +examples/python-demo\.py:21$', text, re.M), text
        assert "key = str 'answer'" in text and re.search(r'^value = list \(8 items\) \(refcnt \d+\)$', text, re.M), text
        assert "    [3]: 'héllo'" in text and "    [4]: b'raw\\x00bytes'" in text and re.search(r"^mp = dict \(2 items\)", text, re.M), text
    rounds = [int(re.search(r'^    \[0\]: (\d+)$', t, re.M).group(1)) for t in outputs[1:]]
    assert rounds[1] == rounds[0] + 1, rounds
    checks.append(f'demo: Space stops in _PyDict_SetItem_Take2, E value/key/mp watches, `stack` prints record<-tick<-<module> with lines; Space advances round {rounds[0]}->{rounds[1]}')
finally:
    demo.close()
(work/'results.json').write_text(json.dumps({'pass': checks, 'fail': []}, indent=2)+'\n')
print('CPython private GUI checks passed:', work)
