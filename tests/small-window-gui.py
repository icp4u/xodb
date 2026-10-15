#!/usr/bin/env python3
"""Fast: real resizes, copied layout diagnostics, overflow clicks and density."""
import argparse
import importlib.util
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--binary')
parser.add_argument('--evidence', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
work = root / '.work' / ('input-small-' + str(time.time_ns())[-8:])
work.mkdir(parents=True)
spec = importlib.util.spec_from_file_location('small_input', root / 'tests/helpers/input.py')
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


def until(d, predicate):
    deadline = time.monotonic() + 8 * h.load_scale()
    while True:
        layout = d.tool('get_layout')
        if predicate(layout):
            return layout
        if time.monotonic() >= deadline:
            raise AssertionError(('layout did not converge', layout, d.tail()))
        time.sleep(.015)  # condition polling, never a settling delay


def check_rect(b, width, height):
    assert min(b.values()) >= 0, b
    assert b['x'] + b['w'] <= width and b['y'] + b['h'] <= height, (b, width, height)


def check_layout(layout):
    w = layout['window']
    width, height = w['width'], w['height']
    assert layout['available'] and not layout['rows_truncated'], layout
    panes = {p['name']: p for p in layout['panes']}
    for p in panes.values():
        check_rect(p['rect'], width, height)
        check_rect(p['tab'], width, height)
        assert p['key'] and (p['tab']['w'] > 0) == p['collapsed'], p
    prior = True
    for name in ('Events', 'Values', 'Stack', 'Threads', 'Assembly'):
        hidden = panes[name]['collapsed']
        assert prior or not hidden, panes
        prior = hidden
    for control in layout['controls']:
        check_rect(control['rect'], width, height)
        assert control['key'] or control['name'] == 'More', control
    for group in (list(panes.values()), layout['controls']):
        for i, item in enumerate(group):
            a = item['rect']
            if not a['w'] or not a['h']:
                continue
            for other in group[i + 1:]:
                b = other['rect']
                overlap_w = min(a['x'] + a['w'], b['x'] + b['w']) - max(a['x'], b['x'])
                overlap_h = min(a['y'] + a['h'], b['y'] + b['h']) - max(a['y'], b['y'])
                assert overlap_w <= 0 or overlap_h <= 0, (item, other)
    for row in layout['rows']:
        check_rect(row['rect'], width, height)
        pane = panes[row['pane']]['rect']
        assert row['rect']['y'] + row['rect']['h'] <= pane['y'] + pane['h'], row
        assert not row['value_elided'] or row['ellipsis'], row
        if row['identifier']:
            assert not row['value_elided'] and row['value'].isdigit(), row
    return panes


def keys(d, predicate, *commands):
    child = d.keys(*commands, wait=False)
    value = until(d, predicate)
    assert child.wait(timeout=5) == 0
    return value


started = time.monotonic()
count = 0
for scale in (1, 2):
    d = h.Display(str(root), list(h.M1), output_size=(1600, 1000), output_scale=scale, binary=args.binary)
    try:
        assert d.stopped()
        child = d.keys('tap', h.KEY['space'], wait=False)
        assert d.stopped('breakpoint'), d.tail()
        assert child.wait(timeout=5) == 0
        for width, height in ((1600, 1000), (1200, 800), (950, 700), (800, 500), (640, 400)):
            subprocess.run(['swaymsg', 'output', 'HEADLESS-1', 'mode', f'{width * scale}x{height * scale}'], env=d.env, check=True, capture_output=True)
            d.width, d.height = width, height
            layout = until(d, lambda v: v['window']['width'] == width and v['window']['height'] == height)
            panes = check_layout(layout)
            assert layout['window']['ui_scale'] == scale and layout['window']['backing_scale'] == scale
            assert layout['window']['buffer_width'] == width * scale
            assert layout['compact'] == (width < 960), layout
            assert layout['font_size'] == (14 if layout['compact'] else 16), layout
            if not panes['Threads']['collapsed']:
                assert any(r['identifier'] for r in layout['rows']), layout
            (work / f'layout-{scale}-{width}.json').write_text(json.dumps(layout, indent=2))
            if args.evidence and width == 950:
                args.evidence.mkdir(parents=True, exist_ok=True)
                shutil.copy2(d.shot(f'small-{scale}'), args.evidence / f'950x700-scale{scale}.png')
            count += 1
        # At the minimum size, source/assembly becomes a real one-pane toggle.
        assert layout['panes'][1]['collapsed'], layout
        layout = keys(d, lambda v: not v['panes'][1]['collapsed'], 'down', 56, 'tap', 3, 'up', 56)
        assert layout['panes'][0]['collapsed'] and layout['panes'][1]['rect']['w'] >= 300, layout
        layout = keys(d, lambda v: not v['panes'][0]['collapsed'], 'down', 56, 'tap', 2, 'up', 56)
        # Reopening values uses a real tab and a real language-tab key.
        tab = next(p['tab'] for p in layout['panes'] if p['name'] == 'Values')
        layout = keys(d, lambda v: not v['panes'][2]['collapsed'], 'click', tab['x'] + 20, tab['y'] + 12)
        assert layout['panes'][1]['collapsed'], layout
        layout = keys(d, lambda v: any(r['pane'] == 'Values' for r in v['rows']), 'tap', h.KEY['tab'])
        values = [r for r in layout['rows'] if r['pane'] == 'Values']
        assert values and all(not r['value_elided'] or r['ellipsis'] for r in values), values
        # More exposes the actual hidden Agent action, not just a declared key.
        more = next(c['rect'] for c in layout['controls'] if c['name'] == 'More')
        layout = keys(d, lambda v: any(c['name'] == 'Agent' and not c['overflow'] for c in v['controls']), 'click', more['x'] + 20, more['y'] + 12)
        agent = next(c['rect'] for c in layout['controls'] if c['name'] == 'Agent' and not c['overflow'])
        child = d.keys('click', agent['x'] + 25, agent['y'] + 12, wait=False)
        assert d.wait(lambda s: s['agent_scope'] == 'control')
        assert child.wait(timeout=5) == 0
        layout = keys(d, lambda v: v['density'] == 'normal', 'down', 29, 'down', 42, 'tap', 32, 'up', 42, 'up', 29)
        assert not layout['compact'] and layout['font_size'] == 16
        layout = keys(d, lambda v: v['density'] == 'compact', 'down', 29, 'down', 42, 'tap', 32, 'up', 42, 'up', 29)
        assert layout['compact'] and layout['font_size'] == 14
    finally:
        d.close()
    # Check the real protocol request, not the diagnostic's declared constant.
    # Sway's explicit IPC resize can override client hints; that must be safe too.
    d = h.Display(str(root), ['--ui-scale', str(scale * 1.5), *h.M1], output_size=(1600, 1000), output_scale=scale, binary=args.binary, wayland_debug=True)
    try:
        until(d, lambda v: v['available'])
        wire = Path(d.log).read_text(errors='replace')
        minima = re.findall(r'xdg_toplevel[^\n]*\.set_min_size\((\d+), (\d+)\)', wire)
        assert minima and minima[-1] == ('960', '600'), minima
        subprocess.run(['swaymsg', 'floating enable, resize set width 100 px height 100 px'], env=d.env, check=True, capture_output=True)
        layout = until(d, lambda v: v['available'] and v['window']['width'] <= 650)
        if layout['window']['width'] < 640 or layout['window']['height'] < 400:
            assert layout['too_small'] and not layout['panes'] and not layout['controls'] and not layout['rows'], layout
        else:
            check_layout(layout)
        assert layout['window']['ui_scale'] == scale * 1.5 and layout['window']['backing_scale'] == scale
    finally:
        d.close()
print(json.dumps({'status': 'pass', 'resize_cases': count, 'seconds': round(time.monotonic() - started, 3), 'work': str(work)}))
