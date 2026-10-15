#!/usr/bin/env python3
"""Fast: all overview panels at two content sizes. --matrix: periodic all themes/scales."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

p = argparse.ArgumentParser()
p.add_argument('--matrix', action='store_true')
p.add_argument('--binary')
p.add_argument('--unavailable', action='store_true')
p.add_argument('--live', action='store_true', help='copied MCP layout on an owned process in Files')
p.add_argument('--shots', type=Path)
args = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-os-' + str(time.time_ns())[-8:])
work.mkdir(parents=True)
spec = importlib.util.spec_from_file_location('overview_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (work / name).mkdir(parents=True, exist_ok=True)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'),
                str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
base = work / 'base.jsonl'
replay = work / 'replay.jsonl'
subprocess.run([sys.executable, 'tests/fixtures/overview-synth.py', str(base), '--frames', '2', *(['--unavailable'] if args.unavailable else [])], check=True)
subprocess.run([sys.executable, 'tests/fixtures/memmap-synth.py', str(base), str(replay)], check=True)
os.environ['XODB_OVERVIEW_LAYOUT'] = '1'
panels = 'summary performance processes memory disk disk_space network connections power system users services apps files memory_map graph galaxy inheritance treemap fetch'.split()
themes = 'dark light green amber blue mono win95'.split() if args.matrix else ['dark']
bad = []
seen = []
started = time.monotonic()

if args.live:
    fixture = subprocess.Popen(['sleep', '60'])
    d = None
    try:
        d = h.Display(str(root), ['--overview', '--redact', '--panel', 'files', '--files-pid', str(fixture.pid)],
                      output_size=(866, 588), binary=args.binary)
        deadline = time.monotonic() + 10 * h.load_scale()
        while True:
            layout = d.tool('get_layout')
            if layout['available'] and layout['view'] == 'overview' and any(row['value'] == 'PID / FD' for row in layout['rows']):
                break
            assert time.monotonic() < deadline, (layout, d.tail())
            time.sleep(.01)
        assert layout['window']['width'] == 866 and layout['window']['buffer_width'] == 866, layout
        assert layout['panes'][0]['rect']['w'] == 650 and layout['panes'][0]['rect']['h'] == 470, layout
        assert layout['text_overlaps'] == 0 and layout['unmarked_text'] == 0, layout
        for row in layout['rows']:
            box = row['rect']
            assert box['x'] >= 0 and box['y'] >= 0 and box['x'] + box['w'] <= 866 and box['y'] + box['h'] <= 588, row
            assert not row['value_elided'] or row['ellipsis'], row
        (work / 'layout.json').write_text(json.dumps(layout, indent=2))
        print(json.dumps({'status': 'pass', 'cases': 1, 'seconds': round(time.monotonic() - started, 3), 'work': str(work)}))
    finally:
        if d:
            d.close()
        fixture.terminate()
        fixture.wait(timeout=5)
    sys.exit(0)


def await_layout(d, panel, theme, size):
    deadline = time.monotonic() + 10 * h.load_scale()
    while True:
        lines = Path(d.log).read_text(errors='replace').splitlines()
        found = [line for line in lines if 'overview layout' in line and
                 f'panel={panel} ' in line and f'theme={theme} ' in line and
                 f'content={size[0]}x{size[1]} ' in line]
        if found:
            return found[-1]
        if d.app.poll() is not None or time.monotonic() >= deadline:
            raise AssertionError(('missing real frame', panel, theme, size, d.tail()))
        time.sleep(.01)


for scale in ((1, 2) if args.matrix else (1,)):
    for theme in themes:
        size = (650, 470)
        window = (size[0] + (230 if theme == 'win95' else 216), size[1] + (206 if theme == 'win95' else 118))
        d = h.Display(str(root), ['--overview', '--replay', str(replay), '--pause', '--redact', '--theme', theme,
                                 '--galaxy-demo', '32:idle', '--look', 'gibson'],
                      stdio=False, output_size=window, output_scale=scale, binary=args.binary)
        try:
            child = d.keys('tap', 2, wait=False)  # demo opens Galaxy; start the full walk at Summary
            assert child.wait(timeout=5) == 0
            for size in ((650, 470), (950, 700)):
                width = size[0] + (230 if theme == 'win95' else 216)
                height = size[1] + (206 if theme == 'win95' else 118)
                subprocess.run(['swaymsg', 'output', 'HEADLESS-1', 'mode', f'{width * scale}x{height * scale}'], env=d.env, check=True, capture_output=True)
                d.width, d.height = width, height
                for panel in panels:
                    line = await_layout(d, panel, theme, size)
                    seen.append(line)
                    if 'overlaps=0 ' not in line or 'unmarked=0 ' not in line:
                        bad.append(line)
                    if args.shots and scale == 2 and size == (650, 470):
                        args.shots.mkdir(parents=True, exist_ok=True)
                        subprocess.run(['grim', '-o', 'HEADLESS-1', str(args.shots / f'{theme}-{panel}.png')], env=d.env, check=True)
                    child = d.keys('tap', 15, wait=False)
                    assert child.wait(timeout=5) == 0
        finally:
            d.close()
(work / 'frames.json').write_text(json.dumps(seen, indent=2))
print(json.dumps({'status': 'fail' if bad else 'pass', 'cases': len(seen), 'seconds': round(time.monotonic() - started, 3), 'failures': bad, 'work': str(work)}, indent=2))
sys.exit(bool(bad))
