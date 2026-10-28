#!/usr/bin/env python3
"""Fast GUI lane: owned live fork/exit scope, finite easing and retained cloud.

Reports CPU/RSS rather than gating on timing-sensitive performance numbers.
--observe keeps baseline failures as evidence without stopping measurement.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work-dir', type=Path, required=True)
p.add_argument('--binary', type=Path)
p.add_argument('--observe', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = a.work_dir.resolve() / '.work/input-churn'
work.mkdir(parents=True)
for name in ('tmp', 'cache'):
    (work / name).mkdir()
spec = importlib.util.spec_from_file_location('churn_input', root / 'tests/helpers/input.py')
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
import os, sys, json
children=[]
for i in range(16):
    rd,wr=os.pipe()
    pid=os.fork()
    if pid==0:
        os.close(wr)
        for _,old in children: os.close(old)
        os.read(rd,1)
        os._exit(0)
    os.close(rd); children.append((pid,wr))
print(json.dumps([pid for pid,_ in children]),flush=True)
for line in sys.stdin:
    if line.strip()=='exit':
        pid,wr=children.pop(); os.close(wr); os.waitpid(pid,0)
        print(len(children),flush=True)
for pid,wr in children: os.close(wr)
for pid,_ in children: os.waitpid(pid,0)
'''
fixture = subprocess.Popen([sys.executable, '-c', fixture_code], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
d = None
checks = []
report = {'load': os.getloadavg(), 'cpus': os.cpu_count()}
def check(name, value):
    checks.append({'check': name, 'pass': bool(value)})
    print(('PASS ' if value else 'FAIL ') + name, flush=True)
def text():
    return Path(d.log).read_text(errors='replace')
def rows(kind):
    return [dict(pair.split('=') for pair in line.split())
            for line in re.findall(r'galaxy-' + kind + r' (.*)', text())]
def until(fn):
    deadline = time.monotonic() + 20 * h.load_scale()
    while not fn():
        assert d.alive() and time.monotonic() < deadline, text()[-3000:]
        time.sleep(.02)
def usage():
    fields = Path(f'/proc/{d.app.pid}/stat').read_text().split(') ', 1)[1].split()
    return {'cpu': (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK'),
            'rss': int(fields[21]) * os.sysconf('SC_PAGE_SIZE')}
def begin():
    return time.monotonic(), usage(), len(rows('frame')), int(rows('look')[-1]['builds'])
def finish(start):
    elapsed = time.monotonic() - start[0]
    end = usage()
    return {'seconds': elapsed, 'frames': len(rows('frame')) - start[2],
            'builds': int(rows('look')[-1]['builds']) - start[3],
            'fps': (len(rows('frame')) - start[2]) / elapsed,
            'one_core_percent': 100 * (end['cpu'] - start[1]['cpu']) / elapsed,
            'rss_before': start[1]['rss'], 'rss_after': end['rss']}
try:
    pids = json.loads(fixture.stdout.readline())
    os.environ['XODB_OVERVIEW_AUDIT'] = '1'
    options = ['--overview', '--panel', 'galaxy', '--redact', '--interval-ms', '500']
    for pid in pids:
        options += ['--graph-pid', str(pid)]
    d = h.Display(str(root), options, trace=False, stdio=False,
                  binary=str(a.binary.resolve()) if a.binary else None)
    until(lambda: rows('frame') and rows('frame')[-1]['stars'] == '16')
    until(lambda: rows('frame')[-1]['moving'] == '0')
    start = begin()
    # Long enough that one late frame does not move the measured quiet rate much.
    until(lambda: time.monotonic() - start[0] >= 3)
    report['quiet'] = finish(start)
    check('quiet owned scope requests no animation', all(f['moving'] == '0' for f in rows('frame')[start[2]:]))
    start = begin()
    observed = []
    for remaining in range(15, 9, -1):
        fixture.stdin.write('exit\n'); fixture.stdin.flush()
        assert int(fixture.stdout.readline()) == remaining
        until(lambda: rows('frame')[-1]['stars'] == str(remaining))
        observed.append(remaining)
    # Include the final transition, not just its first frame.
    until(lambda: rows('frame')[-1]['moving'] == '0')
    report['busy'] = finish(start)
    check('live collector observed every forked child exit', observed == [15, 14, 13, 12, 11, 10])
    # Ordinary poll/header frames continue even when no membership changed.
    # Bound additional work relative to that measured quiet rate, not to just
    # the six publications whose membership changed.
    ordinary = report['quiet']['fps'] * report['busy']['seconds']
    # A changed publication adds a moving and a settled frame; one more each
    # covers the poll phase shifting against the quiet estimate.
    check('churn has bounded frames beyond quiet polling', report['busy']['frames'] <= ordinary + len(observed) * 3 + 4)
    moving = sum(f['moving'] == '1' for f in rows('frame')[start[2]:])
    allowance = len(observed) * 2
    report['moving_frames'] = moving
    report['moving_allowance'] = allowance
    print(f'moving frames {moving} / allowance {allowance}', flush=True)
    if moving + 2 >= allowance:
        print(f'WARN moving frames {moving} / allowance {allowance} are near the limit', flush=True)
    check('at most two moving frames per changed publication', moving <= allowance)
    check('cloud rebuilds are bounded by publications, not eased frames', report['busy']['builds'] <= len(observed) + 2)
    check('no unmeasured traffic impulses', all(f['impulses'] == '0' for f in rows('frame')))
    check('application remains healthy', d.alive() and 'panic' not in text() and 'frame failed' not in text())
finally:
    if d:
        d.close()
    fixture.stdin.close()
    fixture.wait(timeout=10)
    report['checks'] = checks
    (work / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
if not a.observe and not all(c['pass'] for c in checks):
    raise SystemExit(1)
