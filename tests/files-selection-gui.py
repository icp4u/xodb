#!/usr/bin/env python3
"""Files & IO selection and scroll survive 1 Hz re-sorting publications.

An owned workload holds 40 descriptors whose offset progress re-ranks every
second (lseek only, no disk IO); one leading descriptor always sorts first.
Only private headless Sway is used. Evidence stays in .work.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('input-files-select-' + str(time.time_ns())[-8:])
work.mkdir(parents=True)
for name in ('tmp', 'cache', 'churn'):
    (work / name).mkdir()
spec = importlib.util.spec_from_file_location('files_select_input', root / 'tests/helpers/input.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
h.WORK = str(work)
for xml, stem in ((h.VPTR, 'virtual-pointer'), (h.VKBD, 'virtual-keyboard')):
    subprocess.run(['wayland-scanner', 'client-header', xml, str(work / (stem + '.h'))], check=True)
    subprocess.run(['wayland-scanner', 'private-code', xml, str(work / (stem + '.c'))], check=True)
h.HELPER = str(work / 'vinput')
subprocess.run(['cc', '-I', str(work), 'tests/helpers/vinput.c', str(work / 'virtual-pointer.c'), str(work / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', h.HELPER], check=True)

CHURN = r'''
import os, random, sys, time
fds = [os.open(os.path.join(sys.argv[1], 'f%02d' % i), os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644) for i in range(40)]
print('ready', flush=True)
rng = random.Random(7)
order = list(range(1, len(fds)))
while True:
    rng.shuffle(order)
    end = time.monotonic() + 1
    while time.monotonic() < end:
        os.lseek(fds[0], 1 << 26, os.SEEK_CUR)
        for rank, i in enumerate(order): os.lseek(fds[i], (rank + 1) << 14, os.SEEK_CUR)
        time.sleep(.05)
'''
results = []
d = churn = None

def check(label, ok, fatal=True):
    results.append(dict(check=label, status='pass' if ok else 'fail'))
    print(('PASS ' if ok else 'FAIL ') + label, flush=True)
    assert ok or not fatal, label

def ticks(pid): return int(Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19])
FIELDS = r'files collector opens=\d+ sequence=(\d+) filter_pid=\d+ start=\d+ rows=(\d+) mode=\w+ selected_pid=(-?\d+) selected_fd=(-?\d+) row=(\d+) top=(\d+) visible=(\d+)'
def samples():
    return [tuple(map(int, m)) for m in re.findall(FIELDS, Path(d.log).read_text(errors='replace'))]

def until(predicate, label, seconds=25):
    end = time.monotonic() + seconds
    while True:
        value = samples()
        if predicate(value): return value
        assert time.monotonic() < end, (label, value[-3:])
        time.sleep(.05)

def after(count, label):
    """The next `count` publications that follow the current one."""
    start = len(samples())
    return until(lambda value: len(value) >= start + count, label)[start:start + count]

os.environ['XODB_OVERVIEW_AUDIT'] = '1'
try:
    churn = subprocess.Popen([sys.executable, '-c', CHURN, str(work / 'churn')], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True)
    assert select.select([churn.stdout], [], [], 5)[0] and churn.stdout.readline().strip() == 'ready'
    d = h.Display(str(root), ['--overview', '--files-pid', str(churn.pid), '--files-start-ticks', str(ticks(churn.pid)), '--interval-ms', '1000'], trace=False, output_size=(1280, 900))
    # Offsets need a few samples before progress is measured and rows re-rank.
    first = until(lambda value: len(value) >= 7 and value[-1][1] >= 40, 'measured churn rows')[-1]
    rows, visible = first[1], first[6]
    check('owned churn workload fills more rows than fit', rows >= 40 and visible < rows)
    # Nothing is picked yet: re-ranking must not move the view by itself.
    check('unpicked view stays at the top while rows re-rank', all(s[5] == 0 for s in samples()), fatal=False)
    # The user's report: pick a row near the top, scroll the list away from
    # it, and the next 1 Hz publications must not pull the view back up.
    d.keys(*['tap', 103] * 48) # Up to the first row
    leader = after(1, 'publication after Up')[0]
    check('keys pick the first row', leader[4] == 0 and leader[5] == 0)
    d.keys('scroll', 640, 760, 6)
    scrolled = after(1, 'publication after scroll')[0]
    check('wheel scroll is still in place after the next refresh', scrolled[5] > 0)
    held = after(4, 'publications after scroll')
    check('scroll is unchanged across 4 re-sorting refreshes', all(s[5] == scrolled[5] for s in held))
    check('picked identity is kept while scrolled away from it', all(s[2:4] == leader[2:4] for s in held))
    # Click a row on screen: it is selected by identity and stays selected.
    for y in (700, 712, 690):
        d.keys('click', 640, y)
        picked = after(1, 'publication after click')[0]
        if picked[2:4] != leader[2:4]: break
    check('click selects an on-screen descriptor', picked[2:4] != leader[2:4] and picked[5] <= picked[4] < picked[5] + picked[6])
    held = after(4, 'publications after click')
    check('clicked identity stays selected across 4 refreshes', all(s[2:4] == picked[2:4] for s in held))
    prior = picked
    minimal = True
    for s in held:
        top, row, seen = s[5], s[4], s[6]
        # The view keeps its place unless the selected row would leave it,
        # and then moves just far enough to keep that row on its edge.
        minimal = minimal and (top == prior[5] or row == top or row == top + seen - 1) and top <= row < top + seen
        prior = s
    check('scroll moves only minimally to keep the selected row visible', minimal)
    check('rows re-sorted under the selection', len({s[4] for s in held} | {picked[4]}) > 1)
    check('workload and GUI still alive', churn.poll() is None and d.alive())
finally:
    if d: d.close()
    if churn and churn.poll() is None:
        churn.terminate()
        try: churn.wait(timeout=5)
        except subprocess.TimeoutExpired: churn.kill(); churn.wait()
    (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
passed = sum(r['status'] == 'pass' for r in results)
print(f'Files selection GUI: {passed}/{len(results)} passed; {work}', flush=True)
sys.exit(passed != len(results))
