#!/usr/bin/env python3
"""Fast private GUI lane: held-time movement, repeat independence and focus loss."""
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

p = argparse.ArgumentParser()
p.add_argument('--wrong-result', action='store_true')
p.add_argument('--wrong-idle-result', action='store_true')
p.add_argument('--binary')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-cm' + str(time.time_ns())[-5:])
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
                str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-o', h.HELPER], check=True)
base, replay = work / 'base.jsonl', work / 'replay.jsonl'
subprocess.run(['python3', '-B', 'tests/fixtures/overview-synth.py', str(base), '--frames', '3'], check=True)
subprocess.run(['python3', '-B', 'tests/fixtures/memmap-synth.py', str(base), str(replay)], check=True)
os.environ['XODB_OVERVIEW_LAYOUT'] = '1'
started = time.monotonic()
report = {'checks': [], 'load': os.getloadavg(), 'cpus': len(os.sched_getaffinity(0))}
d = None

def check(name, ok):
    if not ok:
        raise AssertionError(name + ': ' + d.tail())
    report['checks'].append(name)
    print('PASS ' + name, flush=True)

def rows(prefix='xodb: gibson frame='):
    return [dict(re.findall(r'(\w+)=([^ ]+)', line)) for line in h.complete_lines(d.log) if line.startswith(prefix)]

def latest():
    found = rows()
    return found[-1] if found else {}

def until(fn, name, seconds=10):
    deadline = time.monotonic() + seconds * h.load_scale()
    while time.monotonic() < deadline:
        if not d.alive():
            raise AssertionError(d.tail())
        row = latest()
        if row and fn(row):
            return row
        time.sleep(.01)
    raise AssertionError(name + ': ' + d.tail())

def send(*cmd):
    proc = d.keys(*cmd, wait=False)
    if proc.wait(timeout=10 * h.load_scale()):
        raise AssertionError('private input failed')

def sway(command):
    subprocess.run(['swaymsg', '-t', 'command', command], env=d.env, check=True,
                   stdout=subprocess.DEVNULL, timeout=10 * h.load_scale())

def ready(proc):
    if not select.select([proc.stdout], [], [], 10 * h.load_scale())[0] or proc.stdout.readline() != b'ready\n':
        raise AssertionError('input barrier was not reached')

def advance(proc):
    proc.stdin.write(b'\n')
    proc.stdin.flush()

def press(codes, rate):
    sway(f'input * repeat_rate {rate}')
    sway('input * repeat_delay 0')
    script = ['layout', 'us']
    for code in codes:
        script += ['down', str(code)]
    script += ['barrier']
    for code in codes:
        script += ['up', str(code)]
    script += ['barrier']
    proc = subprocess.Popen([h.HELPER, str(d.width), str(d.height), *script], env=d.env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    d.procs.append(proc)
    ready(proc)
    first = until(lambda r: r['moving'] == 'true' and r['auto'] == 'false', 'held movement')
    return proc, first

def release(proc):
    advance(proc)
    ready(proc)
    settled = until(lambda r: r['moving'] == 'false', 'release settles')
    advance(proc)
    if proc.wait(timeout=10 * h.load_scale()):
        raise AssertionError('input helper failed')
    return settled

def pan(row):
    return (float(row['pan_x']), float(row['pan_z']))

def usage():
    fields = Path(f'/proc/{d.app.pid}/stat').read_text().rsplit(')', 1)[1].split()
    return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),
                rss_bytes=int(fields[21])*os.sysconf('SC_PAGE_SIZE'))

def travel(codes, rate, duration):
    proc, first = press(codes, rate)
    start = until(lambda r: int(r['now']) - int(first['now']) >= 300_000_000, 'easing reaches cruise')
    end = until(lambda r: int(r['now']) - int(start['now']) >= duration and int(r['frame']) >= int(start['frame']) + 8, 'held frames')
    distance = math.dist(pan(start), pan(end))
    seconds = (int(end['now']) - int(start['now'])) / 1e9
    stopped = release(proc)
    send('m', 5, 5, 'm', 6, 6)
    check('released keys stay stopped', pan(latest()) == pan(stopped))
    return dict(keys=codes, repeat_rate=rate, frames=int(end['frame'])-int(start['frame']), seconds=seconds,
                distance=distance, speed=distance/seconds)

try:
    d = h.Display(str(root), ['--overview', '--look', 'gibson', '--panel', 'memory_map', '--pause',
                  '--replay', str(replay)], stdio=False, trace=True, binary=a.binary, output_size=(1280,720))
    keeper = subprocess.Popen([h.HELPER, str(d.width), str(d.height), 'layout', 'us', 'barrier'],
                              env=d.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    d.procs.append(keeper)
    ready(keeper)
    until(lambda r: int(r['towers']) > 0, 'city populated')
    report['before_motion'] = usage()
    zero = travel([17], 0, 250_000_000)
    fast = travel([17], 120, 500_000_000)
    diagonal = travel([17, 32], 0, 250_000_000)
    report['motion'] = [zero, fast, diagonal]
    report['after_motion'] = usage()
    check('distance follows held time independently of key repeat', abs(fast['speed']/zero['speed'] - (2 if a.wrong_result else 1)) < .05)
    check('longer hold advances proportionally', fast['seconds'] > zero['seconds'] * 1.4 and abs(fast['distance']/zero['distance'] - fast['seconds']/zero['seconds']) < .1)
    check('W and D combine', abs(diagonal['speed']/zero['speed'] - math.sqrt(2)) < .05)
    proc, first = press([17, 32], 0)
    until(lambda r: int(r['frame']) > int(first['frame']) + 3, 'movement before focus loss')
    sway('workspace number 2')
    deadline = time.monotonic() + 10 * h.load_scale()
    while time.monotonic() < deadline and not (rows('xodb: gibson input ') and rows('xodb: gibson input ')[-1]['focused'] == 'false'):
        time.sleep(.01)
    focus = rows('xodb: gibson input ')[-1]
    check('compositor focus loss reached the camera', focus['focused'] == 'false')
    sway('workspace number 1')
    after = until(lambda r: r['focused'] == 'true' and int(r['now']) > int(focus['now']), 'focus restored')
    check('focus loss cancels movement immediately', pan(after) == pan(focus) and after['moving'] == 'false')
    release(proc)
    send('m', 7, 7, 'm', 8, 8)
    check('focus return does not resurrect held keys', pan(latest()) == pan(focus))
    send('tap', 19)  # reset and start a bounded flythrough
    orbit = until(lambda r: r['auto'] == 'true', 'auto orbit starts')
    initial_deadline = int(orbit['auto_until'])
    until(lambda r: int(r['now']) >= initial_deadline - 4_000_000_000, 'interaction after view start')
    send('tap', 35)  # H changes the height encoding, without taking manual control.
    changed = until(lambda r: r['height'] != orbit['height'], 'height interaction reached the view')
    check('interaction renews the orbit deadline', (int(changed['auto_until']) == initial_deadline) if a.wrong_idle_result else (int(changed['auto_until']) > initial_deadline))
    orbit = changed
    report['idle_deadlines'] = dict(initial=initial_deadline, renewed=int(orbit['auto_until']))
    deadline = time.monotonic() + 8 * h.load_scale()
    while time.monotonic() < deadline and time.monotonic_ns() < int(orbit['auto_until']) + 100_000_000:
        time.sleep(.02)
    send('m', 9, 9)
    idle = until(lambda r: r['auto'] == 'false' and r['moving'] == 'false', 'idle orbit stops')
    report['idle_before'] = usage()
    before = len(rows())
    send('m', 10, 10, 'm', 11, 11)
    check('idle orbit preserves its final pose', all(latest()[k] == idle[k] for k in ('yaw','pitch','zoom','pan_x','pan_z')))
    check('idle camera renders only requested repaints', len(rows()) - before <= 3)
    report['idle_after'] = usage()
    send('m', int(float(idle['x']) + float(idle['w']) / 2), int(float(idle['y']) + float(idle['h']) / 2))
    resumed = until(lambda r: r['auto'] == 'true' and int(r['auto_until']) > int(orbit['auto_until']) and r['yaw'] != idle['yaw'], 'pointer resumes idle orbit')
    check('pointer interaction resumes paused auto mode', int(resumed['auto_until']) > int(orbit['auto_until']))
    send('tap', 33)  # F explicitly disables the running orbit.
    disabled = until(lambda r: r['auto'] == 'false' and r['moving'] == 'false', 'explicit orbit off')
    send('tap', 35)
    manual = until(lambda r: r['height'] != disabled['height'], 'interaction after explicit orbit off')
    check('interaction preserves explicit manual mode', manual['auto'] == 'false' and manual['moving'] == 'false')
finally:
    if d:
        d.close()
    report['seconds'] = time.monotonic() - started
    (work/'results.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(dict(passed=len(report['checks']), seconds=report['seconds'], work=str(work))))
