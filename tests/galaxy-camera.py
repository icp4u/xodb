#!/usr/bin/env python3
"""Fast private GUI lane: shared galaxy navigation and transformed picking (<=15s)."""
import argparse
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import select
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-nav' + str(time.time_ns())[-5:])
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
os.environ['XODB_OVERVIEW_AUDIT'] = '1'
report = {'checks': [], 'load': os.getloadavg(), 'cpus': len(os.sched_getaffinity(0))}
started = time.monotonic()
d = None

def check(name, ok):
    if not ok:
        raise AssertionError(name + ': ' + d.tail())
    report['checks'].append(name)
    print('PASS ' + name, flush=True)

def rows(kind='galaxy-look'):
    return [dict(re.findall(r'(\w+)=([^ ]+)', line)) for line in h.complete_lines(d.log)
            if line.startswith('xodb: ' + kind + ' ')]

def latest(kind='galaxy-look'):
    found = rows(kind)
    return found[-1] if found else {}

def until(fn, name):
    deadline = time.monotonic() + 10 * h.load_scale()
    while time.monotonic() < deadline:
        if not d.alive():
            raise AssertionError(d.tail())
        row = latest()
        if row and fn(row):
            return row
        time.sleep(.01)
    raise AssertionError(name + ': ' + d.tail())

def pose(row):
    return tuple(float(row[k]) for k in ('zoom', 'shift_x', 'shift_y', 'rotation'))

def point(row):
    return tuple(float(row[k]) for k in ('x', 'y'))

def ready(proc):
    if not select.select([proc.stdout], [], [], 10 * h.load_scale())[0] or proc.stdout.readline() != b'ready\n':
        raise AssertionError('input barrier not reached')

def advance(proc):
    proc.stdin.write(b'\n')
    proc.stdin.flush()

def send(*commands):
    proc = d.keys(*commands, wait=False)
    if proc.wait(timeout=10 * h.load_scale()):
        raise AssertionError('private input failed')

def hold(code, condition):
    proc = subprocess.Popen([h.HELPER, str(d.width), str(d.height), 'layout', 'us', 'down', str(code),
                             'barrier', 'up', str(code), 'barrier'], env=d.env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    d.procs.append(proc)
    ready(proc)
    until(condition, 'held key moves camera')
    advance(proc)
    ready(proc)
    row = until(lambda r: r['camera'] == '0', 'released key settles')
    advance(proc)
    if proc.wait(timeout=10 * h.load_scale()):
        raise AssertionError('input helper failed')
    return row

def repaint(x, y):
    count = len(rows())
    send('m', x, y)
    return until(lambda r: len(rows()) > count, 'pointer repaint')

try:
    d = h.Display(str(root), ['--overview', '--galaxy-demo', '24:idle', '--galaxy-tour'],
                  stdio=False, trace=False, binary=a.binary, output_size=(1280, 800))
    touring = until(lambda r: r['tour'] == '1' and r['camera'] == '1', 'start option starts tour')
    check('start option requests a moving tour', touring['tour'] == '1')
    repaint(5, 5)
    stopped = until(lambda r: r['tour'] == '0' and r['camera'] == '0', 'pointer stops tour')
    check('pointer stops tour without an extra camera target', pose(stopped) == pose(repaint(6, 6)))
    # Keep a keyboard on the private seat: unplugging its last keyboard is a
    # real focus loss, which releases held keys and an empty-field drag.
    keeper = subprocess.Popen([h.HELPER, str(d.width), str(d.height), 'layout', 'us', 'barrier'],
                              env=d.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    d.procs.append(keeper)
    ready(keeper)
    send('tap', 102)  # Home.
    until(lambda r: pose(r) == (1, 0, 0, 0) and r['camera'] == '0', 'fit all')
    origin = latest()
    hovered = repaint(*map(round, point(latest('galaxy-pick'))))
    check('hover leaves the camera still', pose(hovered) == pose(origin) and hovered['camera'] == '0')
    count = len(rows())
    send('click', *map(round, point(latest('galaxy-pick'))))
    until(lambda r: len(rows()) > count and latest('galaxy-pick')['node'] != '0', 'select node')
    check('single click selects without framing', pose(latest()) == pose(origin) and latest()['camera'] == '0')
    send('tap', 102)
    until(lambda r: latest('galaxy-pick')['node'] == '0' and r['camera'] == '0', 'clear selection before transformed pick')
    held = hold(32, lambda r: float(r['shift_x']) < -30)  # D.
    check('held D pans and eases to rest', float(held['shift_x']) < -30)
    lowered = hold(31, lambda r: float(r['shift_y']) < -30)  # S pans here; it does not sort.
    check('held S pans down and eases to rest', float(lowered['shift_y']) < -30 and lowered['shift_x'] == held['shift_x'])
    turned = hold(52, lambda r: float(r['rotation']) > .08)  # Period.
    check('held period rotates and settles', float(turned['rotation']) > .08)
    back = hold(51, lambda r: float(r['rotation']) < float(turned['rotation']) - .04)  # Comma.
    check('held comma rotates the other way', float(back['rotation']) < float(turned['rotation']) - .04)
    anchor = latest('galaxy-pick')
    pointer = tuple(map(round, point(anchor)))
    old = pose(latest())
    send('scroll', *pointer, -1)
    until(lambda r: float(r['zoom']) > old[0] and r['camera'] == '0', 'wheel zoom')
    after = latest('galaxy-pick')
    check('wheel keeps the pointed star under the pointer', math.dist(point(anchor), point(after)) < 1)
    repaint(*map(round, point(after)))
    picked = latest('galaxy-pick')
    check('transformed hover hits the drawn anchor', picked['hovered'] == picked['anchor'])
    send('click', *map(round, point(picked)))
    until(lambda r: latest('galaxy-pick')['node'] == picked['anchor'], 'transformed selection')
    check('pick after pan rotation and zoom selects the highlighted node', latest('galaxy-pick')['node'] == picked['hovered'])
    d.shot('navigation')
    still = pose(latest())
    # A double click is two presses inside the UI's interval; a loaded host
    # may stretch one injected pair past it, so a missed pair is repeated.
    for attempt in range(4):
        send('fastclick', *map(round, point(picked)), 'fastclick', *map(round, point(picked)))
        time.sleep(.2)
        if pose(latest()) != still:
            break
    framed = until(lambda r: pose(r) != still and r['camera'] == '0', 'double-click frame')
    centre = point(latest('galaxy-pick'))
    check('double-click eases the star to the field centre', float(framed['zoom']) >= still[0] and math.dist(centre, point(picked)) > 20)
    send('tap', 106)  # Right: explicit carousel frame.
    until(lambda r: latest('galaxy-pick')['cluster'] != '0' and r['camera'] == '0', 'carousel frame')
    first = latest('galaxy-pick')['cluster']
    send('tap', 106)
    until(lambda r: latest('galaxy-pick')['cluster'] != first and r['camera'] == '0', 'next cluster')
    send('tap', 105)
    until(lambda r: latest('galaxy-pick')['cluster'] == first and r['camera'] == '0', 'previous cluster')
    check('carousel left reverses right in stable order', latest('galaxy-pick')['cluster'] == first)
    d.shot('carousel')
    send('tap', 35)  # H fits and clears rotation.
    until(lambda r: pose(r) == (1, 0, 0, 0) and r['camera'] == '0', 'H fit')
    # Top-left field is empty in the deterministic fixture.
    x, y = (round(float(latest()[key])) + 6 for key in ('field_x', 'field_y'))
    send('m', x, y, 'button', 272, 1, 'm', x + 40, y + 20, 'button', 272, 0)
    dragged = until(lambda r: float(r['shift_x']) == 40 and r['camera'] == '0', 'empty drag')
    check('drag pans without zoom or rotation', pose(dragged) == (1, 40, 20, 0))
    count = len(rows())
    for i in range(3):
        repaint(8 + i, 8)
    check('settled input requests only repaint frames', len(rows()) - count <= 6 and pose(latest()) == pose(dragged))
    send('tap', 24)  # O tour, Q still quits.
    until(lambda r: r['tour'] == '1', 'O tour')
    d.shot('tour')
    send('tap', 16)
    d.app.wait(timeout=10 * h.load_scale())
    check('Q still exits the touring galaxy', d.app.returncode == 0)
finally:
    if d:
        d.close()
    report['seconds'] = time.monotonic() - started
    (work / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
print('galaxy camera GUI checks PASS')
