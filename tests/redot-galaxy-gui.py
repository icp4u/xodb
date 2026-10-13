#!/usr/bin/env python3
"""Fast GUI lane: real owned scene graph, stable hover and node-to-inspector pick."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import sys
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--redot', required=True)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--binary', type=Path)
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
sys.path.insert(0, str(root / 'scripts/helpers'))
from redot_scene import start_scene
work = (a.work / '.work/input-redot-galaxy').resolve()
work.mkdir(parents=True)
for name in ('tmp', 'cache'):
    (work / name).mkdir()
spec = importlib.util.spec_from_file_location('input_helper', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
h.WORK = str(work)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'),
                str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)
shutil.copytree(root / 'tests/fixtures/redot-values', work / 'project')
os.environ.pop('XODB_TEST_RUNTIME_AGENT', None)
os.environ['XODB_OVERVIEW_AUDIT'] = '1'
checks = []
d = None
began = time.monotonic()
def check(name, value):
    checks.append({'check': name, 'pass': bool(value)})
    print(('PASS ' if value else 'FAIL ') + name, flush=True)
    assert value, name
def rows(kind):
    return [dict(pair.split('=') for pair in line.split()) for line in
            re.findall(r'xodb: ' + kind + r' (.*)', Path(d.log).read_text(errors='replace'))]
def until(fn):
    deadline = time.monotonic() + 20 * h.load_scale()
    while not fn():
        assert d.alive() and time.monotonic() < deadline, d.tail()
        time.sleep(.02)
try:
    d = h.Display(str(root), ['--agent-scope', 'control', '--redot-debugger', '--',
                  str(Path(a.redot).resolve()), '--headless', '--path', str(work / 'project')],
                  binary=str(a.binary.resolve()) if a.binary else None)
    scene = start_scene(d.tool)
    keeper = subprocess.Popen([h.HELPER, str(d.width), str(d.height), 'layout', 'us', 'barrier'],
                              env=d.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    d.procs.append(keeper)
    if not select.select([keeper.stdout], [], [], 10 * h.load_scale())[0] or keeper.stdout.readline() != b'ready\n':
        raise AssertionError('private keyboard barrier not reached')
    player = next(node for node in scene['nodes'] if node['name'] == 'Player')
    d.keys('tap', 22)  # U inspector
    d.keys('tap', 34)  # G galaxy
    until(lambda: rows('redot-galaxy') and int(rows('redot-galaxy')[-1]['nodes']) == scene['total'])
    graph = rows('redot-galaxy')[-1]
    check('scene snapshot becomes nodes and parent-child edges', int(graph['nodes']) == 5 and int(graph['edges']) == 4)
    check('scenes and scripts form multiple clusters', int(graph['clusters']) >= 2)
    check('unreported signal activity is not fabricated', graph['impulses'] == '0' and graph['omitted'] == '0')
    visible = h.ocr_until(d, 'scene-galaxy', lambda text: 'scene galaxy' in text and 'unavailable' in text)
    check('galaxy and unavailable signal provenance are visible', 'signal' in visible)
    point = next(row for row in reversed(rows('redot-galaxy-node')) if row['id'] == player['object_id'])
    before = len(rows('galaxy-look'))
    d.keys('m', round(float(point['x'])), round(float(point['y'])))
    until(lambda: len(rows('galaxy-look')) > before)
    check('hover never moves the selected scene node', all(float(row['zoom']) == 1 and row['camera'] == '0' for row in rows('galaxy-look')[before:]))
    d.keys('click', round(float(point['x'])), round(float(point['y'])))
    until(lambda: rows('redot-galaxy')[-1]['selected'] == player['object_id'])
    check('single click selects without leaving or moving the galaxy', rows('galaxy-look')[-1]['camera'] == '0')
    d.keys('tap', 25)  # P opens the selected object's inspector.
    selected = h.ocr_until(d, 'picked-node', lambda text: 'object inspector' in text and 'player.gd' in text and player['object_id'] in text)
    check('actual node click then P opens matching object and script', player['object_id'] in selected)
    count = len(rows('redot-galaxy'))
    d.keys('tap', 34)
    until(lambda: len(rows('redot-galaxy')) > count)
    check('the inspector selection is ringed in the galaxy', rows('redot-galaxy')[-1]['selected'] == player['object_id'])
    d.keys('tap', 106)  # Same carousel as the descriptor galaxy.
    until(lambda: rows('galaxy-pick')[-1]['cluster'] != '0' and rows('galaxy-look')[-1]['camera'] == '0')
    check('Redot shares explicit carousel framing', float(rows('galaxy-look')[-1]['zoom']) > 1)
    pose_keys = ('zoom', 'shift_x', 'shift_y', 'rotation')
    pose = tuple(rows('galaxy-look')[-1][key] for key in pose_keys)
    old_revision = int(rows('redot-galaxy')[-1]['revision'])
    d.keys('tap', 19)  # R refresh
    until(lambda: int(rows('redot-galaxy')[-1]['revision']) > old_revision)
    check('refresh retains a real scene graph with no invented impulses', rows('redot-galaxy')[-1]['nodes'] == '5' and rows('redot-galaxy')[-1]['impulses'] == '0')
    check('refresh cannot retarget the framed camera', tuple(rows('galaxy-look')[-1][key] for key in pose_keys) == pose and rows('galaxy-look')[-1]['camera'] == '0')
    d.keys('tap', 24)  # O tour.
    until(lambda: rows('galaxy-look')[-1]['tour'] == '1' and rows('galaxy-look')[-1]['camera'] == '1')
    d.keys('tap', 102)  # Home stops the tour and fits.
    until(lambda: rows('galaxy-look')[-1]['tour'] == '0' and rows('galaxy-look')[-1]['camera'] == '0')
    check('Redot shares tour and Home fit', float(rows('galaxy-look')[-1]['zoom']) == 1 and float(rows('galaxy-look')[-1]['rotation']) == 0)
    d.keys('tap', 34)
    h.ocr_until(d, 'tree-again', lambda text: 'scene tree' in text and 'object inspector' in text)
    check('G returns to the existing tree and inspector', True)
finally:
    if d:
        d.close()
    (work / 'results.json').write_text(json.dumps({'checks': checks, 'seconds': time.monotonic() - began}, indent=2) + '\n')
print('Redot scene galaxy GUI checks PASS')
