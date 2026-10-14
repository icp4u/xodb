#!/usr/bin/env python3
"""Fast private GUI lane: documented live PID startup, route and film preset."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-gfl' + str(time.time_ns())[-5:])
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
fixture_code = '''
import mmap,os,sys
maps=[]
for i in range(8):
    fd=os.memfd_create('avenue-%02d'%i)
    os.ftruncate(fd,8*1024*1024)
    m=mmap.mmap(fd,8*1024*1024)
    os.close(fd)
    m.write(b'x'*(8*1024*1024))
    maps.append(m)
print('ready',flush=True)
sys.stdin.readline()
'''
fixture = subprocess.Popen([sys.executable, '-c', fixture_code], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
d = None
report = {'checks': [], 'load': os.getloadavg(), 'cpus': len(os.sched_getaffinity(0))}
started = time.monotonic()
os.environ['XODB_OVERVIEW_LAYOUT'] = '1'
def rows(kind):
    return [dict(re.findall(r'(\w+)=([^ ]+)', line)) for line in h.complete_lines(d.log) if line.startswith('xodb: ' + kind + ' ')]
def until(fn):
    deadline = time.monotonic() + 12 * h.load_scale()
    while not fn():
        assert d.alive() and time.monotonic() < deadline, d.tail()
        time.sleep(.01)
def check(name, ok):
    assert ok, name + ': ' + d.tail()
    report['checks'].append(name)
    print('PASS ' + name, flush=True)
def usage():
    stat = Path('/proc', str(d.app.pid), 'stat').read_text().rsplit(')', 1)[1].split()
    return dict(cpu_seconds=(int(stat[11]) + int(stat[12])) / os.sysconf('SC_CLK_TCK'), rss_bytes=int(stat[21]) * os.sysconf('SC_PAGE_SIZE'))
try:
    assert select.select([fixture.stdout], [], [], 10)[0] and fixture.stdout.readline() == b'ready\n', 'owned mapping fixture failed'
    d = h.Display.__new__(h.Display)
    h.Display.__init__(d, str(root), ['--overview', '--gibson-flight', '--memmap-pid', str(fixture.pid)], stdio=False, trace=False, binary=a.binary, output_size=(1280, 720))
    keeper = subprocess.Popen([h.HELPER, str(d.width), str(d.height), 'layout', 'us', 'barrier'], env=d.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    d.procs.append(keeper)
    assert select.select([keeper.stdout], [], [], 10 * h.load_scale())[0] and keeper.stdout.readline() == b'ready\n'
    until(lambda: rows('gibson-flight') and rows('gibson-flight')[-1]['on'] == 'true' and int(rows('gibson-flight')[-1]['corners']) > 0)
    check('live --gibson-flight --memmap-pid survives target preparation', rows('gibson-flight')[-1]['automatic'] == 'true')
    check('first avenue has towers on both sides', int(rows('gibson-route')[-1]['two_sided']) > 0)
    first = int(rows('gibson-route')[-1]['visit'])
    report['normal'] = usage()
    d.shot('normal-street')
    d.keys('tap', 47)
    until(lambda: rows('gibson-route')[-1]['film'] == 'true' and float(rows('gibson-flight')[-1]['speed']) > 3)
    check('film preset accelerates without taking manual steering', rows('gibson-flight')[-1]['automatic'] == 'true')
    until(lambda: int(rows('gibson-route')[-1]['visit']) > first)
    check('auto route leaves its first district', True)
    until(lambda: int(rows('gibson-flight')[-1]['faces']) > 0)
    check('near street names are drawn with subordinate facts', rows('gibson-route')[-1]['street_names'] == 'true' and float(rows('gibson-route')[-1]['facts_alpha']) < 0.5)
    d.shot('film-street')
    report['film'] = usage()
    report['path'] = rows('gibson-flight')
    report['routes'] = rows('gibson-route')
    d.keys('tap', 47)
    until(lambda: rows('gibson-route')[-1]['film'] == 'false')
    check('V returns to the calm preset', float(rows('gibson-route')[-1]['cruise']) == 1.5)
    d.keys('tap', 33)
    until(lambda: rows('gibson-flight')[-1]['on'] == 'false' and rows('gibson-flight')[-1]['returning'] == 'false')
    check('F still returns to the saved camera', True)
finally:
    if d:
        d.close()
    try:
        fixture.communicate(b'\n', timeout=5)
    except subprocess.TimeoutExpired:
        fixture.kill()
        fixture.communicate()
    report['seconds'] = time.monotonic() - started
    (work / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
