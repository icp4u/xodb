#!/usr/bin/env python3
"""Fast GUI lane: scene selection, properties, signal values and scrolling at 1280x800."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
from PIL import Image, ImageOps
from types import SimpleNamespace

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--redot', required=True)
p.add_argument('--work', type=Path, required=True)
args = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
sys.path.insert(0, str(root / 'scripts/helpers'))
from redot_scene import start_scene

w = (args.work / '.work/input-redot').resolve()
w.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('private_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(w)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (w / name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(w / (stem + '.h'))], check=True, timeout=10)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(w / (stem + '.c'))], check=True, timeout=10)
h.HELPER = str(w / 'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(w), 'tests/helpers/vinput.c', str(w / 'virtual-pointer.c'), str(w / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True, timeout=30)
shutil.copytree(root / 'tests/fixtures/redot-values', w / 'project', dirs_exist_ok=True)
os.environ.pop('XODB_TEST_RUNTIME_AGENT', None)  # The protocol owns a local launch only.
d = None
started = time.monotonic()
try:
    d = h.Display(str(root), ['--agent-scope', 'control', '--redot-debugger', '--', str(Path(args.redot).resolve()), '--headless', '--path', str(w / 'project')])
    scene = start_scene(d.tool)
    def visible(label, words):
        deadline = time.monotonic() + 10
        while True:
            shot = d.shot(label)
            crop = shot + '.pane.png'
            with Image.open(shot) as image:
                pane = ImageOps.invert(image.crop((16, 92, 1264, 770)).convert('L'))
                pane.resize((pane.width * 2, pane.height * 2)).save(crop)
            text = subprocess.run(['tesseract', crop, 'stdout', '--psm', '6'], env=dict(d.env, OMP_THREAD_LIMIT='1'), capture_output=True, text=True, check=True, timeout=20).stdout
            normalized = ''.join(c for c in text.lower() if c.isalnum())
            if all(word in normalized for word in words):
                return text
            assert time.monotonic() < deadline, (label, text, d.tail())
            time.sleep(.02)
    d.keys('tap', 22)  # U
    d.keys('click', 180, 256)  # Player, third scene row
    player = visible('player', ['scenetree', 'player', 'hand', 'dummy', 'objectinspector', 'playergd'])
    # Native and member values come from the same object response as the pane.
    node = next(n for n in scene['nodes'] if n['name'] == 'Player')
    obj = d.tool('inspect_redot_object', object_id=node['object_id'])['object']
    assert next(p['display'] for p in obj['properties'] if p['name'] == 'position') == 'Vector2(12.5, -7.25)', obj
    d.keys('click', 170, 228)  # Arena
    d.keys('tap', 31)  # S
    signals = visible('signals', ['signalvalues', 'vsignal', 'treeexiting', 'arenagd'])
    d.keys('tap', 25)  # P
    d.keys('scroll', 1000, 520, 5)
    scrolled = visible('properties', ['objectinspector', 'members'])
    d.keys('tap', 1)  # Esc
    d.keys('tap', 22)
    visible('reopened', ['scenetree', 'objectinspector'])
    # The public scene launcher bootstraps through its private shared socket,
    # releases its control lease, and leaves the same pane ready for a human.
    d.app.stdin.close()
    assert d.app.wait(timeout=10) == 0, d.tail()
    demo_log = w / 'demo.log'
    with demo_log.open('wb') as output:
        demo = subprocess.Popen(['scripts/demo-redot', 'scene'], env=dict(d.env, REDOT=str(Path(args.redot).resolve()), XODB=str(root / 'zig-out/bin/xodb'), REDOT_PROJECT=str(w / 'project')), stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 30
            while 'Scene ready.' not in demo_log.read_text():
                assert demo.poll() is None and time.monotonic() < deadline, demo_log.read_text()
                time.sleep(.02)
            shared_spec = importlib.util.spec_from_file_location('shared', root / 'tests/shared-sessions.py')
            shared = importlib.util.module_from_spec(shared_spec)
            shared_spec.loader.exec_module(shared)
            endpoint = SimpleNamespace(path=Path(d.env['XDG_RUNTIME_DIR']) / f'xodb-demo-redot-{os.getuid()}' / 'session.sock', clients=[], proc=demo)
            observer = shared.Client(endpoint, 'demo-observer')
            try:
                while observer.info()['controller_id'] is not None:
                    assert time.monotonic() < deadline
                    time.sleep(.02)
                assert observer.tool('get_redot_scene_tree')['total'] == 5
            finally:
                observer.close()
            def focused(node):
                return (node.get('app_id') == 'xodb' and node.get('focused') and node.get('visible')) or any(focused(n) for n in node.get('nodes', []) + node.get('floating_nodes', []))
            while True:
                tree = subprocess.run(['swaymsg', '-r', '-t', 'get_tree'], env=d.env, capture_output=True, text=True, check=True, timeout=10)
                if focused(json.loads(tree.stdout)):
                    break
                assert time.monotonic() < deadline
                time.sleep(.02)
            d.keys('tap', 22)
            visible('demo', ['scenetree', 'player', 'dummy'])
        finally:
            if demo.poll() is None:
                demo.send_signal(signal.SIGINT)
            demo.wait(timeout=15)
    (args.work / 'results.json').write_text(json.dumps(dict(status='pass', seconds=round(time.monotonic()-started, 2), ocr=dict(player=player, signals=signals, scrolled=scrolled)), indent=2)+'\n')
finally:
    if d:
        d.close()
print('Redot GUI: scene tree, selected script/properties, signal values, scroll and reopen pass')
