#!/usr/bin/env python3
"""Wayland UI scale: compositor defaults, sharp backing sizes and logical hit tests."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument('--work', type=Path)
parser.add_argument('--evidence', type=Path)
parser.add_argument('--galaxy', action='store_true', help='check retained galaxy rendering and logical hover input')
parser.add_argument('--sizing', action='store_true', help='check UI sizing independently of compositor backing scale')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
work = (args.work or root / '.work' / ('input-scale-' + str(time.time_ns())[-10:])).resolve()
work.mkdir(parents=True, exist_ok=True)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (work / name).mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('scale_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(work), 'tests/helpers/vinput.c',
                str(work / 'virtual-pointer.c'), str(work / 'virtual-keyboard.c'),
                '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)

checks = []

def check(name, condition, detail=''):
    checks.append((name, bool(condition), str(detail)))
    print(('ok   ' if condition else 'FAIL ') + name + (': ' + str(detail) if detail else ''), flush=True)

def scale_lines(d):
    return re.findall(r'ui scale effective=([0-9.]+) compositor=([0-9.]+) override=(yes|no)',
                      Path(d.log).read_text(errors='replace'))

def wait_scale(d, effective, compositor, override):
    deadline = time.monotonic() + 10
    expected = (f'{effective:.2f}', f'{compositor:.2f}', override)
    while time.monotonic() < deadline:
        lines = scale_lines(d)
        if expected in lines:
            return lines
        time.sleep(.05)
    return scale_lines(d)

scales = ((1.0, '1x'), (1.25, '1_25x'), (1.5, '1_5x'), (2.0, '2x'))
if args.sizing:
    # Four owned sessions, fast GUI lane. A preference-only run and a CLI
    # override of that preference exercise both entry points at each output scale.
    config = work / 'scale-preferences.json'
    config.write_text(json.dumps({'appearance': {'ui_scale': 1.5}}))
    for compositor in (1, 2):
        layouts = []
        for scale in (1, 1.5):
            options = ['--config', str(config)]
            if scale == 1:
                options += ['--ui-scale', '1']
            label = f'output-{compositor}-ui-{scale}'
            d = h.Display(str(root), options + list(h.M1), output_scale=compositor)
            try:
                d.stopped()
                # UI (700,65) is the Agent control. Convert to surface units,
                # the coordinate system used by the compositor's virtual pointer.
                pointer = d.keys('click', round(700 * scale / compositor), round(65 * scale / compositor), wait=False)
                controlled = d.wait(lambda state: state['agent_scope'] == 'control', seconds=2 * h.load_scale())
                check(label + ' pointer helper completed', pointer.wait(timeout=5) == 0)
                check(label + ' scaled pointer hits Agent', controlled is not None)
                text = Path(d.log).read_text(errors='replace')
                rows = re.findall(r'ui layout units=(\d+)x(\d+) buffer=(\d+)x(\d+) scale=([\d.]+)', text)
                faces = re.findall(r'ui font pixels=(\d+) scale=([\d.]+)', text)
                check(label + ' rendered layout and font dump available', bool(rows) and bool(faces))
                if rows and faces:
                    width, height, pixels_w, pixels_h = map(int, rows[-1][:4])
                    check(label + ' native backing buffer', (pixels_w, pixels_h) == (1280 * compositor, 800 * compositor), rows[-1])
                    check(label + ' UI units follow requested scale', (width, height) == (int(pixels_w / scale), int(pixels_h / scale)), rows[-1])
                    check(label + ' font raster follows requested size', int(faces[-1][0]) == round(16 * scale), faces[-1])
                    layouts.append((width, height, int(faces[-1][0])))
                if args.evidence:
                    args.evidence.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(d.shot(label), args.evidence / (label + '.png'))
            finally:
                d.close()
        check(f'output-{compositor} override changes layout and text size', len(layouts) == 2 and layouts[0][0] > layouts[1][0] and layouts[0][2] < layouts[1][2], layouts)
    failed = [name for name, ok, _ in checks if not ok]
    print(json.dumps({'checks': len(checks), 'failed': failed, 'work': str(work)}, indent=2))
    raise SystemExit(bool(failed))

if args.galaxy:
    os.environ['XODB_OVERVIEW_AUDIT'] = '1'
    os.environ['XODB_OVERVIEW_LAYOUT'] = '1'
    for scale, label in scales:
        d = h.Display(str(root), ['--overview', '--galaxy-demo', '24'], output_scale=scale, stdio=False)
        try:
            def until(predicate):
                deadline = time.monotonic() + 15 * h.load_scale()
                while True:
                    text = Path(d.log).read_text(errors='replace')
                    assert d.alive() and 'Draw failed' not in text and 'panic' not in text, text[-2000:]
                    value = predicate(text)
                    if value:
                        return value
                    assert time.monotonic() < deadline, text[-2000:]
                    time.sleep(.02)
            def looks(text):
                return [dict(pair.split('=') for pair in line.split()) for line in re.findall(r'galaxy-look (.*)', text)]
            rows = until(lambda text: looks(text) if len(looks(text)) >= 20 and len({row['builds'] for row in looks(text)[-10:]}) == 1 else None)
            check(label + ' additive retained cloud', rows[-1]['additive'] == '1' and len({row['builds'] for row in rows[-10:]}) == 1)
            lines = wait_scale(d, scale, scale, 'no')
            check(label + ' galaxy follows compositor', (f'{scale:.2f}', f'{scale:.2f}', 'no') in lines)
            shot = Path(d.shot('galaxy-' + label))
            with Image.open(shot) as image:
                check(label + ' galaxy physical extent', image.size == (round(1280 * scale), round(800 * scale)))
                # Compare the same logical cloud region, not merely any nonblank toolbar.
                field = image.crop(tuple(round(v * scale) for v in (280, 190, 1240, 680))).convert('RGB').resize((160, 80))
                check(label + ' cloud field rendered', len(set(field.get_flattened_data())) > 100)
            text = Path(d.log).read_text()
            point = re.findall(r'galaxy-cluster x=([\d.-]+) y=([\d.-]+)', text)[-1]
            count = len(looks(text))
            d.keys('m', *(round(float(v)) for v in point))
            until(lambda text: len(looks(text)) > count)
            check(label + ' hover leaves camera still', all(float(row['zoom']) == 1 and row['camera'] == '0' for row in looks(Path(d.log).read_text())[count:]))
            d.keys('click', *(round(float(v)) for v in point))
            d.keys('tap', 28)  # Return frames; a single click only selects.
            until(lambda text: looks(text) and float(looks(text)[-1]['zoom']) > 1.1)
            check(label + ' logical click and Return frame the selection', True)
            overlaps = re.findall(r'overview layout .*panel=galaxy overlaps=(\d+)', Path(d.log).read_text())
            check(label + ' galaxy layout has no label overlap', bool(overlaps) and all(int(v) == 0 for v in overlaps))
            if args.evidence:
                args.evidence.mkdir(parents=True, exist_ok=True)
                shutil.copy2(shot, args.evidence / shot.name)
        finally:
            d.close()
    failed = [name for name, ok, _ in checks if not ok]
    print(json.dumps({'checks': len(checks), 'failed': failed, 'work': str(work)}, indent=2))
    raise SystemExit(bool(failed))

for scale, label in scales:
    d = h.Display(str(root), list(h.M1), output_scale=scale)
    try:
        d.stopped()
        d.keys('tap', h.KEY['space'])
        check(f'{label} reaches owned breakpoint', d.stopped('breakpoint') is not None)
        lines = wait_scale(d, scale, scale, 'no')
        check(f'{label} follows compositor scale', (f'{scale:.2f}', f'{scale:.2f}', 'no') in lines, lines)
        shot = Path(d.shot('ui-scale-' + label))
        with Image.open(shot) as image:
            expected = (round(1280 * scale), round(800 * scale))
            check(f'{label} screenshot has physical extent', image.size == expected, f'{image.size} expected {expected}')
            colors = len(set(image.convert('RGB').resize((160, 100)).get_flattened_data()))
            check(f'{label} frame is rendered', colors > 32, colors)
        # Virtual input is expressed in the same 1280x800 UI coordinates at every
        # backing scale. Click the same Agent toolbar button and observe its state.
        d.keys('click', 700, 65)
        controlled = d.wait(lambda state: state['agent_scope'] == 'control')
        check(f'{label} logical pointer hits the same toolbar button', controlled is not None)
        if args.evidence:
            args.evidence.mkdir(parents=True, exist_ok=True)
            shutil.copy2(shot, args.evidence / f'ui-scale-{label}.png')
    finally:
        d.close()

config = work / 'scale-preferences.json'
config.write_text(json.dumps({'appearance': {'ui_scale': 1.25}}))
cli_args = list(h.M1)
cli_args[0:0] = ['--config', str(config), '--ui-scale', '1.5']
d = h.Display(str(root), cli_args, output_scale=2.0)
try:
    lines = wait_scale(d, 1.5, 2.0, 'yes')
    check('CLI scale overrides preferences and compositor', ('1.50', '2.00', 'yes') in lines, lines)
finally:
    d.close()

failed = [name for name, ok, _ in checks if not ok]
print(json.dumps({'checks': len(checks), 'failed': failed, 'work': str(work)}, indent=2))
if failed:
    raise SystemExit(1)
