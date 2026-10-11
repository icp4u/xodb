#!/usr/bin/env python3
"""Fast private GUI lane: matched Win95 defrag controls and a paged legend."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
from PIL import Image

p = argparse.ArgumentParser()
p.add_argument('--binary')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-mw95-' + str(time.time_ns())[-8:])
work.mkdir(parents=True)
for name in ('tmp', 'cache'):
    (work / name).mkdir()
spec = importlib.util.spec_from_file_location('private_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'),
                str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
base, replay = work / 'base.jsonl', work / 'replay.jsonl'
subprocess.run(['python3', '-B', 'tests/fixtures/overview-synth.py', str(base), '--frames', '2'], check=True)
subprocess.run(['python3', '-B', 'tests/fixtures/memmap-synth.py', str(base), str(replay)], check=True)
os.environ['XODB_OVERVIEW_LAYOUT'] = '1'
started = time.monotonic()
checks = []
d = None

def until(fn, name):
    deadline = time.monotonic() + 10 * h.load_scale()
    while time.monotonic() < deadline:
        if not d.alive():
            raise AssertionError(d.tail())
        if fn():
            checks.append(name)
            print('PASS ' + name, flush=True)
            return
        time.sleep(.025)
    raise AssertionError(name + ': ' + d.tail())

def shot(name):
    with Image.open(d.shot(name)) as im:
        return im.convert('RGB')

def pixel(name, xy, rgb):
    return shot(name).getpixel(xy) == rgb

def navy(name, xy):
    return all(abs(a-b) <= 4 for a,b in zip(shot(name).getpixel(xy), (0,0,128)))

def send(*cmd):
    if d.keys(*cmd, wait=False).wait(timeout=10 * h.load_scale()):
        raise AssertionError('private input failed')

try:
    d = h.Display(str(root), ['--overview', '--look', 'win95', '--panel', 'memory_map',
                  '--pause', '--redact', '--replay', str(replay)], stdio=False, trace=False,
                  binary=a.binary, output_size=(1280, 720))
    until(lambda: pixel('details', (212, 104), (192, 192, 192)), 'defrag shares the overview panel face')
    until(lambda: navy('title', (500, 122)), 'defrag uses the shared title bar')
    until(lambda: pixel('status', (501, 589), (0, 0, 0)), 'freshness status has a sunken edge')
    # The same bundled face reaches the defrag through the overview context.
    # Clicking the actual Details control changes the frame, and a second click restores it.
    send('click', 1160, 567, 'm', 2, 100)
    until(lambda: pixel('compact', (500, 122), (192, 192, 192)), 'Hide Details collapses the dialog')
    send('click', 1000, 384, 'm', 2, 100)
    until(lambda: navy('restored', (500, 122)), 'Show Details restores the grid')
    send('tap', 34, 'm', 2, 100)  # G
    until(lambda: navy('legend', (390, 122)), 'legend opens with shared chrome')
    send('tap', 16, 'tap', 32)  # Q and D must stay inside the modal.
    until(lambda: d.alive() and navy('modal', (390, 122)), 'legend captures global shortcuts')
    send('tap', 1)
    until(lambda: navy('legend-closed', (500, 122)), 'Escape closes only the legend')
    # A short screen has readable rows with Later/Earlier buttons, never overlapping Close.
    subprocess.run(['swaymsg', 'output', 'HEADLESS-1', 'mode', '900x480'], env=d.env,
                   check=True, capture_output=True, timeout=5 * h.load_scale())
    d.width, d.height = 900, 480
    until(lambda: shot('short').size == (900, 480), 'short output configured')
    send('tap', 34, 'm', 2, 100)
    first = shot('short-legend')
    send(*[part for _ in range(18) for part in ('tap', 108)], 'm', 2, 100)
    until(lambda: shot('last-legend').crop((270, 155, 820, 340)).tobytes() != first.crop((270, 155, 820, 340)).tobytes(), 'short legend pages through its rows')
    send('tap', 1, 'm', 2, 100)
    until(lambda: d.alive(), 'short legend closes cleanly')
    subprocess.run(['swaymsg', 'output', 'HEADLESS-1', 'mode', '1920x1080'], env=d.env,
                   check=True, capture_output=True, timeout=5 * h.load_scale())
    d.width, d.height = 1920, 1080
    until(lambda: shot('defrag-1080').size == (1920, 1080), 'full-size defrag captured')
    send('tap', 34, 'm', 2, 100)
    until(lambda: navy('legend-1080', (725, 302)), 'full-size legend captured')
    layout = [line for line in Path(d.log).read_text().splitlines() if 'overview layout ' in line]
    if not layout or any('overlaps=0 ' not in line for line in layout):
        raise AssertionError(layout)
    if any(x in Path(d.log).read_text() for x in ('panic:', 'Draw failed', 'frame failed')):
        raise AssertionError(d.tail())
finally:
    if d:
        d.close()
    (work / 'results.json').write_text(json.dumps(dict(checks=checks,seconds=time.monotonic()-started),indent=2)+'\n')
    print(work, flush=True)
