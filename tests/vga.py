#!/usr/bin/env python3
"""VGA palette/font/fallback checks on a private display; fonts stay external.

Optional --font points at an extracted Px437/PxPlus IBM VGA 8x16 TTF.
Optional --parent-root compares the unchanged default GUI with a parent build.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
from PIL import Image, ImageChops

parser = argparse.ArgumentParser()
parser.add_argument('--font', type=Path)
parser.add_argument('--parent-root', type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root); os.umask(0o022)
work = root / '.work' / ('input-vga-' + str(time.time_ns())[-10:])
work.mkdir(parents=True)
for name in ('tmp', 'cache/mesa', 'cache/nvidia'):
    (work / name).mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location('vga_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
h.WORK = str(work)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'), str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
checks = []
def block_cursor(path):
    """An empty editor has one solid 16-pixel-high block in the watch pane."""
    with Image.open(path) as im:
        im = im.convert('RGB'); p = im.load()
        for y in range(int(im.height * .65), im.height - 48):
            columns = [x for x in range(int(im.width * .45), im.width - 24)
                       if all(p[x, y + dy] == (85, 255, 255) for dy in range(16))]
            if 5 <= len(columns) <= 18 and columns[-1] - columns[0] + 1 == len(columns):
                return columns[0], y, len(columns)
    raise AssertionError('VGA editor block cursor not found')

def snapshot(tree, options, name):
    d = h.Display(str(tree), options)
    try:
        time.sleep(.3)
        shot = d.shot(name)
        return Image.open(shot).convert('RGB'), Path(d.log).read_text()
    finally: d.close()

if args.parent_root:
    before, _ = snapshot(args.parent_root.resolve(), [], 'default-parent')
    after, _ = snapshot(root, [], 'default-candidate')
    # The bottom status includes timing; compare the entire workspace above it.
    region = (0, 0, before.width, before.height - 32)
    delta = ImageChops.difference(before.crop(region), after.crop(region))
    delta.save(work / 'default-difference.png')
    assert delta.getbbox() is None, delta.getbbox()
    checks.append('default workspace pixels identical to parent (status timing excluded)')

fonts = [([], 'installed')]
if args.font: fonts.append((['--font', str(args.font.resolve())], 'pixel'))
for options, label in fonts:
    d = h.Display(str(root), ['--theme', 'builtin:vga', *options, '--agent-scope', 'control',
                            '--source', 'tests/fixtures/m1.c', '--break', 'change_value',
                            '--', str(root / 'zig-out/bin/xodb-m1-fixture'), 'w'])
    try:
        d.tool('continue', generation=d.session()['generation'])
        assert d.stopped('breakpoint')
        d.keys('tap', h.KEY['b'] if 'b' in h.KEY else 48)
        time.sleep(.2); shot = d.shot('vga-' + label + '-breakpoints')
        with Image.open(shot) as im:
            assert im.convert('RGB').getpixel((2, 82)) == (0, 0, 170)
        d.keys('tap', h.KEY['esc'], 'tap', h.KEY['e'])
        empty = d.shot('vga-' + label + '-expression')
        x, y, cell = block_cursor(empty)
        d.keys('tap', 30, 'tap', 48, 'tap', 46)  # abc
        end = block_cursor(d.shot('vga-' + label + '-cursor-end'))
        assert end == (x + 3 * cell, y, cell), (end, (x, y, cell))
        d.keys('tap', 105)  # Left: insert before c, shared with paste fields.
        with Image.open(d.shot('vga-' + label + '-cursor-middle')) as im:
            im = im.convert('RGB')
            assert all(im.getpixel((x + 2 * cell + dx, y)) == (85, 255, 255) for dx in range(cell))
            assert any(im.getpixel((x + 2 * cell + dx, y + dy)) != (85, 255, 255)
                       for dx in range(cell) for dy in range(2, 14)), 'character under block is obscured'
        assert 'Font failed:' not in Path(d.log).read_text()
        checks.append('VGA ' + label + ' font renders breakpoint and expression views')
    finally: d.close()

invalid = work / 'invalid.ttf'; invalid.write_bytes(b'owned invalid font')
for path in (work / 'missing.ttf', invalid):
    image, log = snapshot(root, ['--theme', 'builtin:vga', '--font', str(path)], path.stem + '-fallback')
    assert 'Font failed:' in log and 'using default font' in log, log
    assert image.getpixel((2, 82)) == (0, 0, 170)
    checks.append(path.stem + ' font falls back with diagnostic')
(work / 'results.json').write_text(json.dumps(checks, indent=2) + '\n')
print('VGA:', len(checks), 'checks passed;', work)
